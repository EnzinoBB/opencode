# Design: opencode air-gapped per RHEL 8/9 via RPM

- **Data:** 2026-06-18
- **Stato:** approvato (brainstorming) → in attesa di implementation plan
- **Fork:** antifraudsolution / opencode

## 1. Obiettivo e contesto

Far girare opencode su macchine **air-gapped** (nessun accesso a internet) RHEL 8 e
RHEL 9, distribuendolo via **RPM** senza che la macchina target debba scaricare
alcun pacchetto a runtime o a install-time.

L'inferenza LLM gira su un **Ollama in LAN** (altra macchina della rete, endpoint
OpenAI-compatible). La macchina target non raggiunge internet ma raggiunge quell'endpoint.

Il binario opencode è già in larga parte self-contained (web UI, native deps, snapshot
`models.dev` embeddati a build-time). Il lavoro consiste nel: (a) produrre un binario
compatibile con tutto il parco RHEL, (b) **bundlare** ciò che opencode scaricherebbe a
runtime (ripgrep, language server), (c) **disabilitare** ogni accesso di rete non
necessario, (d) confezionare il tutto in RPM modulari, (e) **semplificare** la superficie
provider lasciando solo gli endpoint utili offline.

## 2. Vincoli e decisioni (lockate in fase di brainstorming)

| Tema | Decisione |
|---|---|
| Target | Solo **x86_64**; RHEL 8 e RHEL 9; coprire anche CPU **senza AVX2** |
| Binario | **Un unico** target `linux-x64-baseline-musl` (statico, no glibc, no AVX2) copre tutti i casi |
| Inferenza | Ollama in LAN via provider OpenAI-compatible (`baseURL`) |
| Packaging | **Core RPM + sub-RPM per linguaggio** (modulare, estensibile) |
| Linguaggi target | Python, Robot Framework, Java/JavaFX, Bash, XML, HTML (+ estensibilità futura) |
| Runtime LSP (JDK21, Python3) | Dichiarati come `Requires` RPM → risolti dal **mirror RHEL interno** |
| Provider | Approccio **soft**: codice non rimosso, ma neutralizzato; esposti solo custom + openai/anthropic via API key |
| Scope v1 | **Core completo** end-to-end offline + **Python** come sub-RPM pilota |

## 3. Architettura del binario

Build di un singolo target **`linux-x64-baseline`** (glibc, no-AVX2):

- **baseline** → nessun requisito AVX2, gira su CPU datate / VM.
- **glibc** → verificato empiricamente che il binario gira nativamente su **RHEL 8.10
  (glibc 2.28)** e **RHEL 9.8** senza alcun runtime aggiuntivo. Dipende solo dalle libc
  standard (`libc.so.6`, `ld-linux`, `libpthread`, `libdl`, `libm`) presenti su ogni RHEL.
- Un solo artefatto per tutto il parco macchine → un solo RPM core.

> **Nota di revisione (impl):** il design iniziale prevedeva il target `*-musl` per timore
> di incompatibilità con glibc 2.28 su RHEL 8. Il test sul campo (UBI8/UBI9) ha mostrato che
> il binario **glibc baseline** funziona direttamente, mentre il binario musl di Bun è
> *dinamicamente* linkato a `libc.musl`/`libstdc++` musl (assenti su RHEL) e richiederebbe
> di bundlare ~3.4MB di runtime + invocazione via loader. Si è quindi scelto **glibc
> baseline**: più semplice, più piccolo, zero indirezioni. Caveat: testato su 8.10/9.8; le
> minor 8.x più vecchie condividono lo stesso soname glibc 2.28.

Il target esiste già in `packages/opencode/script/build.ts` (`{os:linux, arch:x64,
avx2:false}`). La build gira su una **macchina connessa** (CI o dev box): Bun scarica gli
artefatti di cross-compile in quella fase; l'output è offline-ready.

Trade-off accettato: il binario baseline rinuncia alle ottimizzazioni AVX2 → lieve perdita
di performance su CPU moderne, in cambio di **un solo artefatto universale**.

## 4. Touchpoint di rete e relativa strategia offline

Mappa completa (riferimenti in `packages/opencode/src` e `packages/core/src`):

