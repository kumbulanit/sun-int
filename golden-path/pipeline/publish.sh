#!/usr/bin/env bash
# Build an image for Intel/AMD and Apple-silicon machines and publish it as <version> (its chart's
# appVersion). A version that's already published is never overwritten, so a version always
# means the same code. Each build is also tagged sha-<commit>, for tracing.
# Needs `docker login` to the registry and docker buildx (the pipeline sets both up).
#
#   golden-path/pipeline/publish.sh <image> <version> <build folder> [Dockerfile stage]
#   e.g. publish.sh ghcr.io/me/payments 0.1.0 services/payments
set -euo pipefail
image=${1:?usage: publish.sh <image> <version> <build folder> [stage]}
version=${2:?}; folder=${3:?}; stage=${4:-}

if docker manifest inspect "$image:$version" >/dev/null 2>&1; then
  echo "::notice::$image:$version is already published, so it's left as it is. Changed the code? Bump appVersion in the chart."
  exit 0
fi
docker buildx build --platform linux/amd64,linux/arm64 ${stage:+--target "$stage"} \
  --label "org.opencontainers.image.source=${SOURCE_URL:-}" \
  -t "$image:$version" -t "$image:sha-${GITHUB_SHA:-local}" --push "$folder"
echo "published $image:$version"
