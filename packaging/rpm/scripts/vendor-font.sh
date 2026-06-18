#!/usr/bin/env bash
set -euo pipefail
# Runs on the CONNECTED build host. Bundles a Nerd Font (DejaVuSansMono Nerd Font,
# "Mono" variant — single-cell-width icons, ideal for a terminal grid) into the RPM
# payload so air-gapped machines have the glyphs opencode's TUI uses. Nothing is
# downloaded on the target.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
NF_VER="${NF_VER:-3.2.1}"
ASSET="DejaVuSansMono.tar.xz"
# Pinned SHA-256 of the upstream asset (bump NF_VER and SHA256 together — never silently).
SHA256="b94bde4d2e9ceb1f2c19b2846c1a9892797e4e15e9594303eb7088534244a18b"
URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v${NF_VER}/${ASSET}"
DEST="$ROOT/packaging/rpm/payload/opencode/usr/share/fonts/opencode-nerd"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/$ASSET"
echo "${SHA256}  ${TMP}/${ASSET}" | sha256sum -c -   # abort on integrity mismatch
tar -xJf "$TMP/$ASSET" -C "$TMP"
rm -rf "$DEST"; mkdir -p "$DEST"
# Ship the single-width "Mono" family (Regular/Bold/Oblique/BoldOblique).
cp "$TMP"/DejaVuSansMNerdFontMono-*.ttf "$DEST/"
chmod 0644 "$DEST"/*.ttf
echo "vendored Nerd Font $NF_VER -> $(ls "$DEST" | wc -l) ttf ($(du -sh "$DEST" | cut -f1))"
ls -1 "$DEST"
