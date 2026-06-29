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
