-- SQL warehouse activity per user per day.
CREATE OR REPLACE VIEW ${catalog}.observability.query_activity_daily
COMMENT 'Queries, failures and duration per user, warehouse and day'
AS
SELECT
  date(q.start_time)          AS query_date,
  q.workspace_id,
  q.compute.warehouse_id      AS warehouse_id,
  q.executed_by,
  count(*)                    AS queries,
  count_if(q.execution_status = 'FAILED') AS failed_queries,
  sum(q.total_duration_ms) / 1000.0       AS total_duration_s,
  sum(q.read_bytes) / power(1024, 3)      AS read_gib
FROM system.query.history q
GROUP BY ALL;
