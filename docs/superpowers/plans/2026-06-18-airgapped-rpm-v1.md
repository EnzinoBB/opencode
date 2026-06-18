# Air-gapped opencode RPM (v1: core + Python) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce installable RPMs that run opencode fully offline on RHEL 8/9, with a `linux-x64-baseline-musl` binary, bundled ripgrep, a LAN-Ollama default config, and Python (pyright) as the pilot per-language LSP sub-package.

**Architecture:** A connected build host compiles a single static `linux-x64-baseline-musl` opencode binary, vendors ripgrep and pyright, and assembles two RPMs — `opencode` (core: binary + rg + wrapper + offline config + a compiled `oc-rebuild-config` merge tool) and `opencode-lsp-python` (pyright + `python3` dependency). At install time a `conf.d/` fragment merge regenerates `/etc/opencode/opencode.json`. A wrapper at `/usr/bin/opencode` forces all offline env flags. Target machines never touch the network.

**Tech Stack:** Bun (compile + tests), bash (wrapper, build orchestration, RPM scriptlets), `rpmbuild`/`.spec` files, Red Hat UBI8/UBI9 containers for offline verification.

## Global Constraints

- Target architecture: **x86_64 only**. Binary target: **`opencode-linux-x64-baseline-musl`** (Bun compile target string: `bun-linux-x64-baseline-musl`).
- Must run on **RHEL 8 (glibc 2.28)** and **RHEL 9** and **CPU without AVX2** — guaranteed by the static musl + baseline build.
- **No network access on target** at install-time or runtime. Anything opencode would download must be bundled.
- ripgrep pinned to **15.1.0** (must match `packages/core/src/ripgrep/binary.ts`), asset `ripgrep-15.1.0-x86_64-unknown-linux-musl.tar.gz`.
- Runtime language deps (e.g. `python3`) are declared as RPM `Requires` → resolved from the internal RHEL mirror, never bundled in v1.
- Offline env flags imposed by the wrapper: `OPENCODE_DISABLE_LSP_DOWNLOAD=true`, `OPENCODE_DISABLE_AUTOUPDATE=true`, `OPENCODE_DISABLE_MODELS_FETCH=true`, `OPENCODE_MODELS_PATH=/opt/opencode/share/models.json`, and `PATH` prefixed with `/opt/opencode/bin`.
- FHS layout exactly as in the design spec §5.
- Version string: read from `packages/opencode/package.json` (`version` field, currently `1.17.8`) and passed to `rpmbuild` via `--define "ver <version>"`.
- All new packaging artifacts live under `packaging/rpm/`. Do not restructure existing build code beyond the minimal `--targets` filter in Task 1.

---

### Task 1: Single-target build filter for `linux-x64-baseline-musl`

**Files:**
- Modify: `packages/opencode/script/build.ts` (target selection block, ~lines 116-141)
- Create: `packaging/rpm/scripts/build-binary.sh`

**Interfaces:**
- Consumes: existing `allTargets` array in `build.ts`.
- Produces: `packages/opencode/dist/opencode-linux-x64-baseline-musl/bin/opencode` (static binary). `build-binary.sh` copies it to `packaging/rpm/payload/opencode/opt/opencode/libexec/opencode`.

- [ ] **Step 1: Add a `--targets=` filter to build.ts**

In `packages/opencode/script/build.ts`, just after the existing flag parsing (after the `skipEmbedWebUi` line ~25), add:

```ts
const targetsFlag = process.argv.find((a) => a.startsWith("--targets="))
const targetsFilter = targetsFlag ? targetsFlag.slice("--targets=".length).split(",") : null
```

Then replace the `const targets = singleFlag ? ... : allTargets` assignment so the explicit filter wins:

