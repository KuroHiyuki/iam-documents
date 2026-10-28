-- Chỉ chạy trong DATABASE authorization bằng migration credential.
-- Không có foreign key xuyên database Identity. Identity vẫn là nguồn membership sống.
BEGIN;
CREATE TABLE resource_types (
  name text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_-]{0,63}$'),
  owner_client_id text NOT NULL,
  attributes_schema jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE permissions (
  key text PRIMARY KEY,
  resource_type text NOT NULL REFERENCES resource_types(name),
  description text NOT NULL,
  CHECK (key ~ '^[a-z][a-z0-9_-]*\.[a-z][a-z0-9_-]*$')
);
CREATE TABLE resource_owners (
  resource_type text NOT NULL REFERENCES resource_types(name),
  org_id uuid NOT NULL,
  client_id text NOT NULL,
  subject_audience text NOT NULL,
  PRIMARY KEY(resource_type,org_id,client_id)
);
CREATE TABLE policy_versions (
  org_id uuid PRIMARY KEY,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0)
);
CREATE TABLE roles (
  org_id uuid NOT NULL,
  id uuid NOT NULL,
  name text NOT NULL,
  system_managed boolean NOT NULL DEFAULT false,
  PRIMARY KEY (org_id,id), UNIQUE (org_id,name)
);
CREATE TABLE role_permissions (
  org_id uuid NOT NULL,
  role_id uuid NOT NULL,
  permission_key text NOT NULL REFERENCES permissions(key),
  PRIMARY KEY (org_id,role_id,permission_key),
  FOREIGN KEY (org_id,role_id) REFERENCES roles(org_id,id) ON DELETE CASCADE
);
CREATE TABLE role_assignments (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL,
  subject_type text NOT NULL CHECK (subject_type IN ('user','group','client')),
  subject_id text NOT NULL,
  role_id uuid NOT NULL,
  scope_type text NOT NULL CHECK (scope_type IN ('organization','resource')),
  resource_type text NOT NULL REFERENCES resource_types(name),
  resource_id text,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_until timestamptz,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  revoked_at timestamptz,
  operation_id uuid UNIQUE,
  created_by text NOT NULL,
  FOREIGN KEY (org_id,role_id) REFERENCES roles(org_id,id),
  CHECK ((scope_type='organization' AND resource_id IS NULL) OR
         (scope_type='resource' AND resource_id IS NOT NULL)),
  CHECK (valid_until IS NULL OR valid_until > valid_from),
  CHECK ((status='active' AND revoked_at IS NULL) OR (status='revoked' AND revoked_at IS NOT NULL))
);
CREATE INDEX role_assignment_lookup ON role_assignments(org_id,subject_type,subject_id)
  WHERE status='active';
CREATE TABLE policy_rules (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL,
  effect text NOT NULL CHECK (effect IN ('allow','deny')),
  action text NOT NULL REFERENCES permissions(key),
  resource_type text NOT NULL REFERENCES resource_types(name),
  resource_id text,
  subject_type text NOT NULL CHECK (subject_type IN ('any','user','group','client')),
  subject_id text,
  condition jsonb NOT NULL DEFAULT '{"all":[]}'::jsonb,
  enabled boolean NOT NULL DEFAULT true,
  CHECK ((subject_type='any' AND subject_id IS NULL) OR
         (subject_type<>'any' AND subject_id IS NOT NULL))
);
CREATE INDEX policy_rules_lookup ON policy_rules(org_id,action,resource_type) WHERE enabled;
CREATE TABLE policy_constraints (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL,
  action text NOT NULL REFERENCES permissions(key),
  resource_type text NOT NULL REFERENCES resource_types(name),
  condition jsonb NOT NULL,
  enabled boolean NOT NULL DEFAULT true
);
CREATE TABLE relation_tuples (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL,
  resource_type text NOT NULL REFERENCES resource_types(name),
  resource_id text NOT NULL,
  relation text NOT NULL CHECK (relation IN ('owner','editor','viewer','parent')),
  subject_kind text NOT NULL CHECK (subject_kind IN ('user','group','object')),
  subject_id text NOT NULL,
  subject_namespace text,
  subject_relation text,
  CHECK ((subject_kind='object' AND subject_namespace IS NOT NULL AND subject_relation IS NOT NULL)
      OR (subject_kind<>'object' AND subject_namespace IS NULL AND subject_relation IS NULL)),
  UNIQUE NULLS NOT DISTINCT
    (org_id,resource_type,resource_id,relation,subject_kind,subject_id,subject_namespace,subject_relation)
);
CREATE INDEX relation_lookup ON relation_tuples(org_id,resource_type,resource_id,relation);
CREATE TABLE operation_results (
  org_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  request_hash bytea NOT NULL CHECK (octet_length(request_hash)=32),
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id,operation_id)
);
CREATE TABLE outbox (
  id uuid PRIMARY KEY,
  type text NOT NULL,
  version integer NOT NULL DEFAULT 1 CHECK (version>0),
  aggregate_id text NOT NULL,
  aggregate_version bigint NOT NULL,
  org_id uuid,
  actor jsonb NOT NULL,
  correlation_id uuid NOT NULL,
  data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  available_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0,
  lease_owner uuid,
  lease_until timestamptz,
  UNIQUE (aggregate_id,aggregate_version,type)
);
CREATE INDEX outbox_pending ON outbox(available_at,created_at) WHERE published_at IS NULL;
INSERT INTO resource_types(name,owner_client_id) VALUES ('invoice','invoice-api');
INSERT INTO resource_owners(resource_type,org_id,client_id,subject_audience) VALUES
 ('invoice','10000000-0000-4000-8000-000000000001','invoice-api','invoice-api');
INSERT INTO permissions(key,resource_type,description) VALUES
 ('invoice.read','invoice','Đọc hóa đơn'),
 ('invoice.approve','invoice','Duyệt hóa đơn');
INSERT INTO policy_versions(org_id) VALUES
 ('10000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002');
INSERT INTO roles(org_id,id,name) VALUES
 ('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','InvoiceReader'),
 ('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002','InvoiceApprover');
INSERT INTO role_permissions(org_id,role_id,permission_key) VALUES
 ('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','invoice.read'),
 ('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002','invoice.approve');
INSERT INTO role_assignments(id,org_id,subject_type,subject_id,role_id,scope_type,resource_type,created_by)
 VALUES ('30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',
 'user','00000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',
 'organization','invoice','fixture-migration');
COMMIT;
-- Runtime role: SELECT các bảng policy; CRUD qua service command; không GRANT sang DB Identity.
-- Nên cấp riêng read-only role cho tiến trình PDP; writer role cho administration routes.
