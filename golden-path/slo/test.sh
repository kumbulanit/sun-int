#!/usr/bin/env bash
# Tests SLO as code with Prometheus's own rule tester (promtool), in a pinned container:
#   1. the generator's output for tests/slo.yaml behaves: a healthy service stays quiet,
#      a fast burn pages, a failing dependency only tickets (tests/example.test.yaml)
#   2. every service's slo-rules.yaml is valid, and up to date with its slo.yaml
set -euo pipefail
cd "$(dirname "$0")/../.."
promtool() { docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" -w /work --entrypoint promtool prom/prometheus:v3.15.1 "$@"; }

echo "== 1. The generator's alerts behave"
golden-path/slo/generate.sh golden-path/slo/tests >/dev/null
promtool test rules golden-path/slo/tests/example.test.yaml

echo "== 2. Every service's SLO rules are valid and up to date"
charts=()
for spec in charts/*/slo.yaml; do [ -f "$spec" ] && charts+=("$(dirname "$spec")"); done
[ ${#charts[@]} -gt 0 ] || { echo "no charts/*/slo.yaml found"; exit 0; }
golden-path/slo/generate.sh "${charts[@]}" --check
promtool check rules "${charts[@]/%//slo-rules.yaml}"