| Componente | Default | Strategia |
|---|---|---|
| **ripgrep** | download da GitHub releases in `~/.opencode/bin/rg` | **bundlato** (`x86_64-unknown-linux-musl`) in `/opt/opencode/bin/rg`, su PATH |
| **Language server** | download on-demand (GitHub/npm/`go install`/`gem`) | **bundlati** per linguaggio + `OPENCODE_DISABLE_LSP_DOWNLOAD=true` |
| **models.dev** | fetch live ogni 60 min | snapshot embeddato nel binario + `OPENCODE_DISABLE_MODELS_FETCH=true` (nessun `models.json` spedito) |
| **Auto-update** | check a ogni avvio | `OPENCODE_DISABLE_AUTOUPDATE=true` |
| **Provider OAuth/auth** | phone-home all'auth di vari provider | provider non configurati + approccio soft (§7) |
| **webfetch / websearch** | tool su richiesta dell'agente | nessun endpoint hardcoded; inerti senza rete |
| **LLM** | endpoint provider | provider `ollama` con `baseURL` LAN |

Tutti i flag sono env var lette da `process.env` (`packages/core/src/flag/flag.ts`,
`packages/opencode/src/effect/runtime-flags.ts`). Vengono imposte dal **wrapper** (§6),
così l'air-gap è garantito indipendentemente dalla config dell'utente.

## 5. Layout su filesystem (FHS)

```
/opt/opencode/libexec/opencode          # binario reale (glibc baseline)
/opt/opencode/bin/rg                     # ripgrep bundlato
/opt/opencode/lsp/<lang>/...             # file dei language server, per linguaggio
/opt/opencode/libexec/oc-rebuild-config  # script merge conf.d -> opencode.json
/usr/bin/opencode                        # wrapper (entrypoint utente)
/etc/opencode/opencode.json              # config GENERATA (non editare a mano)
/etc/opencode/conf.d/00-base.json        # fragment base (provider + flag)  -- dal core
/etc/opencode/conf.d/10-python.json      # fragment Python                  -- dal sub-RPM
/etc/opencode/ollama.conf                # host/porta Ollama parametrizzabili
```

## 6. Wrapper `/usr/bin/opencode`

Imposta i flag offline e il PATH, poi fa `exec` del binario reale:

```sh
#!/bin/sh
[ -f /etc/opencode/ollama.conf ] && . /etc/opencode/ollama.conf
export OPENCODE_DISABLE_LSP_DOWNLOAD=true
export OPENCODE_DISABLE_AUTOUPDATE=true
export OPENCODE_DISABLE_MODELS_FETCH=true
export OPENCODE_DISABLE_SHARE=true       # zero-egress: niente session sharing anche con config utente
export OPENCODE_PURE=1                    # niente plugin esterni (npm) caricati
export PATH="/opt/opencode/bin:$PATH"   # rg + lsp bundlati risolti via which()
exec /opt/opencode/libexec/opencode "$@"
```

> **Nota (impl):** `OPENCODE_MODELS_PATH` NON viene impostato di proposito — con
> `OPENCODE_DISABLE_MODELS_FETCH=true` e nessuna cache su disco, opencode usa lo snapshot
> `OPENCODE_MODELS_DEV` embeddato nel binario; puntare a un `models.json` placeholder vuoto
> verrebbe restituito tale e quale (zero modelli). I flag `OPENCODE_DISABLE_SHARE`/
> `OPENCODE_PURE` sono hardening aggiunti in review finale per garantire zero-egress a
> prescindere dalla config dell'utente.

Razionale: centralizza l'air-gap e fa sì che gli LSP bundlati siano trovati via `which()`
senza che opencode tenti alcun download.

## 7. Semplificazione provider (approccio soft)

Il sorgente dei ~30 provider/plugin OAuth **non viene rimosso** (merge da upstream
indolore), ma reso inerte:

- Nessun provider esterno configurato di default.
- Esposti **solo**: provider custom (`ollama` e gateway interni OpenAI-compatible) e,
  opzionalmente, `openai`/`anthropic` via API key + `baseURL` di un gateway interno.
- Gli auth flow di rete non vengono mai innescati perché nessun provider OAuth è
  configurato e i flag offline sono attivi.

> Possibile estensione futura (fuori scope v1): build con catalogo provider ridotto per
> rimpicciolire il binario. Non necessaria ora.

## 8. Config offline di default (`/etc/opencode/conf.d/00-base.json`)

```json
{
  "provider": {
    "ollama": {
      "name": "Ollama (LAN)",
      "options": { "baseURL": "http://OLLAMA_HOST:OLLAMA_PORT/v1", "apiKey": "ollama" },
      "models": { "MODEL_ID": {} }
    }
  }
}
```

