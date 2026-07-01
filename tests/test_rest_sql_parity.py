"""Guard against drift between the two hand-maintained copies of the proxy SQL:
the canonical Python builder (src/gaia/sql.py) and the SQL inlined in the
ObjectScript REST broker (src/web/Gaia.REST.cls, ProxySQL()).

The REST broker inlines the SQL (rather than importing src.gaia.sql via
%SYS.Python) because that embedded-Python import hangs intermittently on the
IRIS Community Edition image. This test ensures the two definitions stay
identical in every proxy expression, so a change to one without the other fails
CI. It is pure host-side text comparison — no IRIS needed.
"""
import re
from pathlib import Path

from src.gaia.sql import build_query

CLS = Path(__file__).resolve().parent.parent / "src" / "web" / "Gaia.REST.cls"


def _norm(s: str) -> str:
    """Canonical token stream: drop ALL whitespace and normalise the intentional
    differences so only real SQL differences fail. The REST ProxySQL() uses a '?'
    bind param for the threshold and omits ORDER BY (the paginator adds its own
    ROW_NUMBER ordering); build_query inlines the threshold and appends ORDER BY."""
    s = re.sub(r"\s+", "", s)
    s = s.replace(">=0.0", ">=?")            # builder literal -> bind param form
    s = s.replace("ORDERBYpct_changeDESC", "")  # builder-only trailing sort
    return s


def _rest_proxy_sql() -> str:
    """Reconstruct the string ProxySQL() builds, from the .cls source. The method
    concatenates ObjectScript string literals with '_'; join the literals and
    unescape the doubled quotes ("" -> ") that ObjectScript requires."""
    text = CLS.read_text(encoding="utf-8")
    body = text.split("ClassMethod ProxySQL(", 1)[1]
    body = body.split("Quit ", 1)[1].split("\n}", 1)[0]
    literals = re.findall(r'"((?:[^"]|"")*)"', body)
    return "".join(lit.replace('""', '"') for lit in literals)


def test_rest_proxy_matches_builder():
    # build_query(0) with no limit == inner proxy SELECT + threshold filter +
    # ORDER BY; ProxySQL() is the same minus ORDER BY (normalised away).
    assert _norm(_rest_proxy_sql()) == _norm(build_query(0))
