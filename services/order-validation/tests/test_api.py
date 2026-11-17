"""End-to-end tests against the running stack: the real API, Postgres and the fake
pricing service. `helm test` runs them inside the cluster.

Skipped unless API_URL is set, so a plain `pytest` still runs just the fast unit tests.
Prices come from the fake: the SKU number x 100 (SKU-0001 costs 100).
The 503 path (no usable cached price) is covered by the unit tests; in the cluster every pod's cache is always warm.
"""
import os

import httpx
import pytest

API_URL = os.environ.get("API_URL")
PRICING_URL = os.environ.get("PRICING_URL")
pytestmark = pytest.mark.skipif(not API_URL, reason="API_URL not set: run with `helm test`")


def validate(*lines):
    """POST an order made of (sku, quantity, unit_price) lines."""
    body = {"items": [{"sku": s, "quantity": q, "unit_price": p} for s, q, p in lines]}
    return httpx.post(f"{API_URL}/orders/validate", json=body, timeout=5)


def pricing_mode(**mode):
    """Flip the fake pricing service's misbehave switch."""
    httpx.post(f"{PRICING_URL}/admin/mode", json=mode, timeout=5).raise_for_status()


@pytest.fixture(autouse=True)
def pricing_back_to_normal():
    yield
    pricing_mode(mode="normal")


def test_valid_order():
    response = validate(("SKU-0001", 2, 100))
    assert response.status_code == 200
    assert response.json() == {"valid": True, "problems": [], "price_source": "live"}


def test_refusals_are_answers_not_errors():
    response = validate(("SKU-0046", 1, 4600), ("SKU-0048", 3, 4800), ("SKU-0002", 1, 99))
    assert response.status_code == 200
    assert [(p["sku"], p["code"]) for p in response.json()["problems"]] == [
        ("SKU-0046", "OUT_OF_STOCK"), ("SKU-0048", "QUANTITY_LIMIT"), ("SKU-0002", "PRICE_CHANGED")]


def test_an_order_of_unknown_products_needs_no_prices():
    response = validate(("SKU-9999", 1, 100))
    assert response.json()["problems"][0]["code"] == "UNKNOWN_ITEM"
    assert response.json()["price_source"] is None


def test_malformed_requests_are_400():
    assert validate(("SKU-0001", 0, 100)).status_code == 400                         # quantity 0
    assert validate(("SKU-0001", 1, 100), ("SKU-0001", 1, 100)).status_code == 400   # same SKU twice


def test_health_checks():
    assert httpx.get(f"{API_URL}/healthz").status_code == 200
    assert httpx.get(f"{API_URL}/readyz").status_code == 200


def test_pricing_errors_fall_back_to_the_cache():
    pricing_mode(mode="error", error_pct=100, duration_s=60)
    # Nobody ordered SKU-0010 in these tests: each pod cached it by itself at startup.
    response = validate(("SKU-0010", 1, 1000))
    assert response.status_code == 200
    assert response.json()["price_source"] == "cache"


def test_slow_pricing_is_cut_short_and_answered_from_the_cache():
    pricing_mode(mode="slow", slow_pct=100, slow_ms_min=2000, slow_ms_max=2000, duration_s=60)
    response = validate(("SKU-0005", 1, 500))
    assert response.json()["price_source"] == "cache"
    assert response.elapsed.total_seconds() < 0.25     # inside the SLO, though pricing takes 2 s


def test_rejected_credentials_fall_back_to_the_cache():
    pricing_mode(mode="auth_fail", duration_s=60)
    assert validate(("SKU-0006", 1, 600)).json()["price_source"] == "cache"
