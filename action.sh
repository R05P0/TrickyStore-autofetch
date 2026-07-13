#!/system/bin/sh
#
# action.sh - interactive menu (KernelSU/APatch action button, KsuWebUIStandalone,
# or a terminal: `su -c 'sh /data/adb/keybox_autofetch/action.sh'`).
#
# Lets you change the check interval, apply a refreshed keybox, or see status.
# Nothing here touches Tricky Store's module files - only keybox.xml / our config.

DATA_DIR="/data/adb/keybox_autofetch"
CONFIG="$DATA_DIR/config.conf"
TS_KEYBOX="/data/adb/tricky_store/keybox.xml"
TS_SECPATCH="/data/adb/tricky_store/security_patch.txt"
PENDING="$DATA_DIR/pending_keybox.xml"
PIF_DIR="/data/adb/modules/playintegrityfix"
ICON_PUB="/sdcard/.keybox_autofetch_icon.png"

# load user config (RENEW_PIF etc.)
[ -f "$CONFIG" ] && . "$CONFIG"
[ -n "$RENEW_PIF" ] || RENEW_PIF=1

notify() {
    iflag=""; [ -f "$ICON_PUB" ] && iflag="-i file://$ICON_PUB"
    su -lp 2000 -c "cmd notification post $iflag -t '$1' keybox_autofetch '$2'" >/dev/null 2>&1
}

cur_interval() { grep '^INTERVAL=' "$CONFIG" 2>/dev/null | cut -d= -f2; }

human() { # seconds -> "Nh"
    case "$1" in
        3600) echo "1h" ;; 10800) echo "3h" ;; 21600) echo "6h" ;;
        43200) echo "12h" ;; 86400) echo "24h" ;; *) echo "${1}s" ;;
    esac
}

set_interval() {
    secs="$1"
    if [ "$secs" -lt 3600 ] 2>/dev/null; then secs=3600; fi
    if grep -q '^INTERVAL=' "$CONFIG" 2>/dev/null; then
        sed -i "s/^INTERVAL=.*/INTERVAL=$secs/" "$CONFIG"
    else
        echo "INTERVAL=$secs" >> "$CONFIG"
    fi
    echo "  -> Interval set to $(human "$secs") ($secs s)."
    echo "     Applies on the next check cycle (no reboot needed)."
}

# autopif sometimes writes a malformed 'system=' line into Tricky Store's
# security_patch.txt (e.g. "system=202607"). Normalise all three to one valid date.
fix_ts_secpatch() {
    [ -f "$TS_SECPATCH" ] || return 0
    sp="$(grep -m1 '^SECURITY_PATCH=' "$PIF_DIR/custom.pif.prop" 2>/dev/null | cut -d= -f2)"
    case "$sp" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *)
        sp="$(grep -m1 '^boot=' "$TS_SECPATCH" | cut -d= -f2)" ;; esac
    case "$sp" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        printf 'system=%s\nboot=%s\nvendor=%s\n' "$sp" "$sp" "$sp" > "$TS_SECPATCH"
        echo "  - Tricky Store security_patch normalised to $sp" ;;
    esac
}

renew_pif() {
    [ "$RENEW_PIF" = "1" ] || return 0
    if [ ! -f "$PIF_DIR/autopif4.sh" ]; then
        echo "  - PlayIntegrityFork not found, skipping fingerprint renewal"; return 0
    fi
    echo "  - renewing PIF fingerprint (autopif)..."
    if (cd "$PIF_DIR" && timeout 150 sh autopif4.sh >/dev/null 2>&1); then
        echo "    fingerprint renewed"
        fix_ts_secpatch
    else
        echo "    autopif failed (no network?) - keeping current fingerprint"
    fi
}

apply_keybox() {
    echo "  Seamless apply: keybox + PIF fingerprint + re-attest + reboot"
    # 1) install the freshly fetched keybox if one is pending
    if [ -f "$PENDING" ] && grep -q "<AndroidAttestation" "$PENDING" 2>/dev/null; then
        cp -f "$TS_KEYBOX" "$DATA_DIR/keybox.prev.xml" 2>/dev/null
        cp -f "$PENDING" "$TS_KEYBOX" && chmod 644 "$TS_KEYBOX" && rm -f "$PENDING"
        echo "  - installed pending keybox"
    fi
    # 2) refresh the PlayIntegrityFork fingerprint (keeps BASIC green)
    renew_pif
    # 3) force GMS/Play to re-attest with the new keybox + fingerprint
    echo "  - clearing Play Integrity caches (GMS + Play Store)"
    pm clear com.google.android.gms  >/dev/null 2>&1
    pm clear com.android.vending     >/dev/null 2>&1
    # 4) reboot
    notify "Applying keybox" "Renewed keybox + fingerprint. Rebooting to re-attest."
    echo "  - rebooting in 3s (re-login to Play after boot)"
    sleep 3
    reboot
}

interval_menu() {
    echo ""
    echo "  Check interval (current: $(human "$(cur_interval)")):"
    echo "    1) 1h   2) 3h   3) 6h   4) 12h   5) 24h   6) custom (seconds)"
    printf "  > "; read i
    case "$i" in
        1) set_interval 3600 ;;  2) set_interval 10800 ;;  3) set_interval 21600 ;;
        4) set_interval 43200 ;; 5) set_interval 86400 ;;
        6) printf "  seconds (min 3600): "; read s; set_interval "$s" ;;
        *) echo "  cancelled" ;;
    esac
}

status() {
    echo ""
    echo "  Interval : $(human "$(cur_interval)")"
    echo "  Keybox   : $( [ -f "$TS_KEYBOX" ] && echo installed || echo MISSING )"
    echo "  Last log :"
    tail -n 3 "$DATA_DIR/autofetch.log" 2>/dev/null | sed 's/^/    /' || echo "    (no log yet)"
}

while true; do
    echo ""
    echo "  === Keybox Autofetch ==="
    echo "  1) Change check interval  (now: $(human "$(cur_interval)"))"
    echo "  2) Apply new keybox now   (pm clear + REBOOT)"
    echo "  3) Status"
    echo "  0) Exit"
    printf "  Choose: "
    if ! read choice; then echo "  (no interactive input - run in a terminal)"; exit 0; fi
    case "$choice" in
        1) interval_menu ;;
        2) apply_keybox ;;
        3) status ;;
        0|q|"") echo "  bye"; exit 0 ;;
        *) echo "  ?" ;;
    esac
done
