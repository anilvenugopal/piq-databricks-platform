-- Lab 6: prove ABAC masking works. Run section A as a PRODUCER (or your admin
-- identity, which is in metastore-admins), section B as test.analyst.

-- A. Create and tag a table (as a dev producer: test.engineer)
CREATE TABLE IF NOT EXISTS dev_claims.silver.claimant (
  claimant_id   BIGINT,
  first_name    STRING,
  last_name     STRING,
  ssn           STRING,
  date_of_birth DATE,
  email_address STRING,
  phone_number  STRING,
  state         STRING
);

INSERT INTO dev_claims.silver.claimant VALUES
  (1, 'Ana',  'Lopez', '123-45-6789', DATE'1984-07-19', 'ana@example.com',  '312-555-0101', 'IL'),
  (2, 'Ben',  'Okoro', '987-65-4321', DATE'1990-02-03', 'ben@example.com',  '773-555-0199', 'WI');

ALTER TABLE dev_claims.silver.claimant ALTER COLUMN ssn           SET TAGS ('pii' = 'ssn');
ALTER TABLE dev_claims.silver.claimant ALTER COLUMN date_of_birth SET TAGS ('pii' = 'dob');
ALTER TABLE dev_claims.silver.claimant ALTER COLUMN email_address SET TAGS ('pii' = 'email');
ALTER TABLE dev_claims.silver.claimant ALTER COLUMN phone_number  SET TAGS ('pii' = 'phone');
ALTER TABLE dev_claims.silver.claimant ALTER COLUMN first_name    SET TAGS ('pii' = 'name');
ALTER TABLE dev_claims.silver.claimant ALTER COLUMN last_name     SET TAGS ('pii' = 'name');

-- Producers are exempt from masking: you should see raw values here.
SELECT * FROM dev_claims.silver.claimant;

-- B. As test.analyst (dev analyst through the data-analyst persona):
-- expect [REDACTED] names, ***-**-6789, year-only DOB, ****@****.com, ***-***-0101
SELECT * FROM dev_claims.silver.claimant;

-- C. As test.analyst: expect PERMISSION_DENIED (analysts have no bronze grant)
SELECT * FROM dev_claims.bronze.anything LIMIT 1;

-- D. As test.analyst in the DEV workspace: expect "catalog not found / not
-- accessible" because prd catalogs are not bound to the dev workspace.
SELECT * FROM prd_claims.gold.anything LIMIT 1;

-- E. Inspect the policies that apply
SHOW POLICIES ON CATALOG dev_claims;
