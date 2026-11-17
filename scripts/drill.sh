#!/usr/bin/env bash
# drill.sh: one incident drill, under load (run scripts/load.sh steady in another terminal).
# Switches the fake pricing service into a bad mode, then watches Alertmanager and
# Prometheus and writes a timeline. It opens its own connections into the cluster.
#
# Usage: scripts/drill.sh <label> [--mode slow|error|auth_fail] [--pct 20] [--duration 300]
#                         [--watch 900] [--interval 15]
#   --pct       share of pricing calls affected (slow or erroring), in percent
#   --duration  how long pricing misbehaves, in seconds (the fake reverts by itself)
#   --watch     how long to keep watching, in seconds (include the recovery)
# Env: NAMESPACE       where order-validation runs (default order-validation)
#      SLI_QUERY       PromQL for the SLI error ratio over 5m
#      DEP_QUERY       PromQL for the share of pricing calls failing or timing out
# Output: docs/drills/<label>-<timestamp>.log
set -euo pipefail

label="${1:-}"
[ -n "$label" ] && [ "${label#-}" = "$label" ] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift

mode=slow; pct=20; duration=300; watch=900; interval=15
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --pct) pct="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    --watch) watch="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
NAMESPACE="${NAMESPACE:-order-validation}"
# Connections into the cluster, closed when the drill ends.
pids=()
forward() { kubectl -n "$1" port-forward "svc/$2" "$3" >/dev/null 2>&1 & pids+=($!); }
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
forward "$NAMESPACE" pricing-fake 18091:8081
forward platform alertmanager 19093:9093
forward platform prometheus 19090:9090
PRICING_ADMIN_URL=http://127.0.0.1:18091
ALERTMANAGER_URL=http://127.0.0.1:19093
PROM_URL=http://127.0.0.1:19090
for _ in $(seq 1 30); do curl -fs -o /dev/null "$PROM_URL/-/ready" && curl -fs -o /dev/null "$ALERTMANAGER_URL/-/ready" && break; sleep 1; done
# The recording rules generated from charts/order-validation/slo.yaml.
# (Set in two steps: a "}" inside ${VAR:-default} would end the default early.)
SLI_QUERY="${SLI_QUERY:-}"
[ -n "$SLI_QUERY" ] || SLI_QUERY='slo:error_ratio:rate5m{service="order-validation"}'
DEP_QUERY="${DEP_QUERY:-}"
[ -n "$DEP_QUERY" ] || DEP_QUERY='sum(rate(dependency_calls_total{job="order-validation",outcome!="ok"}[1m])) / sum(rate(dependency_calls_total{job="order-validation"}[1m]))'

log() { echo "$*" | tee -a "$out"; }

prom() {
  curl -fsS --max-time 5 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)["data"]["result"]
print("%.4g" % float(r[0]["value"][1]) if r else "n/a")' 2>/dev/null || echo "n/a"
}

alerts() {
  curl -fsS --max-time 5 "$ALERTMANAGER_URL/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null | python3 -c '
import json, sys
names = sorted("%s/%s" % (a["labels"].get("alertname"), a["labels"].get("severity", "-")) for a in json.load(sys.stdin))
print(",".join(names) if names else "none")' 2>/dev/null || echo "unreachable"
}

for url in "$PRICING_ADMIN_URL/admin/mode" "$ALERTMANAGER_URL/-/ready" "$PROM_URL/-/ready"; do
  curl -fsS --max-time 3 "$url" >/dev/null 2>&1 || { echo "not reachable: $url (are the platform and order-validation installed?)" >&2; exit 3; }
done

mkdir -p docs/drills
out="docs/drills/${label}-$(date +%Y%m%dT%H%M%S).log"

log "drill=$label mode=$mode pct=$pct duration=${duration}s watch=${watch}s start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "before: alerts=$(alerts) sli_err_5m=$(prom "$SLI_QUERY") pricing_failing=$(prom "$DEP_QUERY")"

body=$(printf '{"mode":"%s","slow_pct":%s,"slow_ms_min":2000,"slow_ms_max":5000,"error_pct":%s,"duration_s":%s}' \
  "$mode" "$pct" "$pct" "$duration")
curl -fsS -X POST -H 'Content-Type: application/json' -d "$body" "$PRICING_ADMIN_URL/admin/mode" >/dev/null
log "t=+0s pricing switched to $mode ($pct%) for ${duration}s"

start=$(date +%s)
prev=""
restored=""
while :; do
  t=$(( $(date +%s) - start ))
  [ "$t" -gt "$watch" ] && break
  if [ -z "$restored" ] && [ "$t" -ge "$duration" ]; then
    log "t=+${t}s pricing back to normal (auto-revert)"
    restored=1
  fi
  a=$(alerts)
  line="t=+${t}s alerts=$a sli_err_5m=$(prom "$SLI_QUERY") pricing_failing=$(prom "$DEP_QUERY")"
  if [ "$a" != "$prev" ]; then line="$line   <- alerts changed"; fi
  log "$line"
  prev="$a"
  sleep "$interval"
done

log "end=$(date -u +%Y-%m-%dT%H:%M:%SZ)  timeline saved to $out"
