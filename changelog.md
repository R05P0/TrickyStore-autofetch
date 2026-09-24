## Unreleased
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
