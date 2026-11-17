"""The pricing client: one batched call per request, a hard 150 ms deadline,
and a last-known-good price cache to fall back on when pricing is slow or failing.

This is the mitigation the incident drill (Phase 4) demonstrates. With the
fallback switched off (PRICING_FALLBACK_ENABLED=false), any pricing problem
becomes a 503 instead.
"""
import asyncio
import time
from dataclasses import dataclass

import httpx
from opentelemetry import metrics

# The telemetry standard: count every call to a dependency by outcome. The golden
# path's dependency alert (share of calls failing or timing out, D22) is built on it.
_calls = metrics.get_meter("order-validation").create_counter(
    "dependency.calls", unit="{call}", description="Calls to dependencies, by outcome")


class PricingUnavailable(Exception):
    """Pricing failed and the cache can't cover the order, so the API answers 503."""

    def __init__(self, reason: str):
        super().__init__(f"pricing unavailable ({reason}) and no usable cached prices")
        self.reason = reason


class _Failed(Exception):
    """Internal: one pricing call failed, for this reason: timeout, error or auth."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class PriceResult:
    prices: dict[str, int]               # sku -> price in minor units
    source: str                          # "live" or "cache"
    fallback_reason: str | None = None   # why the cache was used: timeout, error or auth


class PricingClient:
    def __init__(self, http: httpx.AsyncClient, base_url: str, token: str,
                 timeout_s: float, cache_ttl_s: float, fallback_enabled: bool,
                 clock=time.monotonic):
        self._http = http                    # one shared client, created at startup (step 9)
        self._url = f"{base_url}/prices"
        self._headers = {"Authorization": f"Bearer {token}"}
        self._timeout_s = timeout_s
        self._cache_ttl_s = cache_ttl_s
        self._fallback_enabled = fallback_enabled
        self._clock = clock                  # replaceable, so tests can move time forward
        self._cache: dict[str, tuple[int, float]] = {}   # sku -> (price, when we got it)

    async def get_prices(self, skus: list[str]) -> PriceResult:
        """Current prices for these SKUs: live if pricing answers in time, else from the cache."""
        try:
            prices = await self._fetch(skus, self._timeout_s)
        except _Failed as failure:
            return self._from_cache(skus, failure.reason)
        self._remember(prices)
        return PriceResult(prices, "live")

    async def refresh(self, skus: list[str], timeout_s: float) -> bool:
        """Fetch prices only to fill the cache: at startup and in the background.

        This is not on a customer's request path, so it can wait longer than 150 ms.
        It never raises: if pricing is down, the cache simply keeps what it has.
        """
        try:
            self._remember(await self._fetch(skus, timeout_s))
            return True
        except _Failed:
            return False

    async def _fetch(self, skus: list[str], timeout_s: float) -> dict[str, int]:
        """One call to pricing, counted by outcome: ok, timeout, error or auth."""
        try:
            prices = await self._call(skus, timeout_s)
        except _Failed as failure:
            _calls.add(1, {"dependency": "pricing", "outcome": failure.reason})
            raise
        _calls.add(1, {"dependency": "pricing", "outcome": "ok"})
        return prices

    async def _call(self, skus: list[str], timeout_s: float) -> dict[str, int]:
        """One call to pricing with a hard deadline. No retries: a retry can't fit in our 250 ms."""
        try:
            # The deadline covers the whole call: connect, send, wait, read.
            async with asyncio.timeout(timeout_s):
                response = await self._http.post(self._url, json={"skus": skus}, headers=self._headers)
        except TimeoutError:
            raise _Failed("timeout")
        except httpx.HTTPError:
            raise _Failed("error")           # couldn't connect, connection dropped, ...

        if response.status_code in (401, 403):
            raise _Failed("auth")            # our credentials were rejected
        if response.status_code != 200:
            raise _Failed("error")
        try:
            return {sku: int(price) for sku, price in response.json()["prices"].items()}
        except (ValueError, KeyError, TypeError, AttributeError):
            raise _Failed("error")           # it answered, but not in a form we can read

    def _from_cache(self, skus: list[str], reason: str) -> PriceResult:
        """The fallback: recent prices, but only if EVERY SKU has one."""
        if not self._fallback_enabled:
            raise PricingUnavailable(reason)

        now = self._clock()
        prices = {}
        for sku in skus:
            cached = self._cache.get(sku)
            if cached is None or now - cached[1] > self._cache_ttl_s:
                # One missing or stale price: refuse to guess. A made-up "no price"
                # refusal would look like a correct answer and hide the outage from the SLO.
                raise PricingUnavailable(reason)
            prices[sku] = cached[0]
        return PriceResult(prices, "cache", reason)

    def _remember(self, prices: dict[str, int]) -> None:
        """Store prices in the cache, with the time we got them."""
        now = self._clock()
        for sku, price in prices.items():
            self._cache[sku] = (price, now)
