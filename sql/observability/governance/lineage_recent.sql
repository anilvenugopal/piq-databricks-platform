-- Table-to-table lineage over the last 30 days.
CREATE OR REPLACE VIEW ${catalog}.governance.lineage_recent
COMMENT 'Table lineage edges observed in the last 30 days'
AS
SELECT
  l.source_table_full_name,
  l.target_table_full_name,
  l.entity_type,
  count(*)          AS events,
  max(l.event_time) AS last_seen
FROM system.access.table_lineage l
WHERE l.event_time >= current_timestamp() - INTERVAL 30 DAYS
  AND l.source_table_full_name IS NOT NULL
  AND l.target_table_full_name IS NOT NULL
GROUP BY ALL;
