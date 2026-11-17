# Fake pricing service

A stand-in for the real pricing service, for trying things out, tests and incident drills. It has a **switch to make it misbehave on purpose**: slow, failing, or refusing the token.

Prices are made up but stable: the SKU number × 100, so SKU-0001 costs 100.

## The API

| Endpoint | What it does |
|---|---|
| `POST /prices` | `{"skus": ["SKU-0001", ...]}` → `{"prices": {"SKU-0001": 100, ...}}`. Needs the header `Authorization: Bearer <token>` |
| `POST /admin/mode` | the misbehave switch (below) |
| `GET /admin/mode` | the current mode, and the seconds left |
| `GET /healthz` | is it up? |

## Make it misbehave
1. **Open its port** on your machine (leave it running in another terminal):
   ```bash
   kubectl -n order-validation port-forward svc/pricing-fake 8091:8081
   ```
   Or run `scripts/ui.sh`, which opens it with everything else.
2. **Flip the switch,** e.g. 20% of calls take 2–5 s, for 5 minutes:
   ```bash
   curl -s -H 'Content-Type: application/json' -d '{"mode":"slow","slow_pct":20,"duration_s":300}' http://127.0.0.1:8091/admin/mode
   ```
3. **It goes back to normal by itself** when `duration_s` is up. To stop early:
   ```bash
   curl -s -H 'Content-Type: application/json' -d '{"mode":"normal"}' http://127.0.0.1:8091/admin/mode
   ```

| Mode | What it does | Settings (defaults) |
|---|---|---|
| `slow` | some calls take seconds | `slow_pct` (20), `slow_ms_min` (2000), `slow_ms_max` (5000) |
| `error` | some calls answer 500 | `error_pct` (20) |
| `auth_fail` | every call answers 401 | |
| `normal` | answers straight away | |

Every mode takes `duration_s` (default 300, at most 3600).

**One pod only:** the switch lives in the pod's memory, so with two pods it would reach only one of them.

## Its chart
[charts/pricing-fake/](../../charts/pricing-fake/). It's installed along with `order-validation`, as one of that chart's dependencies. Its token comes from `global.pricingToken` in the order-validation chart, so both ends always match.
