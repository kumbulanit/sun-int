-- Order validation: product catalogue and order limits.
-- Runs once, when Postgres starts with an empty data folder. Files in
-- /docker-entrypoint-initdb.d run in name order: this one, then the seed (step 3).
--
-- Prices are NOT stored here: the pricing service owns them, and the
-- service asks it on every request.

-- One row per product.
CREATE TABLE products (
    sku          TEXT    PRIMARY KEY,             -- the product code orders use; the key also gives the fast lookup index
    name         TEXT    NOT NULL,                -- for readable messages, e.g. "Blue mug is out of stock"
    active       BOOLEAN NOT NULL DEFAULT TRUE,   -- FALSE = withdrawn from sale
    stock        INTEGER NOT NULL CHECK (stock >= 0),
    max_quantity INTEGER CHECK (max_quantity > 0) -- this product's own limit, e.g. 2 on flash-sale items;
                                                  -- NULL = use the order-wide default below
);

-- Order-wide limits. Exactly one row: the CHECK on the key means a second row can't be added.
CREATE TABLE order_limits (
    only_row             BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (only_row),
    max_lines            INTEGER NOT NULL CHECK (max_lines > 0),            -- most lines (different items) in one order
    default_max_quantity INTEGER NOT NULL CHECK (default_max_quantity > 0)  -- most of one product, unless it sets its own
);
