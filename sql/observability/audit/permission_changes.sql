-- Every grant, revoke and permission update. Anything here that Terraform did
-- not do is drift (a human changed access outside the pipeline).
CREATE OR REPLACE VIEW ${catalog}.audit.permission_changes
COMMENT 'Unity Catalog and workspace permission changes with actor'
AS
SELECT
  a.event_time,
  a.workspace_id,
  a.service_name,
  a.action_name,
  a.user_identity.email AS actor,
  a.request_params
FROM system.access.audit a
WHERE a.action_name IN ('updatePermissions', 'changePermissions', 'updateSharePermissions')
   OR (a.service_name = 'unityCatalog' AND lower(a.action_name) LIKE '%permission%');
