<p align="center">
  <img src="assets/logo-readme.png" width="120" alt="TrickyStore Autofetch logo">
</p>

<h1 align="center">TrickyStore Autofetch</h1>

A tiny, dependency-free Magisk/KernelSU/APatch module that keeps [Tricky Store](https://github.com/5ec1cff/TrickyStore) supplied with a **working attestation keybox** — automatically.

On a schedule it asks Google whether your current keybox has been revoked. If it has, it fetches a fresh one from a list of public sources (with failover), validates it, installs it, and sends you a notification. One tap re-attests and reboots.

[**Download latest release →**](https://github.com/R05P0/TrickyStore-autofetch/releases/latest/download/trickystore-autofetch-v1.0.0.zip)

> ⚠️ **For educational purposes only.** Use at your own risk.

> ⚠️ **Not affiliated with Tricky Store.** Do not open issues on the Tricky Store repo because of this module.

---

## Why this exists

Leaked hardware keyboxes are what let Tricky Store spoof DEVICE/STRONG Play Integrity on an unlocked bootloader. Google revokes them over time, so keeping a live one is a chore. Existing helpers (KOWX712's *Tricky Addon*, the *Enhanced* fork) automate the fetch — but the Enhanced fork **modifies Tricky Store's own module files**, which trips Tricky Store's integrity self-check and stops the engine from starting at all. This module was written after debugging exactly that failure.

**The one rule this module follows:** it *only* ever writes to `/data/adb/tricky_store/keybox.xml`. It never touches anything inside `/data/adb/modules/tricky_store/`.

## What it does

- **Revocation-aware.** Extracts the leaf certificate serial from your active keybox and checks it against Google's official revocation list (`https://android.googleapis.com/attestation/status`). It only acts when your keybox is *actually* revoked — no pointless churn.
- **Multi-source with failover.** `yurikey` → `upstream` (KOWX712) → your own `custom` URL. Base64 or raw XML sources both work.
- **Validated before install.** Structural check + a re-check that the candidate isn't itself revoked and isn't the identical key you already have.
- **Notifies you**, then a one-tap **Apply** clears the Play Integrity caches and reboots so the new key takes effect.
- **Pure shell.** No compiled binary, ~4 small scripts. Uses `curl`, `base64`, `awk`, `xxd` — all present on modern Android.

## Requirements

Integrity on an unlocked bootloader needs **two** things working together, and this module keeps both fed:

| Module | Why | Required? |
|--------|-----|-----------|
| **[Tricky Store](https://github.com/5ec1cff/TrickyStore)** | keystore attestation via the keybox → **DEVICE** integrity | ✅ yes |
| **[PlayIntegrityFork](https://github.com/osm0sis/PlayIntegrityFork)** (PIF) | spoofs the device fingerprint → **BASIC** integrity | ✅ yes |
| **Zygisk** (Magisk/KernelSU/APatch) | needed by PIF | ✅ yes |
| **Shamiko** + DenyList | hide root from banking/payment apps | ⭐ recommended for real apps |
| Tricky Addon / Update Target List | — | ❌ **not needed** — this module manages the keybox itself |

> Get all three verdicts only if **both** Tricky Store **and** PIF are healthy. A valid keybox alone gives you DEVICE but **not** BASIC. This module's **Apply** renews *both* the keybox and the PIF fingerprint in one shot.

**`target.txt`:** Tricky Store spoofs attestation only for packages listed in `/data/adb/tricky_store/target.txt`. Install seeds it with the Google core (`gms` / `vending` / `gsf`), and the **action menu → "Auto-fill target.txt"** rebuilds it with the Google core plus every user app you have installed (root managers excluded) — so you never need the Tricky Addon for this.

## Install

1. Install **Tricky Store** and **PlayIntegrityFork** first, with **Zygisk enabled**.
2. Flash `TrickyStore-autofetch.zip` in Magisk / KernelSU / APatch.
3. Reboot.

It runs on boot and every ~6 h thereafter.

## Configure

**Quickest:** run the **action menu** (module Action button on KernelSU/APatch/KsuWebUIStandalone, or by hand: `su -c 'sh /data/adb/trickystore_autofetch/action.sh'`). It lets you change the check interval, apply a refreshed keybox, and see status — interval changes take effect on the next cycle, no reboot.

**Or** edit `/data/adb/trickystore_autofetch/config.conf` directly (this path survives module updates):

```sh
SOURCES="yurikey upstream"   # order to try; add 'custom'
CUSTOM_URL=""                # your own keybox URL if using 'custom'
INTERVAL=21600               # seconds between checks (min 3600)
AUTO_INSTALL=1               # 1: auto-write a valid keybox on revocation; 0: only notify
CRL_URL="https://android.googleapis.com/attestation/status"
```

## Applying a refreshed keybox

When a new keybox is installed you get a notification. To make it effective you must force GMS to re-attest:

- **KernelSU / APatch / KsuWebUIStandalone:** tap the module's **Action** button.
- **Magisk (no Action button):** run
  ```sh
  su -c 'sh /data/adb/trickystore_autofetch/action.sh'
  ```

**Apply is seamless** — one action does everything needed to go green again:

1. installs the freshly fetched keybox,
2. renews the **PlayIntegrityFork fingerprint** (`RENEW_PIF=1`, so BASIC stays green when a canary/beta fingerprint expires) and repairs Tricky Store's `security_patch.txt` if autopif malformed it,
3. clears the GMS + Play Store caches,
4. reboots.

**You will be signed out of Google Play and have to log back in — this is expected** (that's how re-attestation is forced).

## Honest limitations

- **The CRL is not the whole story.** Google's public revocation list catches keys revoked *at the certificate level*. Google's server-side integrity backend can also reject a key that is **not** in the public CRL. So "not revoked per the CRL" is a good signal, **not a guarantee** your keybox passes integrity. The only 100% reliable "is it dead" test is an actual Play Integrity request.
- **Sources overlap.** Public keybox repos frequently serve the *same* leaked key under different labels. This module compares leaf serials and skips a candidate that is identical to your current key, but it can't manufacture a genuinely new key that nobody has published.
- **Leaked keyboxes are a moving target.** When every public source is revoked, no tool can help — the only stable path for real attestation is a locked bootloader on stock firmware.
- **Notifications are best-effort** via `cmd notification`; on some ROMs they may not appear. The log at `/data/adb/trickystore_autofetch/autofetch.log` always records what happened.

## How it works (internals)

| Step | Where |
|------|-------|
| Fetch + base64-normalise a source | `kb_fetch_source`, `kb_normalise` |
| Structural sanity check | `kb_structural_ok` |
| Leaf-serial extraction (ASN.1/DER, no openssl) | `kb_leaf_serial` |
| Revocation check vs Google CRL | `kb_refresh_crl`, `kb_is_revoked` |
| Install to `keybox.xml` (only) | `kb_install` |
| Force re-attest + reboot | `action.sh` |

All in [`scripts/keybox_lib.sh`](scripts/keybox_lib.sh) and [`service.sh`](service.sh).

## Credits

- [5ec1cff / Tricky Store](https://github.com/5ec1cff/TrickyStore) — the attestation engine this feeds.
- [KOWX712 / Tricky-Addon-Update-Target-List](https://github.com/KOWX712/Tricky-Addon-Update-Target-List) — upstream keybox source & prior art.
- [Enginex0 / tricky-addon-enhanced](https://github.com/Enginex0/tricky-addon-enhanced) — source-URL reference and the CRL-validation idea.
- [Yurii0307 / yurikey](https://github.com/Yurii0307/yurikey) — a public keybox source.

## License

[Apache-2.0](LICENSE).
