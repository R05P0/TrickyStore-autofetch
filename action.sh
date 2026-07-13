#!/system/bin/sh
#
# action.sh - backend + launcher for TrickyStore Autofetch.
#
# Usage:
#   action.sh                 -> action button: open the WebUI (or terminal menu)
#   action.sh webui           -> open the WebUI (KsuWebUIStandalone / MMRL)
#   action.sh status-json     -> machine-readable status (used by the WebUI)
#   action.sh set-interval N  -> set check interval (seconds)
#   action.sh populate-target -> auto-fill Tricky Store target.txt
#   action.sh check-now       -> run one keybox revocation check now
#   action.sh apply           -> renew keybox+fingerprint, clear caches, reboot
#
# Nothing here touches Tricky Store's module files - only keybox.xml / target.txt
# / security_patch.txt and our own config.

MODID="trickystore_autofetch"
DATA_DIR="/data/adb/$MODID"
CONFIG="$DATA_DIR/config.conf"
LIB="/data/adb/modules/$MODID/scripts/keybox_lib.sh"
TS_KEYBOX="/data/adb/tricky_store/keybox.xml"
TS_SECPATCH="/data/adb/tricky_store/security_patch.txt"
TS_TARGET="/data/adb/tricky_store/target.txt"
PENDING="$DATA_DIR/pending_keybox.xml"
PIF_DIR="/data/adb/modules/playintegrityfix"
ICON_PUB="/sdcard/.trickystore_autofetch_icon.png"

[ -f "$CONFIG" ] && . "$CONFIG"
[ -n "$RENEW_PIF" ] || RENEW_PIF=1
[ -f "$LIB" ] && . "$LIB" 2>/dev/null

notify() {
    iflag=""; [ -f "$ICON_PUB" ] && iflag="-i file://$ICON_PUB"
    su -lp 2000 -c "cmd notification post $iflag -t '$1' $MODID '$2'" >/dev/null 2>&1
}

cur_interval() { grep '^INTERVAL=' "$CONFIG" 2>/dev/null | cut -d= -f2; }
human() { case "$1" in 3600) echo 1h;; 10800) echo 3h;; 21600) echo 6h;; 43200) echo 12h;; 86400) echo 24h;; *) echo "${1}s";; esac; }

set_interval() {
    secs="$1"
    [ "$secs" -ge 3600 ] 2>/dev/null || secs=3600
    if grep -q '^INTERVAL=' "$CONFIG" 2>/dev/null; then
        sed -i "s/^INTERVAL=.*/INTERVAL=$secs/" "$CONFIG"
    else echo "INTERVAL=$secs" >> "$CONFIG"; fi
    echo "Interval set to $(human "$secs")."
}

# --- target.txt auto-fill ----------------------------------------------------
populate_target() {
    [ -d /data/adb/tricky_store ] || { echo "Tricky Store not installed"; return 1; }
    [ -f "$TS_TARGET" ] && cp -f "$TS_TARGET" "$TS_TARGET.bak" 2>/dev/null
    tmp="$DATA_DIR/target.tmp"
    { echo "com.google.android.gms!"; echo "com.android.vending!"; echo "com.google.android.gsf!"; } > "$tmp"
    pm list packages -3 2>/dev/null | cut -d: -f2 \
        | grep -viE 'magisk|kernelsu|ksun|apatch|lsposed|shamiko|mmrl|zygisk|playintegrity|trickystore|tricky_store' \
        >> "$tmp"
    grep -v '^[[:space:]]*$' "$tmp" | sort -u > "$TS_TARGET"
    chmod 644 "$TS_TARGET"; rm -f "$tmp"
    echo "target.txt now lists $(grep -c . "$TS_TARGET") apps (backup saved)."
}

# packages that commonly enforce Play Integrity -> "recommended" preset
REC_PATTERN='walletnfcrel|paypal|revolut|number26|\.n26|wise|paysafe|satispay|postepay|\.hype|widiba|bank|intesa|unicredit|santander|bbva|monzo|starling|curve|klarna|coinbase|binance|authenticator|\.wallet'
APP_EXCLUDE='magisk|kernelsu|ksun|apatch|lsposed|shamiko|mmrl|zygisk|playintegrity|trickystore|tricky_store'

# JSON list of user apps with recommended + currently-in-target flags (for the WebUI)
list_apps() {
    cur=" $(sed 's/!//g' "$TS_TARGET" 2>/dev/null | tr '\n' ' ') "
    pm list packages -3 2>/dev/null | cut -d: -f2 | grep -viE "$APP_EXCLUDE" | sort \
      | awk -v cur="$cur" -v rec="$REC_PATTERN" '
        BEGIN{printf "["}
        { r=(tolower($0)~rec)?"true":"false"; c=(index(cur," " $0 " ")>0)?"true":"false";
          printf "%s{\"pkg\":\"%s\",\"rec\":%s,\"cur\":%s}",(NR>1?",":""),$0,r,c }
        END{print "]"}'
}

# write target.txt = Google core + the given packages
set_target() {
    [ -d /data/adb/tricky_store ] || { echo "Tricky Store not installed"; return 1; }
    [ -f "$TS_TARGET" ] && cp -f "$TS_TARGET" "$TS_TARGET.bak" 2>/dev/null
    { echo "com.google.android.gms!"; echo "com.android.vending!"; echo "com.google.android.gsf!"
      for p in "$@"; do echo "$p"; done; } | grep -v '^[[:space:]]*$' | sort -u > "$TS_TARGET"
    chmod 644 "$TS_TARGET"
    echo "target.txt now lists $(grep -c . "$TS_TARGET") apps."
}

