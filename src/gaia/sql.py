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
SELECT {top}source_id, ra, dec, mag_max, mag_min, pct_change FROM (
    SELECT
        source_id,
        ra,
        "dec" AS dec,
        phot_g_mean_mag + 2.5*LOG10({_FLUX} / GREATEST({_FLUX} - {_STD}, {_FLUX}*0.001)) AS mag_max,
        phot_g_mean_mag - 2.5*LOG10(({_FLUX} + {_STD}) / {_FLUX})                         AS mag_min,
        {_PCT}                                                                           AS pct_change
    FROM {TABLE}
    WHERE {_FLUX} > 0 AND phot_g_n_obs > 0 AND phot_g_mean_flux_error IS NOT NULL
)
WHERE pct_change >= {x}
ORDER BY pct_change DESC
""".strip()
