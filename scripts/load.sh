#!/usr/bin/env bash
# Load-test order-validation from inside the cluster with k6 (load/validate.js), and print
# k6's summary against the SLO (at most 1 in 2,000 validations fails or takes over 250 ms).
#
#   scripts/load.sh steady [duration]   a normal day: 40 validations a second (default 5m)
#   scripts/load.sh flash  [duration]   the Saturday 15:00 sale: 600 a second (default 20m)
#   NAMESPACE=...                       where order-validation runs (default order-validation)
set -euo pipefail
cd "$(dirname "$0")/.."
scenario=${1:-}; duration=${2:-}
case "$scenario" in
  steady) duration=${duration:-5m} ;;
  flash) duration=${duration:-20m} ;;
  *) echo "usage: scripts/load.sh steady|flash [duration, e.g. 5m]" >&2; exit 2 ;;
esac
NAMESPACE=${NAMESPACE:-order-validation}
k() { kubectl -n "$NAMESPACE" "$@"; }

k create configmap k6-script --from-file=load/validate.js --dry-run=client -o yaml | k apply -f - >/dev/null
k delete job k6 --ignore-not-found --wait >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: k6
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 12345, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: k6
          image: grafana/k6:2.3.0
          args: ["run", "--quiet", "/scripts/validate.js"]
          env:
            - {name: SCENARIO, value: "$scenario"}
            - {name: DURATION, value: "$duration"}
          resources:
            requests: {cpu: 500m, memory: 256Mi}
            limits: {memory: 1Gi}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: script, mountPath: /scripts}, {name: tmp, mountPath: /tmp}]
      volumes:
        - {name: script, configMap: {name: k6-script}}
        - {name: tmp, emptyDir: {}}
EOF
echo "k6: $scenario load for $duration, against http://order-validation:8080 in $NAMESPACE"
# Wait for k6 to start (its image may still be downloading), then follow its output.
for _ in $(seq 1 90); do
  phase=$(k get pods -l job-name=k6 -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  case "$phase" in Running|Succeeded|Failed) break ;; esac
  sleep 2
done
k logs -f job/k6
