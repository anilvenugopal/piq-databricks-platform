-- Usage that escaped attribution. This should trend to zero; anything here
-- means a workload ran outside a usage policy or tagged compute.
CREATE OR REPLACE VIEW ${catalog}.monitoring.cost_untagged_usage
COMMENT 'Usage records missing piq_domain, with the identity that ran them'
AS
SELECT
  u.usage_date,
  u.workspace_id,
  u.billing_origin_product,
  u.identity_metadata.run_as AS run_as,
  u.usage_metadata.job_id    AS job_id,
  u.usage_metadata.warehouse_id AS warehouse_id,
  sum(u.usage_quantity)      AS dbus
FROM system.billing.usage u
WHERE u.custom_tags['piq_domain'] IS NULL
GROUP BY ALL;
