# Order validation

`POST /orders/validate` checks an order before it's placed: the items exist and are in stock, the quantities are within limits, and the prices haven't changed. It needs two things:
- **Postgres:** the product catalogue and order limits
- **the pricing service:** here a fake, with a switch to make it misbehave

```
charts/order-validation/          the Helm chart for the API
  charts/pricing-fake/            ...its dependency: the pricing service's chart
  charts/postgres/                ...its dependency: the database's chart, with the schema + seed (initdb/)
services/order-validation/        the API: code, tests, Dockerfile
tools/pricing-fake/               the fake pricing service: code, Dockerfile
scripts/test.sh                   test an installed release
.github/workflows/images.yml      builds the images and publishes them to ghcr.io
```

## Install it on any Kubernetes cluster
You need `helm` and a cluster that `kubectl` points at: k3d, minikube, kind, Docker Desktop, OrbStack or a cloud cluster. Nothing is built on your machine: the images are published to `ghcr.io` by GitHub.

```bash
helm install order-validation charts/order-validation -n order-validation --create-namespace --wait
```
```bash
scripts/test.sh
```
```bash
helm uninstall order-validation -n order-validation
```

**`helm install`** installs the API and its two dependencies, the pricing service and the database, listed in [Chart.yaml](charts/order-validation/Chart.yaml):
- **Ordering:** Helm starts all three at once. The API pods wait for the database before starting, because the API can't run without it. They don't wait for pricing, on purpose: if pricing is down, the API must still start. It fills its price cache as soon as pricing answers.
- **Timing:** `--wait` returns once everything is ready, about a minute on a laptop.

**`scripts/test.sh`** runs all 40 tests as a pod in the cluster (`helm test`), then sends 3 example orders.

**`helm uninstall`** removes all three.

No cluster yet? Make a local one with any of:

| Cluster | Make one | Remove it afterwards |
|---|---|---|
| k3d | `k3d cluster create sun-int --image rancher/k3s:v1.36.4-k3s1` | `k3d cluster delete sun-int` |
| minikube | `minikube start -p sun-int` | `minikube delete -p sun-int` |
| kind | `kind create cluster --name sun-int` | `kind delete cluster --name sun-int` |

### Settings
All in [values.yaml](charts/order-validation/values.yaml). The ones you're most likely to change:

| Setting | Default | What for |
|---|---|---|
| `global.postgresPassword`, `global.pricingToken` | local-only values | **set your own on any shared cluster**. Each is set once and reaches both ends. |
| `replicas` | 2 | raise before the Saturday sale |
| `pricing.fallbackEnabled` | true | false switches off answering from cached prices (for incident drills) |
| `postgres.enabled=false` + `database.host` | the bundled database | use a managed database instead |
| `image.tag` | the chart's `appVersion` | run another published version; `latest` is refused |

The bundled database is for trying it out. Its data lives in the pod, so a restart reloads the seed.

### Releasing a code change
1. Change the code.
2. Bump `appVersion` in the chart: [order-validation](charts/order-validation/Chart.yaml) for the API (its test image shares that version), [pricing-fake](charts/order-validation/charts/pricing-fake/Chart.yaml) for pricing.
3. Push to `main`.

GitHub then builds the image for Intel/AMD and Apple-silicon machines and publishes it as that version. A version that's already published is never overwritten.

To try a change on a local cluster before releasing it:
1. Build the image under a new tag, e.g. `dev`.
2. Load it into the cluster: `k3d image import`, `minikube image load` or `kind load docker-image`.
3. Install with `--set image.tag=dev`.

The test image shares the API's tag, so build it too, with `--target test`, if you'll run `helm test`.

## Try it
Open the ports first, each in its own terminal:
```bash
kubectl -n order-validation port-forward svc/order-validation 8080:8080
```
```bash
kubectl -n order-validation port-forward svc/pricing-fake 8091:8081
```

Send an order:
```bash
curl -s -H 'Content-Type: application/json' -d '{"items":[{"sku":"SKU-0001","quantity":2,"unit_price":100}]}' http://127.0.0.1:8080/orders/validate
```

- **Prices** are the SKU number × 100, so SKU-0001 costs 100.
- **A refused order** (out of stock, over the limit, price changed) is a **200** with `"valid": false` and the reasons.
- **A malformed order** is a **400**.

To make pricing misbehave:
```bash
curl -s -H 'Content-Type: application/json' -d '{"mode":"slow","slow_pct":20,"duration_s":300}' http://127.0.0.1:8091/admin/mode
```
The modes are `slow`, `error`, `auth_fail` and `normal`. The API gives up on pricing after 150 ms and answers from prices it fetched in the last 60 s.
