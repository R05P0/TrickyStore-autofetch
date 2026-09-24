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
#   action.sh list-sources | set-sources S... | add-source NAME URL [HEADER]
#   action.sh remove-source NAME | test-url URL [HEADER] | test-source NAME
#
# Nothing here touches Tricky Store's module files - only keybox.xml / target.txt
# / security_patch.txt and our own config.

MODID="trickystore_autofetch"
# Paths can be pre-set by the caller (the test harness uses a sandbox); on the
# device nothing sets them, so the defaults apply.
: "${DATA_DIR:=/data/adb/$MODID}"
: "${TS_DIR:=/data/adb/tricky_store}"
CONFIG="$DATA_DIR/config.conf"
: "${LIB:=/data/adb/modules/$MODID/scripts/keybox_lib.sh}"
: "${TS_KEYBOX:=$TS_DIR/keybox.xml}"
TS_SECPATCH="$TS_DIR/security_patch.txt"
TS_TARGET="$TS_DIR/target.txt"
PENDING="$DATA_DIR/pending_keybox.xml"
: "${PIF_DIR:=/data/adb/modules/playintegrityfix}"
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
    [ -d "$TS_DIR" ] || { echo "Tricky Store not installed"; return 1; }
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

# --- keybox sources -----------------------------------------------------------
cur_sources() { grep '^SOURCES=' "$CONFIG" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

# One JSON object per line, each starting with a comma (list_sources strips the
# first one). $1 name $2 label $3 desc $4 enabled $5 priority(0 = not enabled)
src_json() {
    cflag=false; hflag=false
    if [ -s "$CUSTOM_LIST" ] && awk -F'\t' -v n="$1" '$1==n{f=1} END{exit !f}' "$CUSTOM_LIST"; then
        cflag=true
        [ -n "$(awk -F'\t' -v n="$1" '$1==n{print $3; exit}' "$CUSTOM_LIST")" ] && hflag=true
    fi
    printf ',{"name":"%s","label":"%s","desc":"%s","enabled":%s,"prio":%s,"custom":%s,"hdr":%s}\n' \
        "$1" "$2" "$3" "$4" "$5" "$cflag" "$hflag"
}

# JSON list of known sources (for the WebUI): enabled ones first, in the order
# service.sh tries them (prio 1..n), then the disabled ones. Data comes from
# kb_known_sources in keybox_lib.sh. Custom sources also carry "custom":true
# (deletable) and "hdr":true (has an auth header - the value is never printed).
list_sources() {
    command -v kb_known_sources >/dev/null 2>&1 || { echo "[]"; return; }
    known="$(kb_known_sources)"
    curs=" $(cur_sources | tr -s ' ') "
    tab="$(printf '\t')"
    {
        n=0
        for name in $(cur_sources); do
            line="$(printf '%s\n' "$known" | awk -F'\t' -v n="$name" '$1==n{print; exit}')"
            [ -n "$line" ] || continue
            n=$((n+1))
            label="$(printf '%s' "$line" | cut -f2)"; desc="$(printf '%s' "$line" | cut -f3)"
            src_json "$name" "$label" "$desc" true "$n"
        done
        printf '%s\n' "$known" | while IFS="$tab" read -r name label desc; do
            [ -n "$name" ] || continue
            case "$curs" in *" $name "*) continue ;; esac
            src_json "$name" "$label" "$desc" false 0
        done
    } | sed '1s/^,//' | tr -d '\n' | { printf '['; cat; printf ']\n'; }
}

# write SOURCES = the given source names, in the order given (this becomes
# the try-order in service.sh)
set_sources() {
    [ $# -gt 0 ] || { echo "no sources given (at least one required)"; return 1; }
    for nm in "$@"; do
        case "$nm" in ''|*[!a-z0-9_-]*) echo "invalid source name: $nm"; return 1 ;; esac
    done
    val="$*"
    if grep -q '^SOURCES=' "$CONFIG" 2>/dev/null; then
        sed -i "s/^SOURCES=.*/SOURCES=\"$val\"/" "$CONFIG"
    else
        echo "SOURCES=\"$val\"" >> "$CONFIG"
    fi
    echo "Sources set to: $val"
}

