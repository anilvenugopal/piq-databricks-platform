-- Job run outcomes; a failing pipeline shows up here before anyone complains.
CREATE OR REPLACE VIEW ${catalog}.observability.job_run_outcomes
COMMENT 'Lakeflow job runs with result state and duration'
AS
SELECT
  r.workspace_id,
  r.job_id,
  r.run_id,
  r.period_start_time,
  r.period_end_time,
  r.result_state,
  r.trigger_type,
  timestampdiff(SECOND, r.period_start_time, r.period_end_time) AS duration_s
FROM system.lakeflow.job_run_timeline r
WHERE r.result_state IS NOT NULL;
