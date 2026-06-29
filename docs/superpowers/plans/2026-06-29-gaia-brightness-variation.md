# Gaia Brightness Variation Detector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On InterSystems IRIS, ingest 20 Gaia DR1 catalog files, compute a per-object brightness-variation proxy in SQL, and expose results both as a headless `RunChallenge` CSV emitter and a sortable web UI.

**Architecture:** Embedded Python running inside the IRIS container bulk-loads the (extracted) CSV files into a single `GaiaSource` SQL table via `LOAD DATA`. One parameterized SQL query computes the flux-scatter variability proxy, filters by threshold X%, and sorts. `RunChallenge` orchestrates this end-to-end via `docker compose exec`; a REST class + static HTML page reuse the same query for an interactive UI.

**Tech Stack:** InterSystems IRIS (`latest-cd`), IRIS SQL (`LOAD DATA`), Embedded Python (`iris` module inside container), `intersystems_irispython` (host driver, dev only), Docker Compose, vanilla HTML/JS.

## Global Constraints

- Process exactly the 20 files `GaiaSource_000-000-000.*` … `GaiaSource_000-000-019.*` (NOT file 020+).
- `Data/` is gitignored and assumed pre-downloaded; never commit data files.
- Solution language is Python (embedded in IRIS) for the +3 Experts bonus; IRIS SQL is the primary compute platform.
- `RunChallenge` lives at repo root, runs with no manual input, emits CSV (one record per line) to stdout.
- Output fields, in order: `source_id,ra,dec,mag_max,mag_min,pct_change`. RunChallenge emits **no header line**; the web UI adds its own column headers.
- Default threshold when none supplied: `X=10` (percent).
- Variability proxy (exact formula, from spec §3). NOTE: the SQL table columns are
  named to match the Gaia CSV header (see schema below), so the SQL uses
  `phot_g_n_obs`, `phot_g_mean_flux`, `phot_g_mean_flux_error`, `phot_g_mean_mag`.
  Below, `flux`=phot_g_mean_flux, `n_obs`=phot_g_n_obs, `flux_err`=phot_g_mean_flux_error,
  `mag`=phot_g_mean_mag:
  - `std_flux = SQRT(n_obs) * flux_err`
  - `frac = std_flux / flux`
  - `mag_min = mag - 2.5*LOG10((flux+std_flux)/flux)` (brightest)
  - `mag_max = mag + 2.5*LOG10(flux/GREATEST(flux-std_flux, flux*0.001))` (faintest; floored)
  - `pct_change = LEAST(frac, 1.0) * 100`
- **CONFIRMED in Task 1 spike — these override any conflicting code below:**
  - IRIS SQL has **no two-arg LOG**; `LOG(x)` is natural log. Use **`LOG10(x)`** for log base 10.
  - `dec` is a **reserved word**; the table column matching CSV header `dec` MUST be
    quoted as `"dec"` in DDL and every query. Output alias is `dec`.
  - `LOAD DATA` has **no `COLUMNS` clause**. Subset-loading works by naming table
    columns to match the CSV header and using `USING {"from":{"file":{"header":1}}}`.
  - Table is `Gaia.Source` with this exact DDL:
    ```sql
    CREATE TABLE Gaia.Source (
      source_id BIGINT NOT NULL, ra DOUBLE, "dec" DOUBLE,
      phot_g_n_obs INTEGER, phot_g_mean_flux DOUBLE,
      phot_g_mean_flux_error DOUBLE, phot_g_mean_mag DOUBLE )
    ```
- Skip rows where `phot_g_mean_flux IS NULL OR phot_g_mean_flux <= 0 OR phot_g_n_obs IS NULL OR phot_g_n_obs <= 0 OR phot_g_mean_flux_error IS NULL`.
- Confirmed source-column indices (1-based in CSV): source_id=2, ra=5, dec=7, phot_g_n_obs=49, phot_g_mean_flux=50, phot_g_mean_flux_error=51, phot_g_mean_mag=52.
- IRIS connection (host dev): host `localhost`, port `8881`, namespace `USER`, user `_SYSTEM`, password `SYS`. SQL also runnable in-container via `docker compose exec -T iris iris session iris -U USER`.

---

## File Structure

- `src/gaia/sql.py` — builds the analysis SQL string from a threshold X (pure function, no IRIS dependency). The single source of proxy/filter/sort logic.
- `src/gaia/schema.py` — DDL constant + helper to (re)create the `GaiaSource` table.
- `src/gaia/loader.py` — embedded-Python ingest: iterate the 20 mounted CSVs, run `LOAD DATA` per file. Runs inside the container.
- `src/gaia/run.py` — embedded-Python entrypoint invoked inside the container: ensure schema → load → run query → print CSV to stdout. Reads `X` and data dir from env/args.
- `scripts/prepare_data.sh` — host: extract the 20 `.gz` files into `Data/csv/` (flat folder of `.csv`) for the container mount.
- `RunChallenge` — repo-root shell entrypoint: prepare data, ensure container up, `docker compose exec` into IRIS to run `src/gaia/run.py`, stream CSV to stdout.
- `src/web/Gaia.REST.cls` — ObjectScript REST broker exposing `GET /api/variations?x=NN` → JSON, calling the same SQL.
- `web/index.html` — single-page UI: input X, fetch JSON, render client-sortable table.
- `tests/test_sql.py` — host unit tests for `src/gaia/sql.py` (pure, no IRIS).
- `tests/test_proxy_math.py` — host unit tests for the proxy math against hand-computed values.
- `tests/test_integration.py` — host integration test using `intersystems_irispython` against the live container (small synthetic dataset).
- `README.md` — install, operation, data-reality/proxy rationale.
- `docker-compose.yml` — MODIFY: mount `./Data/csv` into IRIS container.

