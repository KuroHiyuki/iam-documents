BEGIN;
CREATE TABLE organization_settings (
  org_id uuid PRIMARY KEY REFERENCES organizations(id),
  locale text NOT NULL DEFAULT 'vi-VN',
  support_email text NOT NULL,
  version bigint NOT NULL DEFAULT 1
);
ALTER TABLE organization_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_settings FORCE ROW LEVEL SECURITY;
CREATE POLICY organization_settings_boundary ON organization_settings
  USING (org_id = nullif(current_setting('app.org_id',true),'')::uuid)
  WITH CHECK (org_id = nullif(current_setting('app.org_id',true),'')::uuid);
COMMIT;
