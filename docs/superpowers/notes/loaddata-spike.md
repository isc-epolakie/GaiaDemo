# Task 1 Spike Findings — LOAD DATA on IRIS 2026.1

## Connection
- IRIS 2026.1 (Build 234U), container `IRISGAIADEMO`, healthy.
- Run SQL via ObjectScript session: `docker compose exec -T iris iris session iris -U USER`.
- Namespace `USER`. Host SQL port 1972 → published on host as 8881.
- `irispython` lives at `/usr/irissys/bin/irispython` but is NOT on PATH and the
  `iris` module did not import via `irispython -c` in plain `exec`. **Decision:**
  the entrypoint (Task 5) runs SQL through `iris session` + an ObjectScript/SQL
  routine OR via `%SYS.Python`; the loader is plain SQL `LOAD DATA`, so embedded
  Python is not strictly required for ingest. Reassess in Task 5.

## LOAD DATA — the working pattern
- There is **NO `COLUMNS (...)` clause** in IRIS LOAD DATA. `COLUMNS` → syntax error
  (`<end of statement> expected, IDENTIFIER (COLUMNS) found`).
- To load a **subset** of CSV columns: create the target table with columns **named
  exactly** like the CSV header fields you want, then:
  ```sql
  LOAD DATA FROM FILE '/path/file.csv'
    INTO Gaia.Source
    USING {"from":{"file":{"header":1}}}
  ```
  With `header:1`, IRIS matches CSV header names to table column names and loads
  only the matching columns; the other 50 CSV columns are ignored. **Verified:**
  1000 rows loaded, values exact (source_id=65408 → ra=44.9961…, dec=0.005616…,
  n_obs=30, flux=1567.255…, mag=17.5369…).

## Reserved word
- `dec` is a **reserved word**. The table column must be quoted as `"dec"` in DDL
  and in every query (the CSV header is literally `dec`, so the column must be named
  `dec` to match — quote it).

## Math functions
- `LOG(x)` is **natural log (ln)**. Two-arg `LOG(10, x)` is **NOT supported**
  (syntax error).
- `LOG10(x)` **exists and works**: `LOG10(1000) = 3`.
- `GREATEST(a,b)` and `LEAST(a,b)` work.
- **Decision:** use `LOG10(...)` in the proxy SQL (NOT `LOG(10,...)`).

## Required schema (revised — column names MUST match CSV header)
```sql
CREATE TABLE Gaia.Source (
  source_id BIGINT NOT NULL,
  ra DOUBLE,
  "dec" DOUBLE,
  phot_g_n_obs INTEGER,
  phot_g_mean_flux DOUBLE,
  phot_g_mean_flux_error DOUBLE,
  phot_g_mean_mag DOUBLE
)
```

## Connection model decision: Host Python + DB-API
- The heavy work (LOAD DATA, aggregation) is server-side regardless of client; the
  server reads mounted files directly off disk. Only SQL strings + final result set
  cross the wire. So connection model ≈ neutral on raw speed; host DB-API has the
  lowest orchestration overhead and is the only working embedded-`iris` path in this image.
- **`irispython` CLI in-container is broken** (`ModuleNotFoundError: iris`) — do NOT use.
- `%SYS.Python` inside an `iris session` works (Python 3.12.3) but is awkward to drive unattended.
- **Chosen:** host Python (`intersystems_irispython`) connects `iris.connect("localhost",8881,"USER","_SYSTEM","SYS")`,
  issues server-side `LOAD DATA`, runs proxy SQL, prints CSV.

## Two gotchas (binding)
1. **Password expiry:** fresh CD container requires a password change before DB-API can
   connect (`Password change required`). Fix idempotently at startup:
   `iris session iris -U %SYS` → `do ##class(Security.Users).UnExpireUserPasswords("*")`
   (returns 1). RunChallenge must run this after `docker compose up`.
2. **LOAD DATA USING clause:** use `{"from":{"file":{"header":true}}}` — the DB-API driver
   misparses `header:1` as bind parameter `:1` (`First value cannot be a digit`). Use `true`.
- **LOAD DATA path is the CONTAINER path** (server reads it), e.g. `/data/gaia/GaiaSource_000-000-000.csv`,
  NOT the host path. Requires `./Data/csv` mounted to `/data/gaia`.

## Impact on plan
- **Task 2 (sql.py):** column names are now `phot_g_mean_flux`, `phot_g_mean_flux_error`,
  `phot_g_n_obs`, `phot_g_mean_mag`, `"dec"` (quoted). Use `LOG10(...)`.
- **Task 4 (schema/loader):** DDL uses the header-matched names above; loader uses the
  no-COLUMNS LOAD DATA form.
- **Output aliasing:** SELECT still outputs `source_id, ra, dec, mag_max, mag_min,
  pct_change` (alias `"dec"` → `dec` in output is fine; column position is what RunChallenge emits).
