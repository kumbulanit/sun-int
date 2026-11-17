"""Tests for the pricing client: the deadline, the cache fallback and its limits.

No network: httpx's MockTransport stands in for the pricing service, and a fake
clock lets the tests jump forward in time instead of waiting.
"""
import asyncio
import json
import time

import httpx
import pytest

from app.pricing import PricingClient, PricingUnavailable

SKUS = ["SKU-0001", "SKU-0048"]
LIVE_PRICES = {"SKU-0001": 1299, "SKU-0048": 39900}


class FakePricing:
    """A pretend pricing service. Tests switch its mode, like the real fake's admin switch."""

    def __init__(self):
        self.mode = "normal"
        self.requests = []

    async def handle(self, request):
        self.requests.append(request)
        if self.mode == "slow":
            await asyncio.sleep(1)                      # far past the 150 ms deadline
        if self.mode == "down":
            raise httpx.ConnectError("connection refused")
        if self.mode == "error":
            return httpx.Response(500)
        if self.mode == "auth_fail":
            return httpx.Response(401)
        if self.mode == "garbage":
            return httpx.Response(200, text="not json")
        # Like the real service: prices only for the SKUs asked about.
        asked = json.loads(request.content)["skus"]
        return httpx.Response(200, json={"prices": {sku: LIVE_PRICES[sku] for sku in asked if sku in LIVE_PRICES}})


class FakeClock:
    """A clock the test moves by hand."""

    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def make_client(pricing, clock, fallback_enabled=True):
    http = httpx.AsyncClient(transport=httpx.MockTransport(pricing.handle))
    return PricingClient(http, "http://pricing.test", "test-token", timeout_s=0.15,
                         cache_ttl_s=60, fallback_enabled=fallback_enabled, clock=clock)


@pytest.fixture
def pricing():
    return FakePricing()


@pytest.fixture
def clock():
    return FakeClock()


# Normal operation
async def test_live_prices(pricing, clock):
    result = await make_client(pricing, clock).get_prices(SKUS)
    assert (result.prices, result.source, result.fallback_reason) == (LIVE_PRICES, "live", None)

async def test_one_call_with_all_skus_and_the_token(pricing, clock):
    await make_client(pricing, clock).get_prices(SKUS)
    assert len(pricing.requests) == 1
    assert json.loads(pricing.requests[0].content) == {"skus": SKUS}
    assert pricing.requests[0].headers["Authorization"] == "Bearer test-token"


# Falling back: warm the cache with one good call, then break pricing
@pytest.mark.parametrize("mode, reason", [
    ("slow", "timeout"), ("down", "error"), ("error", "error"),
    ("garbage", "error"), ("auth_fail", "auth"),
])
async def test_pricing_problems_fall_back_to_recent_prices(pricing, clock, mode, reason):
    client = make_client(pricing, clock)
    await client.get_prices(SKUS)
    pricing.mode = mode
    result = await client.get_prices(SKUS)
    assert (result.prices, result.source, result.fallback_reason) == (LIVE_PRICES, "cache", reason)

async def test_the_deadline_cuts_a_slow_call_short(pricing, clock):
    client = make_client(pricing, clock)
    await client.get_prices(SKUS)
    pricing.mode = "slow"                       # pricing would take 1 s
    start = time.monotonic()
    await client.get_prices(SKUS)
    assert time.monotonic() - start < 0.5       # we gave up at ~0.15 s

async def test_no_retries(pricing, clock):
    client = make_client(pricing, clock)
    await client.get_prices(SKUS)
    pricing.mode = "error"
    await client.get_prices(SKUS)
    assert len(pricing.requests) == 2           # one per get_prices: the failure was not retried


# When the cache can't help: the API will answer 503
async def test_slow_pricing_with_an_empty_cache_is_unavailable(pricing, clock):
    pricing.mode = "slow"
    with pytest.raises(PricingUnavailable) as caught:
        await make_client(pricing, clock).get_prices(SKUS)
    assert caught.value.reason == "timeout"

async def test_cached_prices_last_60_seconds(pricing, clock):
    client = make_client(pricing, clock)
    await client.get_prices(SKUS)
    pricing.mode = "error"
    clock.now += 60
    assert (await client.get_prices(SKUS)).source == "cache"    # exactly 60 s old: still fine
    clock.now += 1
    with pytest.raises(PricingUnavailable):                       # 61 s old: too stale
        await client.get_prices(SKUS)

async def test_one_missing_price_means_unavailable(pricing, clock):
    client = make_client(pricing, clock)
    await client.get_prices(["SKU-0001"])       # only SKU-0001 is cached
    pricing.mode = "error"
    with pytest.raises(PricingUnavailable):
        await client.get_prices(SKUS)           # SKU-0048 has no cached price: refuse to guess

async def test_fallback_switched_off_fails_straight_away(pricing, clock):
    client = make_client(pricing, clock, fallback_enabled=False)
    await client.get_prices(SKUS)               # the cache is warm...
    pricing.mode = "error"
    with pytest.raises(PricingUnavailable):     # ...but switched off, so it isn't used
        await client.get_prices(SKUS)


# Keeping the cache warm (at startup and in the background)
async def test_refresh_fills_the_cache_for_products_nobody_has_ordered_yet(pricing, clock):
    client = make_client(pricing, clock)
    assert await client.refresh(SKUS, timeout_s=2) is True
    pricing.mode = "error"
    result = await client.get_prices(SKUS)        # the first customer request, during an outage
    assert (result.source, result.prices) == ("cache", LIVE_PRICES)

async def test_refresh_never_raises_when_pricing_is_down(pricing, clock):
    pricing.mode = "down"
    assert await make_client(pricing, clock).refresh(SKUS, timeout_s=2) is False

async def test_refresh_can_wait_longer_than_a_customer_request(pricing, clock):
    pricing.mode = "slow"                          # 1 s: too slow for a request (150 ms)...
    client = make_client(pricing, clock)
    assert await client.refresh(SKUS, timeout_s=2) is True   # ...but fine for a background refresh
