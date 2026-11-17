#!/usr/bin/env bash
# Test an installed order-validation:
#   1. all 40 tests (unit + end-to-end) as a pod in the cluster: `helm test`
#   2. 3 example orders sent from this machine, through a port-forward
#
#   scripts/test.sh                  (settings: NAMESPACE, default order-validation;
#                                     RELEASE, default order-validation)
set -euo pipefail
NAMESPACE=${NAMESPACE:-order-validation}
RELEASE=${RELEASE:-order-validation}

echo "== 1. All 40 tests, in the cluster"
helm test "$RELEASE" -n "$NAMESPACE" --logs

echo
echo "== 2. 3 example orders, from this machine"
PORT=18080   # not 8080, so it can't clash with a port-forward you already run
kubectl -n "$NAMESPACE" port-forward svc/order-validation "$PORT:8080" >/dev/null 2>&1 &
PF=$!; trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" && break; sleep 0.5; done
curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" || { echo "error: the port-forward to the API didn't open within 30 s" >&2; exit 1; }

order() { curl -s -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$PORT/orders/validate"; echo; }
echo "--- a valid order: 2 x SKU-0001 at 100"
order '{"items":[{"sku":"SKU-0001","quantity":2,"unit_price":100}]}'
echo "--- out of stock: 1 x SKU-0046 (Wireless earbuds)"
order '{"items":[{"sku":"SKU-0046","quantity":1,"unit_price":4600}]}'
echo "--- price changed: SKU-0001 at 90 (it costs 100)"
order '{"items":[{"sku":"SKU-0001","quantity":1,"unit_price":90}]}'
