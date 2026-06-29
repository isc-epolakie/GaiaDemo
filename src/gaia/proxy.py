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
