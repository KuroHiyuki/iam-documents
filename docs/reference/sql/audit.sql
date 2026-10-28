-- Chỉ chạy trong DATABASE audit bằng migration credential.
BEGIN;
CREATE TABLE inbox (
  source text NOT NULL,
  event_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash)=32),
  received_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source,event_id)
);
CREATE TABLE audit_events (
  id uuid PRIMARY KEY,
  source text NOT NULL,
  event_id uuid NOT NULL,
  event_type text NOT NULL,
  schema_version integer NOT NULL CHECK (schema_version > 0),
  occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  org_id uuid,
  actor_id text NOT NULL,
  subject_id text,
  action text NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('success','denied','failure')),
  reason_code text,
  correlation_id uuid NOT NULL,
  causation_id uuid,
  aggregate_id text NOT NULL,
  aggregate_version bigint NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (source,event_id),
  FOREIGN KEY (source,event_id) REFERENCES inbox(source,event_id)
);
CREATE INDEX audit_org_time ON audit_events(org_id,occurred_at DESC,id);
CREATE INDEX audit_actor_time ON audit_events(actor_id,occurred_at DESC);
CREATE TABLE dead_letters (
  id uuid PRIMARY KEY,
  source text NOT NULL,
  event_id uuid,
  message_hash bytea NOT NULL,
  reason_code text NOT NULL,
  attempts integer NOT NULL,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  redacted_envelope jsonb NOT NULL
);
CREATE TABLE export_jobs (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL,
  requested_by text NOT NULL,
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  status text NOT NULL CHECK (status IN ('queued','running','complete','failed','expired')),
  object_key text,
  expires_at timestamptz,
  CHECK(end_at>start_at)
);
-- Tách login migration role với audit_ingest và audit_reader.
-- Điền tên các role được tạo ở chương nền tảng trước khi chạy các GRANT sau.
-- GRANT INSERT, SELECT ON inbox,audit_events TO audit_ingest;
-- GRANT SELECT ON audit_events TO audit_reader;
-- REVOKE UPDATE,DELETE,TRUNCATE ON inbox,audit_events FROM audit_ingest,audit_reader;
COMMIT;
-- Đây là append-only ở tầng database role, chưa phải WORM chống DBA sửa dữ liệu.
-- Retention/delete phải qua maintenance role, policy và audit ở hệ thống độc lập.
