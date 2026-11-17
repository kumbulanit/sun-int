#!/usr/bin/env bash
# Every check the golden path runs before a service's change can merge. The pipeline runs this
# same script, so "it passes on my laptop" means it passes in CI. Needs Docker and helm.
#
#   golden-path/pipeline/checks.sh <service>          e.g. order-validation
#   SKIP_SCAN=1 golden-path/pipeline/checks.sh ...    skip the vulnerability scan (slow on a laptop)
set -euo pipefail
cd "$(dirname "$0")/../.."
service=${1:?usage: golden-path/pipeline/checks.sh <service>}
chart=charts/$service
code=services/$service
step() { echo; echo "== $*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
in_docker() { docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" -w /work "$@"; }

step "1. On the golden path: chart, SLO, runbook, Dockerfile"
[ -f "$chart/Chart.yaml" ] || fail "no $chart/Chart.yaml: start a service with golden-path/new-service.sh"
grep -q "name: golden-path" "$chart/Chart.yaml" || fail "$chart doesn't depend on the golden-path chart"
[ -f "$chart/slo.yaml" ] || fail "no $chart/slo.yaml: every service on the golden path has an SLO"
runbook=$(awk '/^runbook:/ {print $2}' "$chart/slo.yaml")
[ -n "$runbook" ] && [ -f "$runbook" ] || fail "$chart/slo.yaml links to the runbook '$runbook', which doesn't exist"
[ -f "$code/Dockerfile" ] || fail "no $code/Dockerfile"
echo "ok: $chart (golden path, SLO), $runbook, $code/Dockerfile"

step "2. SLO as code: the alerts behave, and every slo-rules.yaml matches its slo.yaml"
golden-path/slo/test.sh

step "3. The chart: lints and renders (the golden path's guard rails run at render time)"
helm dependency update "$chart" >/dev/null
helm lint "$chart" --quiet
helm template "$service" "$chart" -n "$service" >/dev/null
echo "ok: $chart renders"

step "4. Policy: the image runs as non-root, from pinned base images"
in_docker openpolicyagent/conftest:v0.71.1 verify --policy golden-path/pipeline/policy
in_docker openpolicyagent/conftest:v0.71.1 test "$code/Dockerfile" --policy golden-path/pipeline/policy

if grep -qiE "^FROM .* AS test" "$code/Dockerfile"; then
  step "5. Unit tests (the Dockerfile's test stage)"
  docker build -q --target test -t "$service-checks-tests" "$code" >/dev/null
  docker run --rm "$service-checks-tests"
else
  step "5. Unit tests: none (the Dockerfile has no test stage)"
fi

if [ "${SKIP_SCAN:-}" = 1 ]; then
  step "6. Vulnerability scan: skipped (SKIP_SCAN=1). The pipeline always runs it."
else
  step "6. Vulnerability scan: fails on CRITICAL vulnerabilities that have a fix"
  docker build -q -t "$service-checks:scan" "$code" >/dev/null
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.76.1 \
    image --quiet --exit-code 1 --severity CRITICAL --ignore-unfixed "$service-checks:scan"
fi

echo; echo "All checks passed for $service."