`OLLAMA_HOST` / `OLLAMA_PORT` / `MODEL_ID` parametrizzati a install-time tramite
`/etc/opencode/ollama.conf` + sostituzione in `oc-rebuild-config`. Blocchi
`openai`/`anthropic` forniti come esempio commentato/documentato, da attivare con API key.

Provider schema confermato: `provider.<id>.options.baseURL` + `apiKey` + `models`
(`packages/core/src/v1/config/provider.ts`).

## 9. Pacchetti RPM

### 9.1 `opencode` (core) — v1
Contenuto: binario (glibc baseline), `rg`, wrapper, `oc-rebuild-config`,
`conf.d/00-base.json`, `ollama.conf`. Possiede le dir `/opt/opencode/{,bin,libexec}`.
`%post`/`%postun`: esegue `oc-rebuild-config`. Nessuna dipendenza pesante.

### 9.2 `opencode-lsp-python` — v1 (pilota)
- pyright pre-installato sotto `/opt/opencode/lsp/python/` (node_modules risolto via
  `which`/PATH); robotframework-lsp valutato nel pacchetto robot, non qui.
- `Requires: python3` (dal mirror interno).
- Installa `conf.d/10-python.json` con la voce `lsp.pyright` (o lascia il built-in con
  binario su PATH) e triggera il rebuild.

### 9.3 Sub-RPM futuri (post-v1, stesso pattern)
`opencode-lsp-bash`, `opencode-lsp-web` (html + xml/lemminx),
`opencode-lsp-java` (`Requires: java-21-openjdk-headless`),
`opencode-lsp-robot` (`Requires: python3`).
**Aggiungere un linguaggio = nuovo sub-RPM** (file + fragment), zero modifiche al core.

## 10. Meccanismo di config modulare (`oc-rebuild-config`)

`OPENCODE_CONFIG_DIR` carica un solo `opencode.json` per directory → non basta per N
sub-RPM. Si adotta il pattern **`conf.d/` + assemble**:

1. Ogni RPM (core + sub) installa un proprio frammento in `/etc/opencode/conf.d/NN-*.json`.
2. In `%post`/`%postun` ogni RPM lancia `oc-rebuild-config`, che fa il **deep-merge** di
   tutti i frammenti (in ordine lessicale) producendo `/etc/opencode/opencode.json`,
   applicando anche la sostituzione dei parametri da `ollama.conf`.
3. La chiave `lsp` è un `Record` → i frammenti si fondono per chiave senza conflitti.

`oc-rebuild-config` è un piccolo script (preferibilmente eseguito col binario opencode
stesso o con `jq` se disponibile; in mancanza, con un merge JSON minimale dedicato che
non introduca dipendenze esterne).

## 11. Testing / verifica

- **Build offline check**: container RHEL 8 (UBI8) e RHEL 9 (UBI9) con `--network=none`:
  - `opencode --version` (smoke);
  - avvio TUI;
  - sessione contro un Ollama simulato raggiungibile in rete di test;
  - per Python: apertura di un file `.py`, LSP attivo (diagnostica), **nessun** tentativo
    di download (verifica via strace/log di rete).
- **No-egress check**: con la sola interfaccia verso l'host Ollama, confermare che nessuna
  connessione parta verso GitHub/npm/models.dev/opencode.ai.
- **Idempotenza RPM**: install/uninstall ripetuti di core e sub-RPM rigenerano
  correttamente `opencode.json`.

## 12. Fuori scope (v1)

- Sub-RPM diversi da Python (bash/web/java/robot) → spec/fase successiva, stesso pattern.
- Bundling dei runtime JDK/Python (si usa il mirror interno).
- Rimozione hard dei provider dal sorgente.
- Target ARM/Windows/macOS.

## 13. Rischi aperti

- **pyright offline**: verificare che il pacchetto pre-installato non tenti risoluzioni di
  rete al primo avvio; fissare versione e bundlare i node_modules completi.
- **`oc-rebuild-config` senza dipendenze**: scegliere un meccanismo di merge JSON che non
  richieda pacchetti non garantiti sul target (valutare l'uso del binario opencode stesso
  per emettere la config finale).
- **Parametrizzazione Ollama**: definire UX install-time (variabili in `ollama.conf` vs
  prompt) per host/porta/modello.
