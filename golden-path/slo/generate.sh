#!/usr/bin/env bash
# SLO as code: turn a chart's slo.yaml into its slo-rules.yaml (Prometheus recording rules and
# burn-rate alerts), in a small pinned container, so nobody needs Python installed.
# Run it after every change to slo.yaml, and commit both files.
#
#   golden-path/slo/generate.sh charts/<service>            write charts/<service>/slo-rules.yaml
#   golden-path/slo/generate.sh charts/<service> --check    write nothing; fail if it's out of date
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
here=$(pwd)
case "$here" in "$root"|"$root"/*) ;; *) echo "run it from inside the repository" >&2; exit 1 ;; esac

image="golden-path-slo:$(shasum "$root/golden-path/slo/Dockerfile" | cut -c1-12)"
docker image inspect "$image" >/dev/null 2>&1 || docker build -q -t "$image" "$root/golden-path/slo" >/dev/null
docker run --rm --user "$(id -u):$(id -g)" -v "$root:/work" -w "/work${here#"$root"}" "$image" "$@"