---

## Task 1: Spike — confirm LOAD DATA column-mapping syntax against live IRIS

**Files:**
- Create: `docs/superpowers/notes/loaddata-spike.md` (findings only; delete-able)

**Interfaces:**
- Produces: a verified `LOAD DATA` statement template that loads 7 named columns out of a 57-column CSV with a header row, used verbatim by Task 4.

- [ ] **Step 1: Start the stack and confirm connectivity**

Run:
```bash
cd /c/Users/epolakie/Demos/GaiaDemo
docker compose up -d
sleep 30
docker compose exec iris iris session iris -U USER <<'EOF'
write "alive", !
halt
EOF
```
Expected: prints `alive`. If the namespace/credentials differ, record the working values in the spike note and update the plan's Global Constraints.

- [ ] **Step 2: Create a throwaway table and a 3-row test CSV inside the container**

Run:
```bash
docker compose exec iris bash -lc 'mkdir -p /tmp/spike && cat > /tmp/spike/t.csv <<CSV
source_id,ra,dec,phot_g_n_obs,phot_g_mean_flux,phot_g_mean_flux_error,phot_g_mean_mag
65408,44.99,0.0056,30,1567.25,5.856,17.53
12387583330136064,45.0,0.02,12,275.4,2.73,17.6
99,1.0,2.0,10,100.0,1.0,18.0
CSV'
```

- [ ] **Step 3: Try LOAD DATA with explicit column mapping via embedded Python**

Run (inside container, using the `iris` module):
```bash
docker compose exec iris irispython <<'EOF'
import iris
iris.sql.exec("DROP TABLE IF EXISTS Gaia.Spike")
iris.sql.exec("""CREATE TABLE Gaia.Spike (
  source_id BIGINT, ra DOUBLE, dec DOUBLE, n_obs INTEGER,
  flux DOUBLE, flux_err DOUBLE, mag DOUBLE)""")
# Candidate A: column list maps CSV header names -> table columns positionally
iris.sql.exec("""LOAD DATA FROM FILE '/tmp/spike/t.csv'
  INTO Gaia.Spike (source_id, ra, dec, n_obs, flux, flux_err, mag)
  USING {"from":{"file":{"header":true}}}""")
rs = iris.sql.exec("SELECT COUNT(*) c, AVG(flux) f FROM Gaia.Spike")
for row in rs: print("loaded", row)
EOF
```
Expected: `loaded [3, ...]`. If this errors, try `LOAD DATA ... COLUMNS ...` and `%SQL_Diag` table to inspect; record the syntax that works.

- [ ] **Step 4: Confirm selecting 7 of 57 real columns works**

Run the same `LOAD DATA` against a real file copied in: `docker compose exec iris bash -lc 'zcat /irisdata? ...'` — if `Data/csv` is not yet mounted, copy one extracted file to `/tmp/spike/real.csv` and load it, mapping by the header names `source_id, ra, dec, phot_g_n_obs, phot_g_mean_flux, phot_g_mean_flux_error, phot_g_mean_mag`.
Expected: `COUNT(*) = 218453` for file 000.
Record the exact working statement (especially how to select a subset of CSV columns by name) in the spike note.

- [ ] **Step 5: Write findings + commit**

Write the verified statement template and connection params to `docs/superpowers/notes/loaddata-spike.md`.
```bash
git add docs/superpowers/notes/loaddata-spike.md
git commit -m "spike: confirm LOAD DATA column mapping for Gaia CSVs"
```

> **NOTE:** Tasks 4 and 5 depend on the exact syntax confirmed here. If LOAD DATA cannot select a column subset by name, the fallback (recorded in the spike) is to load all 57 columns into a wide staging table, then `INSERT … SELECT` the 7 needed columns into `GaiaSource`. Task 4 must use whichever the spike proved.

---

## Task 2: Proxy SQL builder (`src/gaia/sql.py`)

**Files:**
- Create: `src/gaia/sql.py`
- Create: `src/gaia/__init__.py` (empty)
- Test: `tests/test_sql.py`

**Interfaces:**
- Produces: `build_query(x: float, *, limit: int | None = None) -> str` returning an IRIS-SQL string. Selects, in order, `source_id, ra, dec, mag_max, mag_min, pct_change` FROM `Gaia.Source`, applying the proxy, filtering `pct_change >= :x` (x inlined as a literal float), ordered by `pct_change DESC`. Optional `LIMIT`.
- Produces: `TABLE = "Gaia.Source"` constant.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_sql.py
from src.gaia.sql import build_query, TABLE

