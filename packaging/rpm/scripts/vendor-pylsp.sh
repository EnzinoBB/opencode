#!/usr/bin/env bash
set -euo pipefail
# Runs on the CONNECTED build host. Bundles python-lsp-server (pylsp) as a PURE-PYTHON,
# version-portable site/ tree (no compiled .so), installed offline at BUILD time and
# shipped whole inside the RPM. Nothing is downloaded on the target machine.
#
# We force universal (py3-none-any) wheels and pull only the pure-python core deps,
# skipping the optional COMPILED deps:
#   - ujson  -> python-lsp-jsonrpc falls back to stdlib json (pylsp_jsonrpc/streams.py)
#   - black  -> optional formatter plugin; pylsp starts fine without it (jedi provides
#               completion/diagnostics/hover/go-to-def, which is the LSP's core value)
# Keeping the tree pure-python is what lets ONE artifact run on both RHEL 8 and RHEL 9
# regardless of their python minor version.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PYLSP_VER="${PYLSP_VER:-1.14.0}"
DEST="$ROOT/packaging/rpm/payload/opencode-lsp-python/opt/opencode/lsp/python"
SITE="$DEST/site"
PY="${PYTHON:-python3}"
rm -rf "$DEST"; mkdir -p "$SITE"
"$PY" -m pip install --target="$SITE" --no-deps --no-cache-dir \
  --only-binary=:all: --platform any --abi none --implementation py --python-version 39 \
  "python-lsp-server==${PYLSP_VER}" jedi parso pluggy python-lsp-jsonrpc \
  docstring-to-markdown importlib_metadata zipp typing_extensions
# Portability guard: the tree MUST contain no compiled extensions.
if find "$SITE" -name "*.so" | grep -q .; then
  echo "ERROR: compiled .so found in pylsp tree — not portable across python versions" >&2
  find "$SITE" -name "*.so" >&2; exit 1
fi
echo "$PYLSP_VER" > "$DEST/.pylsp-version"
echo "vendored python-lsp-server $PYLSP_VER (pure-python, $(du -sh "$SITE" | cut -f1))"
