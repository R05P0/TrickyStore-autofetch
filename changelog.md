## v1.3.0
- **WebUI:** the log line moved to the top (sticky, so feedback stays visible), Status right below it, and a new **Keybox sources** card at the bottom: chips like the interval picker (tap to enable/disable, numbered by priority) and an **Add a source** form (name, https URL, optional header) with a **Test** button that validates a URL without installing anything. Custom sources can be removed with the × on their chip.
- New `action.sh` commands: `add-source`, `remove-source`, `test-url`, `test-source`; `list-sources` now returns priority order.
- Sources are no longer hard-coded in the core: extra (private) sources plug in through optional hooks, so they can be kept out of the repo. `upstream` (dead since 2026-08) was removed.
- The background loop now re-sources `keybox_lib.sh` every cycle (after a self-update the old functions kept running until reboot), and `check-now` refreshes `status.json` like the loop does.
- `status.json` gains `candidate_ready` (true when a replacement keybox is waiting for Apply) and `pif_days_left`.

## v1.2.0
- **New source: `specter`** (dpejoh's curated catalog at `rawbin.dpejoh.com/catalog`). It tracks per-key serial/revoked/timestamp and a "working" pointer. The module now picks the NEWEST non-revoked key; when that equals the currently mounted one it does nothing, so `specter` effectively works as a MONITOR that auto-adopts the next fresh leak. Added to the default source order (`specter ddex yurikey`).
- `kb_normalise` now also decodes Specter's **shuffled-base64** key blobs (scrambled b64 alphabet on `/key/<source>/<version>`).
- Note: a keybox being "not revoked" means it passes Play Integrity — it is NOT a guarantee it passes Google Wallet tap-to-pay, whose blocklist is stricter.

## v1.1.0
- Added `ddex` source (dare-devil-ex/keyboxxBot, DeviceID "wkaie"), a genuinely different key from yurikey.

## v1.0.0
- Initial release: autofetch keybox with CRL revocation check + PIF renewal on Apply.