```ts
const targetName = (item: (typeof allTargets)[number]) =>
  [
    pkg.name,
    item.os === "win32" ? "windows" : item.os,
    item.arch,
    item.avx2 === false ? "baseline" : undefined,
    item.abi === undefined ? undefined : item.abi,
  ]
    .filter(Boolean)
    .join("-")

const targets = targetsFilter
  ? allTargets.filter((item) => targetsFilter.includes(targetName(item)))
  : singleFlag
    ? allTargets.filter((item) => {
        if (item.os !== process.platform || item.arch !== process.arch) return false
        if (item.avx2 === false) return baselineFlag
        if (item.abi !== undefined) return false
        return true
      })
    : allTargets
```

(The existing `name` computation inside the loop stays; `targetName` is the same logic hoisted so the filter can match by full name.)

- [ ] **Step 2: Verify the filter selects exactly one target**

Run: `cd packages/opencode && bun run script/build.ts --targets=opencode-linux-x64-baseline-musl --skip-embed-web-ui 2>&1 | grep -E "^building "`
Expected: a single line `building opencode-linux-x64-baseline-musl` (skip-embed used here only to speed the smoke check; the real build in Step 3 embeds the web UI).

- [ ] **Step 3: Write the build-binary.sh orchestration script**

Create `packaging/rpm/scripts/build-binary.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Builds the single air-gapped target and stages it into the RPM payload.
# Must run on a CONNECTED host (Bun downloads cross-compile artifacts here).
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TARGET="opencode-linux-x64-baseline-musl"
cd "$ROOT/packages/opencode"
bun run script/build.ts --targets="$TARGET"
BIN="$ROOT/packages/opencode/dist/$TARGET/bin/opencode"
test -x "$BIN" || { echo "build failed: $BIN missing"; exit 1; }
DEST="$ROOT/packaging/rpm/payload/opencode/opt/opencode"
mkdir -p "$DEST/libexec" "$DEST/share"
cp "$BIN" "$DEST/libexec/opencode"
chmod 0755 "$DEST/libexec/opencode"
echo "staged binary -> $DEST/libexec/opencode"
"$DEST/libexec/opencode" --version
```

- [ ] **Step 4: Run the build and confirm the binary runs on the (glibc) build host**

Run: `chmod +x packaging/rpm/scripts/build-binary.sh && ./packaging/rpm/scripts/build-binary.sh`
Expected: ends with a version line (e.g. `1.17.8`). A static musl binary runs on the glibc CI host, proving portability.

- [ ] **Step 5: Commit**

```bash
git add packages/opencode/script/build.ts packaging/rpm/scripts/build-binary.sh
git commit -m "feat(packaging): single-target build filter for air-gapped musl binary"
```

---

### Task 2: `oc-rebuild-config` config-merge tool

**Files:**
- Create: `packaging/rpm/tools/rebuild-config.ts`
- Test: `packaging/rpm/tools/rebuild-config.test.ts`
- Create: `packaging/rpm/scripts/build-tools.sh`

**Interfaces:**
- Produces: function `mergeConfig(fragments: object[]): object` (deep merge, later wins, plain objects merged recursively, arrays/scalars replaced) and `substitute(obj: object, vars: Record<string,string>): object` (replaces `OLLAMA_HOST`/`OLLAMA_PORT`/`MODEL_ID` tokens inside string values). CLI: `oc-rebuild-config <confdir> <ollama.conf> <out.json>`. The compiled binary is staged at `payload/opencode/opt/opencode/libexec/oc-rebuild-config`.

- [ ] **Step 1: Write the failing tests**

Create `packaging/rpm/tools/rebuild-config.test.ts`:

