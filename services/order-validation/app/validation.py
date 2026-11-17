"""The validation rules, as one pure function.

No database, no network, no clock: it gets everything it needs as arguments
and returns the answer. That makes it fast to test and easy to read on its own.
The API (step 9) fetches the catalogue and prices, calls validate_order(), and
turns the result into JSON.
"""
from dataclasses import dataclass

# The four reasons an order can be refused. A refusal is a correct answer
# (HTTP 200, "valid": false), not an error, so it never counts against the SLO.
UNKNOWN_ITEM = "UNKNOWN_ITEM"
OUT_OF_STOCK = "OUT_OF_STOCK"
QUANTITY_LIMIT = "QUANTITY_LIMIT"
PRICE_CHANGED = "PRICE_CHANGED"


@dataclass(frozen=True)
class OrderLine:
    sku: str
    quantity: int     # already checked to be 1 or more by the API
    unit_price: int   # the price the customer saw, in minor units (cents)


@dataclass(frozen=True)
class Product:
    sku: str
    name: str
    active: bool
    stock: int
    max_quantity: int | None   # this product's own limit; None = use the order-wide default


@dataclass(frozen=True)
class Limits:
    max_lines: int
    default_max_quantity: int


@dataclass(frozen=True)
class Problem:
    sku: str | None   # None when the problem is with the whole order
    code: str
    detail: str


def validate_order(
    lines: list[OrderLine],
    products: dict[str, Product],
    limits: Limits,
    prices: dict[str, int],
) -> list[Problem]:
    """Check an order. Returns its problems; an empty list means the order is valid.

    lines:    the order, one entry per product (the API rejects repeated SKUs)
    products: the catalogue rows for this order's SKUs, keyed by SKU
    limits:   the order-wide limits
    prices:   current prices from the pricing service, keyed by SKU
    """
    problems: list[Problem] = []

    if len(lines) > limits.max_lines:
        problems.append(Problem(None, QUANTITY_LIMIT,
            f"An order can have at most {limits.max_lines} lines; this one has {len(lines)}."))

    for line in lines:
        product = products.get(line.sku)

        # Unknown, or withdrawn from sale: nothing else to check for this line.
        if product is None:
            problems.append(Problem(line.sku, UNKNOWN_ITEM, f"{line.sku} is not a product we sell."))
            continue
        if not product.active:
            problems.append(Problem(line.sku, UNKNOWN_ITEM, f"{product.name} is no longer on sale."))
            continue

        limit = product.max_quantity if product.max_quantity is not None else limits.default_max_quantity
        if line.quantity > limit:
            problems.append(Problem(line.sku, QUANTITY_LIMIT,
                f"{product.name}: at most {limit} per order; you asked for {line.quantity}."))

        if product.stock == 0:
            problems.append(Problem(line.sku, OUT_OF_STOCK, f"{product.name} is out of stock."))
        elif line.quantity > product.stock:
            problems.append(Problem(line.sku, OUT_OF_STOCK,
                f"{product.name}: only {product.stock} left; you asked for {line.quantity}."))

        current = prices.get(line.sku)
        if current is None:
            problems.append(Problem(line.sku, PRICE_CHANGED, f"{product.name} has no current price."))
        elif current != line.unit_price:
            problems.append(Problem(line.sku, PRICE_CHANGED,
                f"{product.name}: the price is now {current}; you saw {line.unit_price}."))

    return problems
