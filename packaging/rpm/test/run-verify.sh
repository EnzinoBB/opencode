#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RPMDIR="$ROOT/packaging/rpm"
declare -A BASES=(
  [ubi9]="registry.access.redhat.com/ubi9/ubi:latest"
  [ubi8]="registry.access.redhat.com/ubi8/ubi:latest"
)
for tag in ubi9 ubi8; do
  echo "=== building verifier image ($tag) ==="
  docker build --build-arg BASE="${BASES[$tag]}" \
    -f "$RPMDIR/test/Dockerfile.verify" -t "oc-verify:$tag" "$RPMDIR"
  echo "=== running OFFLINE ($tag, --network=none) ==="
  docker run --rm --network=none "oc-verify:$tag"
done
echo "ALL OFFLINE VERIFICATIONS PASSED"
