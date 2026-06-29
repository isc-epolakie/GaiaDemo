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
            # CRITICAL FIX: IRIS DB-API returns computed columns as strings
            mag_max, mag_min, pct = float(mag_max), float(mag_min), float(pct)
            assert abs(mag_max - ref["mag_max"]) < 1e-6
            assert abs(mag_min - ref["mag_min"]) < 1e-6
            assert abs(pct - ref["pct_change"]) < 1e-6

def test_results_sorted_desc(iris_conn):
    _setup(iris_conn)
    cur = iris_conn.cursor()
    cur.execute(build_query(0))
    # CRITICAL FIX: coerce to float for correct numeric comparison
    pcts = [float(r[5]) for r in cur.fetchall()]
    assert pcts == sorted(pcts, reverse=True)
