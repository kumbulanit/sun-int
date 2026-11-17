# Testing

Run every command from the top of the repository.

| Test | What it proves | Needs | Command | Takes |
|---|---|---|---|---|
| [Unit tests](#1-unit-tests-no-cluster) | the rules and the pricing client work | Docker | `docker run` (below) | 1 min |
| [Everything in the cluster](#2-everything-in-the-cluster) | the installed service works end to end | the app installed | `scripts/test.sh` | 30 s |
| [The pipeline's checks](#3-the-pipelines-checks) | it would pass the pipeline | Docker, helm | `golden-path/pipeline/checks.sh order-validation` | 2 min |
| [The SLO alerts](#4-the-slo-alerts) | the alerts fire when they should, and stay quiet when they shouldn't | Docker | `golden-path/slo/test.sh` | 20 s |
| [Load](#5-load) | it meets its SLO at 40 (or 600) orders a second | the app installed | `scripts/load.sh steady 5m` | 5 min |
| [The incident drill](#6-the-incident-drill) | the right alert fires when pricing gets slow | the app, the platform, load | `scripts/drill.sh` | 15 min per run |

## Before the cluster tests
Install the platform and the app (steps 0 to 2 of the main [README](../README.md#run-it-any-kubernetes-cluster); step 0 builds the images while they aren't published yet):
```bash
helm install platform golden-path/charts/platform -n platform --create-namespace --wait
```
```bash
helm install order-validation charts/order-validation --dependency-update -n order-validation --create-namespace --wait
```

## 1. Unit tests (no cluster)
1. Build the test image:
   ```bash
   docker build --target test -t order-validation-tests services/order-validation
   ```
2. Run it:
   ```bash
   docker run --rm order-validation-tests
   ```
3. You should see `32 passed, 8 skipped`. The 8 skipped are the end-to-end tests: they need the running services (test 2).

## 2. Everything in the cluster
1. Run:
   ```bash
   scripts/test.sh
   ```
2. It runs all 40 tests as a pod inside the cluster (`helm test`), then sends 3 example orders from your machine.
3. You should see:
   - `40 passed`
   - a valid order: `"valid":true`
   - an out-of-stock order: `OUT_OF_STOCK`
   - an order with a changed price: `PRICE_CHANGED`

## 3. The pipeline's checks
1. Run:
   ```bash
   golden-path/pipeline/checks.sh order-validation
   ```
2. It runs, in order:
   - the golden path's entry rules (chart, SLO, runbook, Dockerfile)
   - the SLO alert tests
   - the chart (lint and render)
   - the policies (non-root, pinned images)
   - the unit tests
   - the vulnerability scan
3. You should see `All checks passed for order-validation.`

To skip the vulnerability scan (the slowest part) on your machine, run `SKIP_SCAN=1 golden-path/pipeline/checks.sh order-validation`. The pipeline always runs it.

## 4. The SLO alerts
1. Run:
   ```bash
   golden-path/slo/test.sh
   ```
2. It checks the alerts with Prometheus's own tester:
   - a healthy service stays quiet
   - a fast burn pages
   - a failing dependency only raises a ticket

   Then it checks that every service's alerts match its `slo.yaml`.
3. You should see `SUCCESS` and `every slo-rules.yaml matches its slo.yaml`.

## 5. Load
1. Run a normal day, 40 orders a second for 5 minutes:
   ```bash
   scripts/load.sh steady 5m
   ```
   Or the Saturday sale, 600 a second for 20 minutes: `scripts/load.sh flash 20m`.
2. At the end k6 prints a summary. The first lines are the SLO, as the caller sees it:
   - `✓ 'rate>0.9995'`: at most 1 in 2,000 orders failed
   - `✓ 'p(99.95)<250'`: 99.95% of orders were answered within 250 ms

   A `✗` means that part of the SLO was missed.
3. A laptop can't reach 600 a second with 2 pods. Raise the pods first, and expect your machine to be the limit:
   ```bash
   helm upgrade order-validation charts/order-validation -n order-validation --reuse-values --set replicas=6 --wait
   ```

## 6. The incident drill
This makes pricing slow (20% of its calls take 2–5 s, for 5 minutes) and records which alerts fire. Run it twice: once without the service's protection, once with it.

1. **Start the load,** in a second terminal, and leave it running:
   ```bash
   scripts/load.sh steady 30m
   ```
   Wait 3 minutes so there's a normal baseline.
2. **Switch the protection off** (the fallback to recent prices):
   ```bash
   helm upgrade order-validation charts/order-validation -n order-validation --reuse-values --set-string env.PRICING_FALLBACK_ENABLED=false --wait
   ```
3. **Run the drill:**
   ```bash
   scripts/drill.sh A-fallback-off
   ```
   Every 15 s it prints a line:
   ```
   t=+108s alerts=SLOFastBurn/page,SLOSlowBurn/page sli_err_5m=0.1637 pricing_failing=0.2505   <- alerts changed
   ```
   - `alerts`: what is firing, and whether it's a page or a ticket
   - `sli_err_5m`: the share of orders that failed or were slow, over the last 5 minutes
   - `pricing_failing`: the share of pricing calls that failed or timed out

   **Expected:** the page `SLOFastBurn` fires within about 2 minutes.
4. **Switch the protection back on:**
   ```bash
   helm upgrade order-validation charts/order-validation -n order-validation --reuse-values --set-string env.PRICING_FALLBACK_ENABLED=true --wait
   ```
   Then wait until run A's alerts have cleared: up to 30 minutes. Or start Prometheus afresh (it keeps its data in memory):
   ```bash
   kubectl -n platform rollout restart deploy/prometheus
   ```
   For the next hour, a fresh Prometheus pages more easily, because its long alert windows hold only a few minutes of data.
5. **Run the drill again:**
   ```bash
   scripts/drill.sh B-fallback-on
   ```
   **Expected:** `sli_err_5m` stays near 0, and only the ticket `DependencyFailing` fires.

Each drill takes 15 minutes, and saves its timeline in `docs/drills/` (that folder stays out of git). What we saw when we ran it: the "slow-pricing incident" section of the main [README](../README.md).

## Look at the results
```bash
scripts/ui.sh
```
That opens:
- **Prometheus** on http://127.0.0.1:9090: the Alerts page
- **Alertmanager** on http://127.0.0.1:9093: pages and tickets
- **Jaeger** on http://127.0.0.1:16686: traces, e.g. a slow request

Press Ctrl-C to close them.

## If a test fails

| You see | Do this |
|---|---|
| `scripts/test.sh`: fewer than 40 passed | Read the failing test's name and message in the output. Then check the pods: `kubectl -n order-validation get pods` |
| `503` answers, or `catalogue unavailable` in the logs | The database didn't answer in time: `kubectl -n order-validation logs deploy/order-validation` |
| `the port-forward to the API didn't open` | Run it again. If it keeps failing, check the API pods are `Running` |
| `scripts/load.sh` prints nothing for a while | k6's image is still downloading the first time; it starts by itself |
| `drill.sh`: `not reachable` | The platform or the app isn't installed, or isn't ready yet: `kubectl get pods -A` |
| `checks.sh`: `slo-rules.yaml` is out of date | `golden-path/slo/generate.sh charts/order-validation`, then commit both files |