# Field validation shared by add-source and test-url. Fields end up in a TAB
# separated file, in JSON and in curl arguments, so keep them boring: no
# whitespace/control chars, no quotes, no backslash/backtick.
bad_chars() {
    case "$1" in
        *[[:space:]]*|*\"*|*\'*|*\\*|*\`*) return 0 ;;
    esac
    return 1
}
check_url() {
    case "$1" in https://?*) ;; *) echo "URL must start with https://"; return 1 ;; esac
    if bad_chars "$1"; then echo "URL contains spaces or quote characters"; return 1; fi
    return 0
}
# header is optional: "Name: value" (the value may contain spaces, not quotes)
check_header() {
    [ -n "$1" ] || return 0
    case "$1" in *[![:print:]]*) echo "header contains control characters"; return 1 ;; esac
    case "$1" in *\"*|*\'*|*\\*|*\`*) echo "header contains quote characters"; return 1 ;; esac
    printf '%s' "$1" | grep -qE '^[A-Za-z0-9-]+: [^[:space:]]' || { echo "header must look like 'Name: value'"; return 1; }
    return 0
}

add_source() {
    name="$1"; url="$2"; hdr="$3"
    case "$name" in
        ''|[!a-z0-9]*|*[!a-z0-9_-]*) echo "invalid name: use a-z, 0-9, - or _ (must start with a letter/digit)"; return 1 ;;
    esac
    [ "${#name}" -le 24 ] || { echo "name too long (max 24 characters)"; return 1; }
    check_url "$url" || return 1
    check_header "$hdr" || return 1
    if kb_known_sources | cut -f1 | grep -qx "$name"; then echo "a source named '$name' already exists"; return 1; fi
    [ "$(grep -c . "$CUSTOM_LIST" 2>/dev/null)" -lt 20 ] 2>/dev/null || [ ! -s "$CUSTOM_LIST" ] || { echo "too many custom sources (max 20)"; return 1; }
    printf '%s\t%s\t%s\n' "$name" "$url" "$hdr" >> "$CUSTOM_LIST"
    chmod 600 "$CUSTOM_LIST" 2>/dev/null   # may hold an API key in the header
    # enable it right away, lowest priority
    cur="$(cur_sources | tr -s ' ')"
    set_sources $cur "$name" >/dev/null
    echo "Added '$name' (enabled, tried last)."
}

remove_source() {
    name="$1"
    [ -s "$CUSTOM_LIST" ] && awk -F'\t' -v n="$name" '$1==n{f=1} END{exit !f}' "$CUSTOM_LIST" \
        || { echo "'$name' is not a custom source"; return 1; }
    rest=""
    for x in $(cur_sources); do [ "$x" = "$name" ] || rest="$rest $x"; done
    [ -n "$rest" ] || { echo "it's the only enabled source - enable another one first"; return 1; }
    awk -F'\t' -v n="$name" '$1!=n' "$CUSTOM_LIST" > "$CUSTOM_LIST.tmp" && mv -f "$CUSTOM_LIST.tmp" "$CUSTOM_LIST"
    chmod 600 "$CUSTOM_LIST" 2>/dev/null
    set_sources $rest >/dev/null
    echo "Removed '$name'."
}

