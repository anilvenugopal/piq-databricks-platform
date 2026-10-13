-- Lab 10: cost and attribution (run as a member of piq-platform-monitoring)

-- Cost by env and domain, last 30 days
SELECT piq_env, piq_domain, round(sum(list_cost_usd), 2) AS usd
FROM prd_platform.monitoring.cost_daily_by_env_domain
WHERE usage_date >= current_date() - INTERVAL 30 DAYS
GROUP BY ALL ORDER BY usd DESC;

-- What escaped attribution, and who ran it
SELECT * FROM prd_platform.monitoring.cost_untagged_usage
WHERE usage_date >= current_date() - INTERVAL 7 DAYS
ORDER BY dbus DESC;

-- Denied requests from the labs (should include test.analyst's attempts)
SELECT event_time, user_email, service_name, action_name, status_code
FROM prd_platform.audit.denied_requests
WHERE event_time >= current_timestamp() - INTERVAL 1 DAY
ORDER BY event_time DESC;

-- Permission changes NOT made by Terraform = drift
SELECT * FROM prd_platform.audit.permission_changes
WHERE actor NOT LIKE '%terraform%'
  AND event_time >= current_timestamp() - INTERVAL 7 DAYS;
