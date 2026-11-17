#!/usr/bin/env bash
# Start a new service on the golden path. Creates, ready to deploy:
#   services/<name>/                 a starter app (Python, FastAPI, telemetry wired in) and its
#                                    Dockerfile. Replace it with your own code; keep /healthz,
#                                    /readyz and the telemetry launcher.
#   services/<name>/runbooks/        the runbook its alerts link to (from golden-path/runbook/TEMPLATE.md)
#   charts/<name>/                   its chart: the golden path in one line, its values, its SLO
#   .github/workflows/<name>.yml     its pipeline: the golden-path workflow
#
# Usage: golden-path/new-service.sh <name> --team <team> [--registry ghcr.io/<owner>]
#   The registry defaults to ghcr.io/<owner of this repository on GitHub>.
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }

name=${1:-}; [ $# -gt 0 ] && shift
team=""; registry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) team=${2:-}; shift 2 ;;
    --registry) registry=${2:-}; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
valid='^[a-z][a-z0-9-]{0,38}[a-z0-9]$'   # a Kubernetes name: lower case, digits and dashes
[[ $name =~ $valid ]] || die "usage: golden-path/new-service.sh <name> --team <team>   (name: lower case, digits, dashes)"
[[ $team =~ $valid ]] || die "--team is required: the owning team, lower case, e.g. checkout"
[ ! -e "charts/$name" ] && [ ! -e "services/$name" ] || die "charts/$name or services/$name already exists"
if [ -z "$registry" ]; then
  owner=$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+)/.*#\1#p' | tr '[:upper:]' '[:lower:]')
  [ -n "$owner" ] || die "can't tell the registry from the git remote: pass --registry ghcr.io/<owner>"
  registry="ghcr.io/$owner"
fi

# Copy the template, filling in the name, team and registry.
template=golden-path/new-service
(cd "$template" && find . -type f) | sort | while read -r file; do
  dest=${file#./}; dest=${dest//__SERVICE__/$name}
  mkdir -p "$(dirname "$dest")"
  sed -e "s/__SERVICE__/$name/g" -e "s/__TEAM__/$team/g" -e "s|__REGISTRY__|$registry|g" "$template/$file" > "$dest"
  echo "created $dest"
done
mkdir -p "services/$name/runbooks"
sed -e "s/<service>/$name/g" -e "s/<one failure>/the SLO is burning/" golden-path/runbook/TEMPLATE.md > "services/$name/runbooks/slo-burn.md"
echo "created services/$name/runbooks/slo-burn.md"

# Its SLO alerts, from the starter slo.yaml.
golden-path/slo/generate.sh "charts/$name"

cat <<EOF

$name is on the golden path. Next:
  1. Put your code in services/$name/ (or keep the starter to try the path first).
  2. Set the SLO in charts/$name/slo.yaml, then: golden-path/slo/generate.sh charts/$name
  3. Fill in services/$name/runbooks/slo-burn.md.
  4. Push: .github/workflows/$name.yml checks, builds, publishes and deploys it.
     Or install it yourself (needs the platform: see golden-path/README.md):
       helm install $name charts/$name --dependency-update -n $name --create-namespace --wait
EOF
