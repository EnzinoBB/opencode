#!/usr/bin/env bash
set -euo pipefail
# Runs on the CONNECTED build host. Pins pyright; bundles full node_modules.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PYRIGHT_VER="${PYRIGHT_VER:-1.1.405}"
DEST="$ROOT/packaging/rpm/payload/opencode-lsp-python/opt/opencode/lsp/python"
rm -rf "$DEST"; mkdir -p "$DEST"
cd "$DEST"
npm init -y >/dev/null
npm install --no-audit --no-fund "pyright@${PYRIGHT_VER}"
test -x "$DEST/node_modules/.bin/pyright-langserver"
echo "$PYRIGHT_VER" > "$DEST/.pyright-version"
echo "vendored pyright $PYRIGHT_VER"
