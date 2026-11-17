"""Everything that talks to Postgres: the connection pool and the one query per request."""
import asyncpg

from app.validation import Limits, Product

# One round trip for everything the rules need. It starts from the single
# order_limits row and attaches any products whose SKU is in the order, so
# the limits come back even when none of the SKUs exist.
QUERY = """
    SELECT l.max_lines, l.default_max_quantity,
           p.sku, p.name, p.active, p.stock, p.max_quantity
    FROM order_limits AS l
    LEFT JOIN products AS p ON p.sku = ANY($1::text[])
"""


async def create_pool(dsn: str, size: int, statement_timeout_ms: int) -> asyncpg.Pool:
    """Open a small, fixed-size connection pool.

    At 600 req/s with ~2 ms queries only ~1.2 connections are busy
    (Little's law: golden-path/tools/slo_math.py), so 10 is plenty; a bigger pool would only hide
    problems. statement_timeout makes Postgres itself cancel any slower query,
    so one stuck query can't hold a connection, or our 250 ms budget, for long.
    """
    return await asyncpg.create_pool(
        dsn,
        min_size=size,
        max_size=size,
        # jit off: Postgres's JIT compiler only pays off for big reporting queries. For
        # our tiny lookups it adds latency, and it made the first query on a new
        # connection take 179 ms, past the 100 ms limit (measured in Phase 1b).
        server_settings={"statement_timeout": str(statement_timeout_ms), "jit": "off"},
    )


async def load_catalogue(
    pool: asyncpg.Pool, skus: list[str], wait_timeout_s: float
) -> tuple[dict[str, Product], Limits]:
    """Return the products for these SKUs (keyed by SKU) and the order-wide limits."""
    # Wait a short, fixed time for a free connection rather than queueing
    # forever: under overload, failing fast beats every request getting slow.
    async with pool.acquire(timeout=wait_timeout_s) as conn:
        rows = await conn.fetch(QUERY, skus)

    if not rows:
        # No order_limits row means the database wasn't seeded: a broken
        # deployment, not a bad order, so it must surface as a 5xx.
        raise RuntimeError("order_limits table is empty")

    limits = Limits(rows[0]["max_lines"], rows[0]["default_max_quantity"])
    products = {
        row["sku"]: Product(row["sku"], row["name"], row["active"], row["stock"], row["max_quantity"])
        for row in rows
        if row["sku"] is not None   # when no SKU matches, the one row has empty product columns
    }
    return products, limits


SELLABLE = "SELECT sku FROM products WHERE active ORDER BY sku"


async def load_sellable_skus(pool: asyncpg.Pool) -> list[str]:
    """Every product on sale: the list each pod keeps its price cache warm for."""
    rows = await pool.fetch(SELLABLE)
    return [row["sku"] for row in rows]
