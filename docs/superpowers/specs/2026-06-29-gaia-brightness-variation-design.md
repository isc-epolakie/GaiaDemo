# Gaia Brightness Variation Detector on InterSystems IRIS — Design

**Date:** 2026-06-29
**Context:** 1st InterSystems Programming Challenge submission.

## 1. Problem Statement

Using publicly available Gaia observation archives, identify astronomical objects
whose brightness changed over time by more than a user-provided threshold **X%**,
and produce a sortable list of results containing:

- `source_id`
- `ra`, `dec`
- maximum and minimum brightness (`phot_g_mean_mag`)
- % of change

Scope (per contest update): process only the first 20 files matching
`GaiaSource_000-000-000.*` through `GaiaSource_000-000-019.*`.

## 2. Critical Data Reality (the part that shapes everything)

Empirical inspection of the actual files reveals these are **Gaia DR1 aggregate
catalog** data, *not* per-epoch (time-series) photometry:

- Each `source_id` appears **exactly once per file** (218,453 rows = 218,453 unique IDs in file 000).
- Source IDs **do not overlap across files** — files are partitioned by `source_id`
  range (file 000: 65408 → 1.49e16; file 001: 1.49e16 → 3.03e16; …). The same star
  never appears in two files.
- Therefore each object has exactly **one** `phot_g_mean_mag`. There is no literal
  per-object time series of magnitude in this dataset.
- `phot_variable_flag` is `NOT_AVAILABLE` for every row.

**Consequence:** "max and min magnitude per object over time" cannot be computed
directly — naive cross-file matching yields zero results, and the variability flag
is unusable.

## 3. Solution: Flux-Scatter Variability Proxy

Gaia DR1's main catalog supports a scientifically-accepted reconstruction of
per-object brightness scatter. Each source carries `phot_g_mean_flux`,
`phot_g_mean_flux_error`, and `phot_g_n_obs` (number of CCD transits over the
mission). The flux *error* is the error **on the mean** over those N observations, so
the per-epoch flux scatter (standard deviation) is recovered as:

```
std_flux   = sqrt(phot_g_n_obs) * phot_g_mean_flux_error      -- per-epoch flux scatter
frac       = std_flux / phot_g_mean_flux                      -- fractional variation
flux_max   = phot_g_mean_flux + std_flux
flux_min   = phot_g_mean_flux - std_flux
mag_min    = phot_g_mean_mag - 2.5 * LOG10(flux_max / phot_g_mean_flux)   -- brightest
mag_max    = phot_g_mean_mag + 2.5 * LOG10(phot_g_mean_flux / flux_min)   -- faintest
pct_change = frac * 100
```

This is the standard variability-amplitude proxy used in published Gaia DR1
variable-star searches (e.g. Belokurov et al. 2017). The magnitude *difference* is
zeropoint-independent, so `mag_max`/`mag_min` are well-defined.

**Validated on real data:** source `6476948121350144` → 58.3% change, Δmag 1.45;
source `12387583330136064` → 51.0% change, Δmag 1.22.

The README will document this data-reality gap honestly and cite the proxy.

### Edge cases / filtering rules

- Skip rows where `phot_g_mean_flux` is null/<=0, `phot_g_n_obs` is null/<=0, or
  `phot_g_mean_flux_error` is null (cannot compute proxy).
- When `std_flux >= phot_g_mean_flux` (`frac >= 1`, i.e. `flux_min <= 0`),
  `mag_max` (faintest) is undefined via the log. Clamp `flux_min` to a small
  positive floor OR cap `pct_change` at 100% and define `mag_max` from the floor;
  decision recorded in plan. Default: cap reported `pct_change` at 100% and compute
  `mag_max` from a floored `flux_min` so output stays finite. These extreme rows are
  rare and flagged.

### Confirmed column indices (1-based, after header)

| Field | Index |
|---|---|
| `source_id` | 2 |
| `ra` | 5 |
| `dec` | 7 |
| `phot_g_n_obs` | 49 |
| `phot_g_mean_flux` | 50 |
| `phot_g_mean_flux_error` | 51 |
| `phot_g_mean_mag` | 52 |

