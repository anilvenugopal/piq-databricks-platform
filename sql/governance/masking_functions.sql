-- =============================================================================
-- Masking functions used by ABAC column-mask policies (stack 60-governance).
-- ${catalog} is substituted by scripts/run_sql.py (dev_platform / prd_platform).
--
-- Each function only TRANSFORMS a value. WHO sees masked data is decided by the
-- policy's TO / EXCEPT clauses, and WHICH columns by governed tags. Keeping the
-- three concerns separate is what makes ABAC scale.
-- =============================================================================

CREATE OR REPLACE FUNCTION ${catalog}.governance.mask_ssn(val STRING)
RETURNS STRING
COMMENT 'ABAC mask: ***-**-1234'
RETURN CASE WHEN val IS NULL THEN NULL ELSE concat('***-**-', right(val, 4)) END;

CREATE OR REPLACE FUNCTION ${catalog}.governance.mask_dob(val DATE)
RETURNS DATE
COMMENT 'ABAC mask: keep the year only (YYYY-01-01)'
RETURN CASE WHEN val IS NULL THEN NULL ELSE make_date(year(val), 1, 1) END;

CREATE OR REPLACE FUNCTION ${catalog}.governance.mask_email(val STRING)
RETURNS STRING
COMMENT 'ABAC mask: ****@****.com'
RETURN CASE WHEN val IS NULL THEN NULL ELSE '****@****.com' END;

CREATE OR REPLACE FUNCTION ${catalog}.governance.mask_phone(val STRING)
RETURNS STRING
COMMENT 'ABAC mask: ***-***-1234'
RETURN CASE WHEN val IS NULL THEN NULL ELSE concat('***-***-', right(val, 4)) END;

CREATE OR REPLACE FUNCTION ${catalog}.governance.mask_name(val STRING)
RETURNS STRING
COMMENT 'ABAC mask: [REDACTED]'
RETURN CASE WHEN val IS NULL THEN NULL ELSE '[REDACTED]' END;

-- Sensitive financial metrics (tag sensitive_metric = financial). Columns with
-- this tag should be DECIMAL; the masked value is NULL.
CREATE OR REPLACE FUNCTION ${catalog}.governance.mask_amount(val DECIMAL(38, 6))
RETURNS DECIMAL(38, 6)
COMMENT 'ABAC mask: hide sensitive financial amounts'
RETURN CAST(NULL AS DECIMAL(38, 6));
