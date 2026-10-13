-- Lab 6: prove ABAC masking works. Masks exempt only SAR members and the data
-- writers (deploy service principals), so producers build with masked values.

-- A. As test.engineer (dev claims producer): create and tag a table
CREATE TABLE IF NOT EXISTS dev_claims.business_vault.claimant (
  claimant_id   BIGINT,
  first_name    STRING,
  last_name     STRING,
  ssn           STRING,
  date_of_birth DATE,
  email_address STRING,
  phone_number  STRING,
  state         STRING
);

INSERT INTO dev_claims.business_vault.claimant VALUES
  (1, 'Ana', 'Lopez', '123-45-6789', DATE'1984-07-19', 'ana@example.com', '312-555-0101', 'IL'),
  (2, 'Ben', 'Okoro', '987-65-4321', DATE'1990-02-03', 'ben@example.com', '773-555-0199', 'WI');

ALTER TABLE dev_claims.business_vault.claimant ALTER COLUMN ssn           SET TAGS ('pii' = 'ssn');
ALTER TABLE dev_claims.business_vault.claimant ALTER COLUMN date_of_birth SET TAGS ('pii' = 'dob');
ALTER TABLE dev_claims.business_vault.claimant ALTER COLUMN email_address SET TAGS ('pii' = 'email');
ALTER TABLE dev_claims.business_vault.claimant ALTER COLUMN phone_number  SET TAGS ('pii' = 'phone');
ALTER TABLE dev_claims.business_vault.claimant ALTER COLUMN first_name    SET TAGS ('pii' = 'name');
ALTER TABLE dev_claims.business_vault.claimant ALTER COLUMN last_name     SET TAGS ('pii' = 'name');

-- Even the producer sees masked values: [REDACTED], ***-**-6789, year-only DOB...
SELECT * FROM dev_claims.business_vault.claimant;

-- B. Grant the SAR: add "dev:claims:producer" to sars.yaml claimant_pii.members.dev,
--    apply stack 20, wait a few minutes for group sync, then re-run: values are clear.
SELECT * FROM dev_claims.business_vault.claimant;

-- C. As test.analyst (dev claims analyst): masked, because analysts hold no SAR
SELECT * FROM dev_claims.business_vault.claimant;

-- D. As test.analyst: PERMISSION_DENIED, analysts have no grant on the vault landing zone
SELECT * FROM dev_vault.landing.anything LIMIT 1;

-- E. As test.analyst in the DEV workspace: prd catalogs are not bound here
SELECT * FROM prd_claims.product_loss.loss_triangle LIMIT 1;

-- F. Inspect the policies
SHOW POLICIES ON CATALOG dev_claims;
