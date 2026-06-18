#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RPMDIR="$ROOT/packaging/rpm"
VER="$(node -p "require('$ROOT/packages/opencode/package.json').version")"
chmod 0755 "$RPMDIR/files/opencode.wrapper"
PYVER="$(cat "$RPMDIR/payload/opencode-lsp-python/opt/opencode/lsp/python/.pyright-version" 2>/dev/null || echo "")"
mkdir -p "$RPMDIR/out"
IMAGE="registry.access.redhat.com/ubi9/ubi:latest"
docker run --rm -v "$RPMDIR":/work -w /work -e VER="$VER" -e PYVER="$PYVER" "$IMAGE" bash -c '
  set -euo pipefail
  rpmbuild --version >/dev/null 2>&1 || dnf -y install rpm-build >/dev/null
  TOP=/tmp/top; rm -rf $TOP; mkdir -p $TOP/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  cp -a /work/payload /work/config /work/files $TOP/SOURCES/
  rpmbuild --define "_topdir $TOP" --define "ver $VER" --define "_sourcedir $TOP/SOURCES" -bb /work/opencode.spec
  if [ -n "$PYVER" ] && [ -d /work/payload/opencode-lsp-python ]; then
    rpmbuild --define "_topdir $TOP" --define "pyrightver $PYVER" --define "_sourcedir $TOP/SOURCES" -bb /work/opencode-lsp-python.spec
  fi
  cp $TOP/RPMS/x86_64/*.rpm /work/out/
'
ls -1 "$RPMDIR/out/"
