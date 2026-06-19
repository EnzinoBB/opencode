# Air-gapped opencode RPMs

This directory contains everything needed to build, package, and verify offline-capable
RPM packages for opencode on RHEL/UBI targets.

## Prerequisites (connected build host)

The build host needs the following tools installed:

- **bun** — installed at `$HOME/.bun/bin` (scripts export this onto PATH automatically)
- **python3 + pip** — for vendoring the pure-Python python-lsp-server tree
- **docker** — rpmbuild and all RPM/verify steps run inside UBI containers; host `rpmbuild` is NOT required
- **curl** — used by vendor scripts to download upstream release archives
- **tar** — used to extract downloaded archives

No special system packages (e.g., `rpm-build`) are required on the build host itself;
all RPM construction happens inside a `registry.access.redhat.com/ubi9/ubi:latest` container.

## Build (connected host)

    ./packaging/rpm/scripts/build-all.sh

This runs the full pipeline in order:

1. `build-binary.sh` — bundles the opencode CLI binary
2. `build-tools.sh` — compiles the `oc-rebuild-config` config-merge tool
3. `vendor-ripgrep.sh` — downloads and stages the ripgrep binary
4. `vendor-font.sh` — downloads and stages a Nerd Font (DejaVuSansMono Nerd Font, Mono)
5. `vendor-pylsp.sh` — vendors python-lsp-server as a pure-Python `site/` tree (no node)
6. `build-rpm.sh` — runs `rpmbuild` inside a UBI9 container, producing both RPMs

Artifacts land in `packaging/rpm/out/`:

- `opencode-<ver>-1.<dist>.x86_64.rpm` — core opencode package
- `opencode-lsp-python-<ver>-1.<dist>.x86_64.rpm` — Python LSP (python-lsp-server) extension pack

## Verify offline (connected host, before shipping)

    ./packaging/rpm/test/run-verify.sh

Builds UBI8 + UBI9 verifier images (online step: installs runtime deps from Red Hat CDN),
then runs each image with `--network=none` to prove the RPMs are fully self-contained.

Both images must print `OFFLINE VERIFY OK` and the script ends with:

    ALL OFFLINE VERIFICATIONS PASSED

The `--network=none` flag is hardcoded in `run-verify.sh` so the air-gap guarantee is
reproducible and not dependent on a remembered flag.

## Install (target, offline)

    sudo dnf install ./opencode-<ver>.x86_64.rpm
    sudo dnf install ./opencode-lsp-python-<ver>.x86_64.rpm   # requires python3 (>= 3.9) only — no nodejs

Edit `/etc/opencode/ollama.conf` (host/port/model), then regenerate the runtime config:

    sudo opencode-update-config

`opencode-update-config` auto-discovers everything under `/etc/opencode`: it merges all
`*.json` fragments in `/etc/opencode/conf.d/` with the Ollama endpoint settings from
`ollama.conf` and writes `/etc/opencode/opencode.json`. (It is a thin wrapper over
`/opt/opencode/libexec/oc-rebuild-config`; the base dir can be overridden with
`OPENCODE_ETC`.) The RPM `%post` runs the same regeneration automatically on
install/upgrade — run the command by hand only after editing `ollama.conf` or a fragment.

### Terminal font (TUI icons)

The core RPM bundles **DejaVuSansMono Nerd Font** into `/usr/share/fonts/opencode-nerd/`
and refreshes the font cache in `%post`. opencode's TUI uses Nerd Font icon glyphs; a
terminal whose font lacks them shows corrupted characters. After install, set your
terminal's font to **"DejaVuSansM Nerd Font Mono"** once (e.g. xfce4-terminal →
Preferences → Appearance → uncheck "Use system font" → select it). opencode cannot set
the terminal's font itself — that is a terminal-emulator preference.

## Adding a language (future)

Replicate the Python pilot: a `vendor-<lang>.sh`, a `opencode-lsp-<lang>.spec`
(with the right `Requires:`), and a `config/NN-<lang>.json` fragment. No core change.

The pattern is:

1. `packaging/rpm/scripts/vendor-<lang>.sh` — downloads/stages the LSP server offline payload
2. `packaging/rpm/opencode-lsp-<lang>.spec` — RPM spec with `Requires: opencode` and any runtime deps
3. `packaging/rpm/config/NN-<lang>.json` — JSON fragment enabling the language server in opencode's config
4. Add `"$D/vendor-<lang>.sh"` to `build-all.sh` before the `build-rpm.sh` call

The offline guarantee is enforced by the same `run-verify.sh` verifier — extend
`verify-offline.sh` to test the new language server binary.
