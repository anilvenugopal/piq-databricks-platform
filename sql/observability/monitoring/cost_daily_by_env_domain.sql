-- Daily list-price cost by environment and domain.
-- piq_env / piq_domain come from serverless usage policies (stack 30),
-- warehouse tags and compute-policy tags (stack 50).
CREATE OR REPLACE VIEW ${catalog}.monitoring.cost_daily_by_env_domain
COMMENT 'Daily DBUs and list-price USD by piq_env, piq_domain and product'
AS
SELECT
  u.usage_date,
  coalesce(u.custom_tags['piq_env'], 'untagged')    AS piq_env,
  coalesce(u.custom_tags['piq_domain'], 'untagged') AS piq_domain,
  u.billing_origin_product,
  u.sku_name,
  sum(u.usage_quantity)                              AS dbus,
  sum(u.usage_quantity * lp.pricing.default)         AS list_cost_usd
FROM system.billing.usage u
LEFT JOIN system.billing.list_prices lp
  ON  u.sku_name   = lp.sku_name
  AND u.cloud      = lp.cloud
  AND u.usage_unit = lp.usage_unit
  AND u.usage_end_time >= lp.price_start_time
  AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
GROUP BY ALL;
