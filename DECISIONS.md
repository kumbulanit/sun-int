# Decisions

How the order validation service and its golden path were built:
- what we decided, and what we rejected
- what we kept small
- where AI helped
- what we assumed
- what it costs
- what's missing

Every number was measured, or comes from `golden-path/tools/slo_math.py`. The decision IDs (D1–D38) are kept stable, because other documents refer to them.

**Contents**
1. [Key decisions, and what we rejected](#1-key-decisions-and-what-we-rejected)
2. [How we approached the service build](#2-how-we-approached-the-service-build)
3. [Where we used AI, and what we changed](#3-where-we-used-ai-and-what-we-changed)
4. [Questions we asked, and assumptions we made](#4-questions-we-asked-and-assumptions-we-made)
5. [Rough monthly cost](#5-rough-monthly-cost)
6. [The two golden-path parts we didn't build](#6-the-two-golden-path-parts-we-didnt-build)
7. [Known gaps and shortcuts, and what we cut](#7-known-gaps-and-shortcuts-and-what-we-cut)
8. [With one more sprint](#8-with-one-more-sprint)

## 1. Key decisions, and what we rejected

### Runtime and delivery

| ID | We decided | We rejected | Why |
|---|---|---|---|
| D1 | Everything runs on Kubernetes, installed with plain Helm charts, on any cluster (proven on k3d and minikube) | docker compose; install scripts per cluster type; Skaffold | Production is AKS, so the kit must be Kubernetes artifacts. A cluster also shows what compose can't: readiness taking a pod out of service, rolling updates, disruption budgets. Two setups would drift apart |
| D2 | Python 3.12, FastAPI, asyncpg, httpx; no ORM | Go | Easiest to read and explain; the service mostly waits on I/O. What it costs in capacity is measured (D29) |
| D32 | The pipeline builds the images and publishes each as its chart's `appVersion`. A published version is never overwritten | Building on each laptop and loading it into the cluster; Skaffold; code shipped in a ConfigMap | Clone, `helm install`, and the cluster pulls ready images. Nothing to build, on any cluster. Loading into k3d was also unreliable: it once reported success without loading anything |
| D33 | Each application has its own chart, and the API's chart lists pricing and Postgres as dependencies | One chart for everything; install order handled by a script | One install brings all three, and either can be switched off to use a real one. Shared secrets are set once and reach both ends |
| D34 | The guard rails live in one shared **library chart** that each service's chart depends on | Copying a full chart into each team's folder, checked by policy | A team writes its values and one line. The platform fixes things in one place, and teams pick them up by bumping a version. Copies drift. Cost: installs need `--dependency-update` |
| D36 | `golden-path/new-service/` is a working example service, and `new-service.sh` copies it and changes three names | A folder of placeholder files; a code generator | One source for both ways (by hand, or by script), so they can't differ. The example can be read, copied and deployed as it is |
| D16 | The golden-path option we built: the **pipeline template**, as a reusable GitHub Actions workflow | Edge and security; the Azure IaC module; Azure Pipelines (first built, then replaced) | Only the pipeline covers safe delivery, and its gate enforces the rest of the kit. The repository is on GitHub, so the workflow really runs. The Azure template could only be read. The steps are scripts either way (D18) |
| D18 | Every pipeline step is a script that also runs on a laptop (`checks.sh`, `publish.sh`, `release-facts.sh`, `deploy.sh`) | Logic inside the workflow file | Teams can run exactly what CI runs, and reviewers can check it without pushing. Moving to another CI tool means rewriting about 80 lines of YAML, not the logic |
| D27 | Safe delivery: a rolling update that never drops capacity, then a 5-minute SLO watch that rolls back by itself | A 10% canary with traffic splitting | A canary needs a service mesh or Argo Rollouts: a lot to run and explain. A version that can't start never takes traffic anyway, and the watch catches one that hurts users. Trade-off: a bad version reaches everyone for a few minutes |
| D17 | The policy gate refuses: no SLO or runbook, a root container, an unpinned base image, CRITICAL vulnerabilities, a used-up budget (unless labelled), and anything but a rollback on Saturday 13:00–17:00 | Guidelines in a wiki | A policy nobody enforces is ignored under deadline pressure. Every rule has a policy test (11 in all) |
| D31 | An unreadable error budget stops the gate. A service's first deploy uses the label `first-deploy` | Treating "no data" as "fine" | Found by testing: with no traffic the budget read as `NaN`, and "NaN ≤ 0" is false, so the gate would have **passed** any deploy |

### SLO and alerting

| ID | We decided | We rejected | Why |
|---|---|---|---|
| D5 | Business rejections (out of stock, price changed) are **good** events; malformed requests (400) don't count | Counting every `valid: false` or non-200 as bad | A correct "no" is the service doing its job. Only 5xx and slow answers are bad |
| D6 | One combined SLI: good = not a 5xx **and** answered within 250 ms | Separate availability and latency SLOs | The brief gives one budget for "fail or take longer than 250 ms": one budget, one set of alerts, one number for the product team |
| D7 | SLO 99.95% over a rolling 28 days, counted in requests: 49,728 bad requests | A 30-day window; a time-based budget | Straight from the brief. 28 days always holds 4 Saturdays, so every window has the same number of flash sales |
| D8 | Multi-window, multi-burn-rate alerts, recomputed for 28 days: burn rates 13.44 / 5.6 / 0.93 | The 30-day table (14.4 / 6 / 1); static thresholds like "errors > 1%" | Burn rate ties every alert to the budget. The long window proves it matters, and the short window lets it clear soon after recovery |
| D9, D22 | **Page** on the SLO (what users feel). **Ticket** when more than 5% of a dependency's calls fail or time out | Paging on pricing problems; alerting on pricing latency | If the fallback absorbs a slow pricing service, nobody should be woken. And our 150 ms deadline caps the latency we measure, so a latency alert could never fire |
| D10 | Our own small SLO generator (about 150 lines, in a pinned container) | Sloth; Pyrra | Our telemetry standard fixes the metric names, so a team's spec needs no PromQL. Sloth would make every team write queries |
| D11 | Alert rules are unit-tested with Prometheus's own tester | Linting only | Tests prove a fast burn pages, a failing dependency only tickets, and a healthy service stays quiet. A planted bug was caught |
| D35 | A service's alerts travel in its own chart; the platform's Prometheus picks them up from every namespace by itself | The Prometheus Operator; all rules kept in the platform chart | Deploying a service brings its alerts, and removing it takes them away. Nobody touches the platform. Proven both ways |
| D20 | No extra volume-aware page for the flash sale | A page on absolute bad requests during the sale | At 600 req/s a full outage spends the whole budget in 83 s, faster than any alert. The sale is protected up front instead (D14) |
| D21 | The drill's slow mode is 20% of calls taking 2–5 s | 10% | At 10% the fast page needs about 4 minutes, which doesn't fit a 5-minute incident |

### Resilience

| ID | We decided | We rejected | Why |
|---|---|---|---|
| D12 | Pricing call: 150 ms deadline, no retries, prices from the last 60 s as the fallback; `503` + `Retry-After` if a price is missing | Retries; failing every request when pricing is slow | A retry can't fit in 250 ms, and retries add load to a struggling dependency. The deadline caps requests in flight (430 → 28 at 600 req/s). Checkout prices the order again, so a 60-second-old price is safe |
| D25 | Each pod fills its price cache at startup and refreshes it every 30 s | Filling the cache only from customer orders | Found by testing: a new pod had nothing to fall back on, and a restart under traffic lost 2 of 160 requests. After the change: 160/160 |
| D13 | Readiness checks only that the pod has started, never Postgres or pricing | Readiness that checks dependencies | Proven: with the old check, a Postgres outage took every pod out of service and callers got no answer, while our own metrics saw nothing. Now they get a fast `503`, which the SLO counts |
| D33 | API pods wait for the database before starting, not for pricing | Waiting for both | A pod that waits on pricing can't start during a pricing outage, which would block every deploy and every recovery |
| D26 | Postgres JIT is off for the app's connections | The default (on) | Found by testing: the first query on a new connection took 179 ms with JIT on and 9 ms with it off, past our 100 ms limit |
| D14 | The flash sale is protected up front: scale out before 15:00, freeze deploys 13:00–17:00, load-test at 1.5× the peak; alerts are the safety net | Relying on alerts | At 600 req/s the whole month's budget lasts 83 seconds |
| D19, D29 | Scale out on a schedule (6 pods from 14:30 to 15:45); one pod handles about 250 req/s | An autoscaler (D30); paying for the peak all week | Measured: 2 pods hit one full core each at 600 req/s. This laptop (in Low Power Mode) couldn't prove the 6-pod plan, so it needs a re-run on real hardware |
| D30 | A PodDisruptionBudget yes, an autoscaler no | Autoscaling | The budget is 10 lines and protects every service during node maintenance. The one known peak is better met by scaling before it than by reacting after it starts |

### Telemetry, cost and security

| ID | We decided | We rejected | Why |
|---|---|---|---|
| D3 | Locally: OpenTelemetry → collector → Prometheus and Alertmanager for metrics and alerts, Jaeger for traces. No Grafana, no log backend | Grafana + Tempo; Loki | The brief asks for metrics and traces locally and calls dashboards optional. Each signal needs one container and no glue |
| D28 | Telemetry by auto-instrumentation; the shared chart sets the standard settings | Hand-written telemetry code | Request metrics (the SLI), traces and trace IDs on logs, with no app code. Found: without the pod name in the settings, two pods' counters overwrote each other |
| D15 | Cost controls are enforced in the platform's collector:<br>• 6 allowed labels<br>• the unused body-size histograms dropped<br>• all errors and slow traces kept, plus 5% of the rest<br>• a 2,000-series budget alert | Guidelines for teams | One bad label can multiply the bill. Measured: dropping the unused histograms took order-validation from 396 to 180 series |
| D38 | Jaeger keeps at most 20,000 traces in memory | No cap | Found in a drill: it ran out of memory 5 times in an hour |
| D37 | The bundled database and the whole platform run without root; services pass Pod Security `restricted` | Defaults | The same rules for everything. Proven by installing into namespaces that refuse root |

## 2. How we approached the service build

**The order:**
1. **Numbers first:** the budget in requests and minutes, the alert maths.
2. **Questions** for the product team.
3. **The service, step by step:** each step explained, approved, built and tested before the next.
4. **On a cluster:** the service on a real Kubernetes cluster.
5. **Telemetry, SLO and alerts.**
6. **Load and capacity.**
7. **The incident drill.**
8. **The pipeline.**
9. **Plain Helm charts,** then the golden path rebuilt around them.

Each step was proven on the cluster before moving on.

**What we kept small:**
- **One business endpoint,** `POST /orders/validate`, plus two health checks.
- **The rules as one plain function** (`validation.py`), with no database or network, so they're tested in milliseconds.
- **One database query per request,** and a fixed pool of 10 connections.
- **One process per container.** No ORM, no message queue, no cache server: the price cache is a dictionary in each pod.
- **A fake pricing service** with a switch, instead of a mock framework.
- **Local observability** as one chart: four containers, data in memory.

**What we chose not to build, and why (D4):**

| Not built | Why |
|---|---|
| API authentication | The brief doesn't ask for it; it belongs at the edge (section 6) |
| Stock reservation | Validation is advisory; checkout re-checks stock and price (assumption 8) |
| A traffic-splitting canary, a service mesh | D27 |
| An autoscaler | D30 |
| Grafana dashboards, a log backend | Optional in the brief; Prometheus and Jaeger show the signals |
| A real cloud deploy, a UI, multi-region | Out of scope for 3 days and a local demo |
| An ORM, a message queue | Nothing here needs them |
| The Prometheus Operator | D35 |
| The two golden-path options we didn't pick | Section 6 |

**What testing changed** (each one measured before it was fixed, and checked after):
- **D13:** a readiness check that hid a database outage.
- **D25:** caches that left gaps.
- **D26:** a 179 ms first query.
- **D31:** a gate that would pass with no data.
- **D32:** an image load that loaded nothing.
- **D38:** Jaeger running out of memory.
- **The fake pricing service:** killed by its own health check mid-drill.
- **Helm silently deploying an old copy** of a dependency chart.

## 3. Where we used AI, and what we changed

**How (D23):**
- **The tool:** Claude Code. **The rule:** I decide, the AI drafts, I verify.
- **Numbers and names:** numbers come from scripts, and metric names from the live Prometheus, never from the model's memory.
- **The start:** a phased plan and the questions. Then a small AI "team" of roles and skills, which I reviewed and approved item by item (11 approvals).
- **The service itself:** built in 14 steps. I saw and approved each one before it was written.
- **Later phases:****Plain Helm charts,** then the golden path rebuilt around them, it drafts i review and approve 

**What the AI generated:**
- the budget maths
- the service and its tests
- the charts
- the SLO generator and its tests
- the telemetry standard and the collector config
- the pipeline and its policies
- the load and drill scripts
- the docs
- the kit's two tools (`slo_math.py`, `prom.sh`) and two AI skills (D24). The skills are written but held back from the repository for now

**What I decided or changed:**
- **The runtime:** k3d instead of docker compose and also made sure it can install on any kubernetes cluster, k3d, minikube,or k8s. Then plain Helm charts with dependencies instead of install scripts. Then compose removed altogether.
- **Images:** built by GitHub and pulled by Helm (D32).
- **The guard rails:** in a shared library chart (D34).
- **The pipeline:** GitHub Actions instead of the Azure template (D16).
- **The new-service folder:** keep the name `new-service`, as a working example a team copies; and make the script do the by-hand steps (D36).
- **Instructions:** as simple and step by step as possible.
-

**Mistakes the AI made, and how they were caught:**
- **A shell trap:** zsh doesn't split `$VAR` into words, which broke several commands.
- **The drill harness:** the first drill ran without any load, because its log folder didn't exist.
- **The k6 logs:** deleted with the job before they were read.
- **A Helm trap:** `default` turns `enabled: false` into true.
- **Two wrong theories** about the database timeouts (idle connections, and CPU). Each was disproved by measurement before anything was "fixed".
- **`new-service.sh`** left three names unchanged while every check still passed. Caught by comparing its output with a hand-made copy.
- **A false "done":** an onboarding step was written up as done before it was run. Caught, then run.

**Not verified:**
- the workflow on GitHub (nothing pushed yet)
- 600 req/s on proper hardware
- a blind onboarding by someone new



## 4. Questions we asked, and assumptions we made
We drafted a reply to the brief with these questions. No answers yet, so we built on the assumptions. The full table and the reply email are in `docs/questions-and-assumptions.md`.

| # | Question | Our assumption |
|---|---|---|
| 1 | What happens when the error budget runs out? | Only fixes and rollbacks ship until it recovers. The pipeline enforces it, and the product owner can approve an exception |
| 2 | Is "out of stock" or "price changed" a failure? Where is 250 ms measured? | A correct "no" is good. Only 5xx and answers over 250 ms are bad, measured at the service |
| 3 | When pricing is slow, may we use a recent price? How old? | Yes, up to 60 s, flagged `"price_source": "cache"`. Checkout re-prices |
| 4 | Can we freeze deploys and pre-scale before the Saturday sale? Which timezone? | Freeze 13:00–17:00, scale out 14:30–15:45, store local time |
| 5 | Who is on call, and when should they be woken? | Storefront's on-call gets pages 24/7; tickets go to the team's queue |
| 6 | How do callers retry? | Once, with jitter, honouring `Retry-After`, with a 1 s timeout |
| 7 | Who owns order limits? | Merchandising, in the database: 20 lines per order, 10 per line by default, per-product overrides |
| 8 | Does checkout re-check stock and price? | Yes: validation is advisory and reserves nothing |
| 9 | How fast is pricing normally? How are its credentials rotated? | p99 under 50 ms; credentials rotated with an overlap |
| 10 | One currency? How big is the catalogue? | One currency, prices in cents, thousands of products, 1–5 lines per order |
| 11 | What if one product appears twice in an order? | Refused as malformed (400) |

## 5. Rough monthly cost
For the service alone, on the platform's shared AKS cluster, in a single region (US East list prices, pay-as-you-go).

**Assumptions:**
- **Traffic:** 40 validations a second all month, plus the 20-minute flash sale at 600 a second about 4 times a month. That's about **107 million requests a month**.
- **Pods:** 2 API pods (0.1 vCPU, 128 MiB reserved each), and 6 for about 1.25 hours each Saturday.
- **Database:** Azure Database for PostgreSQL Flexible Server, General Purpose D2ds_v5 (2 vCores), with **zone-redundant high availability**. We assume (to check) that the database's SLA without HA is below our 99.95% SLO, so one maintenance event could spend the month's budget.
- **Telemetry:** Azure Monitor's managed Prometheus for metrics, and a Log Analytics workspace for traces and logs, with the platform's default cost controls.
- **Shared and not counted:** the AKS control plane, ingress and edge, the container registry and Key Vault. Our share of each is a few dollars at most.

| Item | Working | ~USD/month |
|---|---|---|
| Compute: our share of the AKS nodes | 0.2 vCPU reserved at about $35 per vCPU-month (D4s_v5), plus the Saturday scale-out (about 22 vCPU-hours, ~$1) and some node headroom | **~$10** |
| PostgreSQL Flexible Server | D2ds_v5 about $130, doubled for zone-redundant HA, plus storage | **~$265** |
| Metrics (managed Prometheus) | about 190 series every 15 s = 33 million samples, at $0.16 per 10 million | **~$1** |
| Traces (Log Analytics) | 5% sampled, plus every error and slow request = 5.4 million traces, about 19 GB at ~$2.30/GB | **~$45** |
| Logs | JSON, warnings and errors only, with no line per request: well under 1 GB | **~$1** |
| **Total** | | **≈ $320/month** |

**What the cost controls are worth:**

| Without | Cost |
|---|---|
| Trace sampling (every request kept) | about 374 GB, **~$860** a month instead of ~$45 |
| Cutting the per-request log line | about 32 GB, **~$74** a month instead of ~$1 |
| The label allowlist and series budget (e.g. one label with 10,000 values) | about **$28** a month per such mistake, per service, instead of ~$1 |

So the defaults keep telemetry around **$50 a month instead of about $1,000**. The database is the biggest line. A burstable server without HA would cost a fraction of it, but it can't meet a 99.95% SLO.

**Caveats:**
- These are list prices from secondary sources: check them in the Azure pricing calculator before budgeting.
- Trace size (about 3.5 KB for 3–4 spans) is an estimate.
- Querying metrics (alert rules, dashboards) is billed separately, per billion samples processed. Our 3-day and 28-day alert windows are the biggest part of that.


## 6. The two golden-path parts we didn't build
The brief asks for one of three options, with half a page each on the other two. We built the pipeline template (D16).

### Edge and security
**What we'd build:** Azure Front Door Premium in front of AKS, all in Terraform. Cloudflare works the same way.
- **TLS:** a Front Door managed certificate for the public hostname, issued and renewed automatically; TLS 1.2+ end to end.
- **WAF:** a Front Door WAF policy in prevention mode, with the managed default rule set and bot protection. Plus a **rate limit per client IP** on `/orders/validate`, e.g. 300 a minute: generous for a shopper, low for a script.
- **The origin is reachable only through the edge:**
  - Front Door Premium **Private Link** to an internal load balancer in AKS, so the service has no public IP.
  - The cheaper alternative: a network rule that allows only the `AzureFrontDoor.Backend` service tag, plus a check at ingress that the `X-Azure-FDID` header is our Front Door's.
- **Certificate alert:** a probe on the public URL raises a ticket when the certificate expires within 14 days, and a page within 3.
- **Locally:** Caddy in front of the Service, with its own CA and a rate limit.

**Why not this one:** it secures the front door, but most of it is Terraform we could only validate, not run. The pipeline shows safe delivery and enforces the SLO, runbook and budget rules, which the brief scores directly.

### Azure IaC module
**What we'd build:** one Terraform module, `aks-service`, holding everything a team's service needs in Azure:
- **A namespace** on the shared AKS cluster.
- **A workload identity:** a managed identity linked to the service's Kubernetes service account. Pods then read `DATABASE_URL` and `PRICING_TOKEN` from **Key Vault**, with no stored credentials. This would replace the local-only passwords in the charts.
- **A database** on Azure Database for PostgreSQL Flexible Server, with zone-redundant HA (section 5).
- **The service's generated SLO rules** as an Azure Monitor managed Prometheus rule group.

**Cost tags, enforced twice:**
1. The module's `tags` variable fails `terraform plan` unless `owner`, `service`, `environment` and `cost_centre` are all set.
2. An Azure Policy assignment ("require a tag", deny) on the resource group catches anything created outside Terraform.

**Checked with:** `terraform fmt -check` and `terraform validate` (with `init -backend=false`, no cloud account needed), plus `tflint`.

**Why not this one:** it would only ever be validated, never applied, and it shows less of what the golden path does for a team than the pipeline's gate does.

## 7. Known gaps and shortcuts, and what we cut

**Not yet proven:**
- **The workflow** hasn't run on GitHub, and the images aren't published yet. Every step's script ran locally, and `actionlint` passes.
- **600 req/s:** a laptop  couldn't reach it with 2 pods, and couldn't prove the 6-pod plan (D29).
- **The database timeout bursts** seen in drills. They aren't caused by pricing, idle connections or CPU (all measured). They're most likely the laptop's VM stalling. The re-test with Low Power Mode off is still to do.
- **Onboarding** was done by the builder, not a blind test by a new team.
- **kind:** the install commands are documented, but only k3d and minikube were tested.

**Shortcuts, fine locally and not for production:**
- **Passwords:** the charts carry local-only default passwords (production: Key Vault through workload identity, section 6).
- **The bundled database** keeps its data in the pod, so a restart reloads the seed (production: a managed database).
- **The platform** runs single replicas with data in memory. A Prometheus restart wipes its history, which makes the slow-burn page over-sensitive for a while, as seen in a drill.
- **The release gate** reaches Prometheus through a port-forward (production: the platform's endpoint).
- **GitHub Actions** are pinned to major versions, not commit SHAs. Images aren't signed, and there's no SBOM.
- **The telemetry standard** is detailed for Python only.
- **One release per namespace:** the same service installed twice in one cluster would clash on its rules file.

**Cut to stay within 3 days:**
- Grafana dashboards
- the canary
- autoscaling
- the edge and IaC options
- a real AKS deploy
- a log backend
- a circuit breaker for pricing
- a full kind test pass

## 8. With one more sprint
1. **Ship it for real:**
   - push, let the workflow publish the images, and make them public
   - stand up an AKS staging namespace
   - run the first deploy through the gate with `first-deploy`
2. **Capacity on real hardware:**
   - re-run 600 and 900 req/s (1.5× the peak) on AKS
   - set the Saturday replica count from the result
   - schedule it (a KEDA cron or a scheduled pipeline run)
3. **Close the database question:** re-run the drill and the burst test with Low Power Mode off, then on AKS. Fix it in the app only if it's still there.
4. **Build the Azure IaC module** (section 6), with Key Vault through workload identity in place of the local passwords.
5. **Dashboards:** one Grafana board per service, with the SLI, the budget left and the burn rate, generated from `slo.yaml` like the alerts.
6. **A circuit breaker for pricing,** so a failing dependency doesn't cost each request 150 ms.
7. **Real adoption:** a product team onboards a new service with only the kit, while we time it and fix what they trip on.
8. **Publish the golden-path chart to a registry** (OCI on ghcr.io), so services in other repositories depend on it by version.
9. **Supply-chain hardening:** pin Actions by SHA, sign images (cosign), and publish an SBOM.
10. **Telemetry guides** for more languages than Python.