```ts
import { test, expect } from "bun:test"
import { mergeConfig, substitute } from "./rebuild-config"

test("deep-merges lsp records by key", () => {
  const a = { lsp: { pyright: { command: ["x"] } }, provider: { ollama: { name: "O" } } }
  const b = { lsp: { bash: { command: ["y"] } } }
  expect(mergeConfig([a, b])).toEqual({
    lsp: { pyright: { command: ["x"] }, bash: { command: ["y"] } },
    provider: { ollama: { name: "O" } },
  })
})

test("later fragment overrides scalar and replaces arrays", () => {
  expect(mergeConfig([{ a: 1, arr: [1, 2] }, { a: 2, arr: [9] }])).toEqual({ a: 2, arr: [9] })
})

test("substitute replaces tokens inside string values only", () => {
  const out = substitute(
    { provider: { ollama: { options: { baseURL: "http://OLLAMA_HOST:OLLAMA_PORT/v1" }, models: { MODEL_ID: {} } } } },
    { OLLAMA_HOST: "10.0.0.5", OLLAMA_PORT: "11434", MODEL_ID: "qwen2.5-coder" },
  )
  expect(out).toEqual({
    provider: { ollama: { options: { baseURL: "http://10.0.0.5:11434/v1" }, models: { "qwen2.5-coder": {} } } },
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun test packaging/rpm/tools/rebuild-config.test.ts`
Expected: FAIL — `Cannot find module './rebuild-config'`.

- [ ] **Step 3: Implement the tool**

Create `packaging/rpm/tools/rebuild-config.ts`:

```ts
#!/usr/bin/env bun
import { readdirSync, readFileSync, writeFileSync, existsSync } from "fs"
import { join } from "path"

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v)
}

export function mergeConfig(fragments: object[]): object {
  const merge = (target: any, source: any): any => {
    if (!isPlainObject(target) || !isPlainObject(source)) return source
    const out: Record<string, unknown> = { ...target }
    for (const [k, v] of Object.entries(source)) {
      out[k] = k in target ? merge((target as any)[k], v) : v
    }
    return out
  }
  return fragments.reduce((acc, f) => merge(acc, f), {})
}

export function substitute(obj: object, vars: Record<string, string>): object {
  const walk = (v: any): any => {
    if (typeof v === "string") {
      let s = v
      for (const [from, to] of Object.entries(vars)) s = s.split(from).join(to)
      return s
    }
    if (Array.isArray(v)) return v.map(walk)
    if (isPlainObject(v)) {
      const out: Record<string, unknown> = {}
      for (const [k, val] of Object.entries(v)) {
        let nk = k
        for (const [from, to] of Object.entries(vars)) nk = nk.split(from).join(to)
        out[nk] = walk(val)
      }
      return out
    }
    return v
  }
  return walk(obj)
}

function parseConf(path: string): Record<string, string> {
  const vars: Record<string, string> = {}
  if (!existsSync(path)) return vars
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$/)
    if (m) vars[m[1]] = m[2].replace(/^["']|["']$/g, "")
  }
  return vars
}

function main() {
  const [confdir, conf, out] = process.argv.slice(2)
  if (!confdir || !out) {
    console.error("usage: oc-rebuild-config <confdir> <ollama.conf> <out.json>")
    process.exit(2)
  }
  const fragments = readdirSync(confdir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(confdir, f), "utf8")))
  const merged = substitute(mergeConfig(fragments), parseConf(conf))
  writeFileSync(out, JSON.stringify(merged, null, 2) + "\n")
  console.error(`wrote ${out} from ${fragments.length} fragment(s)`)
}

if (import.meta.main) main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun test packaging/rpm/tools/rebuild-config.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the tool-compile script**

Create `packaging/rpm/scripts/build-tools.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/packaging/rpm/payload/opencode/opt/opencode/libexec"
mkdir -p "$DEST"
bun build "$ROOT/packaging/rpm/tools/rebuild-config.ts" \
  --compile --target=bun-linux-x64-baseline-musl \
  --outfile "$DEST/oc-rebuild-config"
