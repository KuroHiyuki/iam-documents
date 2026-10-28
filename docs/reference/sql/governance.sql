-- PostgreSQL 18. Chỉ chạy trong database governance bằng migration owner.
-- Không có foreign key hay quyền SELECT sang database Identity/Authorization.
BEGIN;

CREATE TABLE access_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  requester_id uuid NOT NULL,
  subject_id uuid NOT NULL,
  role_id uuid NOT NULL,
  reason text NOT NULL CHECK (length(reason) BETWEEN 10 AND 2000),
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','approved','rejected','activating','active','expired','cancelled','failed')),
  requested_until timestamptz NOT NULL,
  approved_until timestamptz,
  assignment_id uuid,
  revision bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (id, org_id, requester_id),
  CHECK (requested_until > created_at),
  CHECK (approved_until IS NULL OR approved_until <= requested_until)
);
CREATE INDEX access_requests_org_state ON access_requests (org_id, state, created_at);

CREATE TABLE approval_votes (
  request_id uuid NOT NULL,
  org_id uuid NOT NULL,
  requester_id uuid NOT NULL,
  approver_id uuid NOT NULL,
  decision text NOT NULL CHECK (decision IN ('approve','reject')),
  comment text NOT NULL CHECK (length(comment) BETWEEN 1 AND 2000),
  decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (request_id, approver_id),
  FOREIGN KEY (request_id, org_id, requester_id)
    REFERENCES access_requests (id, org_id, requester_id),
  CHECK (approver_id <> requester_id)
);

CREATE TABLE governance_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  request_id uuid REFERENCES access_requests(id),
  target_owner text NOT NULL CHECK (target_owner IN ('identity','authorization')),
  kind text NOT NULL CHECK (kind IN ('membership.status','grant.create','grant.revoke','scim.user','scim.group')),
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','running','succeeded','retry','failed')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_until timestamptz,
  result jsonb,
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz
);
CREATE INDEX governance_operations_due
  ON governance_operations (available_at) WHERE state IN ('pending','retry','running');

CREATE TABLE access_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  title text NOT NULL,
  reviewer_id uuid NOT NULL,
  state text NOT NULL DEFAULT 'open' CHECK (state IN ('open','closing','closed')),
  due_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (id, org_id)
);
CREATE TABLE access_review_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id uuid NOT NULL,
  org_id uuid NOT NULL,
  assignment_id uuid NOT NULL,
  observed_revision bigint NOT NULL,
  subject_id text NOT NULL,
  role_id uuid NOT NULL,
  decision text CHECK (decision IN ('retain','revoke')),
  decided_by uuid,
  decided_at timestamptz,
  operation_id uuid REFERENCES governance_operations(id),
  FOREIGN KEY (review_id, org_id) REFERENCES access_reviews(id, org_id),
  UNIQUE (review_id, assignment_id)
);

CREATE TABLE scim_integrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL,
  client_id text NOT NULL UNIQUE,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (id, org_id)
);
-- Authoritative SCIM documents/version nằm ở Identity.provisioned_resources.
-- Bảng sau chỉ giữ request/receipt để retry; không trả active state từ journal.
CREATE TABLE scim_mutations (
  integration_id uuid NOT NULL,
  resource_id uuid NOT NULL,
  org_id uuid NOT NULL,
  expected_version bigint NOT NULL,
  operation_id uuid NOT NULL UNIQUE REFERENCES governance_operations(id),
  request_payload jsonb NOT NULL,
  response jsonb,
  completed_at timestamptz,
  PRIMARY KEY (integration_id, resource_id, expected_version),
  FOREIGN KEY (integration_id, org_id) REFERENCES scim_integrations(id, org_id)
);

CREATE TABLE outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text NOT NULL,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  aggregate_id text NOT NULL,
  aggregate_version bigint NOT NULL,
  org_id uuid NOT NULL,
  actor jsonb NOT NULL,
  correlation_id uuid NOT NULL,
  data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  published_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_owner uuid,
  lease_until timestamptz
);
CREATE INDEX governance_outbox_pending ON outbox(available_at, created_at) WHERE published_at IS NULL;

-- RLS là defense in depth; app role không là table owner và không có BYPASSRLS.
ALTER TABLE access_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE access_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE access_review_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE scim_integrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE scim_mutations ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_access_requests ON access_requests
  USING (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
CREATE POLICY tenant_votes ON approval_votes
  USING (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
CREATE POLICY tenant_reviews ON access_reviews
  USING (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
CREATE POLICY tenant_review_items ON access_review_items
  USING (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
CREATE POLICY tenant_integrations ON scim_integrations
  USING (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);
CREATE POLICY tenant_scim_mutations ON scim_mutations
  USING (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid)
  WITH CHECK (org_id = NULLIF(current_setting('app.org_id', true), '')::uuid);

-- Worker dùng role chuyên biệt, chỉ được cấp các bảng queue/outbox cần thiết.
-- Người học tạo roles và GRANT riêng trong migration quyền; không dùng owner cho API.
COMMIT;
