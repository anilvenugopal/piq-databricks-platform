-- Lab 11: products and consumers (prd workspace)

-- As test.executive (member of piq-prd-exec-reporting-analyst):
-- only product schemas you were approved for are visible
SHOW SCHEMAS IN prd_profitability;          -- product_loss_ratio only
SHOW SCHEMAS IN prd_claims;                 -- nothing: exec reporting was not approved for Loss
SELECT * FROM prd_profitability.product_loss_ratio.loss_ratio LIMIT 10;

-- Financial metrics are unmasked because exec reporting holds the financial_metrics SAR
DESCRIBE TABLE EXTENDED prd_profitability.product_loss_ratio.loss_ratio;

-- As a monitoring admin: the product catalog
SELECT * FROM prd_platform.governance.products ORDER BY catalog_name, schema_name;