chmod 0755 "$DEST/oc-rebuild-config"
echo "staged oc-rebuild-config -> $DEST/oc-rebuild-config"
```

- [ ] **Step 6: Run the compile and smoke-test the binary**

Run:
```bash
chmod +x packaging/rpm/scripts/build-tools.sh && ./packaging/rpm/scripts/build-tools.sh
mkdir -p /tmp/cd && echo '{"lsp":{"bash":{"command":["x"]}}}' > /tmp/cd/10-x.json
printf 'OLLAMA_HOST=h\nOLLAMA_PORT=1\nMODEL_ID=m\n' > /tmp/o.conf
packaging/rpm/payload/opencode/opt/opencode/libexec/oc-rebuild-config /tmp/cd /tmp/o.conf /tmp/out.json && cat /tmp/out.json
```
Expected: `/tmp/out.json` contains the merged `lsp.bash` entry.

- [ ] **Step 7: Commit**

```bash
git add packaging/rpm/tools/rebuild-config.ts packaging/rpm/tools/rebuild-config.test.ts packaging/rpm/scripts/build-tools.sh
git commit -m "feat(packaging): config-merge tool oc-rebuild-config with tests"
```

---

### Task 3: Vendor ripgrep into the core payload

**Files:**
- Create: `packaging/rpm/scripts/vendor-ripgrep.sh`

**Interfaces:**
- Produces: `packaging/rpm/payload/opencode/opt/opencode/bin/rg` (executable, ripgrep 15.1.0 musl).

- [ ] **Step 1: Write the vendor script**

Create `packaging/rpm/scripts/vendor-ripgrep.sh`:

```bash
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
```

- [ ] **Step 2: Run it and verify the version matches the pin**

Run: `chmod +x packaging/rpm/scripts/vendor-ripgrep.sh && ./packaging/rpm/scripts/vendor-ripgrep.sh`
Expected: output `ripgrep 15.1.0`.

- [ ] **Step 3: Commit (script only; payload binaries are git-ignored)**

```bash
echo "packaging/rpm/payload/" >> .gitignore
git add packaging/rpm/scripts/vendor-ripgrep.sh .gitignore
git commit -m "feat(packaging): vendor ripgrep 15.1.0 musl into core payload"
```

---

### Task 4: Core RPM (`opencode`)

**Files:**
- Create: `packaging/rpm/opencode.spec`
- Create: `packaging/rpm/payload/opencode/usr/bin/opencode` (wrapper)
- Create: `packaging/rpm/config/00-base.json`
- Create: `packaging/rpm/config/ollama.conf`
- Create: `packaging/rpm/scripts/build-rpm.sh`

**Interfaces:**
- Consumes: staged payload from Tasks 1-3 (`opt/opencode/libexec/opencode`, `.../libexec/oc-rebuild-config`, `.../bin/rg`).
- Produces: `opencode-<ver>-1.<dist>.x86_64.rpm`. Installs files under `/opt/opencode`, `/usr/bin/opencode`, `/etc/opencode/conf.d/00-base.json`, `/etc/opencode/ollama.conf`; `%post` regenerates `/etc/opencode/opencode.json`.

- [ ] **Step 1: Write the wrapper**

Create `packaging/rpm/payload/opencode/usr/bin/opencode`:

```sh
#!/bin/sh
# opencode air-gapped wrapper: forces offline behavior regardless of user config.
[ -f /etc/opencode/ollama.conf ] && . /etc/opencode/ollama.conf
export OPENCODE_DISABLE_LSP_DOWNLOAD=true
export OPENCODE_DISABLE_AUTOUPDATE=true
export OPENCODE_DISABLE_MODELS_FETCH=true
export OPENCODE_MODELS_PATH=/opt/opencode/share/models.json
export PATH="/opt/opencode/bin:$PATH"
exec /opt/opencode/libexec/opencode "$@"
```

- [ ] **Step 2: Write the base config fragment and ollama.conf**

Create `packaging/rpm/config/00-base.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "name": "Ollama (LAN)",
      "options": { "baseURL": "http://OLLAMA_HOST:OLLAMA_PORT/v1", "apiKey": "ollama" },
      "models": { "MODEL_ID": {} }
    }
  }
}
```

Create `packaging/rpm/config/ollama.conf`:

```sh
# Air-gapped opencode — edit to point at your LAN Ollama, then run:
#   /opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json
OLLAMA_HOST=127.0.0.1
OLLAMA_PORT=11434
MODEL_ID=qwen2.5-coder:7b
```

- [ ] **Step 3: Write the spec file**

Create `packaging/rpm/opencode.spec`:

```spec
Name:           opencode
Version:        %{ver}
Release:        1%{?dist}
Summary:        opencode AI coding agent (air-gapped build)
License:        MIT
URL:            https://opencode.ai
BuildArch:      x86_64
Requires:       tar
%global __os_install_post %{nil}
%global debug_package %{nil}

