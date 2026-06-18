#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.bun/bin:$PATH"   # bun is installed here, not on default PATH
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
D="$ROOT/packaging/rpm/scripts"
"$D/build-binary.sh"
"$D/build-tools.sh"
"$D/vendor-ripgrep.sh"
"$D/vendor-font.sh"
"$D/vendor-pylsp.sh"
"$D/build-rpm.sh"   # runs rpmbuild inside a UBI9 container; builds core + python
echo "All RPMs in packaging/rpm/out/:"; ls -1 "$ROOT/packaging/rpm/out/"
