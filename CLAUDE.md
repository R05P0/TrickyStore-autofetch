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
| `uninstall.sh` | removes only our data dir; never touches keybox.xml |

## Runtime paths
- Config (persistent): `/data/adb/trickystore_autofetch/config.conf`
- Log: `/data/adb/trickystore_autofetch/autofetch.log`
- CRL cache: `/data/adb/trickystore_autofetch/crl.json`
- Notif icon (must be readable by SystemUI): `/sdcard/.trickystore_autofetch_icon.png`

## action.sh subcommands (the WebUI's API)
```
action.sh status-json        # JSON: interval, keybox, serial, revoked, target_count, pif
action.sh set-interval N     # seconds (min 3600); loop re-reads config each cycle, no reboot
action.sh list-apps          # JSON [{pkg,rec,cur}] of user apps (rec=recommended, cur=in target)
action.sh set-target P...    # write target.txt = Google core + given packages
action.sh populate-target    # = set-target with ALL user apps
action.sh check-now          # run one CRL revocation check
action.sh apply              # install pending keybox + renew PIF + fix secpatch + pm clear + reboot
action.sh webui              # open WebUI in KsuWebUIStandalone / MMRL
```

## keybox_lib.sh functions
`kb_fetch_source` (yurikey/upstream/custom) → `kb_normalise` → `kb_structural_ok` → `kb_leaf_serial` → `kb_refresh_crl`/`kb_is_revoked` → `kb_install`. Notify via `kb_notify`.

- **Source encodings** (auto-detected by `kb_normalise`): raw XML | base64→XML (yurikey) | hex→base64→XML (upstream KOWX712 `keybox/.extra`).
- **Revocation**: extract the leaf cert serial (ASN.1/DER parsed in pure `awk`+`base64`+`xxd`, **no openssl on device**) and grep it in Google's CRL `https://android.googleapis.com/attestation/status`. NB: the public CRL doesn't list *every* dead key (Google also blocks server-side), so "not revoked" ≠ "passes integrity".
- Public sources often serve the **same** leaked key under different labels; `kb_leaf_serial` is used to skip a candidate identical to the current key.

## WebUI (webroot/)
- Talks to root via the KSU WebUI bridge: `ksu.exec(cmd, '{}', callbackName)` where the callback gets `(errno, stdout, stderr)`. See the `exec()` wrapper in `index.html`.
- On Magisk (no built-in WebUI/Action button) the page is opened by **KsuWebUIStandalone** (`io.github.a13e300.ksuwebui`) or MMRL. `action.sh` launches it via `am start -n io.github.a13e300.ksuwebui/.WebUIActivity -e id trickystore_autofetch`.
- App selector: `list-apps` → checkboxes; presets Recommended/All/None; Save → `set-target`.

## GOTCHAS / traps we hit (don't relearn these)
- **PIF fresh reinstall loses `custom.pif.prop`** → runs with no fingerprint → BASIC fails. Fix: `sh /data/adb/modules/playintegrityfix/autopif4.sh` (canary Pixel fp is fine). Old fp backup was at `/data/adb/pif.json.old`.
- **autopif writes a malformed `security_patch.txt`** for Tricky Store (`system=202607`). Always normalise all three lines to one valid `YYYY-MM-DD`. `action.sh`'s `fix_ts_secpatch` does this.
- **Notifications must post as uid 2000** (`su -lp 2000 -c "cmd notification post ..."`). As root (uid 0) `cmd` accepts it but it never displays.
- **Notification/app icon**: a **white-on-transparent** PNG works as a monochrome mask; the system tints it (Material You). Pass via `cmd notification post -i file:///sdcard/...`. It must live on shared storage (SystemUI, uid system, can't read `/data/adb`).
- **`adb push` to `/data/adb/...` fails silently** (root-only, adb runs as shell). Deploy via `adb push /data/local/tmp/... && su -c cp`.
- **KsuWebUIStandalone caches the WebView** — after changing `webroot/`, `pm clear io.github.a13e300.ksuwebui` (or force-close) to see changes.
- **ImageMagick `+level-colors X,X` destroys PNG alpha** (makes an opaque square). To recolor a silhouette keeping transparency: `magick in.png -channel RGB -fill '#RRGGBB' -colorize 100 +channel out.png`.
- **zsh doesn't word-split unquoted vars** — `for f in a b c` works; `sed ... $FILES` doesn't.

## Test / deploy cheatsheet (device over adb)
```
# deploy a changed script into the live module (adb can't write /data/adb directly)
adb push action.sh /data/local/tmp/a.sh
adb shell 'su -c "cp /data/local/tmp/a.sh /data/adb/modules/trickystore_autofetch/action.sh; chmod 755 $_"'

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