# Dry run: fetch + decode + validate a candidate and report, without installing
# anything. The candidate file (it holds a private key) is deleted right after.
# $1 = mode (url|source) ; url mode: $2 url, $3 header ; source mode: $2 name
test_candidate() {
    mode="$1"
    tmp="$DATA_DIR/test_candidate.xml"; rm -f "$tmp"
    if [ "$mode" = url ]; then
        check_url "$2" || return 1
        check_header "$3" || return 1
        KB_EXTRA_HEADER="$3"; kb_fetch_url "$2" "$tmp" test; got=$?; KB_EXTRA_HEADER=""
    else
        kb_fetch_source "$2" "$CUSTOM_URL" "$tmp"; got=$?
    fi
    if [ "$got" -ne 0 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "FAIL: nothing usable came back (bad URL/auth, or the source has nothing new). See autofetch.log."
        return 1
    fi
    if ! kb_structural_ok "$tmp"; then
        rm -f "$tmp"; echo "FAIL: downloaded, but it doesn't look like a keybox."; return 1
    fi
    ser="$(kb_leaf_serial "$tmp")"
    cur="$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)"
    rm -f "$tmp"
    [ -n "$ser" ] || { echo "FAIL: keybox found but the certificate serial is unreadable."; return 1; }
    echo "keybox OK, serial $(printf '%s' "$ser" | cut -c1-10)..."
    kb_refresh_crl >/dev/null 2>&1
    if kb_is_revoked "$ser"; then echo "REVOKED in Google's list - useless."; return 1; fi
    if [ -s "$CRL_CACHE" ]; then echo "not revoked."; else echo "(no CRL available, revocation not checked)"; fi
    if [ -n "$cur" ] && [ "$ser" = "$cur" ]; then echo "same key as the active one (fine, but nothing to gain)."; fi
    echo "USABLE."
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
    [ -d "$TS_DIR" ] || { echo "Tricky Store not installed"; return 1; }
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
        # Tag::OS_PATCHLEVEL vuole YYYYMM; vendor/boot patch level vogliono YYYYMMDD.
        printf 'system=%s\nboot=%s\nvendor=%s\n' "$(echo "$sp" | cut -c1-7 | tr -d -)" "$sp" "$sp" > "$TS_SECPATCH" ;; esac
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

# Also refreshes status.json (+ widget broadcast): the companion widget's refresh
# button runs this and re-reads that file, so a check that didn't write it would
# look like a no-op. Only checks - it never fetches/installs a replacement; that
# stays the background loop's job. If the loop already staged one ($PENDING), we
# report it as candidate_ready instead of clobbering that state with a bare "revoked".
check_now() {
    command -v kb_refresh_crl >/dev/null 2>&1 || { echo "lib unavailable"; return 1; }
    cs="$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)"
    if ! kb_refresh_crl; then
        kb_write_widget_status "error" "$cs" "No network / CRL unavailable"
        echo "no network / CRL"; return 1
    fi
    if [ -n "$cs" ] && kb_is_revoked "$cs"; then
        if [ -f "$PENDING" ] && grep -q "<AndroidAttestation" "$PENDING" 2>/dev/null; then
            kb_write_widget_status "revoked" "$cs" "Replacement ready, tap Apply" true
        else
            kb_write_widget_status "revoked" "$cs" "Revoked, no replacement staged yet"
        fi
        echo "Active keybox is REVOKED - open Apply."
    elif [ -n "$cs" ]; then
        kb_write_widget_status "ok" "$cs" "OK"
        echo "Active keybox OK (not revoked)."
    else
        kb_write_widget_status "missing" "" "No active keybox installed"
        echo "No active keybox installed."
    fi
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
    sc=0; sc="$(cur_sources | wc -w | tr -d ' ')"
    keyinfo="null"
    if command -v kb_private_status_extra >/dev/null 2>&1; then
        ke="$(kb_private_status_extra 2>/dev/null)"; [ -n "$ke" ] && keyinfo="$ke"
    fi
    pifdays="null"
    if command -v kb_pif_days_left >/dev/null 2>&1; then
        pd="$(kb_pif_days_left 2>/dev/null)"; [ -n "$pd" ] && pifdays="$pd"
    fi
    printf '{"interval":%s,"interval_h":"%s","keybox":"%s","serial":"%s","revoked":%s,"target_count":%s,"pif":%s,"renew_pif":%s,"source_count":%s,"key_info":%s,"pif_days_left":%s}\n' \
        "$it" "$(human "$it")" "$kb" "$serial" "$rev" "$tc" "$pif" "${RENEW_PIF:-1}" "$sc" "$keyinfo" "$pifdays"
}

# Opens the renewal page of a gated source (only if the private sources file
# provides one). Runs as root: a direct `am start`, not a notification intent.
open_renew() {
    if command -v kb_private_renew >/dev/null 2>&1; then kb_private_renew
    else echo "No renewal page configured."; fi
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
        echo "  6) Keybox sources"
        echo "  0) Exit"; printf "  Choose: "
        if ! read c; then return; fi
        case "$c" in
            1) echo "  seconds (3600/10800/21600/43200/86400): "; read s; set_interval "$s" ;;
            2) populate_target ;;
            3) check_now ;;
            4) status_json ;;
            5) apply_keybox ;;
            6) list_sources ;;
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
    list-sources)    list_sources ;;
    set-sources)     shift; set_sources "$@" ;;
    add-source)      add_source "$2" "$3" "$4" ;;
    remove-source)   remove_source "$2" ;;
    test-url)        test_candidate url "$2" "$3" ;;
    test-source)     test_candidate source "$2" ;;
    open-renew)      open_renew ;;
    check-now)       check_now ;;
    apply)           apply_keybox ;;
    webui)           launch_webui ;;
    "")              if [ -t 0 ]; then terminal_menu; else launch_webui; fi ;;
    *)               echo "usage: action.sh [status-json|set-interval N|populate-target|list-apps|set-target P...|list-sources|set-sources S...|add-source NAME URL [HEADER]|remove-source NAME|test-url URL [HEADER]|test-source NAME|open-renew|check-now|apply|webui]" ;;
esac
