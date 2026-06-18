#!/usr/bin/env bash
set -euo pipefail
# Runs INSIDE the container (already offline). RPMs are mounted at /rpms.
# python3 is preinstalled in the image build step (the only online step). No nodejs.
rpm -i --nodeps /rpms/opencode-[0-9]*.rpm
rpm -i --nodeps /rpms/opencode-lsp-python-*.rpm
test -f /etc/opencode/opencode.json
echo "=== generated config ==="; cat /etc/opencode/opencode.json
command -v opencode
opencode --version
echo "=== python (used by pylsp wrapper) ===" ; python3.9 --version
# python-lsp-server is bundled (pure Python) and launched via /opt/opencode/bin/pylsp.
test -x /opt/opencode/bin/pylsp
# Confirm pylsp starts from the bundled tree with no network and no node.
/opt/opencode/bin/pylsp --help | head -1
# Ensure NO node runtime is required anywhere.
if command -v node >/dev/null 2>&1; then echo "WARN: node present (not required)"; else echo "confirmed: no node on system"; fi
/opt/opencode/bin/rg --version | head -1
# Bundled Nerd Font present and registered with fontconfig (offline fc-cache in %post).
test -n "$(ls /usr/share/fonts/opencode-nerd/*.ttf 2>/dev/null)"
fc-list | grep -i "DejaVuSansM Nerd Font" | head -1
echo "OFFLINE VERIFY OK"
