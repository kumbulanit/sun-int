#!/usr/bin/env bash
# Safe deploy: roll out with Helm, then watch the service's SLO; if the fast-burn page fires
# during the watch, roll back automatically.
#   - The golden-path chart's rolling update never drops capacity: each new pod must be ready
#     before an old one goes, so a version that can't start never takes traffic (--wait fails).
#   - The watch catches a version that starts fine but hurts users.
#
#   golden-path/pipeline/deploy.sh <service> [watch seconds, default 300]
#   The service goes to the namespace of the same name.
# Env: PROM_URL   the platform's Prometheus (default: a port-forward to it)
#      HELM_ARGS  extra flags for helm, e.g. "--set replicas=6"
set -euo pipefail
cd "$(dirname "$0")/../.."
service=${1:?usage: deploy.sh <service> [watch seconds]}
watch=${2:-300}

# Always rebuild the dependencies: `helm --dependency-update` only fetches missing ones, so a
# stale copy on disk (e.g. an older golden-path chart) would be deployed without a warning.
helm dependency update "charts/$service" >/dev/null
# shellcheck disable=SC2086  # HELM_ARGS is deliberately split into flags
helm upgrade --install "$service" "charts/$service" -n "$service" --create-namespace \
  ${HELM_ARGS:-} --wait --timeout 5m
revision=$(helm history "$service" -n "$service" --max 1 -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["revision"])')
echo "deployed $service (revision $revision); watching its SLO for ${watch}s"

if [ -z "${PROM_URL:-}" ]; then
  kubectl -n platform port-forward svc/prometheus 19090:9090 >/dev/null 2>&1 &
  pf=$!; trap 'kill "$pf" 2>/dev/null || true' EXIT
  PROM_URL=http://127.0.0.1:19090
  for _ in $(seq 1 30); do curl -fs -o /dev/null "$PROM_URL/-/ready" && break; sleep 1; done
fi

query="ALERTS{alertname=\"SLOFastBurn\", service=\"$service\", alertstate=\"firing\"}"
end=$(( $(date +%s) + watch ))
while [ "$(date +%s)" -lt "$end" ]; do
  firing=$(curl -fsS --max-time 10 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$query" \
           | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["result"]))')
  if [ "$firing" != "0" ]; then
    if [ "$revision" = 1 ]; then
      echo "SLOFastBurn is firing for $service after its first deploy: nothing to roll back to. Page the team." >&2
      exit 1
    fi
    echo "SLOFastBurn is firing for $service after the deploy: rolling back" >&2
    helm rollback "$service" -n "$service" --wait
    exit 1
  fi
  sleep 15
done
echo "$service is healthy after ${watch}s"
