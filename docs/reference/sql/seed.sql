-- Lab fixtures ONLY. No passwords or client credentials here.
BEGIN;
INSERT INTO users(id,email,email_normalized,email_verified_at,status) VALUES
 ('00000000-0000-4000-8000-000000000001','alice@example.test','alice@example.test',now(),'active'),
 ('00000000-0000-4000-8000-000000000002','bob@example.test','bob@example.test',now(),'active');
INSERT INTO organizations(id,slug,name) VALUES
 ('10000000-0000-4000-8000-000000000001','acme','Acme'),
 ('10000000-0000-4000-8000-000000000002','beta','Beta');
INSERT INTO memberships(org_id,user_id) VALUES
 ('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000002');
INSERT INTO clients(id,name,kind,token_endpoint_auth_method,redirect_uris,post_logout_redirect_uris,allowed_scopes,allowed_audiences) VALUES
 ('web-a','Web A','confidential','client_secret_basic',ARRAY['https://app-a.local.test:8444/callback'],ARRAY['https://app-a.local.test:8444/'],ARRAY['openid','profile','email','offline_access','invoice.read'],ARRAY['invoice-api']),
 ('web-b','Web B','confidential','client_secret_basic',ARRAY['https://app-b.local.test:8445/callback'],ARRAY['https://app-b.local.test:8445/'],ARRAY['openid','profile','email','offline_access','invoice.read'],ARRAY['invoice-api']);
INSERT INTO clients(id,name,kind,grant_types,allowed_scopes,allowed_audiences,introspection_audiences,service_org_id) VALUES
 ('invoice-api','Invoice API','confidential',ARRAY['client_credentials'],ARRAY['authz:check'],ARRAY['iam-policy-api'],ARRAY['invoice-api'],'10000000-0000-4000-8000-000000000001'),
 ('iam-policy-api','Policy API','confidential',ARRAY['client_credentials'],ARRAY['authz:check'],ARRAY['iam-policy-api'],ARRAY['invoice-api','iam-policy-api'],'10000000-0000-4000-8000-000000000001');
INSERT INTO app_assignments(org_id,client_id)
 SELECT o.id,c.id FROM organizations o CROSS JOIN clients c;
COMMIT;
