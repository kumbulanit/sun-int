# The golden path

The golden path runs your service on Kubernetes with alerts, traces, safe deploys and a runbook, **without your team having to work any of it out.** One command creates your service. You fill in only what you know: your code, your target, your runbook. Budget about an hour.

## What you get
- **Alerts that wake you only when customers are hurt:**
  - a **page** when your error budget burns fast
  - a **ticket** when something you depend on is struggling

  They load into Prometheus by themselves when you deploy.
- **Metrics and traces,** with no telemetry code, cheap by default.
- **A pipeline** that checks, tests, scans, publishes and deploys your service, and **rolls back by itself** if your SLO starts burning after a deploy.
- **Safe settings you can't get wrong:**
  - not running as root, with a read-only disk
  - at least 2 pods
  - deploys that never drop below full capacity

## You need
- `helm`, `kubectl` and Docker
- a Kubernetes cluster that `kubectl` points at. For a local one, run `k3d cluster create sun-int`.
- **once per cluster,** the platform (Prometheus, Alertmanager, Jaeger and the telemetry collector):
  ```bash
  helm install platform golden-path/charts/platform -n platform --create-namespace --wait
  ```

## Put a new service on the golden path
Run each step from the top of the repository. The examples use a service called `payments`, owned by the team `checkout`.

**Step 1. Create it.**
```bash
golden-path/new-service.sh payments --team checkout
```
This creates a working starter service. You can deploy it straight away, and then replace its code:

| Created | What it is |
|---|---|
| `services/payments/` | a small starter app with telemetry wired in, and its Dockerfile |
| `charts/payments/` | its Helm chart: the golden path in one line, plus its settings |
| `charts/payments/slo.yaml` | its SLO: what "working" means for its users. Its alerts are generated from it |
| `services/payments/runbooks/slo-burn.md` | the runbook its alerts link to |
| `.github/workflows/payments.yml` | its pipeline |

**Step 2. Put in your code,** in `services/payments/`. Keep three things from the starter:
- `/healthz` and `/readyz`: the health checks
- the `opentelemetry-instrument` launcher in the Dockerfile: it measures your SLO
- if your service calls other services: count those calls, as [telemetry/STANDARD.md](telemetry/STANDARD.md) shows

**Step 3. Set your SLO,** in `charts/payments/slo.yaml`: your endpoint, how fast is fast enough, and what share of requests must be good. To see what a target means in practice:
```bash
golden-path/tools/slo_math.py --objective 99.9 --steady-rps 20
```
That prints the budget and how quickly you'd be paged. Then generate your alerts. You write no alert rules yourself.
```bash
golden-path/slo/generate.sh charts/payments
```

**Step 4. Write your runbook** in `services/payments/runbooks/slo-burn.md`: what to check and what to do when the alert fires. Keep it to one page. The template explains each part.

**Step 5. Check everything,** exactly as the pipeline will:
```bash
golden-path/pipeline/checks.sh payments
```
It ends with `All checks passed for payments.` If something fails, it says what and how to fix it.

**Step 6. Deploy.** Either let the pipeline do it, or do it yourself.
- **The pipeline:** commit and push to `main`. Your first deploy has no error-budget history yet, so run the `payments` workflow once by hand on GitHub, with the release label `first-deploy`.
- **Yourself:** deploy, watch the SLO for 5 minutes, and roll back if it burns:
  ```bash
  golden-path/pipeline/deploy.sh payments
  ```
  Your image must already be published, or loaded into a local cluster.

**Step 7. See it working.**
```bash
scripts/ui.sh
```
That opens:
- **Prometheus** on http://127.0.0.1:9090: the Alerts page lists your alerts.
- **Jaeger** on http://127.0.0.1:16686: your service's traces.

## Day to day