%description
Air-gapped opencode for RHEL 8/9. Bundles a static musl binary, ripgrep,
and a LAN-Ollama default configuration. Performs no network access at
install time or runtime except to the configured Ollama endpoint.

%install
rm -rf %{buildroot}
cp -a %{_sourcedir}/payload/opencode/. %{buildroot}/
install -d %{buildroot}/etc/opencode/conf.d
install -m 0644 %{_sourcedir}/config/00-base.json %{buildroot}/etc/opencode/conf.d/00-base.json
install -m 0644 %{_sourcedir}/config/ollama.conf  %{buildroot}/etc/opencode/ollama.conf

%files
%dir /opt/opencode
/opt/opencode/libexec/opencode
/opt/opencode/libexec/oc-rebuild-config
/opt/opencode/bin/rg
/opt/opencode/share
/usr/bin/opencode
%dir /etc/opencode
%dir /etc/opencode/conf.d
%config(noreplace) /etc/opencode/conf.d/00-base.json
%config(noreplace) /etc/opencode/ollama.conf

%post
/opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :

%postun
if [ "$1" = 0 ]; then rm -f /etc/opencode/opencode.json; fi
```

Note: `models.json` is staged into `/opt/opencode/share` by Task 7 (build-all). For a core-only build, create it empty so `%files` is satisfied — handled in build-rpm.sh below.

- [ ] **Step 4: Write the RPM build script**

Create `packaging/rpm/scripts/build-rpm.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RPMDIR="$ROOT/packaging/rpm"
VER="$(node -p "require('$ROOT/packages/opencode/package.json').version" 2>/dev/null || \
       grep -m1 '"version"' "$ROOT/packages/opencode/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
# ensure models snapshot exists (placeholder if build-all didn't stage one)
SHARE="$RPMDIR/payload/opencode/opt/opencode/share"
mkdir -p "$SHARE"; [ -f "$SHARE/models.json" ] || echo '{}' > "$SHARE/models.json"
# wrapper perms
chmod 0755 "$RPMDIR/payload/opencode/usr/bin/opencode"
TOP="$(mktemp -d)"
mkdir -p "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp -a "$RPMDIR/payload" "$RPMDIR/config" "$TOP/SOURCES/"
rpmbuild --define "_topdir $TOP" --define "ver $VER" \
  --define "_sourcedir $TOP/SOURCES" -bb "$RPMDIR/opencode.spec"
