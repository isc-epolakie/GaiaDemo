# src/gaia/run.py
"""Host entrypoint: connect to IRIS over DB-API, ensure schema, bulk-load the
files via server-side LOAD DATA, run the proxy query, print CSV (no header).

The IRIS server reads the mounted CSVs directly off disk during LOAD DATA, so
ingest is server-side bulk speed; only SQL strings and the final result set
cross the wire."""
import os, sys
import iris
from src.gaia import schema, loader
from src.gaia.sql import build_query

def connect():
    return iris.connect(
        os.environ.get("GAIA_HOST", "localhost"),
        int(os.environ.get("GAIA_PORT", "8881")),
        os.environ.get("GAIA_NS", "USER"),
        os.environ.get("GAIA_USER", "_SYSTEM"),
        os.environ.get("GAIA_PW", "SYS"),
    )

def _fmt(v):
    if v is None: return ""
    if isinstance(v, float): return repr(v)
    return str(v)

def main():
    x = float(os.environ.get("GAIA_X", "10"))
    data_dir = os.environ.get("GAIA_DATA", "/data/gaia")
    n_files = int(os.environ.get("GAIA_NFILES", "20"))
    conn = connect()
    cur = conn.cursor()
    if not os.environ.get("GAIA_SKIP_LOAD"):
        schema.ensure(cur)
        loader.load_dir(cur, data_dir, n_files)
        conn.commit()
    cur.execute(build_query(x))
    out = sys.stdout
    for row in cur.fetchall():
        out.write(",".join(_fmt(c) for c in row) + "\n")
    conn.close()

if __name__ == "__main__":
    main()
