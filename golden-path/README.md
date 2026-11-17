# The golden path

Templates for running a service on Kubernetes the same safe way every time. You get, without building any of it:
- alerts that page only when users are hurt
- metrics and traces
- safe deploys with automatic rollback
- a runbook

## How a service uses the templates

| Template | How you use it |
|---|---|
| `charts/service/`: the Deployment, Service, health checks, security, telemetry and alerts | **Referenced:** your chart lists it as a dependency and includes it in one line |
| `.github/workflows/golden-path.yml`: checks, tests, scan, publish, deploy with rollback | **Referenced:** your pipeline file calls it |
| `charts/platform/`: Prometheus, Alertmanager, Jaeger, the telemetry collector | **Installed once** per cluster |
| `new-service/`: a complete, working example service | **Copied:** the starting point for your service. You change three names |

Referenced templates stay with the platform team. When they improve one, you pick it up by bumping a version number, with no copying.

## Before you start
You need `helm`, `kubectl`, Docker and a cluster (for a local one: `k3d cluster create sun-int`). Install the platform once:
```bash
helm install platform golden-path/charts/platform -n platform --create-namespace --wait
```

## Start a new service
**Easiest:** the script copies `new-service/` and puts your names in for you. It asks for anything you leave out.
```bash
golden-path/new-service.sh payments --team checkout
```

**Or by hand:** copy `new-service/` and change the names marked `# CHANGE:`, following [new-service/README.md](new-service/README.md).

Either way you get a working service that you can deploy as it is.

## Then
1. **Check it:**
   ```bash
   golden-path/pipeline/checks.sh payments
   ```
   You should see `All checks passed for payments.`
2. **Add your code** in `services/payments/app/`. Keep `/healthz`, `/readyz`, and the `opentelemetry-instrument` line in the Dockerfile.
3. **Set your SLO** in `charts/payments/slo.yaml`, then regenerate the alerts:
   ```bash
   golden-path/slo/generate.sh charts/payments
   ```
   `golden-path/tools/slo_math.py --objective 99.9 --steady-rps 20` shows what a target means in practice.
4. **Write your runbook:** `services/payments/runbooks/slo-burn.md`.
5. **Deploy:** push to `main`. The first time, run the `payments` workflow by hand on GitHub with the label `first-deploy`, because a new service has no error-budget history yet.

To see it working, run `scripts/ui.sh`. It opens Prometheus (your alerts) and Jaeger (your traces).

## Day to day

| To | Do |
|---|---|
| Release a change | Bump `appVersion` in `charts/<name>/Chart.yaml` (e.g. `0.1.0` → `0.1.1`) and push |
| Change your SLO | Edit `slo.yaml`, run `golden-path/slo/generate.sh charts/<name>`, commit both files |
| Get ready for a peak | Raise `replicas` in `charts/<name>/values.yaml` before it |
| Undo a bad deploy | `helm rollback <name> -n <name>` (the pipeline does it by itself if the SLO burns after a deploy) |
| Take a new golden-path version | Bump the `golden-path` version in your `Chart.yaml`, then run `helm dependency update charts/<name>` |

## Your chart's settings (`values.yaml`)

| Setting | Required | Default | What it is |
|---|---|---|---|
| `team` | yes | | the owning team |
| `image.repository` | yes | | where your image is published |
| `resources` | yes | | CPU and memory per pod, and a memory limit |
| `image.tag` | | the chart's `appVersion` | an exact version (`latest` is refused) |
| `replicas` | | 2 | how many pods |
| `port` | | 8080 | the port your app listens on |
| `env` | | | settings |
| `secretEnv` | | | settings from a Secret: `{NAME: {secret: <name>, key: <key>}}` |
| `waitFor` | | | what the app can't start without: `[{name, host, port}]` |
| `telemetry.enabled` | | true | false only if your service sends no telemetry |

## Rules the platform enforces
- **Running out of error budget:** feature deploys stop until it recovers. Fixes and rollbacks still go out with the label `reliability-fix` or `rollback`, and the product owner can approve a `budget-exception`.
- **Saturday 13:00–17:00, the flash sale:** only rollbacks deploy.
- **Every deploy:** new pods must be ready before old ones stop, and the pipeline watches your SLO for 5 minutes afterwards.

## If something goes wrong

| You see | Do |
|---|---|
| `has no slo-rules.yaml`, or `out of date` | `golden-path/slo/generate.sh charts/<name>`, then commit both files |
| A chart change doesn't show up after `helm upgrade` | Run `helm dependency update charts/<name>` first |
| `helm dependency update` fails on a repository you don't use | Remove it: `helm repo remove <name>` |
| The deploy says there's no error-budget data | It's the first deploy: run the workflow by hand with the label `first-deploy` |

**More:**
- the telemetry rules: [telemetry/STANDARD.md](telemetry/STANDARD.md)
- the runbook template: [runbook/TEMPLATE.md](runbook/TEMPLATE.md)
- the tools: [tools/README.md](tools/README.md)
