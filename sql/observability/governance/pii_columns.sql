-- Inventory of columns tagged with the governed `pii` tag (what ABAC masks).
CREATE OR REPLACE VIEW ${catalog}.governance.pii_columns
COMMENT 'Columns tagged pii=<type>; these are masked by ABAC policies'
AS
SELECT catalog_name, schema_name, table_name, column_name, tag_value AS pii_type
FROM system.information_schema.column_tags
WHERE tag_name = 'pii';
