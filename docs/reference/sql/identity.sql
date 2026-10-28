-- Apply ONCE to the identity database as its migration owner.
-- app roles / RLS permissions are configured in chapter 04.
BEGIN;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  email_normalized text NOT NULL UNIQUE,
  email_verified_at timestamptz,
  password_hash text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','suspended','deleted')),
  credential_version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','deleted')),
  security_policy jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
  org_id uuid NOT NULL REFERENCES organizations(id),
  user_id uuid NOT NULL REFERENCES users(id),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('invited','active','suspended','removed')),
  version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id,user_id)
);
CREATE INDEX memberships_user_idx ON memberships(user_id,org_id);

CREATE TABLE groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id),
  name text NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  UNIQUE(org_id,id), UNIQUE(org_id,name)
);
CREATE TABLE group_members (
  org_id uuid NOT NULL,
  group_id uuid NOT NULL,
  user_id uuid NOT NULL,
  PRIMARY KEY(org_id,group_id,user_id),
  FOREIGN KEY(org_id,group_id) REFERENCES groups(org_id,id),
  FOREIGN KEY(org_id,user_id) REFERENCES memberships(org_id,user_id)
);

CREATE TABLE clients (
  id text PRIMARY KEY,
  name text NOT NULL,
  kind text NOT NULL CHECK(kind IN ('public','confidential')),
  status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','disabled')),
  secret_hash bytea,
  token_endpoint_auth_method text NOT NULL DEFAULT 'client_secret_basic'
    CHECK(token_endpoint_auth_method IN ('none','client_secret_basic','private_key_jwt')),
  redirect_uris text[] NOT NULL DEFAULT '{}',
  post_logout_redirect_uris text[] NOT NULL DEFAULT '{}',
  grant_types text[] NOT NULL DEFAULT '{authorization_code,refresh_token}',
  allowed_scopes text[] NOT NULL DEFAULT '{}',
  allowed_audiences text[] NOT NULL DEFAULT '{}',
  introspection_audiences text[] NOT NULL DEFAULT '{}',
  service_org_id uuid REFERENCES organizations(id),
  jwks jsonb NOT NULL DEFAULT '{"keys":[]}'::jsonb,
  trusted_first_party boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(kind <> 'public' OR (secret_hash IS NULL AND token_endpoint_auth_method='none'))
);
CREATE TABLE app_assignments (
  org_id uuid NOT NULL REFERENCES organizations(id),
  client_id text NOT NULL REFERENCES clients(id),
  status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','disabled')),
  PRIMARY KEY(org_id,client_id)
);

CREATE TABLE sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id),
  cookie_hash bytea NOT NULL UNIQUE,
  authenticated_at timestamptz NOT NULL DEFAULT now(),
  amr text[] NOT NULL DEFAULT '{pwd}',
  acr text NOT NULL DEFAULT 'urn:iam:aal:1',
  upstream_issuer text,
  mfa_at timestamptz,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(expires_at > authenticated_at)
);
CREATE INDEX sessions_user_idx ON sessions(user_id) WHERE revoked_at IS NULL;

CREATE TABLE challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK(kind IN ('verify_email','reset_password','invite','mfa_enroll','webauthn_register','webauthn_authenticate','recovery')),
  token_hash bytea NOT NULL UNIQUE,
  user_id uuid REFERENCES users(id),
  org_id uuid REFERENCES organizations(id),
  email text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  delivered_at timestamptz,
  delivery_attempts integer NOT NULL DEFAULT 0,
  next_delivery_at timestamptz NOT NULL DEFAULT now(),
  delivery_lease_until timestamptz,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX challenges_expiry_idx ON challenges(expires_at);

CREATE TABLE authenticators (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id),
  type text NOT NULL CHECK(type IN ('totp','webauthn','recovery_code')),
  status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','active','revoked')),
  credential_id bytea UNIQUE,
  public_key bytea,
  counter bigint NOT NULL DEFAULT 0 CHECK(counter >= 0),
  encrypted_secret bytea,
  secret_ref text,
  recovery_hash bytea,
  transports text[] NOT NULL DEFAULT '{}',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
CREATE INDEX authenticators_user_idx ON authenticators(user_id,type);

