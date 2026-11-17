"""The order validation API.

POST /orders/validate   check an order: catalogue from Postgres, prices from the
                        pricing service, then the rules in validation.py
GET  /healthz           liveness: is the process up?
GET  /readyz            readiness: can it reach Postgres? (never pricing)
"""
import asyncio
import logging
from contextlib import asynccontextmanager
from dataclasses import asdict

import asyncpg
import httpx
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

from app.catalogue import create_pool, load_catalogue, load_sellable_skus
from app.logs import setup_logging
from app.pricing import PricingClient, PricingUnavailable
from app.settings import load_settings
from app.validation import OrderLine, validate_order

log = logging.getLogger("app")

# JSON logs from the moment the app is imported, so even uvicorn's first lines are
# JSON. The level is set again at startup, once load_settings() has checked LOG_LEVEL.
setup_logging("INFO")


async def refresh_prices(app: FastAPI) -> bool:
    """Fill this pod's price cache for every product on sale. True if it worked."""
    skus = await load_sellable_skus(app.state.db_pool)
    return await app.state.pricing.refresh(skus, app.state.settings.pricing_refresh_timeout_s)


async def keep_prices_fresh(app: FastAPI) -> None:
    """Background job: refresh the price cache every PRICING_REFRESH_INTERVAL_S.
    It must never crash, or the cache would quietly go stale."""
    while True:
        await asyncio.sleep(app.state.settings.pricing_refresh_interval_s)
        try:
            if not await refresh_prices(app):
                log.warning("price refresh failed: the cache keeps what it has")
        except Exception as error:          # e.g. the database is briefly unreachable
            log.warning("price refresh failed", extra={"fields": {"error": repr(error)}})


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: settings, logs, the database pool, the pricing client. Shutdown: close them."""
    settings = load_settings()                  # refuses to start if anything is missing or wrong
    setup_logging(settings.log_level)
    app.state.settings = settings
    app.state.db_pool = await create_pool(
        settings.database_url, settings.db_pool_size, settings.db_statement_timeout_ms)
    # At most 100 pricing calls at once, so a slow pricing service can't take all our
    # capacity (Little's law: ~90 in flight at 600 req/s with the 150 ms deadline).
    app.state.http = httpx.AsyncClient(limits=httpx.Limits(max_connections=100))
    app.state.pricing = PricingClient(
        app.state.http, settings.pricing_url, settings.pricing_token, settings.pricing_timeout_s,
        settings.pricing_cache_ttl_s, settings.pricing_fallback_enabled)
    # Fill the cache before this pod takes traffic, so even its first request can fall
    # back if pricing is struggling. If pricing is down right now, start anyway.
    cache_warm = await refresh_prices(app)
    refresher = asyncio.create_task(keep_prices_fresh(app))
    log.info("started", extra={"fields": {"settings": repr(settings), "price_cache_warm": cache_warm}})
    yield
    # By now uvicorn has stopped taking new requests and let the running ones finish.
    refresher.cancel()
    await app.state.http.aclose()
    await app.state.db_pool.close()
    log.info("stopped")


app = FastAPI(title="Order validation", lifespan=lifespan)


class LineIn(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    quantity: int = Field(ge=1)
    unit_price: int = Field(ge=0)               # minor units (cents)


class OrderIn(BaseModel):
    # 100 is a safety cap against absurd requests (answered 400). The business
    # limit of 20 lines is a rule (answered 200 with "valid": false).
    items: list[LineIn] = Field(min_length=1, max_length=100)

    @field_validator("items")
    @classmethod
    def each_sku_once(cls, items: list[LineIn]) -> list[LineIn]:
        skus = [item.sku for item in items]
        if len(skus) != len(set(skus)):
            raise ValueError("each SKU may appear only once")
        return items


@app.exception_handler(RequestValidationError)
async def malformed_request(request: Request, error: RequestValidationError) -> JSONResponse:
    """Malformed input is the caller's mistake: 400, so it never counts against our SLO."""
    details = [{"field": ".".join(str(part) for part in e["loc"][1:]), "message": e["msg"]}
               for e in error.errors()]
    return JSONResponse(status_code=400, content={"error": "malformed request", "details": details})


def unavailable(reason: str) -> JSONResponse:
    """503 with Retry-After: an honest "try again in a second"."""
    return JSONResponse(status_code=503, content={"error": reason}, headers={"Retry-After": "1"})


@app.post("/orders/validate")
async def validate(order: OrderIn, request: Request):
    state = request.app.state
    lines = [OrderLine(item.sku, item.quantity, item.unit_price) for item in order.items]

    try:
        products, limits = await load_catalogue(
            state.db_pool, [line.sku for line in lines], state.settings.db_wait_timeout_s)
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError, TimeoutError) as error:
        log.warning("catalogue unavailable", extra={"fields": {"error": repr(error)}})
        return unavailable("catalogue unavailable")

    # Ask pricing only about products that exist and are on sale: the others are
    # refused anyway, and they never have cached prices to fall back on.
    sellable = [sku for sku, product in products.items() if product.active]
    prices, price_source = {}, None             # None: this order needed no prices
    if sellable:
        try:
            result = await state.pricing.get_prices(sellable)
        except PricingUnavailable as error:
            log.warning("pricing unavailable", extra={"fields": {"reason": error.reason}})
            return unavailable("pricing unavailable")
        prices, price_source = result.prices, result.source

    problems = validate_order(lines, products, limits, prices)
    return {
        "valid": not problems,
        "problems": [asdict(problem) for problem in problems],
        "price_source": price_source,
    }


@app.get("/healthz")
async def healthz():
    """Liveness: the process is up and answering. Restart it only if this fails."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    """Readiness: has this pod finished starting? uvicorn only answers once startup is
    done (database pool open, price cache tried), so a new pod gets no traffic before then.

    It deliberately checks neither Postgres nor pricing. Every pod shares them, so if one
    went down, every pod would fail readiness together and Kubernetes would take them all
    out of service: callers would get connection errors instead of our quick 503s, and our
    own metrics would see no requests, so the SLO alert would stay silent during a full
    outage. Dependency trouble shows up as 503s instead, which the SLO counts.
    """
    return {"status": "ready"}
