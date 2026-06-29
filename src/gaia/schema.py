"""(Re)create the Gaia.Source table via a DB-API cursor.
Column names match the Gaia CSV header so LOAD DATA maps by name (Task 1 spike).
`dec` is a reserved word and is quoted."""
from src.gaia.sql import TABLE

DDL = f"""CREATE TABLE {TABLE} (
  source_id BIGINT NOT NULL,
  ra DOUBLE,
  "dec" DOUBLE,
  phot_g_n_obs INTEGER,
  phot_g_mean_flux DOUBLE,
  phot_g_mean_flux_error DOUBLE,
  phot_g_mean_mag DOUBLE
)"""

def ensure(cur):
    cur.execute(f"DROP TABLE IF EXISTS {TABLE}")
    cur.execute(DDL)