## 4. Architecture

```
Data/*.csv.gz  (20 files, gitignored — assumed pre-downloaded)
        |  embedded-Python bulk loader (streams gzip -> IRIS SQL)
        v
IRIS SQL table  GaiaSource(source_id, ra, dec, n_obs, flux, flux_err, mag)
        |  single parameterized SQL query: proxy math + WHERE pct >= X + ORDER BY
        +--------------------> RunChallenge  -> CSV to stdout   (benchmark path)
        +--------------------> REST endpoint -> CSP/JS web UI    (enter X, sortable table)
```

**Design principles:**

- **One analysis core**: a single parameterized SQL query holds the proxy math, the
  `WHERE pct_change >= X` filter, and `ORDER BY`. Both the headless script and the
  web UI call the same query — no duplicated logic.
- **Direct bulk-load only** (no Interoperability production). RunChallenge is judged
  on wall-clock speed, so the fast path is the only path.
- **IRIS as primary platform**: SQL performs the compute and sort; embedded Python
  performs ingest and orchestration (+3 Experts Python bonus).
- **Well-rounded first, then optimize**: build correct + readable, then tune
  RunChallenge for the Benchmarking nomination (bulk insert batching, indexing,
  computed column vs. inline expression).

## 5. Components

| Component | Purpose | Depends on |
|---|---|---|
| `src/schema` (Python DDL) | Define `GaiaSource` table | IRIS |
| `src/loader.py` | Embedded Python: stream each `.csv.gz`, batched bulk INSERT | IRIS, gzip, csv |
| `src/analyze.sql` | Proxy + threshold filter + sort query (parameterized on X) | populated table |
| `RunChallenge` (+ `RunChallenge.py`) | Headless: load -> query at default X -> emit CSV lines, no manual input | loader, analyze |
| `web/` (CSP page + REST class) | Input X, fetch JSON results, client-side sortable table | REST -> analyze |
| `README.md` | Install steps, how it works, the data-reality explanation | — |

### Data table schema

```
GaiaSource (
  source_id   BIGINT     PRIMARY KEY,
  ra          DOUBLE,
  dec         DOUBLE,
  n_obs       INTEGER,
  flux        DOUBLE,
  flux_err    DOUBLE,
  mag         DOUBLE
)
```

Only the columns needed for the proxy are stored, keeping ingest lean.

## 6. RunChallenge Contract

- Lives at repo root, named `RunChallenge` (per contest rule), runs with no manual input.
- Reads the 20 files from `Data/` (configurable via env var; default `./Data`).
- Default threshold X supplied via env var or argument with a sensible default
  (e.g. `X=10`) so CI runs unattended.
- Emits CSV, **one record per line**, to stdout in the format below.

## 7. Output Format

Comma-separated, one record per line:

```
source_id,ra,dec,mag_max,mag_min,pct_change
```

Where `mag_max` = faintest (numerically larger magnitude), `mag_min` = brightest
(numerically smaller magnitude), `pct_change` = fractional variation x 100.
Sorted by `pct_change` descending by default. A header line MAY be emitted; the plan
will decide based on the contest's CSV expectations (default: include a header).

## 8. Out of Scope (YAGNI)

- Interoperability / filedrop production (described conceptually but not built; the
  fast bulk-load path is what we ship).
- Downloading files at runtime (assume pre-downloaded into `Data/`).
- Authentication on the web UI.
- Handling Gaia data releases other than the DR1-style files provided.

## 9. Success Criteria

1. RunChallenge runs unattended and emits correct, complete CSV for the 20 files.
2. Output contains all required fields and is sortable by % change.
3. Web UI accepts X and renders a sortable result table backed by the same SQL.
4. README explains installation, operation, and the data-reality / proxy rationale.
5. Solution uses IRIS SQL as the primary compute platform with embedded Python.
6. Performance: full 20-file load + query completes in a benchmark-competitive time
   (target to be measured and tuned in the optimization pass).
