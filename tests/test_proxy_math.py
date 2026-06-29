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
