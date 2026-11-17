-- Seed data: the product catalogue and the order-wide limits.
-- Runs once, after 01-schema.sql, when Postgres starts with an empty data folder.
--
-- 45 ordinary products plus 5 special ones that the tests, the load script
-- and the demo use on purpose. Validating an order never changes stock
-- (validation is advisory; checkout reserves), so these numbers stay put
-- under load.

-- Order-wide limits (assumption 7 in docs/questions-and-assumptions.md).
INSERT INTO order_limits (max_lines, default_max_quantity) VALUES (20, 10);

-- 45 ordinary products: SKU-0001 to SKU-0045, plenty of stock, default limit.
INSERT INTO products (sku, name, stock)
SELECT format('SKU-%s', lpad(n::text, 4, '0')),   -- SKU-0001, SKU-0002, ...
       format('Everyday item %s', n),
       1000
FROM generate_series(1, 45) AS n;

-- 5 special products, each there to exercise one rule.
INSERT INTO products (sku, name, active, stock, max_quantity) VALUES
    ('SKU-0046', 'Wireless earbuds', TRUE,        0, NULL),  -- out of stock
    ('SKU-0047', 'Retro radio',      FALSE,     250, NULL),  -- withdrawn from sale (still has stock)
    ('SKU-0048', 'Flash-sale TV',    TRUE,      500,    2),  -- own limit: 2 per order
    ('SKU-0049', 'Leather wallet',   TRUE,        3, NULL),  -- only 3 left: asking for 4 or more fails
    ('SKU-0050', 'Gift card',        TRUE,   100000,   50);  -- own limit HIGHER than the default 10