CREATE TABLE consents (
  user_id uuid NOT NULL REFERENCES users(id),
  org_id uuid NOT NULL REFERENCES organizations(id),
  client_id text NOT NULL REFERENCES clients(id),
  scope text[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(user_id,org_id,client_id)
);

CREATE TABLE oauth_authorization_requests (
  request_hash bytea PRIMARY KEY,
  client_id text NOT NULL REFERENCES clients(id),
  org_id uuid REFERENCES organizations(id),
  redirect_uri text NOT NULL,
  state text,
  nonce text,
  code_challenge text NOT NULL,
  code_challenge_method text NOT NULL DEFAULT 'S256' CHECK(code_challenge_method='S256'),
  scope text[] NOT NULL,
  audience text NOT NULL,
  prompt text,
  max_age integer CHECK(max_age >= 0),
  session_id uuid REFERENCES sessions(id),
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE oauth_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id text NOT NULL REFERENCES clients(id),
  user_id uuid REFERENCES users(id),
  org_id uuid REFERENCES organizations(id),
  session_id uuid REFERENCES sessions(id),
  scope text[] NOT NULL,
  audience text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  absolute_expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  CHECK ((user_id IS NULL AND session_id IS NULL) OR (user_id IS NOT NULL AND session_id IS NOT NULL))
);
CREATE INDEX oauth_grants_session_idx ON oauth_grants(session_id) WHERE revoked_at IS NULL;
CREATE INDEX oauth_grants_user_org_idx ON oauth_grants(user_id,org_id) WHERE revoked_at IS NULL;

CREATE TABLE oauth_codes (
  code_hash bytea PRIMARY KEY,
  grant_id uuid NOT NULL REFERENCES oauth_grants(id),
  client_id text NOT NULL REFERENCES clients(id),
  user_id uuid NOT NULL REFERENCES users(id),
  org_id uuid NOT NULL REFERENCES organizations(id),
  session_id uuid NOT NULL REFERENCES sessions(id),
  redirect_uri text NOT NULL,
  code_challenge text NOT NULL,
  scope text[] NOT NULL,
  audience text NOT NULL,
  nonce text,
  auth_time timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz
);

CREATE TABLE oauth_tokens (
  token_hash bytea PRIMARY KEY,
  kind text NOT NULL CHECK(kind IN ('access','refresh')),
  grant_id uuid NOT NULL REFERENCES oauth_grants(id),
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  revoked_at timestamptz,
  parent_hash bytea UNIQUE REFERENCES oauth_tokens(token_hash),
  CHECK (kind='refresh' OR (consumed_at IS NULL AND parent_hash IS NULL)),
  CHECK (expires_at > issued_at)
);
CREATE INDEX oauth_tokens_grant_idx ON oauth_tokens(grant_id);
CREATE INDEX oauth_tokens_expiry_idx ON oauth_tokens(expires_at);

CREATE TABLE signing_keys (
  kid text PRIMARY KEY,
  algorithm text NOT NULL DEFAULT 'RS256' CHECK(algorithm='RS256'),
  status text NOT NULL CHECK(status IN ('prepublished','active','retiring','retired')),
  public_jwk jsonb NOT NULL,
  private_ref text NOT NULL,
  not_before timestamptz NOT NULL DEFAULT now(),
  retire_after timestamptz,
  CHECK(NOT(public_jwk ? 'd'))
);
CREATE UNIQUE INDEX signing_keys_one_active_idx ON signing_keys((status)) WHERE status='active';

CREATE TABLE outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text NOT NULL,
  version integer NOT NULL DEFAULT 1 CHECK(version > 0),
  aggregate_id text NOT NULL,
  aggregate_version bigint NOT NULL,
  org_id uuid,
  actor jsonb NOT NULL,
  correlation_id uuid NOT NULL,
  data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  available_at timestamptz NOT NULL DEFAULT now(),
  lease_owner uuid,
  lease_until timestamptz
);
CREATE INDEX outbox_pending_idx ON outbox(available_at,created_at) WHERE published_at IS NULL;

CREATE TABLE idempotency_records (
  operation_id uuid PRIMARY KEY,
  scope text NOT NULL,
  payload_hash bytea NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);

CREATE TABLE client_assertion_replays (
  client_id text NOT NULL REFERENCES clients(id),
  jti text NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY(client_id,jti)
);

COMMIT;