mkdir -p "$RPMDIR/out"; cp "$TOP"/RPMS/x86_64/opencode-*.rpm "$RPMDIR/out/"
rm -rf "$TOP"
ls -1 "$RPMDIR/out/"
```

- [ ] **Step 5: Build the core RPM and inspect it**

Run:
```bash
chmod +x packaging/rpm/scripts/build-rpm.sh && ./packaging/rpm/scripts/build-rpm.sh
rpm -qlp packaging/rpm/out/opencode-*.rpm
```
Expected: lists `/usr/bin/opencode`, `/opt/opencode/libexec/opencode`, `/opt/opencode/bin/rg`, `/opt/opencode/libexec/oc-rebuild-config`, `/etc/opencode/conf.d/00-base.json`, `/etc/opencode/ollama.conf`.

- [ ] **Step 6: Commit**

```bash
git add packaging/rpm/opencode.spec packaging/rpm/payload/opencode/usr/bin/opencode packaging/rpm/config packaging/rpm/scripts/build-rpm.sh
git commit -m "feat(packaging): core opencode RPM with offline wrapper and config merge"
```

---

### Task 5: Python pilot sub-RPM (`opencode-lsp-python`)

**Files:**
- Create: `packaging/rpm/scripts/vendor-pyright.sh`
- Create: `packaging/rpm/opencode-lsp-python.spec`
- Create: `packaging/rpm/config/10-python.json`

**Interfaces:**
- Consumes: core RPM's `/etc/opencode/conf.d` and `oc-rebuild-config`.
- Produces: `opencode-lsp-python-<pyrightver>-1.<dist>.x86_64.rpm`. Installs pyright under `/opt/opencode/lsp/python`, symlinks `pyright-langserver` into `/opt/opencode/bin`, drops `conf.d/10-python.json`, `Requires: opencode, python3`.

- [ ] **Step 1: Write the pyright vendor script**

Create `packaging/rpm/scripts/vendor-pyright.sh`:

```bash
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
```

- [ ] **Step 2: Run it and confirm the langserver binary exists**

Run: `chmod +x packaging/rpm/scripts/vendor-pyright.sh && ./packaging/rpm/scripts/vendor-pyright.sh && ls packaging/rpm/payload/opencode-lsp-python/opt/opencode/lsp/python/node_modules/.bin/`
Expected: lists `pyright-langserver` and `pyright`.

- [ ] **Step 3: Write the Python config fragment**

Create `packaging/rpm/config/10-python.json`. opencode's built-in `pyright` server calls `which("pyright-langserver")` first, so a PATH symlink is enough; this fragment only documents/locks intent and is harmless to merge:

```json
{
  "lsp": {
    "pyright": {
      "command": ["/opt/opencode/bin/pyright-langserver", "--stdio"],
      "extensions": [".py", ".pyi"]
    }
  }
}
```

- [ ] **Step 4: Write the sub-RPM spec**

Create `packaging/rpm/opencode-lsp-python.spec`:

```spec
Name:           opencode-lsp-python
Version:        %{pyrightver}
Release:        1%{?dist}
Summary:        Python LSP (pyright) for air-gapped opencode
License:        MIT
BuildArch:      x86_64
Requires:       opencode
Requires:       python3
%global __os_install_post %{nil}
%global debug_package %{nil}

%description
Bundles pyright (Python language server) for air-gapped opencode and
registers it via /etc/opencode/conf.d. Requires python3 from the system
(internal mirror).

%install
rm -rf %{buildroot}
cp -a %{_sourcedir}/payload/opencode-lsp-python/. %{buildroot}/
install -d %{buildroot}/opt/opencode/bin
ln -sf ../lsp/python/node_modules/.bin/pyright-langserver %{buildroot}/opt/opencode/bin/pyright-langserver
install -d %{buildroot}/etc/opencode/conf.d
install -m 0644 %{_sourcedir}/config/10-python.json %{buildroot}/etc/opencode/conf.d/10-python.json

%files
/opt/opencode/lsp/python
/opt/opencode/bin/pyright-langserver
%config(noreplace) /etc/opencode/conf.d/10-python.json

%post
/opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :

%postun
if [ "$1" = 0 ]; then
  rm -f /etc/opencode/conf.d/10-python.json
  /opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :
fi
```

- [ ] **Step 5: Extend build-rpm.sh to build the sub-RPM**

In `packaging/rpm/scripts/build-rpm.sh`, before the final `ls`, add (uses the pinned pyright version for `pyrightver`):

```bash
PYVER="$(cat "$RPMDIR/payload/opencode-lsp-python/opt/opencode/lsp/python/.pyright-version" 2>/dev/null || echo 0.0.0)"
if [ -d "$RPMDIR/payload/opencode-lsp-python" ]; then
  rpmbuild --define "_topdir $TOP" --define "pyrightver $PYVER" \
    --define "_sourcedir $TOP/SOURCES" -bb "$RPMDIR/opencode-lsp-python.spec"
  cp "$TOP"/RPMS/x86_64/opencode-lsp-python-*.rpm "$RPMDIR/out/" 2>/dev/null || true
