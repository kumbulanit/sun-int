# Order validation service

Checks an order **before** it's placed: every item exists and is in stock, each quantity is within its limit, and the price the shopper saw is still the current price.

It needs two things:
- **Postgres:** the product catalogue and order limits (the chart [charts/postgres](../../charts/postgres/))
- **the pricing service:** the current prices (locally the fake, [tools/pricing-fake](../../tools/pricing-fake/))

## The API

| Endpoint | What it does |
|---|---|
| `POST /orders/validate` | checks an order |
| `GET /healthz` | is the process up? (failing this restarts the pod) |
| `GET /readyz` | has the pod finished starting? (it never checks Postgres or pricing) |

**Send an order:**
```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"items":[{"sku":"SKU-0001","quantity":2,"unit_price":100}]}' \
  http://127.0.0.1:8080/orders/validate
```
Prices are in cents. In the test data, a product costs its SKU number × 100, so SKU-0001 costs 100.

**What comes back:**

| Answer | When | Counts against the SLO? |
|---|---|---|
| **200** `{"valid": true, "problems": [], "price_source": "live"}` | the order is fine | no |
| **200** `{"valid": false, "problems": [...]}` | the order has problems: `UNKNOWN_ITEM`, `OUT_OF_STOCK`, `QUANTITY_LIMIT`, `PRICE_CHANGED`. Each problem names the SKU and says what's wrong | no: the service did its job |
| **400** `{"error": "malformed request", "details": [...]}` | the request itself is wrong (missing fields, quantity 0, the same SKU twice) | no: the caller's mistake |
| **503** `{"error": "..."}` + `Retry-After: 1` | the database or pricing can't answer right now | **yes** |

`price_source` says where the prices came from: `live` (asked pricing just now), `cache` (pricing was slow, so prices from the last 60 s were used), or `null` (the order needed no prices).

## How it copes with a slow pricing service
1. **It gives up after 150 ms.** There are no retries: a retry can't fit in the 250 ms target.
2. **It answers from the prices it fetched in the last 60 s,** and says `"price_source": "cache"`.
3. **It keeps those prices fresh:** each pod fetches every product's price when it starts, then every 30 s.
4. **Only if a product has no recent price** does it answer `503`, honestly, rather than guess.

The runbook for this failure: [runbooks/pricing-slow.md](runbooks/pricing-slow.md).

## Settings
Set by its chart ([charts/order-validation/values.yaml](../../charts/order-validation/values.yaml)). The API refuses to start, with a clear message, if a required one is missing or wrong.

| Setting | Default | What it is |
|---|---|---|
| `DATABASE_URL` | required | the Postgres address, with the password (from a Secret) |
| `PRICING_URL` | required | the pricing service's address |
| `PRICING_TOKEN` | required | the token for the pricing service (from a Secret) |
| `PRICING_FALLBACK_ENABLED` | `true` | answer from recent prices when pricing is slow. `false` only for incident drills |
| `PRICING_TIMEOUT_S` | `0.15` | how long to wait for pricing |
| `PRICING_CACHE_TTL_S` | `60` | how old a remembered price may be |
| `PRICING_REFRESH_INTERVAL_S`, `PRICING_REFRESH_TIMEOUT_S` | `30`, `2` | how often each pod refreshes its prices, and how long it waits |
| `DB_POOL_SIZE` | `10` | database connections per pod |
| `DB_WAIT_TIMEOUT_S` | `0.1` | how long a request waits for a free database connection |
| `DB_STATEMENT_TIMEOUT_MS` | `100` | Postgres cancels any query slower than this |
| `LOG_LEVEL` | `INFO` | `DEBUG` only while investigating, then back |

## What's in this folder

| Path | What |
|---|---|
| `app/main.py` | the API: endpoints, startup, the request flow |
| `app/validation.py` | the rules, as one plain function (no database, no network) |
| `app/catalogue.py` | the database: the connection pool and the one query per request |
| `app/pricing.py` | the pricing client: deadline, remembered prices, refresh |
| `app/settings.py`, `app/logs.py` | settings and JSON logs |
| `tests/` | 40 tests: 16 for the rules, 16 for the pricing client, 8 end-to-end against the running services |
| `Dockerfile` | two images: the service, and its tests (`--target test`) |
| `runbooks/` | what to do when its alerts fire |

Its chart, SLO and alerts are in [charts/order-validation/](../../charts/order-validation/).

## Run it
Follow the steps in the main [README](../../README.md): install the platform, then this service with its chart, then `scripts/test.sh`.

## Change it
1. **Change the code** in `app/`.
2. **Run the tests on your machine** (no cluster needed; the 8 end-to-end tests are skipped):
   ```bash
   docker build --target test -t order-validation-tests services/order-validation
   ```
   ```bash
   docker run --rm order-validation-tests
   ```
   You should see `32 passed, 8 skipped`.
3. **Run every pipeline check:** `golden-path/pipeline/checks.sh order-validation`.
4. **Bump `appVersion`** in [charts/order-validation/Chart.yaml](../../charts/order-validation/Chart.yaml), e.g. `0.1.0` → `0.1.1`. A published version is never overwritten.
5. **Push to `main`.** The pipeline tests, publishes and deploys it.

More on testing: [scripts/README.md](../../scripts/README.md).
