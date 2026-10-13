-- Catalog of published products: every product schema with its tags.
CREATE OR REPLACE VIEW ${catalog}.governance.products
COMMENT 'Product schemas with product name, type and status tags'
AS
SELECT
  t.catalog_name,
  t.schema_name,
  max(CASE WHEN t.tag_name = 'piq_product'        THEN t.tag_value END) AS product,
  max(CASE WHEN t.tag_name = 'piq_product_type'   THEN t.tag_value END) AS product_type,
  max(CASE WHEN t.tag_name = 'piq_product_status' THEN t.tag_value END) AS product_status,
  max(CASE WHEN t.tag_name = 'piq_env'            THEN t.tag_value END) AS piq_env
FROM system.information_schema.schema_tags t
WHERE t.schema_name LIKE 'product\_%'
GROUP BY t.catalog_name, t.schema_name;
