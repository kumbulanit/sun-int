#!/usr/bin/env bash
# Open everything on this machine until Ctrl-C:
#   http://127.0.0.1:9090    Prometheus: metrics, SLO rules, alerts
#   http://127.0.0.1:9093    Alertmanager: pages and tickets
#   http://127.0.0.1:16686   Jaeger: traces
#   http://127.0.0.1:8080    the order validation API
#   http://127.0.0.1:8091    the fake pricing service's misbehave switch
# NAMESPACE: where order-validation runs (default order-validation).
set -euo pipefail
NAMESPACE=${NAMESPACE:-order-validation}
pids=()
forward() { kubectl -n "$1" port-forward "svc/$2" "$3" >/dev/null 2>&1 & pids+=($!); }
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
forward platform prometheus 9090:9090
forward platform alertmanager 9093:9093
forward platform jaeger 16686:16686
forward "$NAMESPACE" order-validation 8080:8080
forward "$NAMESPACE" pricing-fake 8091:8081   # 8091: 8081 is often taken
sed -n '2,7p' "$0" | sed 's/^# //'
echo "Ctrl-C to close them."
wait