# --- PIF + apply -------------------------------------------------------------
fix_ts_secpatch() {
    [ -f "$TS_SECPATCH" ] || return 0
    sp="$(grep -m1 '^SECURITY_PATCH=' "$PIF_DIR/custom.pif.prop" 2>/dev/null | cut -d= -f2)"
    case "$sp" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *)
        sp="$(grep -m1 '^boot=' "$TS_SECPATCH" | cut -d= -f2)" ;; esac
    case "$sp" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        printf 'system=%s\nboot=%s\nvendor=%s\n' "$sp" "$sp" "$sp" > "$TS_SECPATCH" ;; esac
}

renew_pif() {
    [ "$RENEW_PIF" = "1" ] || return 0
    [ -f "$PIF_DIR/autopif4.sh" ] || { echo "PIF not found, skipping fingerprint renewal"; return 0; }
    echo "Renewing PIF fingerprint..."
    if (cd "$PIF_DIR" && timeout 150 sh autopif4.sh >/dev/null 2>&1); then
        echo "Fingerprint renewed."; fix_ts_secpatch
    else echo "autopif failed (no network?), keeping current fingerprint."; fi
}

apply_keybox() {
    echo "Seamless apply: keybox + PIF fingerprint + re-attest + reboot"
    if [ -f "$PENDING" ] && grep -q "<AndroidAttestation" "$PENDING" 2>/dev/null; then
        cp -f "$TS_KEYBOX" "$DATA_DIR/keybox.prev.xml" 2>/dev/null
        cp -f "$PENDING" "$TS_KEYBOX" && chmod 644 "$TS_KEYBOX" && rm -f "$PENDING"
        echo "Installed pending keybox."
    fi
    renew_pif
    echo "Clearing Play Integrity caches..."
    pm clear com.google.android.gms >/dev/null 2>&1
    pm clear com.android.vending    >/dev/null 2>&1
    notify "Applying keybox" "Renewed keybox + fingerprint. Rebooting to re-attest."
    echo "Rebooting in 3s (re-login to Play after boot)."
    sleep 3; reboot
}

check_now() {
    command -v kb_refresh_crl >/dev/null 2>&1 || { echo "lib unavailable"; return 1; }
    kb_refresh_crl || { echo "no network / CRL"; return 1; }
    cs="$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)"
    if [ -n "$cs" ] && kb_is_revoked "$cs"; then echo "Active keybox is REVOKED - open Apply."; else echo "Active keybox OK (not revoked)."; fi
}

# --- status ------------------------------------------------------------------
status_json() {
    it="$(cur_interval)"; [ -n "$it" ] || it=21600
    kb="none"; [ -f "$TS_KEYBOX" ] && kb="installed"
    serial=""; rev="false"
    if command -v kb_leaf_serial >/dev/null 2>&1; then
        serial="$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)"
        if [ -n "$serial" ] && [ -s "$CRL_CACHE" ] && kb_is_revoked "$serial"; then rev="true"; fi
    fi
    tc=0; [ -f "$TS_TARGET" ] && tc="$(grep -c . "$TS_TARGET")"
    pif="false"; [ -d "$PIF_DIR" ] && pif="true"
    printf '{"interval":%s,"interval_h":"%s","keybox":"%s","serial":"%s","revoked":%s,"target_count":%s,"pif":%s,"renew_pif":%s}\n' \
        "$it" "$(human "$it")" "$kb" "$serial" "$rev" "$tc" "$pif" "${RENEW_PIF:-1}"
}

# --- WebUI launcher ----------------------------------------------------------
launch_webui() {
    if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
        echo "Opening WebUI in KsuWebUIStandalone..."
        am start -n io.github.a13e300.ksuwebui/.WebUIActivity -e id "$MODID" >/dev/null 2>&1
    elif pm path com.dergoogler.mmrl >/dev/null 2>&1; then
        echo "Opening WebUI in MMRL..."
        am start -n com.dergoogler.mmrl/.ui.activity.webui.WebUIActivity -e MODID "$MODID" >/dev/null 2>&1
    else
        echo "No WebUI host found."
        echo "Install KsuWebUIStandalone (or MMRL) to use the graphical menu,"
        echo "or use the terminal: su -c 'sh /data/adb/$MODID/action.sh <cmd>'"
    fi
}

terminal_menu() {
    while true; do
        echo ""; echo "  === TrickyStore Autofetch ==="
        echo "  1) Change check interval (now: $(human "$(cur_interval)"))"
        echo "  2) Auto-fill target.txt"
        echo "  3) Check now"
        echo "  4) Status"
        echo "  5) Apply (renew + REBOOT)"
        echo "  0) Exit"; printf "  Choose: "
        if ! read c; then return; fi
        case "$c" in
            1) echo "  seconds (3600/10800/21600/43200/86400): "; read s; set_interval "$s" ;;
            2) populate_target ;;
            3) check_now ;;
            4) status_json ;;
            5) apply_keybox ;;
            0|q|"") echo "  bye"; return ;;
            *) echo "  ?" ;;
        esac
    done
}

case "${1:-}" in
    status-json)     status_json ;;
    set-interval)    set_interval "$2" ;;
    populate-target) populate_target ;;
    list-apps)       list_apps ;;
    set-target)      shift; set_target "$@" ;;
    check-now)       check_now ;;
    apply)           apply_keybox ;;
    webui)           launch_webui ;;
    "")              if [ -t 0 ]; then terminal_menu; else launch_webui; fi ;;
    *)               echo "usage: action.sh [status-json|set-interval N|populate-target|list-apps|set-target P...|check-now|apply|webui]" ;;
esac