| You want to | Do this |
|---|---|
| Release a change | Change the code, bump `appVersion` in `charts/<name>/Chart.yaml` (e.g. `0.1.0` → `0.1.1`), push to `main`. A published version is never overwritten |
| Change your SLO | Edit `slo.yaml`, run `golden-path/slo/generate.sh charts/<name>`, commit both files |
| Get ready for a known peak | Raise `replicas` in your values before it, not all week. Measure one pod first with a load test |
| Undo a bad deploy | `helm rollback <name> -n <name>`. The pipeline does this by itself if the fast-burn page fires within 5 minutes of a deploy |
| Pick up a new golden path version | Bump the `golden-path` dependency's version in your `Chart.yaml`, then run `helm dependency update charts/<name>` |

## Your chart's settings
Your chart has one template, `{{ include "golden-path.service" . }}`. That gives you:
- the Deployment and Service
- the disruption budget
- the telemetry settings
- your SLO alerts

You set these in `values.yaml`:

| Setting | Required | Default | What for |
|---|---|---|---|
| `team` | yes | | who owns it: cost reports and alert routing |
| `image.repository` | yes | | where the pipeline publishes your image |
| `image.tag` | | the chart's `appVersion` | an exact version. `latest` is refused |
| `resources` | yes | | CPU and memory reserved per pod (what you pay for), and a memory limit |
| `replicas` | | 2 | how many pods |
| `port` | | 8080 | the port your app listens on |
| `env` | | | plain settings |
| `secretEnv` | | | settings from a Secret: `{NAME: {secret: <name>, key: <key>}}` |
| `waitFor` | | | what your app can't start without: `[{name, host, port}]`. Only real hard needs |
| `probes.liveness`, `probes.readiness` | | `/healthz`, `/readyz` | your health-check paths |
| `telemetry.enabled` | | true | false only if your service sends no telemetry |

The chart stops with a clear message if `team`, `image.repository`, `resources` or an SLO is missing, or if the tag is `latest`. You can add your own templates next to the include, e.g. a Secret, or a `helm test` pod. `charts/order-validation/` shows both, and how to depend on other charts (a database, another service).

## The rules the platform enforces
- **When your error budget runs out,** feature deploys stop until it recovers. Fixes and rollbacks still ship (label the run `reliability-fix` or `rollback`). Your product owner can approve an exception (`budget-exception`).
- **On Saturday 13:00–17:00,** the flash sale, only rollbacks deploy.
- **A deploy never drops capacity:** new pods must be ready before old ones go, so a version that can't start never takes traffic.

## What it costs
- **Telemetry:** a typical service uses 150–250 of its 2,000-series budget. Go over it and you get a ticket naming the label to fix.
- **Compute:** by default, 2 pods with 0.1 CPU and 128 MiB reserved each.

## If something goes wrong

| You see | Do this |
|---|---|
| `<name> has no slo-rules.yaml` | Run `golden-path/slo/generate.sh charts/<name>` |
| `checks.sh` says a `slo-rules.yaml` is out of date | Same: regenerate it, then commit both files |
| An install uses an old version of a chart you changed | Run `helm dependency update charts/<name>` first. `--dependency-update` only fetches what's missing |
| `helm dependency update` fails on a repository you don't use | A broken entry in `helm repo list`: remove it with `helm repo remove <name>` |
| The pipeline's deploy says there's no error-budget data | It's the service's first deploy: run the workflow by hand with the label `first-deploy` |

## What's in the kit

| Folder | What |
|---|---|
| `new-service.sh`, `new-service/` | creates a service, and the files it starts from |
| `charts/service/` | the golden-path chart every service's chart depends on |
| `charts/platform/` | the platform: Prometheus, Alertmanager, Jaeger, the telemetry collector |
| `slo/` | turns `slo.yaml` into alerts, and tests them |
| `telemetry/STANDARD.md` | how to add telemetry, the naming rules, and the cost controls |
| `runbook/TEMPLATE.md` | the one-page runbook template |
| `pipeline/` | the pipeline's scripts and rules. The workflow is `.github/workflows/golden-path.yml` |
| `tools/` | `slo_math.py` (what an SLO means in numbers), `prom.sh` (what your metrics are really called) |

**Questions?** Ask the platform team. If the kit can't do something you need, tell us rather than working around it.
