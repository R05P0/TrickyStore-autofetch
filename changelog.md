## v1.0.0
- Initial release.
- Revocation-aware keybox rotation for Tricky Store.
- Checks the active keybox leaf serial against Google's attestation CRL.
- Multi-source fetch with failover: yurikey, upstream (KOWX712), custom.
- Structural + revocation validation before install; skips identical keys.
- Writes only `/data/adb/tricky_store/keybox.xml` — never touches Tricky Store's module files.
- Notification + one-tap `action.sh` Apply (clears Play caches, reboots).
