#!/system/bin/sh
#
# action.sh - "Apply" the (new) keybox.
#
# Tap this from KernelSU / APatch / KsuWebUIStandalone module Action button,
# or run manually:  su -c 'sh /data/adb/keybox_autofetch/action.sh'
#
# It installs any pending keybox, forces Play Integrity to re-attest by clearing
# the GMS/Play caches, then reboots. NOTE: clearing GMS signs you out of Google
# Play - you will re-enter your Google account after the reboot. That is normal.

MODDIR=${0%/*}
DATA_DIR="/data/adb/keybox_autofetch"
TS_KEYBOX="/data/adb/tricky_store/keybox.xml"
PENDING="$DATA_DIR/pending_keybox.xml"

# best-effort notify helper (must post as shell uid 2000, not root)
notify() { su -lp 2000 -c "cmd notification post -t '$1' keybox_autofetch '$2'" >/dev/null 2>&1; }

echo "== Keybox Autofetch: Apply =="

# 1) install a pending keybox if AUTO_INSTALL was disabled
if [ -f "$PENDING" ] && grep -q "<AndroidAttestation" "$PENDING" 2>/dev/null; then
    cp -f "$TS_KEYBOX" "$DATA_DIR/keybox.prev.xml" 2>/dev/null
    cp -f "$PENDING" "$TS_KEYBOX" && chmod 644 "$TS_KEYBOX" && rm -f "$PENDING"
    echo "- installed pending keybox"
fi

# 2) force re-attestation
echo "- clearing Play Integrity caches (GMS + Play Store)"
pm clear com.google.android.gms   >/dev/null 2>&1
pm clear com.android.vending      >/dev/null 2>&1

# 3) reboot
notify "Applying keybox" "Re-attesting and rebooting now."
echo "- rebooting in 3s (re-login to Play after boot)"
sleep 3
reboot
