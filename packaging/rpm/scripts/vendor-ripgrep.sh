#!/usr/bin/env bash
set -euo pipefail
# Runs on the CONNECTED build host.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
VER="15.1.0"
PLAT="x86_64-unknown-linux-musl"
ASSET="ripgrep-${VER}-${PLAT}.tar.gz"
URL="https://github.com/BurntSushi/ripgrep/releases/download/${VER}/${ASSET}"
DEST="$ROOT/packaging/rpm/payload/opencode/opt/opencode/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/$ASSET"
tar -xzf "$TMP/$ASSET" -C "$TMP"
mkdir -p "$DEST"
cp "$TMP/ripgrep-${VER}-${PLAT}/rg" "$DEST/rg"
chmod 0755 "$DEST/rg"
"$DEST/rg" --version | head -1
