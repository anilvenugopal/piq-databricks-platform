"""
Minimal on-behalf-of-user app.

Databricks Apps forwards the signed-in user's OAuth token in the
`x-forwarded-access-token` header. Querying with that token means Unity Catalog
evaluates THIS user's grants, row filters and ABAC column masks.
"""
import os

import pandas as pd
import streamlit as st
from databricks import sql
from databricks.sdk.core import Config

cfg = Config()  # host comes from the app environment
# The catalog is built from the environment: no hard-coded environment.
CATALOG = f"{os.environ.get('PIQ_ENV', 'dev')}_{os.environ.get('PIQ_DOMAIN', 'claims')}"
WAREHOUSE_ID = os.environ["DATABRICKS_WAREHOUSE_ID"]

st.set_page_config(page_title="Claims explorer", layout="wide")
st.title("Claims explorer")

user_token = st.context.headers.get("x-forwarded-access-token")
user_email = st.context.headers.get("x-forwarded-email", "unknown")
if not user_token:
    st.error("No user token: enable user authorization (user_api_scopes: [sql]) for this app.")
    st.stop()

st.caption(f"Querying as {user_email}. Masked columns are masked because of YOUR permissions.")


def run(query: str) -> pd.DataFrame:
    with sql.connect(
        server_hostname=cfg.host.replace("https://", ""),
        http_path=f"/sql/1.0/warehouses/{WAREHOUSE_ID}",
        access_token=user_token,   # the user's token, not the app's
    ) as conn, conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall_arrow().to_pandas()


schema = st.selectbox("Product schema", ["product_loss"])
try:
    tables = run(f"SHOW TABLES IN {CATALOG}.{schema}")
    if tables.empty:
        st.info("No tables you can see in this schema yet.")
    else:
        table = st.selectbox("Table", tables["tableName"].tolist())
        st.dataframe(run(f"SELECT * FROM {CATALOG}.{schema}.{table} LIMIT 100"), use_container_width=True)
except Exception as exc:  # permission errors are expected for some personas
    st.warning(f"Unity Catalog refused or failed the query: {exc}")
