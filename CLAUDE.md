# TrickyStore Autofetch — maintainer map

Notes for anyone (incl. Claude) doing future fixes. Read this before touching the module.

## What it is
A shell-only Magisk/KernelSU/APatch module that keeps [Tricky Store](https://github.com/5ec1cff/TrickyStore) fed with a working attestation keybox, and (on Apply) also renews the PlayIntegrityFork fingerprint. Goal: keep Play Integrity green on an unlocked bootloader with minimal fuss. Ships a WebUI.

## ⚠️ THE GOLDEN RULE
**Never modify anything under `/data/adb/modules/tricky_store/`.** We only write to files under `/data/adb/tricky_store/` (`keybox.xml`, `target.txt`, `security_patch.txt`) and our own `/data/adb/trickystore_autofetch/`.
Reason: the *Enhanced* fork (Enginex0) rewrote tricky_store's `module.prop` + added symlinks → tripped Tricky Store's integrity self-check (`verify1 failed` / `unverified!`) → the engine refused to start → `keystore2 SECURE_HW_COMMUNICATION_FAILED`. This whole module exists to avoid that.

## The integrity recipe (learned the hard way)
Three verdicts, and what actually drives each on this setup:
- **DEVICE** ← a valid, non-revoked **keybox** served by **Tricky Store**. (This module manages the keybox.)
- **BASIC** ← a spoofed device **fingerprint** from **PlayIntegrityFork (PIF)**. A valid keybox alone gives DEVICE but **NOT** BASIC — the classic `BASIC❌ DEVICE✅` split means PIF isn't supplying a good fingerprint.
- **STRONG** ← hardware-strong attestation; usually fails on unlocked bootloaders. Nice-to-have.

**After ANY change to keybox or fingerprint you MUST force re-attestation:**
```
pm clear com.google.android.gms com.android.vending
reboot        # then re-login to Play Store
```
GMS caches the DroidGuard/attestation result. Skipping the cache-clear makes a working setup *look* broken. This bit us repeatedly. `action.sh apply` does this for you.

Minimum required modules: **Tricky Store + PlayIntegrityFork + Zygisk**. The KOWX712 "Tricky Addon" is NOT needed. `target.txt` must list at least `com.google.android.gms!` `com.android.vending!` `com.google.android.gsf!`.

## File map
| File | Role |
|------|------|
| `module.prop` | id=`trickystore_autofetch`, version, `updateJson` URL |
| `customize.sh` | install: seed config, publish notif icon, seed target.txt core, perms |
| `service.sh` | late_start: boot wait → publish icon → background loop calling the check every `INTERVAL`s |
| `scripts/keybox_lib.sh` | all keybox logic (see below); sourced by service.sh & action.sh |
| `action.sh` | CLI backend + WebUI launcher + terminal-menu fallback (see subcommands) |
| `webroot/index.html` | the WebUI (talks to action.sh via `ksu.exec`) |
| `webroot/logo.png` | white-alpha keys, header logo |
| `icon.png` | notification icon (white-alpha), published to `/sdcard/.trickystore_autofetch_icon.png` |
| `config.conf` | seeded to `/data/adb/trickystore_autofetch/config.conf` (survives updates) |
| `deploy-private.sh` | pushes `private/sources_private.sh` (gitignored, see "Private sources") to the device's DATA_DIR |
| `build.sh` | builds the zip; aborts if a private source name is found in a file that would ship |
| `uninstall.sh` | removes only our data dir; never touches keybox.xml |

## Runtime paths
- Config (persistent): `/data/adb/trickystore_autofetch/config.conf`
- Log: `/data/adb/trickystore_autofetch/autofetch.log`
- CRL cache: `/data/adb/trickystore_autofetch/crl.json`
- User-added sources: `/data/adb/trickystore_autofetch/custom_sources.list` (mode 600, TAB separated `name url [header]`; the header may hold an API key)
- Optional private sources: `/data/adb/trickystore_autofetch/sources_private.sh` (see "Private sources")
- Notif icon (must be readable by SystemUI): `/sdcard/.trickystore_autofetch_icon.png`

## action.sh subcommands (the WebUI's API)
```
action.sh status-json        # JSON: interval, keybox, serial, revoked, target_count, pif, source_count
action.sh set-interval N     # seconds (min 3600); loop re-reads config each cycle, no reboot
action.sh list-apps          # JSON [{pkg,rec,cur}] of user apps (rec=recommended, cur=in target)
action.sh set-target P...    # write target.txt = Google core + given packages
action.sh populate-target    # = set-target with ALL user apps
action.sh list-sources       # JSON [{name,label,desc,enabled,prio,custom,hdr}] from kb_known_sources; enabled ones first in SOURCES order (prio 1..n), then the rest
action.sh set-sources S...   # write SOURCES = given names, in the given priority order
action.sh add-source N URL [HDR]  # save a custom source (https only, name a-z0-9_-, optional "Name: value" header) and enable it last
action.sh remove-source N    # delete a custom source (refuses if it's the only enabled one)
action.sh test-url URL [HDR] # dry run: fetch+decode+validate+CRL, prints a verdict, installs nothing
action.sh test-source N      # same for an already known source
action.sh open-renew         # opens a gated source's renewal page, if the private file provides one (runs as root - see GOTCHAS re: notification content-intents)
action.sh check-now          # run one CRL revocation check
action.sh apply              # install pending keybox + renew PIF + fix secpatch + pm clear + reboot
action.sh webui              # open WebUI in KsuWebUIStandalone / MMRL
```

### Adding a new keybox source
- **From the WebUI (normal case):** "Keybox sources → Add a source" (name, https URL, optional header). Stored in `custom_sources.list`; decoding is auto-detected. Use **Test** first.
- **Built-in (public) source:** in `scripts/keybox_lib.sh` add `URL_X=...`, a line in `kb_known_sources()` and a case in `kb_fetch_source()`. The WebUI and `action.sh list-sources`/`set-sources` are data-driven off `kb_known_sources`.
- **Private source (must not be published):** see "Private sources" below.

## Private sources (not in the repo)
Some sources must not be public. They live in `./private/` (**gitignored**, never zipped) and are deployed with `./deploy-private.sh` to `/data/adb/trickystore_autofetch/sources_private.sh`, which `keybox_lib.sh` sources if present (guarded by `sh -n`; without it the module just runs with the public sources). The core knows nothing about them except these optional hooks, all checked with `command -v`: `kb_private_known_sources`, `kb_private_fetch NAME OUT` (return 127 = not mine), `kb_private_cycle` (called every `service.sh` cycle), `kb_private_status_extra` (JSON for the WebUI status row: `{"label":..,"days":N,"renew":bool}`), `kb_private_renew`. Details live in `private/CLAUDE.private.md` if that folder exists on your machine.
- **Never** put source names/URLs/keys in a public file: `build.sh` greps the shipping files and aborts the build if it finds any.
- The private file lives in DATA_DIR on purpose, so a module self-update (which replaces the module dir) doesn't wipe it. `uninstall.sh` removes DATA_DIR, so redeploy after a reinstall.
- Changing it needs no reboot: the loop re-sources `keybox_lib.sh` (and through it the private file) every cycle.

## keybox_lib.sh functions
`kb_fetch_source` (yurikey/ddex/legacy `custom`/private hook/`custom_sources.list`) → `kb_fetch_url` → `kb_normalise` → `kb_structural_ok` → `kb_leaf_serial` → `kb_refresh_crl`/`kb_is_revoked` → `kb_install`. Notify via `kb_notify`.

- **Source encodings** (auto-detected by `kb_normalise`): raw XML | base64→XML (yurikey) | hex→base64→XML. A private source may bring its own decoder.
- **Revocation**: extract the leaf cert serial (ASN.1/DER parsed in pure `awk`+`base64`+`xxd`, **no openssl on device**) and grep it in Google's CRL `https://android.googleapis.com/attestation/status`. NB: the public CRL doesn't list *every* dead key (Google also blocks server-side), so "not revoked" ≠ "passes integrity".
- Public sources often serve the **same** leaked key under different labels; `kb_leaf_serial` is used to skip a candidate identical to the current key.
- "Not revoked" = passes Play Integrity, NOT necessarily tap-to-pay (Google's payment blocklist is stricter).

## WebUI (webroot/)
- Talks to root via the KSU WebUI bridge: `ksu.exec(cmd, '{}', callbackName)` where the callback gets `(errno, stdout, stderr)`. See the `exec()` wrapper in `index.html`.
- On Magisk (no built-in WebUI/Action button) the page is opened by **KsuWebUIStandalone** (`io.github.a13e300.ksuwebui`) or MMRL. `action.sh` launches it via `am start -n io.github.a13e300.ksuwebui/.WebUIActivity -e id trickystore_autofetch`.
- App selector: `list-apps` → checkboxes; presets Recommended/All/None; Save → `set-target`.

## GOTCHAS / traps we hit (don't relearn these)
- **`action.sh` exists in TWO places, and the WebUI calls the one you're less likely to edit.** `customize.sh` copies `$MODPATH/action.sh` to `$DATA_DIR/action.sh` (`/data/adb/trickystore_autofetch/action.sh`) at install time "so it can be run manually". The WebUI's `AC` constant in `index.html` hardcodes that `$DATA_DIR` path, NOT `/data/adb/modules/trickystore_autofetch/action.sh`. If you deploy a changed `action.sh` live (adb push to the module dir, see cheatsheet below) without also copying it to `$DATA_DIR`, the WebUI keeps calling the stale copy — symptom: new UI elements render (HTML/JS reloaded fine) but their data comes back `undefined` or `cmd: usage: ...` (old subcommand missing). Fix/rule: after any `action.sh` edit, push it to BOTH paths. `scripts/keybox_lib.sh` doesn't have this problem — `action.sh`'s `LIB=` always points at the module-dir copy regardless of where `action.sh` itself runs from.
- **PIF fresh reinstall loses `custom.pif.prop`** → runs with no fingerprint → BASIC fails. Fix: `sh /data/adb/modules/playintegrityfix/autopif4.sh` (canary Pixel fp is fine). Old fp backup was at `/data/adb/pif.json.old`.
- **autopif writes a malformed `security_patch.txt`** for Tricky Store (`system=202607`). Always normalise all three lines to one valid `YYYY-MM-DD`. `action.sh`'s `fix_ts_secpatch` does this.
- **Notifications must post as uid 2000** (`su -lp 2000 -c "cmd notification post ..."`). As root (uid 0) `cmd` accepts it but it never displays.
- **Notification/app icon**: a **white-on-transparent** PNG works as a monochrome mask; the system tints it (Material You). Pass via `cmd notification post -i file:///sdcard/...`. It must live on shared storage (SystemUI, uid system, can't read `/data/adb`).
- **`adb push` to `/data/adb/...` fails silently** (root-only, adb runs as shell). Deploy via `adb push /data/local/tmp/... && su -c cp`.
- **KsuWebUIStandalone caches the WebView** — after changing `webroot/`, `pm clear io.github.a13e300.ksuwebui` (or force-close) to see changes.
- **ImageMagick `+level-colors X,X` destroys PNG alpha** (makes an opaque square). To recolor a silhouette keeping transparency: `magick in.png -channel RGB -fill '#RRGGBB' -colorize 100 +channel out.png`.
- **zsh doesn't word-split unquoted vars** — `for f in a b c` works; `sed ... $FILES` doesn't.
- **A shell-posted notification (`cmd notification post`) can't get a tap-to-open link.** Tried `-c "activity -a android.intent.action.VIEW -d <url>"` (as documented in `cmd notification post --help`): fails hard with `Permission Denial: getIntentSender() ... uid=2000 is not allowed to send as package android` — uid 2000 (shell) can't construct a PendingIntent for a Notification. Putting a raw URL in the notification text doesn't get auto-linkified either (this minimal template skips that). Working alternative: `am start -a android.intent.action.VIEW -d <url>` run directly as **root** (not inside a notification) works fine — that's what `action.sh open-renew` + the WebUI's "Renew" button do. Don't re-attempt the notification content-intent route.
- **Editing `config.conf` live on the device: don't build the new content with nested `sed`/heredoc through `adb shell su -c "..."`.** Multiple shell layers (local shell → adb → su -c → remote sh) mangle quotes silently (e.g. a `sed` meant to add quotes around a value stripped them instead, producing `SOURCES=ddex yurikey` with no quotes — which breaks sourcing the config, since sh then tries to run `yurikey` as a command). Safe pattern: pull the file, edit it locally (a real editor/tool, not adb-remote sed), `sh -n -c '. file'` or eyeball it, then `adb push` + `su -c cp` it back into place — same as deploying scripts.

- **The service.sh loop lives for the whole uptime, so what it has sourced is frozen.** `run_once()` now re-sources `scripts/keybox_lib.sh` every cycle (guarded by `sh -n`), so lib changes apply on the next cycle without a reboot. BUT `service.sh` itself (incl. `run_once`'s own body) is still read once: after changing `service.sh`, restart the loop once. Relaunch with `setsid /data/adb/magisk/busybox sh /data/adb/modules/trickystore_autofetch/service.sh </dev/null >/dev/null 2>&1 &` (absolute busybox path; bare `busybox` isn't always in `$PATH` under `su`). Don't kill it with `pkill -f trickystore_autofetch/service.sh` inside the same `su -c "..."` line: the pattern also matches your own shell's cmdline and kills it (`Terminated`) before the relaunch runs; kill by PID, or do it in two calls.
- **`status.json` is a contract with the TrickyStoreCompanion widget** (`it.nacho.tsacompanion`, reads it via `su -c cat`). Fields: `status` (ok|revoked|missing|error), `serial_short`, `note`, `last_check`, `pif_days_left` (int or `null`), `candidate_ready` (bool, always present; true = a replacement keybox is staged and waits for Apply, only meaningful with `status=revoked`). Written by `kb_write_widget_status status serial note [candidate_ready]` from both `service.sh` and `action.sh check-now` (the widget's refresh button runs `check-now` then re-reads the file). Don't rename/remove fields without telling the widget side.

## Test / deploy cheatsheet (device over adb)
```
# deploy a changed script into the live module (adb can't write /data/adb directly)
adb push action.sh /data/local/tmp/a.sh
adb shell 'su -c "cp /data/local/tmp/a.sh /data/adb/modules/trickystore_autofetch/action.sh; chmod 755 $_"'
# action.sh ALSO needs the DATA_DIR copy updated - see GOTCHAS above, the WebUI calls this one:
adb shell 'su -c "cp /data/local/tmp/a.sh /data/adb/trickystore_autofetch/action.sh; chmod 755 $_"'

sh -n action.sh                                    # syntax check (run on device: sh -n)
adb shell 'su -c "sh /data/adb/trickystore_autofetch/action.sh status-json"'   # must be valid JSON
# integrity verdict: open "Play Integrity API Checker" (gr.nikolasspyr.integritycheck) and tap CHECK
#   (can't drive it via adb — screen is PIN-locked)
```

## Release process
1. Bump `version`/`versionCode` in **both** `module.prop` and `update.json`.
2. `zip -rq TrickyStore-autofetch.zip module.prop customize.sh service.sh action.sh uninstall.sh config.conf icon.png scripts webroot README.md LICENSE changelog.md`
3. `gh release create vX.Y.Z TrickyStore-autofetch.zip --title ... --notes-file changelog.md`
4. The `updateJson` (`update.json` on `main`) drives in-app updates; keep its `zipUrl` pointing at the release asset.

Repo: https://github.com/R05P0/TrickyStore-autofetch — commits attributed to R05P0 only (no co-author trailer, noreply email).