def test_query_contains_required_columns_in_order():
    q = build_query(10)
    select = q.lower().split("from")[0]
    for col in ["source_id", "ra", "dec", "mag_max", "mag_min", "pct_change"]:
        assert col in select
    # required column order
    assert select.index("mag_max") < select.index("mag_min") < select.index("pct_change")

def test_query_filters_and_sorts():
    q = build_query(25.5).lower()
    assert "pct_change >= 25.5" in q.replace(" ", " ")
    assert "order by pct_change desc" in q
    assert TABLE.lower() in q

def test_query_floors_flux_to_avoid_log_domain_error():
    q = build_query(10).lower()
    assert "greatest" in q          # flux-std floored
    assert "least" in q             # pct capped at 100

def test_limit_optional():
    assert "top" in build_query(10, limit=5).lower() or "limit" in build_query(10, limit=5).lower()
    assert "top" not in build_query(10).lower().split("from")[0] or "limit" not in build_query(10).lower()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_sql.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.gaia.sql'`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/gaia/sql.py
"""Single source of truth for the brightness-variation analysis query.

Pure string builder — no IRIS dependency — so it is unit-testable on the host.
Implements the Gaia DR1 flux-scatter variability proxy (see spec §3).

Column names match the Gaia CSV header (Task 1 spike): phot_g_mean_flux,
phot_g_mean_flux_error, phot_g_n_obs, phot_g_mean_mag, and the reserved word
"dec" (quoted). IRIS uses LOG10(x) for base-10 log (no two-arg LOG)."""

TABLE = "Gaia.Source"

# Shared sub-expressions referencing the real (CSV-header) column names.
_STD = "SQRT(phot_g_n_obs)*phot_g_mean_flux_error"          # per-epoch flux scatter
_FLUX = "phot_g_mean_flux"
_PCT = f"LEAST({_STD} / {_FLUX}, 1.0) * 100"                 # capped at 100%

def build_query(x: float, *, limit: int | None = None) -> str:
    x = float(x)
    top = f"TOP {int(limit)} " if limit else ""
    # floor flux-std to flux*0.001 to keep LOG10 in-domain when scatter >= flux
    return f"""
SELECT {top}
    source_id,
    ra,
    "dec" AS dec,
    phot_g_mean_mag + 2.5*LOG10({_FLUX} / GREATEST({_FLUX} - {_STD}, {_FLUX}*0.001)) AS mag_max,
    phot_g_mean_mag - 2.5*LOG10(({_FLUX} + {_STD}) / {_FLUX})                         AS mag_min,
    {_PCT}                                                                           AS pct_change
FROM {TABLE}
WHERE {_FLUX} > 0 AND phot_g_n_obs > 0 AND phot_g_mean_flux_error IS NOT NULL
  AND {_PCT} >= {x}
ORDER BY pct_change DESC
""".strip()
```

> **NOTE (from Task 1 spike — binding):** IRIS has NO two-arg `LOG`; use `LOG10(x)`.
> The `dec` column is reserved and MUST be quoted `"dec"`. Column names match the
> CSV header so `LOAD DATA` (Task 4) maps by name. The `test_query_floors...` and
> column-order tests in Step 1 still pass against this implementation (they check for
> `greatest`/`least` and the `mag_max < mag_min < pct_change` ordering in the SELECT).

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_sql.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/gaia/__init__.py src/gaia/sql.py tests/test_sql.py
git commit -m "feat: SQL builder for flux-scatter variability proxy"
```

---

## Task 3: Proxy math reference test (`tests/test_proxy_math.py`)

**Files:**
- Create: `src/gaia/proxy.py`
- Test: `tests/test_proxy_math.py`

**Interfaces:**
- Produces: `proxy(n_obs, flux, flux_err, mag) -> dict` with keys `mag_max, mag_min, pct_change`, a pure-Python reference implementation mirroring the SQL. Used by the integration test (Task 6) to assert SQL == Python, and as documentation of the math.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_proxy_math.py
import math
from src.gaia.proxy import proxy

def test_matches_hand_computed_value():
    # source 6476948121350144-like: n_obs=15, frac ~ 0.5833
    r = proxy(n_obs=15, flux=1000.0, flux_err=1000.0*0.5833/math.sqrt(15), mag=20.83)
    assert abs(r["pct_change"] - 58.33) < 0.1

def test_caps_pct_at_100():
    r = proxy(n_obs=100, flux=10.0, flux_err=5.0, mag=18.0)  # frac huge
    assert r["pct_change"] == 100.0
    assert math.isfinite(r["mag_max"])  # floored, not inf

