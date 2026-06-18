#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.bun/bin:$PATH"   # bun is installed here, not on default PATH
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/packaging/rpm/payload/opencode/opt/opencode/libexec"
mkdir -p "$DEST"
bun build "$ROOT/packaging/rpm/tools/rebuild-config.ts" \
  --compile --target=bun-linux-x64-baseline \
  --outfile "$DEST/oc-rebuild-config"
chmod 0755 "$DEST/oc-rebuild-config"
echo "staged oc-rebuild-config -> $DEST/oc-rebuild-config"
