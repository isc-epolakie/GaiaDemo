# tests/conftest.py
import os
import pytest

@pytest.fixture(scope="session")
def iris_conn():
    iris = pytest.importorskip("iris")
    try:
        conn = iris.connect(
            os.environ.get("GAIA_HOST", "localhost"),
            int(os.environ.get("GAIA_PORT", "8881")),
            os.environ.get("GAIA_NS", "USER"),
            os.environ.get("GAIA_USER", "_SYSTEM"),
            os.environ.get("GAIA_PW", "SYS"),
        )
    except Exception as e:
        pytest.skip(f"IRIS not reachable: {e}")
    yield conn
    conn.close()