def test_mag_min_is_brighter_than_mag_max():
    r = proxy(n_obs=15, flux=1000.0, flux_err=50.0, mag=18.0)
    assert r["mag_min"] < r["mag_max"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_proxy_math.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'src.gaia.proxy'`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/gaia/proxy.py
"""Pure-Python reference implementation of the variability proxy.
Mirrors src/gaia/sql.py exactly so the integration test can assert parity."""
import math

def proxy(n_obs: float, flux: float, flux_err: float, mag: float) -> dict:
    std = math.sqrt(n_obs) * flux_err
    frac = std / flux
    flux_lo = max(flux - std, flux * 0.001)
    return {
        "mag_max": mag + 2.5 * math.log10(flux / flux_lo),
        "mag_min": mag - 2.5 * math.log10((flux + std) / flux),
        "pct_change": min(frac, 1.0) * 100,
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_proxy_math.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/gaia/proxy.py tests/test_proxy_math.py
git commit -m "feat: pure-Python reference for variability proxy"
```

---

## Task 4: Schema + loader (embedded Python, `src/gaia/schema.py`, `src/gaia/loader.py`)

**Files:**
- Create: `src/gaia/schema.py`
- Create: `src/gaia/loader.py`
- MODIFY: `docker-compose.yml` (mount `./Data/csv` → `/data/gaia`)
- Create: `scripts/prepare_data.sh`

**Interfaces:**
- Consumes: verified `LOAD DATA` form from Task 1 spike (no COLUMNS; header-matched
  names; `header:true`; container-side paths).
- Produces: `schema.ensure(cur)` — given a DB-API cursor, drops/recreates the
  `Gaia.Source` table with the exact DDL from Global Constraints (quoted `"dec"`,
  CSV-header column names).
- Produces: `loader.load_dir(cur, data_dir: str, n_files: int = 20) -> int` — given a
  DB-API cursor, loads files `GaiaSource_000-000-000.csv` … `-019.csv` from `data_dir`
  (a **container-side** path, e.g. `/data/gaia`) via server-side `LOAD DATA`, returns
  total rows loaded.

- [ ] **Step 1: Write `scripts/prepare_data.sh`**

```bash
#!/usr/bin/env bash
# Extract the first N Gaia .csv.gz files into Data/csv/ as flat .csv files
# for the IRIS container mount. Idempotent: skips files already extracted.
# N defaults to 20 (the challenge scope) and is overridable via GAIA_NFILES
# (CI uses a smaller fixture set).
set -euo pipefail
SRC="${1:-Data}"
DST="${2:-Data/csv}"
N="${GAIA_NFILES:-20}"
mkdir -p "$DST"
for i in $(seq 0 $((N - 1))); do
  idx=$(printf '%03d' "$i")           # 0 -> 000, 19 -> 019
  f="$SRC/GaiaSource_000-000-${idx}.csv.gz"
  out="$DST/GaiaSource_000-000-${idx}.csv"
  [ -f "$f" ] || { echo "MISSING: $f" >&2; exit 1; }
  if [ ! -f "$out" ]; then
    echo "extracting $f" >&2
    gunzip -c "$f" > "$out"
  fi
done
echo "prepared $N files in $DST" >&2
```

> **NOTE:** `printf '%03d'` yields `000`…`019` for the challenge's file pattern.
> Verify the first/last produced names match `GaiaSource_000-000-000.csv` and
> `GaiaSource_000-000-019.csv` before relying on it (Step 5).

- [ ] **Step 2: Mount data dir in `docker-compose.yml`**

Under the `iris` service `volumes:`, ADD:
```yaml
    - type: bind
      source: ./Data/csv
      target: /data/gaia
      read_only: true
```

- [ ] **Step 3: Write `schema.py` and `loader.py`**

```python
# src/gaia/schema.py
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
```

```python
# src/gaia/loader.py
"""Bulk-load Gaia CSVs into Gaia.Source via server-side LOAD DATA.
Driven from host Python over DB-API; `data_dir` is the path AS SEEN BY THE IRIS
SERVER (the container mount, e.g. /data/gaia). With header:true, IRIS maps CSV
header names to the like-named table columns and ignores the other ~50 columns
(Task 1 spike: there is NO COLUMNS clause)."""
import os
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
```

> **NOTE (Task 1 spike — binding):** No `COLUMNS` clause exists; subset-load works
> purely by matching table column names to the CSV header. `data_dir` is the
> CONTAINER path (server reads the file), not the host path. Keep both function
> signatures (`ensure(cur)`, `load_dir(cur, data_dir, n_files)`) stable — Tasks 5–7 rely on them.

- [ ] **Step 4: Make script executable**

Run: `chmod +x scripts/prepare_data.sh`

- [ ] **Step 5: Verify extraction produces correct filenames**

Run:
```bash
bash scripts/prepare_data.sh
ls Data/csv | head -1; ls Data/csv | tail -1; ls Data/csv | wc -l
```
Expected: first `GaiaSource_000-000-000.csv`, last `GaiaSource_000-000-019.csv`, count `20`.

- [ ] **Step 6: Commit**

```bash
git add src/gaia/schema.py src/gaia/loader.py scripts/prepare_data.sh docker-compose.yml
git commit -m "feat: schema + LOAD DATA bulk loader, data prep script, compose mount"
```

---

## Task 5: Host entrypoint (`src/gaia/run.py`)

**Files:**
- Create: `src/gaia/run.py`

**Interfaces:**
- Consumes: `intersystems_irispython` host driver (`import iris`), `schema.ensure(cur)`, `loader.load_dir(cur, data_dir, n_files)`, `sql.build_query`.
- Produces: `connect()` → DB-API connection (reads `GAIA_HOST`/`GAIA_PORT`/`GAIA_NS`/`GAIA_USER`/`GAIA_PW` env, defaults `localhost`/`8881`/`USER`/`_SYSTEM`/`SYS`).
- Produces: `main()`. Reads `GAIA_X` (default `10`), `GAIA_DATA` (container-side dir, default `/data/gaia`), `GAIA_NFILES` (default `20`), `GAIA_SKIP_LOAD` (if set, skip ingest). Prints CSV rows (no header) to stdout: `source_id,ra,dec,mag_max,mag_min,pct_change`.

- [ ] **Step 1: Write `run.py`**

```python
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
```

- [ ] **Step 2: Smoke-test from the host (data prepared + mounted in Task 4)**

The container must be running with `./Data/csv` mounted to `/data/gaia`, and the
`_SYSTEM` password must be un-expired (Task 7 automates this; for now run it once):
```bash
docker compose exec -T iris iris session iris -U %SYS <<'EOF'
do ##class(Security.Users).UnExpireUserPasswords("*")
halt
EOF
GAIA_X=50 GAIA_NFILES=1 PYTHONPATH=. python src/gaia/run.py | head -5
```
Expected: up to 5 CSV lines, 6 comma-separated fields each, all `pct_change >= 50`.

- [ ] **Step 3: Commit**

```bash
git add src/gaia/run.py
git commit -m "feat: host DB-API entrypoint — schema, load, query, emit CSV"
```

---

## Task 6: Integration test — SQL parity against live IRIS (`tests/test_integration.py`)

**Files:**
- Create: `tests/test_integration.py`
- Create: `tests/conftest.py`

**Interfaces:**
- Consumes: `intersystems_irispython` host driver, `src.gaia.sql.build_query`, `src.gaia.proxy.proxy`.
- Produces: a test that inserts a small synthetic dataset over the wire, runs `build_query`, and asserts each returned row matches the Python `proxy()` reference within tolerance, and that `LOG(10, …)` behaves as log10.

- [ ] **Step 1: Write `conftest.py` (skip cleanly if no container)**

```python
# tests/conftest.py
import os
import pytest

@pytest.fixture(scope="session")
def iris_conn():
    iris = pytest.importorskip("iris")
    try:
        conn = iris.connect(
            os.environ.get("GAIA_HOST", "localhost"),
            int(os.environ.get("GAIA_PORT", "8881")),
            os.environ.get("GAIA_NS", "USER"),
            os.environ.get("GAIA_USER", "_SYSTEM"),
            os.environ.get("GAIA_PW", "SYS"),
        )
    except Exception as e:
        pytest.skip(f"IRIS not reachable: {e}")
    yield conn
    conn.close()
```

- [ ] **Step 2: Write the failing integration test**

```python
# tests/test_integration.py
import math
from src.gaia.sql import build_query, TABLE
from src.gaia.proxy import proxy

ROWS = [
    # source_id, ra, dec, phot_g_n_obs, phot_g_mean_flux, phot_g_mean_flux_error, phot_g_mean_mag
    (1, 10.0, -5.0, 15, 1000.0, 50.0, 18.0),
    (2, 11.0, -6.0, 30, 2000.0, 5.0,  17.0),   # tiny variation -> filtered at X=10
    (3, 12.0, -7.0, 25, 500.0, 120.0, 19.0),   # large variation
]

def _setup(conn):
    cur = conn.cursor()
    cur.execute(f"DROP TABLE IF EXISTS {TABLE}")
    # Column names match the CSV header; "dec" is reserved so it is quoted.
    cur.execute(f'CREATE TABLE {TABLE} (source_id BIGINT, ra DOUBLE, "dec" DOUBLE, '
                f"phot_g_n_obs INTEGER, phot_g_mean_flux DOUBLE, "
                f"phot_g_mean_flux_error DOUBLE, phot_g_mean_mag DOUBLE)")
    cur.executemany(f"INSERT INTO {TABLE} VALUES (?,?,?,?,?,?,?)", ROWS)
    conn.commit()

def test_sql_matches_python_reference(iris_conn):
    _setup(iris_conn)
    cur = iris_conn.cursor()
    cur.execute(build_query(10))
    got = cur.fetchall()
    by_id = {r[0]: r for r in got}
    # row 2 filtered out (variation < 10%)
    assert 2 not in by_id
    for sid, ra, dec, n_obs, flux, flux_err, mag in ROWS:
        ref = proxy(n_obs, flux, flux_err, mag)
        if ref["pct_change"] >= 10:
            _, _, _, mag_max, mag_min, pct = by_id[sid]
            assert abs(mag_max - ref["mag_max"]) < 1e-6
            assert abs(mag_min - ref["mag_min"]) < 1e-6
            assert abs(pct - ref["pct_change"]) < 1e-6

def test_results_sorted_desc(iris_conn):
    _setup(iris_conn)
    cur = iris_conn.cursor()
    cur.execute(build_query(0))
    pcts = [r[5] for r in cur.fetchall()]
    assert pcts == sorted(pcts, reverse=True)
```

- [ ] **Step 3: Run — verify it passes (or skips cleanly without container)**

Run (un-expire password once if needed — see Task 5 Step 2):
`docker compose up -d && sleep 20 && PYTHONPATH=. python -m pytest tests/test_integration.py -v`
Expected: PASS. (The SQL uses `LOG10`, confirmed working in the Task 1 spike.)

- [ ] **Step 4: Commit**

```bash
git add tests/conftest.py tests/test_integration.py
git commit -m "test: SQL/Python parity integration test against live IRIS"
```

---

## Task 7: `RunChallenge` root entrypoint

**Files:**
- Create: `RunChallenge` (shell, repo root)

**Interfaces:**
- Consumes: `scripts/prepare_data.sh`, host Python entrypoint `src/gaia/run.py`.
- Produces: an executable that runs with no manual input and prints the challenge CSV to stdout. Honors `X` (env or `$1`, default 10) and `DATA` dir (host dir holding the `.csv.gz`).

- [ ] **Step 1: Write `RunChallenge`**

```bash
#!/usr/bin/env bash
# Challenge entrypoint: extract data, ensure IRIS is up, then run the host-Python
# analysis (server-side LOAD DATA + proxy SQL) and stream CSV — one record per
# line — to stdout. No manual input.
set -euo pipefail
cd "$(dirname "$0")"

X="${X:-${1:-10}}"
DATA="${DATA:-Data}"                 # host dir with GaiaSource_*.csv.gz
NFILES="${GAIA_NFILES:-20}"

# 1. Extract the .gz files into Data/csv (idempotent). This dir is mounted into
#    the IRIS container at /data/gaia (see docker-compose.yml).
GAIA_NFILES="$NFILES" bash scripts/prepare_data.sh "$DATA" "$DATA/csv" >&2

# 2. Ensure the stack is running and wait for IRIS to accept SQL.
docker compose up -d >&2
for _ in $(seq 1 60); do
  if docker compose exec -T iris iris session iris -U USER <<<'halt' >/dev/null 2>&1; then break; fi
  sleep 2
done

# 3. Clear the first-login password-expiry so DB-API can authenticate (idempotent).
docker compose exec -T iris iris session iris -U %SYS >&2 <<'EOF' || true
do ##class(Security.Users).UnExpireUserPasswords("*")
halt
EOF

# 4. Run the analysis from the host over DB-API; only CSV reaches stdout.
GAIA_X="$X" GAIA_NFILES="$NFILES" GAIA_DATA=/data/gaia PYTHONPATH=. python src/gaia/run.py
```

> **NOTE:** `scripts/prepare_data.sh` (Task 4) must honor `GAIA_NFILES` to limit how
> many files it extracts (default 20). If Task 4 hard-coded 20, update it to read
> `${GAIA_NFILES:-20}` as the loop bound. `python` must be the interpreter with
> `intersystems_irispython` installed.

- [ ] **Step 2: Make executable and run end-to-end**

Run:
```bash
chmod +x RunChallenge
X=80 ./RunChallenge > /tmp/out.csv
wc -l /tmp/out.csv && head -3 /tmp/out.csv
awk -F, 'NF!=6{bad++} END{print "bad-field-rows:", bad+0}' /tmp/out.csv
```
Expected: every line has 6 fields (`bad-field-rows: 0`); rows present with high pct_change.

- [ ] **Step 3: Verify full default run completes**

Run: `time ./RunChallenge > /tmp/full.csv; wc -l /tmp/full.csv`
Expected: completes, nonzero rows, all with `pct_change >= 10`. Record wall-clock for the later optimization pass.

- [ ] **Step 4: Commit**

```bash
git add RunChallenge
git commit -m "feat: RunChallenge entrypoint — end-to-end CSV generation"
```

---

## Task 8: REST broker (`src/web/Gaia.REST.cls`)

**Files:**
- Create: `src/web/Gaia.REST.cls`
- MODIFY: `docker-compose.yml` (mount repo read-only into the container so the
  embedded Python can import `src.gaia.sql` and `$system.OBJ.Load` can read the `.cls`)

**Interfaces:**
- Consumes: `src/gaia/sql.build_query(x, limit=...)` via embedded Python (`%SYS.Python.Import`), so the proxy SQL has exactly one definition (DRY with Task 2).
- Produces: `GET /api/variations?x=NN&limit=MM` → JSON array of `{source_id, ra, dec, mag_max, mag_min, pct_change}`.

- [ ] **Step 0: Mount the repo + expose it to embedded Python**

In `docker-compose.yml`, under the `iris` service `volumes:`, ADD:
```yaml
    - type: bind
      source: .
      target: /irisrun/repo
      read_only: true
```
Then `docker compose up -d` to apply. Embedded Python must see the repo root on
`sys.path`; the REST method adds it explicitly (Step 1), so no image change is needed.

- [ ] **Step 1: Write the REST class**

```objectscript
Class Gaia.REST Extends %CSP.REST
{
XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/variations" Method="GET" Call="Variations"/>
</Routes>
}

ClassMethod Variations() As %Status
{
  Set x = $Get(%request.Data("x",1), 10)
  Set limit = $Get(%request.Data("limit",1), 1000)
  // Reuse the exact proxy SQL from src/gaia/sql.py via embedded Python (DRY).
  // build_query has a keyword-only `limit`; call the positional helper to avoid
  // keyword-arg friction across the ObjectScript<->Python boundary.
  Set sys = ##class(%SYS.Python).Import("sys")
  Do sys.path.append("/irisrun/repo")
  Set sqlmod = ##class(%SYS.Python).Import("src.gaia.sql")
  Set sql = sqlmod."build_query_limited"(x, limit)
  Set stmt = ##class(%SQL.Statement).%New()
  $$$ThrowOnError(stmt.%Prepare(sql))
  Set rs = stmt.%Execute()
  Set arr = []
  While rs.%Next() {
    Set o = {}
    Set o."source_id" = rs.%GetData(1), o.ra = rs.%GetData(2), o.dec = rs.%GetData(3)
    Set o."mag_max" = rs.%GetData(4), o."mag_min" = rs.%GetData(5), o."pct_change" = rs.%GetData(6)
    Do arr.%Push(o)
  }
  Write %response.SetHeader("Content-Type","application/json")
  Write arr.%ToJSON()
  Quit $$$OK
}
}
```

> **NOTE:** Calls `src.gaia.sql.build_query_limited(x, limit)` — a tiny positional
> wrapper that must be ADDED to `src/gaia/sql.py` in this task:
> ```python
> def build_query_limited(x, limit):
>     """Positional wrapper for ObjectScript/%SYS.Python callers."""
>     return build_query(x, limit=int(limit))
> ```
> Add a unit test for it in `tests/test_sql.py` (asserts it equals
> `build_query(x, limit=limit)`), run `python -m pytest tests/test_sql.py`, before
> wiring the REST class. This keeps the proxy SQL defined in exactly one place.

- [ ] **Step 2: Load the class and create the web app**

Run:
```bash
docker compose exec -T iris iris session iris -U USER <<'EOF'
do $system.OBJ.Load("/irisrun/repo/src/web/Gaia.REST.cls","ck")
set p=##class(Security.Applications).%OpenId("/api")
if '$isobject(p) { set p=##class(Security.Applications).%New(), p.Name="/api", p.NameSpace="USER", p.DispatchClass="Gaia.REST", p.AutheEnabled=64 do p.%Save() }
write "rest-app-ready",!
halt
EOF
```
Expected: prints `rest-app-ready`.

- [ ] **Step 3: Verify endpoint returns JSON**

Run: `curl -s "http://localhost:8882/api/variations?x=80&limit=3"` (web gateway port)
Expected: a JSON array of ≤3 objects with the six fields.

> **NOTE:** If `8882` routing to the IRIS app needs CSP config, fall back to the IRIS internal web server port. Record the working base URL for Task 9 and the README.

- [ ] **Step 4: Commit**

```bash
git add src/web/Gaia.REST.cls
git commit -m "feat: REST broker reusing the proxy SQL for JSON results"
```

---

## Task 9: Web UI (`web/index.html`)

**Files:**
- Create: `web/index.html`

**Interfaces:**
- Consumes: `GET /api/variations?x=NN` JSON.
- Produces: a single static page with an X input, a "Find" button, and a sortable results table (click column header to sort).

- [ ] **Step 1: Write `index.html`**

```html
<!doctype html><html><head><meta charset="utf-8"><title>Gaia Brightness Variations</title>
<style>body{font-family:system-ui;margin:2rem}table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ccc;padding:4px 8px;text-align:right}th{cursor:pointer;background:#f0f0f0}
td:first-child,th:first-child{text-align:left}</style></head><body>
<h1>Gaia Brightness Variation Detector</h1>
<p>Threshold X (%): <input id="x" type="number" value="10" min="0" step="1">
<input id="limit" type="number" value="500" min="1" step="100" title="max rows">
<button onclick="load()">Find</button> <span id="status"></span></p>
<table><thead><tr id="head"></tr></thead><tbody id="body"></tbody></table>
<script>
const COLS=["source_id","ra","dec","mag_max","mag_min","pct_change"];
let rows=[], sortCol="pct_change", asc=false;
const API=(window.GAIA_API||"/api")+"/variations";
function render(){
  document.getElementById("head").innerHTML=COLS.map(c=>`<th onclick="sortBy('${c}')">${c}</th>`).join("");
  const r=[...rows].sort((a,b)=>{const v=a[sortCol]-b[sortCol]||(""+a[sortCol]).localeCompare(b[sortCol]);return asc?v:-v;});
  document.getElementById("body").innerHTML=r.map(o=>"<tr>"+COLS.map(c=>`<td>${o[c]}</td>`).join("")+"</tr>").join("");
}
function sortBy(c){asc=(c===sortCol)?!asc:false;sortCol=c;render();}
async function load(){
  const x=document.getElementById("x").value, lim=document.getElementById("limit").value;
  document.getElementById("status").textContent="loading…";
  const res=await fetch(`${API}?x=${encodeURIComponent(x)}&limit=${encodeURIComponent(lim)}`);
  rows=await res.json();
  document.getElementById("status").textContent=`${rows.length} objects`;
  render();
}
load();
</script></body></html>
```

- [ ] **Step 2: Serve the page from IRIS and verify in browser**

Decide serving path (record in README). Simplest: copy `web/` into the IRIS CSP directory or add a static route. Then open the served URL.
Run: `curl -s http://localhost:8882/gaia/index.html | head -3` (or chosen path)
Expected: HTML served. Manually confirm in a browser that entering X and clicking Find populates a sortable table.

> **NOTE:** Static-file serving on IRIS/CSP may need a routing tweak. The `iris-hosting-fastapi-react` skill documents the CSP static-file 404 fix — consult it if bare paths 404. Set `window.GAIA_API` if the API base differs from `/api`.

- [ ] **Step 3: Commit**

```bash
git add web/index.html
git commit -m "feat: sortable web UI over the variations REST API"
```

---

## Task 10: README + CI workflow + cleanup

**Files:**
- Create: `README.md`
- Create: `.github/workflows/run-challenge.yml`
- Delete: `docs/superpowers/notes/loaddata-spike.md` (fold key facts into README)

**Interfaces:**
- Produces: install + run docs, the data-reality/proxy explanation (from spec §2–§3), and a CI workflow that runs `RunChallenge`.

- [ ] **Step 1: Write `README.md`**

Sections (each a few sentences, real content — no placeholders):
1. **What it does** — detect Gaia objects whose brightness varies > X%.
2. **The data reality** — DR1 aggregate catalog, one mag/object, IDs partitioned across files (spec §2). Copy the key numbers.
3. **The proxy** — flux-scatter formula and citation (spec §3), with the worked example (source `6476948121350144` → 58.3%).
4. **Architecture** — IRIS SQL compute + embedded-Python ingest diagram.
5. **Install** — `docker compose up -d`; place 20 `GaiaSource_*.csv.gz` in `Data/`.
6. **Run the challenge** — `./RunChallenge` (and `X=25 ./RunChallenge`); output format `source_id,ra,dec,mag_max,mag_min,pct_change`.
7. **Web UI** — URL and usage.
8. **Tests** — `pytest`.
9. **Feedback comments** — note in-code comments capture API/dev feedback per contest rule.

- [ ] **Step 2: Write the CI workflow**

```yaml
# .github/workflows/run-challenge.yml
name: RunChallenge
on: [push, workflow_dispatch]
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Start IRIS
        run: docker compose up -d
      # NOTE: real Gaia data is gitignored. CI uses a tiny committed sample
      # under tests/fixtures/ to prove the pipeline runs unattended.
      - name: Run challenge on sample
        run: DATA=tests/fixtures ./RunChallenge | tee out.csv
      - name: Validate CSV shape
        run: awk -F, 'NF!=6{exit 1}' out.csv
```

> **NOTE:** Add a tiny `tests/fixtures/GaiaSource_000-000-000.csv.gz` (a few hundred rows) so CI runs without the full 800MB dataset. Adjust `prepare_data.sh`/`RunChallenge` to accept fewer than 20 files when running on fixtures (e.g. `GAIA_NFILES` env, default 20). Add this env to `load_dir` and `run.py` if not already present.

- [ ] **Step 3: Create the CI sample fixture**

Run:
```bash
mkdir -p tests/fixtures
zcat Data/GaiaSource_000-000-000.csv.gz | head -500 | gzip -c > tests/fixtures/GaiaSource_000-000-000.csv.gz
```

- [ ] **Step 4: Verify fixture run works locally**

Run: `GAIA_NFILES=1 DATA=tests/fixtures ./RunChallenge | head`
Expected: CSV output from the sample.

- [ ] **Step 5: Commit and push**

```bash
git rm -q docs/superpowers/notes/loaddata-spike.md
git add README.md .github/workflows/run-challenge.yml tests/fixtures/GaiaSource_000-000-000.csv.gz
git commit -m "docs: README + CI workflow; add CI sample fixture"
git push
```

---

## Post-Implementation: Optimization Pass (separate effort)

Once correct and well-rounded, tune `RunChallenge` for the Benchmarking nomination. Candidate levers (measure each):
- Batch/parallelize `LOAD DATA` across files; tune IRIS global buffers.
- Add a bitmap/standard index or precompute `pct_change` as a computed column to speed the sort.
- Skip the web/REST setup in the benchmark path.
- Consider keeping CSVs uncompressed and pre-mounted to remove extraction time.
This is tracked separately, not part of the initial build.
