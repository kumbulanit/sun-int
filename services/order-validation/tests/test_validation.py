"""Fast tests for the validation rules: no database, no network.

The catalogue below copies the special products from db/02-seed.sql, so these
tests and the live demo use the same examples.
"""
from app.validation import (
    OUT_OF_STOCK, PRICE_CHANGED, QUANTITY_LIMIT, UNKNOWN_ITEM,
    Limits, OrderLine, Product, validate_order,
)

CATALOGUE = {p.sku: p for p in [
    Product("SKU-0001", "Everyday item 1", True, 1000, None),
    Product("SKU-0046", "Wireless earbuds", True, 0, None),    # out of stock
    Product("SKU-0047", "Retro radio", False, 250, None),      # withdrawn from sale
    Product("SKU-0048", "Flash-sale TV", True, 500, 2),        # own limit 2
    Product("SKU-0049", "Leather wallet", True, 3, None),      # only 3 left
    Product("SKU-0050", "Gift card", True, 100000, 50),        # own limit 50
]}
LIMITS = Limits(max_lines=20, default_max_quantity=10)
PRICES = {sku: 1000 for sku in CATALOGUE}   # every product costs 1000 in these tests


def codes(sku, quantity, unit_price=1000, prices=PRICES):
    """Validate a one-line order and return just the problem codes."""
    problems = validate_order([OrderLine(sku, quantity, unit_price)], CATALOGUE, LIMITS, prices)
    return [p.code for p in problems]


def test_valid_line_has_no_problems():
    assert codes("SKU-0001", 2) == []


# Unknown and withdrawn products
def test_unknown_sku():
    assert codes("SKU-9999", 1) == [UNKNOWN_ITEM]

def test_withdrawn_product_is_unknown_and_nothing_else_is_checked():
    # The price is wrong too, but a withdrawn product only gets the one problem.
    assert codes("SKU-0047", 1, unit_price=1) == [UNKNOWN_ITEM]


# Stock
def test_out_of_stock():
    assert codes("SKU-0046", 1) == [OUT_OF_STOCK]

def test_exactly_the_stock_left_is_fine():
    assert codes("SKU-0049", 3) == []

def test_more_than_the_stock_left():
    assert codes("SKU-0049", 4) == [OUT_OF_STOCK]


# Quantity limits: at the limit is fine, one over is not
def test_default_limit():
    assert codes("SKU-0001", 10) == []
    assert codes("SKU-0001", 11) == [QUANTITY_LIMIT]

def test_product_with_its_own_lower_limit():
    assert codes("SKU-0048", 2) == []
    assert codes("SKU-0048", 3) == [QUANTITY_LIMIT]

def test_product_with_its_own_higher_limit():
    assert codes("SKU-0050", 50) == []
    assert codes("SKU-0050", 51) == [QUANTITY_LIMIT]


# Prices
def test_price_changed():
    assert codes("SKU-0001", 1, unit_price=900) == [PRICE_CHANGED]

def test_no_current_price():
    assert codes("SKU-0001", 1, prices={}) == [PRICE_CHANGED]


# The whole order
def order_of(n):
    """Validate an order with n different, valid lines."""
    products = {f"SKU-{i:04d}": Product(f"SKU-{i:04d}", f"Item {i}", True, 1000, None)
                for i in range(1, n + 1)}
    lines = [OrderLine(sku, 1, 1000) for sku in products]
    return validate_order(lines, products, LIMITS, {sku: 1000 for sku in products})

def test_twenty_lines_is_fine():
    assert order_of(20) == []

def test_too_many_lines_is_one_problem_for_the_whole_order():
    problems = order_of(21)
    assert [(p.sku, p.code) for p in problems] == [(None, QUANTITY_LIMIT)]


# Several problems
def test_every_problem_on_a_line_is_reported():
    # Over the TV's limit AND the price changed: both are reported.
    assert codes("SKU-0048", 3, unit_price=1) == [QUANTITY_LIMIT, PRICE_CHANGED]

def test_problems_on_different_lines_are_all_reported():
    lines = [OrderLine("SKU-0001", 1, 1000),   # fine
             OrderLine("SKU-0046", 1, 1000),   # out of stock
             OrderLine("SKU-9999", 1, 1000)]   # unknown
    problems = validate_order(lines, CATALOGUE, LIMITS, PRICES)
    assert [(p.sku, p.code) for p in problems] == [("SKU-0046", OUT_OF_STOCK), ("SKU-9999", UNKNOWN_ITEM)]

def test_messages_are_readable():
    problems = validate_order([OrderLine("SKU-0049", 4, 1000)], CATALOGUE, LIMITS, PRICES)
    assert len(problems) == 1
    assert problems[0].detail == "Leather wallet: only 3 left; you asked for 4."
