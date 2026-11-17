# Telemetry standard

What every service on the golden path sends, how to add it, and the rules that keep the bill small. Our observability platform bills by usage, so **the defaults are cheap**. You get metrics, traces and searchable logs without writing telemetry code.

## What you get without doing anything
The golden-path chart sets these for every service (unless you set `telemetry.enabled: false`):

| Setting | Value | Why |
|---|---|---|
| `OTEL_SERVICE_NAME` | your chart's name | Your service's name everywhere: metrics (`job` label), traces, alerts |
| `OTEL_RESOURCE_ATTRIBUTES` | pod name, version, environment, team | Each pod's numbers stay separate; a trace says which version produced it |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | the platform's collector, `http://otel-collector.platform:4318` | Where to send. Never change it: the collector applies the cost controls |
| `OTEL_METRIC_EXPORT_INTERVAL` | 15 s | Fresh enough for 5-minute alert windows; slower would hide fast incidents |
| `OTEL_LOGS_EXPORTER` | `none` | Logs go to stdout as JSON, collected by the platform |

## Add it to a Python service (about 15 minutes)
1. **Add the packages** to `requirements.txt`, at the versions in `services/order-validation/requirements.txt`: `opentelemetry-distro`, `opentelemetry-exporter-otlp-proto-http`, plus one instrumentation per library you use (`-fastapi`, `-httpx`, `-asyncpg`, `-logging`, …).
2. **Start your server through the launcher** in your Dockerfile: `CMD ["opentelemetry-instrument", "uvicorn", ...]`.
3. **Add 4 settings** to `env` in your chart's `values.yaml` (new-service.sh puts them there for you):
   ```yaml
   OTEL_SEMCONV_STABILITY_OPT_IN: http               # the standard HTTP metric names, in seconds
   OTEL_PYTHON_LOG_CORRELATION: "true"               # trace_id on log lines
   OTEL_PYTHON_EXCLUDED_URLS: "healthz,readyz"       # no telemetry for health checks
   OTEL_PYTHON_FASTAPI_EXCLUDE_SPANS: "receive,send" # skip tiny internal spans nobody reads
   ```
4. **Check it arrived:** send some requests, wait 30 s, then `golden-path/tools/prom.sh names http_server` and open Jaeger (`kubectl -n platform port-forward svc/jaeger 16686`).

That gives you request rate, errors and latency (**your SLI comes from this**), a trace for every request across HTTP calls and database queries, and a `trace_id` on log lines. Other languages: the same chart settings, plus that language's OpenTelemetry auto-instrumentation agent.

## Count your dependencies
For every service you call, count each call by outcome. It's the one metric you write yourself, and your SLO spec's dependency alerts are built on it:

```python
from opentelemetry import metrics
calls = metrics.get_meter("your-service").create_counter("dependency.calls", unit="{call}")
calls.add(1, {"dependency": "pricing", "outcome": "ok"})   # outcome: ok | timeout | error | auth
```

Count **timeouts** too. A dependency that's slower than your own deadline never shows high latency (your timeout caps what you measure), but it does show up as timeouts.

## Naming and label rules
- **Names:** use the OpenTelemetry standard names; don't invent your own for HTTP or database. Your own metrics are lower-case `<area>.<thing>` with a unit (`s`, `By`, `{call}`).
- **Labels (attributes):** only values from a **short, fixed list**. **Never** IDs, SKUs, emails, raw URLs or error messages: each new value creates a new series, and series are what we pay for. Use `http.route` (`/orders/{id}`), never the raw path.
- **What the collector keeps:** `http.route`, `http.request.method`, `http.response.status_code`, `error.type`, `dependency`, `outcome`. Anything else is dropped. Ask the platform team if you need another one, and say why.
- **How names look in Prometheus:** dots become underscores and the unit becomes a suffix, so `http.server.request.duration` (seconds) becomes `http_server_request_duration_seconds_bucket` / `_count` / `_sum`, and `dependency.calls` becomes `dependency_calls_total`. Your service name is the `job` label and the pod is `instance`. Check real names with `golden-path/tools/prom.sh names <word>`; don't guess.

## Cost controls (defaults; the platform enforces them)

| Control | Default | Why | Enforced in |
|---|---|---|---|
| Label allowlist | the 6 attributes above | Unbounded labels multiply series | Collector (`transform/allowlist`) |
| Series budget | 2,000 active series per service | Catches a bad label before the bill does | Platform alert `ServiceOverSeriesBudget` |
| Histogram buckets | 14 standard edges, including **0.25 s** | Few buckets, and an exact edge at our SLO's 250 ms | OpenTelemetry's standard HTTP buckets |
| Unused metrics | the request and response **body-size histograms** are dropped | Nothing reads them (no SLI, no alert), and they were more than half of a service's series | Collector (`filter/unused`) |
| Trace sampling | **all** errors + **all** requests over 250 ms + **5%** of the rest (100% locally) | You keep the traces anyone will open | Collector (`tail_sampling`) |
| Health checks | no metrics, no traces | Thousands of identical, useless data points a day | App setting + collector filter |
| Logs | JSON on stdout, `INFO`; no line per successful request; `DEBUG` only while investigating, then back | Logs are the most expensive signal per event | Your service (`LOG_LEVEL`) |
| Retention | metrics 15 d raw, SLO results 28 d+; traces 3 d; logs 7 d | Long enough to investigate; the 28-day SLO needs only small recorded series | Platform backends (local: 2 d / in memory) |

**Worked example, `order-validation`:** **180 active series** with 2 pods (budget 2,000). It was 396 before the collector dropped the unused body-size histograms. Measured in Prometheus; check yours with `prom.sh series <service>`. At 40 req/s with 5% sampling it keeps about 173,000 traces a day, plus every error and every slow request. It writes no log lines on the happy path.
