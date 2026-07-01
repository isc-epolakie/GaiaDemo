"""Guard against drift between the two hand-maintained copies of the proxy SQL:
the canonical Python builder (src/gaia/sql.py) and the SQL inlined in the
ObjectScript REST broker (src/web/Gaia.REST.cls).

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
    """Reduce to a canonical token stream: drop ALL whitespace, normalise the
    two intentional differences (TOP <n> vs the spliced TOP, and the threshold
    literal vs the '?' bind param), so only real SQL differences fail."""
    s = re.sub(r"\s+", "", s)
    s = re.sub(r"TOP\d+", "TOP", s)          # TOP 1000 -> TOP
    s = s.replace(">=0.0", ">=?")            # builder literal -> bind param form
    return s


def _rest_sql() -> str:
    """Reconstruct the SQL string the REST class builds, from the .cls source.

    The SQL() method concatenates ObjectScript string literals with '_' (with a
    non-literal `top` variable spliced after "TOP "). We pull the literals out of
    the method body and join them, then unescape the doubled quotes ("" -> ")
    that ObjectScript requires. The dropped `top` splice is handled by _norm,
    which collapses "TOP <n>" and a bare "TOP" alike."""
    text = CLS.read_text(encoding="utf-8")
    body = text.split("ClassMethod SQL(", 1)[1]
    body = body.split("Quit ", 1)[1].split("\n}", 1)[0]
    literals = re.findall(r'"((?:[^"]|"")*)"', body)
    return "".join(lit.replace('""', '"') for lit in literals)


def test_rest_sql_matches_builder():
    assert _norm(_rest_sql()) == _norm(build_query(0, limit=1000))
