#!/usr/bin/env bash
# Start a new service on the golden path. It does the by-hand steps of golden-path/new-service/README.md
# for you: copies golden-path/new-service/ (a working example service) and changes its three
# example values to yours: example-service (the name), example-team, example-org (the registry).
#
#   golden-path/new-service.sh                                 it asks for the name and team
#   golden-path/new-service.sh payments --team checkout        or give them straight away
#   ... [--registry ghcr.io/<owner>]                           default: this repository's GitHub owner
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }
ask() { local answer; read -r -p "$1" answer || true; echo "$answer"; }   # empty if there's no one to ask

name=""; team=""; registry=""
[ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { name=$1; shift; }
while [ $# -gt 0 ]; do
  case "$1" in
    --team) team=${2:-}; shift 2 ;;
    --registry) registry=${2:-}; shift 2 ;;
    *) die "unknown option $1 (usage: golden-path/new-service.sh [<name> --team <team>])" ;;
  esac
done

valid='^[a-z][a-z0-9-]{0,38}[a-z0-9]$'   # a Kubernetes name: lower case, digits and dashes
[ -n "$name" ] || name=$(ask "Service name (lower case, e.g. payments): ")
[[ $name =~ $valid ]] || die "the service name must be lower case letters, digits and dashes, e.g. payments"
[ ! -e "charts/$name" ] && [ ! -e "services/$name" ] || die "charts/$name or services/$name already exists"
[ -n "$team" ] || team=$(ask "Owning team (lower case, e.g. checkout): ")
[[ $team =~ $valid ]] || die "the team must be lower case letters, digits and dashes, e.g. checkout"
if [ -z "$registry" ]; then
  owner=$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+)/.*#\1#p' | tr '[:upper:]' '[:lower:]')
  [ -n "$owner" ] && registry="ghcr.io/$owner" || registry=$(ask "Image registry (e.g. ghcr.io/myorg): ")
  [ -n "$registry" ] || die "no registry: pass --registry ghcr.io/<owner>"
fi

# The by-hand steps: copy the example, then change the names (and drop the "# CHANGE:" notes).
example=golden-path/new-service   # a working example; the three example-* values are what change
(cd "$example" && find services charts workflows -type f) | while read -r file; do
  dest=${file//example-service/$name}
  [[ $dest == workflows/* ]] && dest=".github/$dest"
  mkdir -p "$(dirname "$dest")"
  sed -e "s|ghcr.io/example-org|$registry|g" -e "s/example-service/$name/g" -e "s/example-team/$team/g" \
      -e '/^ *# CHANGE:/d' -e 's/ *# CHANGE:.*$//' "$example/$file" > "$dest"
done
golden-path/slo/generate.sh "charts/$name" >/dev/null   # its alerts, for the new name

cat <<EOF

Created $name (team $team), a copy of golden-path/new-service:
  services/$name/                 the app, its Dockerfile and its runbook
  charts/$name/                   its chart and SLO, with the alerts generated
  .github/workflows/$name.yml     its pipeline
Its image will be $registry/$name.

Next:
  1. Check it:       golden-path/pipeline/checks.sh $name
  2. Your code:      services/$name/app/   (the starter works as it is)
  3. Your SLO:       charts/$name/slo.yaml, then: golden-path/slo/generate.sh charts/$name
  4. Your runbook:   services/$name/runbooks/slo-burn.md
  5. Deploy:         push to main. The first time, run its workflow by hand with the label first-deploy.
EOF
