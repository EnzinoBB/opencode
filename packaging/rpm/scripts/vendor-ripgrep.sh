#!/usr/bin/env bash
set -euo pipefail
# Runs on the CONNECTED build host.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
VER="15.1.0"
PLAT="x86_64-unknown-linux-musl"
ASSET="ripgrep-${VER}-${PLAT}.tar.gz"
# Pinned SHA-256 of the upstream asset (bump VER and SHA256 together — never silently).
SHA256="1c9297be4a084eea7ecaedf93eb03d058d6faae29bbc57ecdaf5063921491599"
URL="https://github.com/BurntSushi/ripgrep/releases/download/${VER}/${ASSET}"
DEST="$ROOT/packaging/rpm/payload/opencode/opt/opencode/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/$ASSET"
echo "${SHA256}  ${TMP}/${ASSET}" | sha256sum -c -   # abort on integrity mismatch
tar -xzf "$TMP/$ASSET" -C "$TMP"
mkdir -p "$DEST"
cp "$TMP/ripgrep-${VER}-${PLAT}/rg" "$DEST/rg"
chmod 0755 "$DEST/rg"
"$DEST/rg" --version | head -1
