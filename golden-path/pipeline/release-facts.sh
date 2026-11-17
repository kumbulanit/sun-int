#!/usr/bin/env bash
# The facts the release policy (policy/release.rego) needs, printed as JSON:
# how much error budget is left, the run's labels, and the day and hour in the
# store's timezone (for the Saturday freeze).
# Usage: release-facts.sh <service> [comma-separated labels, e.g. rollback]
#   A service's first deploy has no error-budget data yet: label it first-deploy.
# Env:   PROM_URL          the platform's Prometheus (default: a port-forward to it)
#        BUDGET_REMAINING  set it to skip Prometheus, e.g. in a test (say why in the run)
#        STORE_TZ          the store's timezone (default UTC; assumption 4)
set -euo pipefail
service="$1"; labels="${2:-}"
if [ -z "${PROM_URL:-}" ] && [ -z "${BUDGET_REMAINING:-}" ]; then
  kubectl -n platform port-forward svc/prometheus 19091:9090 >/dev/null 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' EXIT
  PROM_URL=http://127.0.0.1:19091
  for _ in $(seq 1 30); do curl -fs -o /dev/null "$PROM_URL/-/ready" && break; sleep 1; done
fi

if [ -n "${BUDGET_REMAINING:-}" ]; then
  budget="$BUDGET_REMAINING"
else
  query="slo:error_budget_remaining{service=\"${service}\"}"
  if ! reply=$(curl -fsS --max-time 10 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$query"); then
    echo "can't read the error budget from $PROM_URL; set BUDGET_REMAINING to override, and say why" >&2
    exit 1
  fi
  # No data, or NaN (no requests counted yet), must stop the gate, never pass it:
  # "NaN <= 0" is false, so an unreadable budget would otherwise let any deploy through.
  budget=$(echo "$reply" | python3 -c '
import json, math, sys
r = json.load(sys.stdin)["data"]["result"]
value = float(r[0]["value"][1]) if r else float("nan")
print("" if math.isnan(value) else value)')
  if [ -z "$budget" ] && [[ ",$labels," == *",first-deploy,"* ]]; then
    echo "no error-budget data for $service yet; labelled first-deploy, so the whole budget counts as left" >&2
    budget=1
  elif [ -z "$budget" ]; then
    echo "no error-budget data for $service in $PROM_URL: no traffic yet, or the name in slo.yaml is wrong." >&2
    echo "If this is its first deploy, run it with the label first-deploy." >&2
    exit 1
  fi
fi

python3 - "$service" "$budget" "$labels" "${STORE_TZ:-UTC}" <<'EOF'
import json, sys
from datetime import datetime
from zoneinfo import ZoneInfo
service, budget, labels, tz = sys.argv[1:]
now = datetime.now(ZoneInfo(tz))
print(json.dumps({"service": service, "budget_remaining": float(budget),
                  "labels": [label for label in labels.split(",") if label],
                  "weekday": now.strftime("%A"), "hour": now.hour}))
EOF
