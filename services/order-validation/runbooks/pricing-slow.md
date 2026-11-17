# Runbook: pricing is slow or failing (order-validation)

| | |
|---|---|
| **Service / team** | order-validation / Storefront |
| **Alerts that link here** | `DependencyFailing` (ticket) when pricing struggles; `SLOFastBurn`, `SLOSlowBurn` (page) when customers feel it |
| **Where to look** | Prometheus http://127.0.0.1:9090 · Jaeger http://127.0.0.1:16686, service `order-validation` (open both with `scripts/ui.sh`) · `kubectl -n order-validation logs deploy/order-validation` |
| **Escalate to** | the pricing team's on-call (they own the cause); the Storefront lead if the page fires during the Saturday sale |

## What it means
Pricing answers slowly or not at all. We give up on a pricing call after **150 ms** and answer from the **price we got in the last 60 s** (`"price_source": "cache"`); each pod refreshes those prices every 30 s.
- **Ticket** (`DependencyFailing`): more than 5% of pricing calls failed or timed out over 10 minutes. The fallback is working, so customers aren't affected yet.
- **Page** (`SLOFastBurn`): customers *are* affected. More than 0.67% of validations failed or took over 250 ms, over both the last hour and the last 5 minutes.

## User impact
- **Fallback working:** none that shoppers see. Prices may be up to 60 s old; checkout prices the order again.
- **Fallback can't help** (pricing down for over a minute, so the cached prices are too old): `503 pricing unavailable`, and shoppers can't validate their basket.
- **Cost:** 20% of requests failing for 5 minutes spends 4.8% of the 28-day budget at 40 req/s, and **72% during the flash sale**.

## Check (first 5 minutes)
1. **Is it pricing?** `golden-path/tools/prom.sh query 'dependency:failure_ratio:rate10m{service="order-validation"}'`. Above 0.05 means yes. Near 0 means this is **not** this failure: look for `catalogue unavailable` in `kubectl -n order-validation logs deploy/order-validation` (the database).
2. **Are customers getting errors?** `golden-path/tools/prom.sh query 'sum by (http_response_status_code) (rate(http_server_request_duration_seconds_count{job="order-validation"}[5m]))'`. Any `503` is bad.
3. **Is the fallback switched on?** `kubectl -n order-validation get deploy order-validation -o yaml | grep -A1 PRICING_FALLBACK_ENABLED`. It must be `"true"`.
4. **Is the cache still being refreshed?** `price refresh failed` in `kubectl -n order-validation logs deploy/order-validation` every 30 s means pricing is failing even with a 2 s deadline. Cached prices expire 60 s after the last success, then 503s start.
5. **How slow is pricing?** In Jaeger, the `POST` span to pricing in a slow trace: about 150 ms with an error means our deadline cut it off.

## Mitigate (stop the harm, no code change)
1. **Fallback switched off?** Switch it on: change `PRICING_FALLBACK_ENABLED` to `"true"` under `env` in `charts/order-validation/values.yaml` and deploy with the label `reliability-fix` (locally: `helm upgrade order-validation charts/order-validation -n order-validation --reuse-values --set-string env.PRICING_FALLBACK_ENABLED=true --wait`). **Worked if:** answers show `"price_source": "cache"`, 503s stop, and the page clears within about 5 minutes.
2. **Pricing down for over a minute (503s because the cache is too old)?** Page the pricing team now. Only if the product owner agrees to older prices (checkout re-prices; assumption 3), raise `PRICING_CACHE_TTL_S` (e.g. to `300`), and **never around 15:00 on Saturday**, when sale prices start. **Worked if:** 503s stop.
3. **During the flash sale:** tell the Storefront lead. Every minute at 600 req/s costs about 7× the budget of a normal minute.

## Fix (the cause)
- **The pricing team** finds why pricing is slow: their latency, a recent deploy, their own dependencies.
- **Our follow-ups:**
  - check the ticket fired well before any page
  - consider a circuit breaker (stop calling a failing pricing service for a few seconds, which saves each request 150 ms)
  - review the cache's age limit with the product owner

## Don't
- **Raise the 150 ms timeout.** Requests then take longer than 250 ms, so the SLO burns anyway, and requests pile up in our pods (Little's law).
- **Add retries.** They can't fit in 250 ms, and they double the load on a pricing service that's already struggling.
- **Restart or scale our pods.** A new pod starts with an empty cache when pricing is down, and more pods mean more calls to pricing.

## Afterwards
An incident review if it spent more than 20% of the budget (`slo:error_budget_remaining` shows what's left). Update this page with what you learned.
