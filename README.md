# Order validation, on a golden path

The Storefront team's order validation API, ready for the next big sales weekend. It's built on a **golden path** that any product team can follow to run a service with an SLO, alerts, traces, safe deploys and a runbook.

- **The API:** `POST /orders/validate` checks an order before it's placed: the items exist and are in stock, the quantities are within limits, and the prices haven't changed. It needs Postgres (the catalogue and order limits) and a pricing service (here a fake, with a switch to make it misbehave).
- **The golden path:** [golden-path/README.md](golden-path/README.md), the guide for product teams. One command starts a new service.

**Guides**

| To | Read |
|---|---|
| Install and try it | this page, [Run it](#run-it-any-kubernetes-cluster) |
| Test it: unit tests, tests in the cluster, load, the incident drill | [scripts/README.md](scripts/README.md) |
| Understand the service: its API, answers, settings, how it copes with slow pricing | [services/order-validation/README.md](services/order-validation/README.md) |
| Make pricing misbehave | [tools/pricing-fake/README.md](tools/pricing-fake/README.md) |
| Put a new service on the golden path | [golden-path/README.md](golden-path/README.md) |

```
golden-path/                  the kit: the shared chart, the platform chart, new-service.sh, SLO as code,
                              the telemetry standard, the runbook template, the pipeline's scripts, tools
charts/order-validation/      the API's chart, on the golden path; its dependencies:
charts/pricing-fake/            the fake pricing service
charts/postgres/                the database, with the schema and seed
services/order-validation/    the API's code, tests, Dockerfile and runbook
tools/pricing-fake/           the fake pricing service's code
.github/workflows/            the golden-path pipeline, and one short file per service that calls it
load/, scripts/               the k6 load test; scripts to test, open the UIs, load and drill
```

## Run it (any Kubernetes cluster)
You need `helm` and a cluster that `kubectl` points at. No cluster? `k3d cluster create sun-int`, `minikube start -p sun-int` or `kind create cluster --name sun-int`.

**1. The platform,** once per cluster: the OpenTelemetry collector, Prometheus, Alertmanager and Jaeger.
```bash
helm install platform golden-path/charts/platform -n platform --create-namespace --wait
```

**2. The API,** with its pricing service and database. Its SLO alerts load into Prometheus by themselves.
```bash
helm install order-validation charts/order-validation --dependency-update -n order-validation --create-namespace --wait
```

**3. Test it:** all 40 tests in the cluster, then 3 example orders.
```bash
scripts/test.sh
```

**4. Look at it:** Prometheus, Alertmanager, Jaeger, the API and the pricing switch, on your machine.
```bash
scripts/ui.sh
```

Nothing is built on your machine: the images come from `ghcr.io`, published by the pipeline.

`--dependency-update` reads every Helm repository you have registered, and a broken entry in `helm repo list` stops it. Remove that entry (`helm repo remove <name>`) and run it again.

It also only fetches dependencies that are missing. After changing a chart, run `helm dependency update charts/order-validation` before `helm upgrade`, or an older copy is deployed without a warning.

## Load
`scripts/load.sh steady 5m` sends 40 validations a second. `scripts/load.sh flash 20m` sends 600 a second, the Saturday sale. k6 runs in the cluster and checks the SLO from the caller's side: at most 1 in 2,000 validations may fail or take over 250 ms. How to read the result: [scripts/README.md](scripts/README.md#5-load).

## The slow-pricing incident
Pricing's p99 jumps to several seconds for 5 minutes: 20% of its calls take 2–5 s. This was run twice on the golden path on 2026-11-17, under a steady 40 validations a second, on a local k3d cluster on a laptop in Low Power Mode.

| | Fallback off | Fallback on |
|---|---|---|
| Validations that failed or were slow | climbed to 16% by the page, then far more (see 1 below) | **0%, for the whole 5 minutes** |
| First alert | **page:** `SLOFastBurn` and `SLOSlowBurn` at **1.8 min** | **ticket:** `DependencyFailing` at **3.8 min**, and no page |
| Pricing calls failing or timing out | 14%, rising to 47% | about 20% |

**Why those alerts:**
- **We page on what customers feel:** the SLO's burn rate, 2% of the 28-day budget going in an hour.
- **A struggling dependency is only a ticket:** more than 5% of its calls failing or timing out. It tells the responder where to look.
- **The same broken pricing gives two different outcomes:** with the fallback off, customers fail and someone is woken; with it on, customers are fine and nobody is.
- **Not on pricing latency:** our 150 ms deadline caps the latency we measure, so a latency alert could never fire.

**The mitigation built into the service:**
- **A deadline:** the API gives up on a pricing call after 150 ms, with no retries, because a retry can't fit in 250 ms.
- **A fallback:** it then answers from prices fetched in the last 60 s, and each pod refreshes those every 30 s. The switch is `env.PRICING_FALLBACK_ENABLED`.
- **The runbook** for this failure, to mitigate and fix: [services/order-validation/runbooks/pricing-slow.md](services/order-validation/runbooks/pricing-slow.md).

**What else the drills found:**
1. **With the fallback off, it got much worse than 20%:**
   - Mid-drill, the fake pricing service was **killed twice by its own health check**, turning "20% slow" into "pricing down".
   - The database also timed out about 60 times a minute.
   - **Fixed:** the fake now has lenient health checks.
2. **With the fallback on, the pages fired 103 s after pricing recovered:**
   - **What happened:** the database timed out for about 2 minutes, about 800 `503 catalogue unavailable`, while pricing was healthy.
   - **It isn't caused by pricing.** A later test brought the same failure back once with pricing healthy: about 230 failed orders in a minute. At the same moment, the whole local cluster showed signs of stalling: Kubernetes' own API server timed out, and the API's health check took 2.5 s instead of milliseconds.
   - **Ruled out:** idle database connections being closed and reopened (they stayed at 20), and running out of CPU. The same burst of 80 orders, repeated, was served in full in 1 s, with every part using under a quarter of a CPU.
   - **Most likely, not yet proven:** the laptop's virtual machine pausing for a few seconds. The laptop was in Low Power Mode. An earlier drill had the same kind of database blip.
   - **Why it paged:** partly because Prometheus had been restarted 10 minutes before the drill. With a real hour of history, 800 bad requests is 0.56% of the hour, under the fast page's 0.672% line.
3. **Jaeger stayed up** with its memory cap. In the earlier drills it ran out of memory 5 times in an hour.

The two drills together failed 12,088 validations (k6's count): about a quarter of the 49,728 a 28-day window allows.

**Run it yourself** (under `scripts/load.sh steady 30m` in another terminal):
1. Switch the fallback off:
   ```bash
   helm upgrade order-validation charts/order-validation -n order-validation --reuse-values --set-string env.PRICING_FALLBACK_ENABLED=false --wait
   ```
2. Run the drill. It writes a timeline of the alerts and the error ratio.
   ```bash
   scripts/drill.sh A-fallback-off
   ```
3. Switch the fallback back on (the same command with `=true`), then run `scripts/drill.sh B-fallback-on`.

## A new team on the golden path
`golden-path/new-service.sh payments --team checkout` creates a service that's ready to deploy, then the guide takes over. When we did it:
- the new service's alerts were loaded into Prometheus seconds after its install
- its metrics and traces arrived, with no telemetry code
- nothing was done to the platform

## Try the API by hand
With `scripts/ui.sh` running:
```bash
curl -s -H 'Content-Type: application/json' -d '{"items":[{"sku":"SKU-0001","quantity":2,"unit_price":100}]}' http://127.0.0.1:8080/orders/validate
```
- **Prices** are the SKU number × 100, so SKU-0001 costs 100.
- **A refused order** (out of stock, over the limit, price changed) is a **200** with `"valid": false` and the reasons. That's the service working, so it counts as good for the SLO.
- **A malformed order** is a **400**.

To make pricing misbehave (`slow`, `error`, `auth_fail`, `normal`):
```bash
curl -s -H 'Content-Type: application/json' -d '{"mode":"slow","slow_pct":20,"duration_s":300}' http://127.0.0.1:8091/admin/mode
```
The API gives up on pricing after 150 ms and answers from prices it fetched in the last 60 s.