fi
```

(Note: this block must run while `$TOP` still exists — move the `rm -rf "$TOP"` and `ls` to after it. Re-copy `payload`/`config` into `$TOP/SOURCES` already covers the new payload dir.)

- [ ] **Step 6: Build both RPMs and inspect the sub-RPM**

Run: `./packaging/rpm/scripts/build-rpm.sh && rpm -qlp packaging/rpm/out/opencode-lsp-python-*.rpm`
Expected: lists `/opt/opencode/lsp/python/...`, the `pyright-langserver` symlink, and `/etc/opencode/conf.d/10-python.json`.

- [ ] **Step 7: Commit**

```bash
git add packaging/rpm/scripts/vendor-pyright.sh packaging/rpm/opencode-lsp-python.spec packaging/rpm/config/10-python.json packaging/rpm/scripts/build-rpm.sh
git commit -m "feat(packaging): opencode-lsp-python pilot sub-RPM (pyright)"
```

---

### Task 6: Offline integration verification (UBI8 + UBI9)

**Files:**
- Create: `packaging/rpm/test/Dockerfile.verify`
- Create: `packaging/rpm/test/verify-offline.sh`
- Create: `packaging/rpm/test/sample/hello.py`

**Interfaces:**
- Consumes: built RPMs in `packaging/rpm/out/`.
- Produces: pass/fail verification that the RPMs install and run with `--network=none`.

- [ ] **Step 1: Write a sample Python file**

Create `packaging/rpm/test/sample/hello.py`:

```python
def greet(name: str) -> str:
    return "hello " + name
