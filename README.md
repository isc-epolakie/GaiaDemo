# Gaia Brightness Variation Detector — on InterSystems IRIS

Detect astronomical objects in the **Gaia** archive whose brightness varies by more
than a user-supplied threshold **X%**, and produce a sortable list of them with their
sky position and reconstructed brightness range. Built for the 1st InterSystems
Programming Challenge: IRIS SQL does the compute and sort, embedded/host Python does
the ingest and orchestration.

For each qualifying object the system reports:

```
source_id, ra, dec, mag_max (faintest), mag_min (brightest), pct_change (% variation)
```

---

## The data reality (read this first)

It is tempting to assume the Gaia files are per-epoch light curves and to compute
"max magnitude minus min magnitude per object over time." **They are not**, and that
naive approach yields nothing. Empirical inspection of the actual files shows they are
**Gaia DR1 aggregate-catalog** data, not time-series photometry:

- Each `source_id` appears **exactly once per file** (file 000: 218,453 rows =
  218,453 unique IDs).
- Source IDs **do not overlap across files** — the files are partitioned by
  `source_id` range (file 000: 65,408 → ~1.49e16; file 001: ~1.49e16 → ~3.03e16; …).
  The same star never appears in two files.
- Therefore each object has exactly **one** `phot_g_mean_mag`. There is no literal
  per-object magnitude time series in this dataset.
- `phot_variable_flag` is `NOT_AVAILABLE` for every row, so it cannot be used either.

**Consequence:** a literal "min/max magnitude per object over time" is not computable
from these files, and cross-file matching produces zero results. We solve the intended
problem with a scientifically-accepted proxy instead, described next.

## The variability proxy

Gaia DR1's main catalog supports a standard reconstruction of per-object brightness
scatter. Each source carries the mean G-band flux (`phot_g_mean_flux`), the error on
that mean (`phot_g_mean_flux_error`), and the number of CCD transits over the mission
(`phot_g_n_obs`). Because the flux error is the error **on the mean** over N
observations, the per-epoch flux standard deviation is recovered by multiplying back
through √N:

```
std_flux   = sqrt(phot_g_n_obs) * phot_g_mean_flux_error      -- per-epoch flux scatter
frac       = std_flux / phot_g_mean_flux                      -- fractional variation
pct_change = min(frac, 1.0) * 100                             -- % variation (capped at 100)

mag_min    = phot_g_mean_mag - 2.5 * LOG10((flux + std_flux) / flux)   -- brightest
mag_max    = phot_g_mean_mag + 2.5 * LOG10(flux / max(flux - std_flux, flux*0.001))  -- faintest
```

This is the standard variability-amplitude proxy used in published Gaia DR1
variable-star searches (e.g. Belokurov et al. 2017). Magnitude *differences* are
zeropoint-independent, so `mag_max`/`mag_min` are well defined. When the scatter
meets or exceeds the mean flux (`frac ≥ 1`, an extreme/rare case), `pct_change` is
capped at 100% and `flux - std_flux` is floored at `flux*0.001` to keep the logarithm
in-domain and the output finite. Rows with null/non-positive flux, null flux error, or
non-positive `phot_g_n_obs` are skipped (the proxy is undefined).

**Worked example (real data):** source `6476948121350144` → **58.3%** change,
**Δmag 1.45**. (A second validated case: source `12387583330136064` → 51.0%,
Δmag 1.22.)

## Architecture

```
Data/*.csv.gz   (20 files, ~800 MB, gitignored — user-provided)
      │  scripts/prepare_data.sh: gunzip -> Data/csv/  (bind-mounted into IRIS as /data/gaia)
      ▼
Host Python (intersystems-irispython, DB-API @ localhost:8881)
      │  issues SERVER-SIDE `LOAD DATA FROM FILE '/data/gaia/...'`
      │  (the IRIS server reads the mounted CSVs straight off disk — fast bulk load;
      │   only SQL strings + the final result set ever cross the wire)
      ▼
IRIS SQL table  Gaia.Source(source_id, ra, "dec", phot_g_n_obs,
                            phot_g_mean_flux, phot_g_mean_flux_error, phot_g_mean_mag)
      │  ONE parameterized proxy query (src/gaia/sql.py):
      │  computes mag_max/mag_min/pct_change, WHERE pct_change >= X, ORDER BY pct_change DESC
      ├──────────────► RunChallenge        -> CSV to stdout      (headless / benchmark path)
      └──────────────► Gaia.REST /api      -> web/index.html     (enter X, sortable table)
```

**One analysis core.** The proxy math, the `WHERE pct_change >= X` filter, and the
sort all live in a single parameterized SQL query (`src/gaia/sql.py`). Both the
headless `RunChallenge` and the web REST endpoint call that same query — no duplicated
logic. The container brings up IRIS plus the Web Gateway via `docker-compose`; the host
issues the bulk `LOAD DATA` so the server does the heavy lifting against locally-mounted
files.

## Prerequisites

- **Docker** with Docker Compose (the `docker compose` v2 subcommand).
- Access to `containers.intersystems.com` (the IRIS + Web Gateway images) and a valid
  IRIS license key wired into `docker-compose.yml` / `durable/`.
- **Python 3** on the host, with the IRIS DB-API driver:
  ```bash
  pip install intersystems-irispython
  ```
- The **20 Gaia DR1 files** placed in `Data/`, named
  `GaiaSource_000-000-000.csv.gz` through `GaiaSource_000-000-019.csv.gz`. These are
  user-provided and gitignored (~800 MB); nothing is downloaded at runtime.

## Install & run

```bash
docker compose up -d      # start IRIS + Web Gateway
./RunChallenge            # extract data, load into IRIS, print results to stdout
```

