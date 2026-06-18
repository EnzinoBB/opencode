#!/usr/bin/env bash
set -euo pipefail
# Runs INSIDE the container (already offline). RPMs are mounted at /rpms.
# python3 is preinstalled in the image build step (the only online step).
rpm -i --nodeps /rpms/opencode-[0-9]*.rpm
rpm -i --nodeps /rpms/opencode-lsp-python-*.rpm
test -f /etc/opencode/opencode.json
echo "=== generated config ==="; cat /etc/opencode/opencode.json
command -v opencode
opencode --version
echo "=== node version ===" ; node --version
# pyright-langserver is at /opt/opencode/bin/pyright-langserver (added to PATH by opencode wrapper)
test -x /opt/opencode/bin/pyright-langserver
# use pyright CLI (same package) to confirm node + pyright work without downloads
/opt/opencode/lsp/python/node_modules/.bin/pyright --version
/opt/opencode/bin/rg --version | head -1
echo "OFFLINE VERIFY OK"
