"""Bulk-load Gaia CSVs into Gaia.Source via server-side LOAD DATA.
Driven from host Python over DB-API; `data_dir` is the path AS SEEN BY THE IRIS
SERVER (the container mount, e.g. /data/gaia). With header:true, IRIS maps CSV
header names to the like-named table columns and ignores the other ~50 columns
(Task 1 spike: there is NO COLUMNS clause)."""
from src.gaia.sql import TABLE

# header:true (NOT 1) — the DB-API driver misparses ":1" as a bind parameter.
_LOAD = ('LOAD DATA FROM FILE \'{path}\' INTO {table} '
         'USING {{"from":{{"file":{{"header":true}}}}}}')

def load_dir(cur, data_dir: str, n_files: int = 20) -> int:
    for i in range(n_files):
        path = f"{data_dir.rstrip('/')}/GaiaSource_000-000-{i:03d}.csv"
        cur.execute(_LOAD.format(path=path, table=TABLE))
    cur.execute(f"SELECT COUNT(*) FROM {TABLE}")
    return cur.fetchone()[0]