`RunChallenge` is the headless contest entrypoint and takes no manual input. It
extracts the `.gz` files into `Data/csv/`, waits for IRIS, clears the first-login
password expiry, runs the proxy query, and streams CSV to stdout.

The threshold defaults to **X = 10** (%). Override it with an env var or argument:

```bash
X=25 ./RunChallenge       # only objects varying by >= 25%
./RunChallenge 25         # same, positional
```

Useful env vars: `DATA` (host data dir, default `Data`), `GAIA_NFILES` (number of
files to process, default `20`).

A full 20-file run at X=10 produces **1,082,096 rows in ~143 s** on the reference
machine.

## Output format

CSV, **one record per line, no header**, sorted by `pct_change` **descending**:

```
source_id,ra,dec,mag_max,mag_min,pct_change
```

where `mag_max` is the faintest (numerically larger) magnitude, `mag_min` the
brightest (numerically smaller), and `pct_change` the fractional variation × 100.

## Web UI

Provision the web showcase once, after the stack is up:

```bash
bash scripts/setup_web.sh
```

This idempotently loads/compiles the REST broker (`src/web/Gaia.REST.cls`) into the USER
namespace, creates an unauthenticated `/csp/gaia/api` REST application and a static
`/csp/gaia/ui` application serving `web/index.html`, and enables `UnknownUser` so the demo
works without login (local demo only — do not do this in production). The apps live under
`/csp/` because the Community Edition built-in web server only forwards that path prefix.
Then:

- **UI:** `http://localhost:52773/csp/gaia/ui/index.html` → enter X, click *Find*, page
  through the results with Prev/Next, and sort the current page by any column.
- **REST:** `http://localhost:52773/csp/gaia/api/variations?x=NN&page=P&pageSize=S` →
  `{"x","page","pageSize","total","rows":[…6 fields…]}`, sorted by % change desc.

Results are **paginated server-side** (`pageSize` capped at 5000): a full result set can
be 160k+ rows, and serialising that into one JSON array overflows IRIS's string stack.
`page` is 1-based; `total` gives the full match count for the pager.

The REST endpoint runs the exact same proxy SQL as `RunChallenge`. To avoid an
embedded-Python import that hangs intermittently on the Community image, the SQL is
inlined in the ObjectScript broker; `tests/test_rest_sql_parity.py` asserts it stays
identical to `src/gaia/sql.py`.

## Running tests

```bash
PYTHONPATH=. python -m pytest -q
```

- `tests/test_sql.py`, `tests/test_proxy_math.py` — pure, host-side (no IRIS needed):
  validate the SQL builder and the reference proxy math.
- `tests/test_integration.py` — runs against a **live IRIS** container and asserts the
  in-database SQL matches the pure-Python reference (parity). It is skipped
  automatically if IRIS is unreachable.

`pytest.ini` confines collection to `tests/` (so pytest does not crawl the container's
`durable/` tree, which contains a symlinked CSP file that crashes collection on
Windows) and disables the cache provider.

## Project layout

```
RunChallenge                 headless entrypoint (bash): extract -> load -> query -> CSV
docker-compose.yml           IRIS + Web Gateway services and bind mounts
pytest.ini                   confines test collection to tests/
scripts/prepare_data.sh      gunzip the .csv.gz files into Data/csv/ (idempotent)
scripts/setup_web.sh         provision /api + /gaia web apps in IRIS (idempotent)
src/gaia/sql.py              THE analysis query (proxy math + filter + sort), pure string builder
src/gaia/proxy.py            pure-Python reference proxy (mirrors sql.py for parity tests)
src/gaia/schema.py           Gaia.Source DDL
src/gaia/loader.py           server-side LOAD DATA bulk ingest
src/gaia/run.py              host DB-API driver: connect, load, query, emit CSV
src/web/Gaia.REST.cls        REST broker (embedded Python, reuses sql.py)
web/index.html               static sortable-table UI
tests/                       unit + integration tests
tests/fixtures/              tiny committed sample file for CI / smoke runs
.github/workflows/           CI that runs the pipeline on the fixture
```

## Notes / feedback

The challenge invited feedback on the developer experience; these are the notable
findings from building on IRIS 2026.1, also captured as comments in the code:

- **`LOAD DATA` has no `COLUMNS (...)` clause.** To load a subset of CSV columns you
  name the target table's columns *exactly* like the wanted CSV header fields and pass
  `USING {"from":{"file":{"header":true}}}`; IRIS then matches header names to columns
  and ignores the rest. (Use `header:true`, not `header:1` — the DB-API driver
  misparses `:1` as a bind parameter.)
- **`dec` is a reserved word.** The CSV header field is literally `dec`, so the table
  column must be named `dec` to match `LOAD DATA` — which means quoting it as `"dec"`
  in the DDL and in every query.
- **`LOG10(x)` exists; two-arg `LOG(10, x)` does not.** Plain `LOG(x)` is natural log.
  The proxy uses `LOG10(...)`.
- **The host DB-API client issues a server-side `LOAD DATA`.** The heavy work is
  server-side regardless of client: IRIS reads the mounted files directly off disk, and
  only SQL strings and the final result set cross the wire. So a host Python process
  using `intersystems-irispython` gives full bulk-load speed with the least
  orchestration overhead — and it was the only reliably-working embedded-`iris` path in
  this image (the in-container `irispython` CLI could not import the `iris` module).
- **First-login password expiry** on a fresh container blocks DB-API auth until
  cleared; `RunChallenge` clears it idempotently with
  `##class(Security.Users).UnExpireUserPasswords("*")`.
