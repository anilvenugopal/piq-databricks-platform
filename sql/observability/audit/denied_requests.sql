-- Requests that were refused. Use it in the labs to prove that access controls
-- actually stopped your test personas.
CREATE OR REPLACE VIEW ${catalog}.audit.denied_requests
COMMENT 'Audit events with 401/403 responses'
AS
SELECT
  a.event_time,
  a.workspace_id,
  a.service_name,
  a.action_name,
  a.user_identity.email AS user_email,
  a.source_ip_address,
  a.response.status_code,
  a.response.error_message,
  a.request_params
FROM system.access.audit a
WHERE a.response.status_code IN (401, 403);
