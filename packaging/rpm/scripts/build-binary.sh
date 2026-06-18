#!/usr/bin/env bash
set -euo pipefail
# Builds the single air-gapped target and stages it into the RPM payload.
# Must run on a CONNECTED host (Bun downloads cross-compile artifacts here).
export PATH="$HOME/.bun/bin:$PATH"   # bun is installed here, not on default PATH
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TARGET="opencode-linux-x64-baseline-musl"
cd "$ROOT/packages/opencode"
bun run script/build.ts --targets="$TARGET"
BIN="$ROOT/packages/opencode/dist/$TARGET/bin/opencode"
test -x "$BIN" || { echo "build failed: $BIN missing"; exit 1; }
DEST="$ROOT/packaging/rpm/payload/opencode/opt/opencode"
mkdir -p "$DEST/libexec"
cp "$BIN" "$DEST/libexec/opencode"
chmod 0755 "$DEST/libexec/opencode"
echo "staged binary -> $DEST/libexec/opencode"
"$DEST/libexec/opencode" --version
