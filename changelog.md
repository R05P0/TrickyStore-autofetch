## v1.0.0
- Initial release.
- Revocation-aware keybox rotation for Tricky Store.
- Checks the active keybox leaf serial against Google's attestation CRL.
- Multi-source fetch with failover: yurikey, upstream (KOWX712), custom.
- Structural + revocation validation before install; skips identical keys.
- Writes only `/data/adb/tricky_store/keybox.xml` — never touches Tricky Store's module files.
- Notification with a keys icon; interactive `action.sh` menu (change interval / status / apply).
- **Seamless Apply**: installs the keybox, renews the PlayIntegrityFork fingerprint (autopif) so BASIC stays green, repairs Tricky Store's `security_patch.txt`, clears Play caches, and reboots — one action, all three verdicts.
- Default check interval 6h (configurable, no reboot to change).