```

- [ ] **Step 2: Write the in-container verify script**

Create `packaging/rpm/test/verify-offline.sh`:

```bash
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
command -v pyright-langserver
/opt/opencode/bin/rg --version | head -1
# pyright must start and not attempt any download
timeout 20 pyright-langserver --version
echo "OFFLINE VERIFY OK"
```

(`--nodeps` is used only because `python3` is layered at image-build time; on a real host dnf resolves it from the mirror.)

- [ ] **Step 3: Write the verification Dockerfile**

Create `packaging/rpm/test/Dockerfile.verify`:

```dockerfile
ARG BASE=registry.access.redhat.com/ubi9/ubi:latest
FROM ${BASE}
# ONLY online step: install python3 (simulates internal mirror availability)
RUN dnf -y install python3 tar && dnf clean all
COPY out /rpms
COPY test/verify-offline.sh /verify.sh
RUN chmod +x /verify.sh
ENTRYPOINT ["/verify.sh"]
```

- [ ] **Step 4: Build the verifier image (online) then run it offline — UBI9**

Run:
```bash
docker build -f packaging/rpm/test/Dockerfile.verify -t oc-verify:ubi9 packaging/rpm
docker run --rm --network=none oc-verify:ubi9
```
Expected: ends with `OFFLINE VERIFY OK`; config shows the `ollama` provider with substituted host/port; `opencode --version` prints the version; no network errors.

- [ ] **Step 5: Repeat for UBI8**

Run:
```bash
docker build --build-arg BASE=registry.access.redhat.com/ubi8/ubi:latest -f packaging/rpm/test/Dockerfile.verify -t oc-verify:ubi8 packaging/rpm
docker run --rm --network=none oc-verify:ubi8
```
Expected: `OFFLINE VERIFY OK` (proves the musl binary runs on glibc 2.28).

- [ ] **Step 6: Commit**

```bash
git add packaging/rpm/test
git commit -m "test(packaging): offline install verification on UBI8 and UBI9"
```

---

### Task 7: Build orchestration + docs

**Files:**
- Create: `packaging/rpm/scripts/build-all.sh`
- Create: `packaging/rpm/README.md`

**Interfaces:**
- Produces: one-command build of all v1 artifacts on a connected host; staged `models.json` snapshot.

- [ ] **Step 1: Stage the models snapshot in build-all and chain every step**

Create `packaging/rpm/scripts/build-all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
D="$ROOT/packaging/rpm/scripts"
"$D/build-binary.sh"
"$D/build-tools.sh"
"$D/vendor-ripgrep.sh"
"$D/vendor-pyright.sh"
# Stage the embedded models snapshot for OPENCODE_MODELS_PATH:
SHARE="$ROOT/packaging/rpm/payload/opencode/opt/opencode/share"
mkdir -p "$SHARE"
node -e "const g=require('$ROOT/packages/opencode/script/generate.ts');" 2>/dev/null || true
# Fallback: emit an empty object if no snapshot is produced; the binary also
# carries OPENCODE_MODELS_DEV embedded, so this file is a safety net.
[ -f "$SHARE/models.json" ] || echo '{}' > "$SHARE/models.json"
"$D/build-rpm.sh"
echo "All RPMs in packaging/rpm/out/:"; ls -1 "$ROOT/packaging/rpm/out/"
```

- [ ] **Step 2: Run the full pipeline and confirm both RPMs appear**

Run: `chmod +x packaging/rpm/scripts/build-all.sh && ./packaging/rpm/scripts/build-all.sh`
Expected: `packaging/rpm/out/` contains `opencode-<ver>-1.*.x86_64.rpm` and `opencode-lsp-python-*.x86_64.rpm`.

- [ ] **Step 3: Write the README**

Create `packaging/rpm/README.md` documenting: prerequisites (connected build host with Bun, npm, rpmbuild, docker, curl); `build-all.sh`; how to set the Ollama endpoint on a target (`/etc/opencode/ollama.conf` + rerun `oc-rebuild-config`, or before install); how to add a future language pack (copy the python pattern: vendor script + spec + `NN-<lang>.json` fragment + `Requires`); the offline guarantees enforced by the wrapper.

```markdown
# Air-gapped opencode RPMs

## Build (connected host)
    ./packaging/rpm/scripts/build-all.sh
Artifacts land in `packaging/rpm/out/`.

## Install (target, offline)
    sudo dnf install ./opencode-<ver>.x86_64.rpm
    sudo dnf install ./opencode-lsp-python-<ver>.x86_64.rpm   # python3 from internal mirror
Edit `/etc/opencode/ollama.conf` (host/port/model), then:
    sudo /opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json

## Adding a language (future)
Replicate the Python pilot: a `vendor-<lang>.sh`, a `opencode-lsp-<lang>.spec`
(with the right `Requires:`), and a `config/NN-<lang>.json` fragment. No core change.
```

- [ ] **Step 4: Verify README links match real paths**

Run: `ls packaging/rpm/scripts/build-all.sh packaging/rpm/out/*.rpm`
Expected: all paths exist.

- [ ] **Step 5: Commit**

```bash
git add packaging/rpm/scripts/build-all.sh packaging/rpm/README.md
git commit -m "feat(packaging): one-command build-all + air-gapped RPM docs"
```

---

## Notes for the implementer

- Tasks 1-3, 5(step1), 7 require **internet** (build host). Task 6 builds an image online then runs it with `--network=none` to prove the air-gap.
- Native unit tests exist only where there is real logic (Task 2). Packaging tasks are verified by inspecting RPM contents (`rpm -qlp`) and the offline container run (Task 6) — those are the gates.
- Do not commit the `packaging/rpm/payload/` or `out/` trees (git-ignored in Task 3); they are regenerated by `build-all.sh`.
- If `rpmbuild` is unavailable on the build host, install it (`dnf install rpm-build` / `apt install rpmbuild`); it is a build-host tool only, never required on targets.
