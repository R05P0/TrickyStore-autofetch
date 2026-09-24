#!/system/bin/sh
#
# keybox_lib.sh - shared helpers for TrickyStore Autofetch
#
# Design rule (learned the hard way): NEVER modify Tricky Store's own module
# files. We only ever write to $TS_KEYBOX. Touching /data/adb/modules/tricky_store
# trips Tricky Store's integrity self-check and the engine refuses to start.

TS_DIR="/data/adb/tricky_store"
TS_KEYBOX="$TS_DIR/keybox.xml"
DATA_DIR="/data/adb/trickystore_autofetch"
LOG="$DATA_DIR/autofetch.log"
PENDING="$DATA_DIR/pending_keybox.xml"
CRL_CACHE="$DATA_DIR/crl.json"
# Notification icon must live where SystemUI (uid system) can read it; /data/adb
# is root-only, so we publish it to shared storage. service.sh keeps it in place.
ICON_PUB="/sdcard/.trickystore_autofetch_icon.png"
# Small JSON status file for a companion widget app to read. Lives under our
# own root-only data dir (not shared storage) - the widget app reads it via
# `su -c cat ...` (root is already available on this device via Magisk), which
# sidesteps Android 10+ scoped storage entirely. See WIDGET_APP_PACKAGE below:
# if set, we also fire an explicit broadcast so the widget updates instantly
# instead of waiting on Android's slow (min. ~30min) widget poll interval.
WIDGET_STATUS="$DATA_DIR/status.json"
: "${WIDGET_APP_PACKAGE:=}"
# PlayIntegrityFix (autopif4.sh) stamps a "# Estimated Expiry: YYYY-MM-DD"
# comment into custom.pif.prop when it picks a canary build. We read that
# (never write it - PIF_DIR is someone else's module, same rule as TS_DIR).
PIF_DIR="/data/adb/modules/playintegrityfix"
PIF_PROP="$PIF_DIR/custom.pif.prop"

# Source endpoints
URL_YURIKEY="https://raw.githubusercontent.com/Yurii0307/yurikey/main/key"
URL_DDEX="https://raw.githubusercontent.com/dare-devil-ex/keyboxxBot/main/keybox.xml"
# KOWX712 upstream mirror: dead as of 2026-08 (serves 0 bytes). Kept as a known
# name for back-compat; not in the default source list any more.
URL_UPSTREAM="https://raw.githubusercontent.com/KOWX712/Tricky-Addon-Update-Target-List/keybox/.extra"
# Specter keybox catalog (dpejoh) - the best-curated public source: a JSON catalog
# with per-entry serial/revoked/timestamp + a "working"/"latest" summary. We monitor
# it and grab the NEWEST non-revoked key when a genuinely new one is leaked.
URL_SPECTER_CATALOG="https://rawbin.dpejoh.com/catalog"
URL_SPECTER_KEY="https://rawbin.dpejoh.com/key"

# Fallback if config.conf is missing/old (service.sh sources config which sets this)
: "${CRL_URL:=https://android.googleapis.com/attestation/status}"

mkdir -p "$DATA_DIR" 2>/dev/null

kb_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
    # keep the log small
    tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
}

# --- network -----------------------------------------------------------------
kb_download() {
    # $1 = url ; prints body to stdout
    if command -v curl >/dev/null 2>&1; then
        curl --connect-timeout 15 -m 60 -fsSL "$1" 2>/dev/null
    else
        toybox wget -T 15 -qO- "$1" 2>/dev/null
    fi
}

# --- keybox normalisation ----------------------------------------------------
# Sources encode the keybox differently:
#   ddex     : already <AndroidAttestation> XML (raw)
#   yurikey  : base64  -> XML
#   upstream : hex     -> base64 -> XML
#   specter  : shuffled-base64 -> XML (scrambled alphabet)
# Auto-detect by trying each and keeping whatever yields valid XML.
kb_normalise() {
    # stdin = raw source body ; stdout = keybox XML ; returns non-zero on failure
    body="$(cat)"
    case "$body" in *"<AndroidAttestation"*) printf '%s' "$body"; return 0 ;; esac

    clean="$(printf '%s' "$body" | tr -d ' \t\r\n')"
    [ -n "$clean" ] || return 1

    # base64 -> XML
    dec="$(printf '%s' "$clean" | base64 -d 2>/dev/null)"
    case "$dec" in *"<AndroidAttestation"*) printf '%s' "$dec"; return 0 ;; esac

    # hex -> base64 -> XML
    b64="$(printf '%s' "$clean" | tr -dc '0-9a-fA-F' | xxd -r -p 2>/dev/null | tr -d ' \t\r\n')"
    dec2="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    case "$dec2" in *"<AndroidAttestation"*) printf '%s' "$dec2"; return 0 ;; esac

    # Specter shuffled-base64 -> XML (dpejoh's /key endpoint scrambles the b64 alphabet)
    sdec="$(printf '%s' "$clean" \
        | tr '1dgWnocayqxU3r6vA5lCIPYfHmkV08b4tz+KMsp2NQ9LRXihODwSj7BEFJ/ZuGTe' \
             'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' \
        | base64 -d 2>/dev/null)"
    case "$sdec" in *"<AndroidAttestation"*) printf '%s' "$sdec"; return 0 ;; esac

    return 1
}

# Parse Specter's JSON catalog (stdin) and print the NEWEST non-revoked entry as
# "source\tversion\tserial\ttimestamp". Pure sed/grep/sort so it runs under toybox.
kb_specter_pick_newest() {
    sed 's/},{/}\n{/g' \
      | grep '"revoked":false' \
      | while IFS= read -r line; do
            ser=$(printf '%s' "$line" | grep -oE '"serial":"[^"]*"'    | head -1 | sed 's/.*:"//;s/"$//')
            src=$(printf '%s' "$line" | grep -oE '"source":"[^"]*"'    | head -1 | sed 's/.*:"//;s/"$//')
            ver=$(printf '%s' "$line" | grep -oE '"version":"[^"]*"'   | head -1 | sed 's/.*:"//;s/"$//')
            ts=$(printf  '%s' "$line" | grep -oE '"timestamp":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')
            [ -n "$ser" ] || continue
            printf '%s\t%s\t%s\t%s\n' "$ts" "$src" "$ver" "$ser"
        done \
      | sort -r | head -1 \
      | awk -F'\t' '{print $2"\t"$3"\t"$4"\t"$1}'
}

kb_fetch_source() {
    # $1 = source name ; $2 = custom url (optional) ; writes XML to $3
    src="$1"; custom="$2"; out="$3"
    case "$src" in
        yurikey)  url="$URL_YURIKEY" ;;
        ddex)     url="$URL_DDEX" ;;
        upstream) url="$URL_UPSTREAM" ;;
        specter)
            catj="$(kb_download "$URL_SPECTER_CATALOG")"
            [ -n "$catj" ] || { kb_log "specter: empty catalog"; return 1; }
            newest="$(printf '%s' "$catj" | kb_specter_pick_newest)"
            [ -n "$newest" ] || { kb_log "specter: no non-revoked entry"; return 1; }
            n_src="$(printf '%s' "$newest" | cut -f1)"
            n_ver="$(printf '%s' "$newest" | cut -f2)"
            n_ser="$(printf '%s' "$newest" | cut -f3)"
            cur_ser="$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)"
            if [ -n "$cur_ser" ] && [ "$n_ser" = "$cur_ser" ]; then
                kb_log "specter: newest non-revoked ($n_src/$n_ver serial=$n_ser) == current; nothing new"
                return 1
            fi
            kb_log "specter: NEW candidate $n_src/$n_ver serial=$n_ser (current=$cur_ser)"
            url="$URL_SPECTER_KEY/$n_src/$n_ver"
            ;;
        custom)   url="$custom" ;;
        *) kb_log "unknown source '$src'"; return 1 ;;
    esac
    [ -n "$url" ] || { kb_log "source '$src' has no url"; return 1; }
    kb_download "$url" | kb_normalise > "$out" 2>/dev/null
    [ -s "$out" ] || { kb_log "source '$src' returned nothing"; return 1; }
    return 0
}

# --- validation --------------------------------------------------------------
kb_structural_ok() {
    # $1 = xml file. Floor check: looks like a real keybox.
    f="$1"
    [ -s "$f" ] || return 1
    grep -q "<AndroidAttestation" "$f" || return 1
    grep -q "<Keybox"             "$f" || return 1
    grep -q "<PrivateKey"         "$f" || return 1
    grep -q "<Certificate format" "$f" || return 1
    return 0
}

# Extract the leaf (first) certificate serial number as lowercase hex.
kb_leaf_serial() {
    # $1 = xml file ; prints hex serial or nothing
    awk '/<Certificate format/{if(s){exit}s=1;next} /<\/Certificate>/{if(s)exit} s' "$1" \
        | grep -vE 'BEGIN|END' | tr -d ' \t\r\n' | base64 -d 2>/dev/null | xxd -p 2>/dev/null | tr -d '\n' \
        | awk '
            function hv(c){return index("0123456789abcdef",tolower(c))-1}
            function rb(){v=hv(substr(H,p,1))*16+hv(substr(H,p+1,1));p+=2;return v}
            function rlen(){l=rb();if(l<128)return l;n=l-128;L=0;for(i=0;i<n;i++)L=L*256+rb();return L}
            { H=$0; if(length(H)<8) exit; p=1
              rb();rlen()                       # Certificate SEQUENCE
              rb();rlen()                       # tbsCertificate SEQUENCE
              t=rb()
              if(t==160){vl=rlen();p+=vl*2;t=rb()}   # skip [0] EXPLICIT version
              if(t!=2) exit                     # expect INTEGER serialNumber
              sl=rlen(); s=""
              for(i=0;i<sl;i++){s=s substr(H,p,1) substr(H,p+1,1);p+=2}
              sub(/^0+/,"",s); print tolower(s) }'
}

kb_refresh_crl() {
    # Download the CRL to cache; keep old cache on failure. Returns 0 if usable.
    tmp="$CRL_CACHE.tmp"
    if kb_download "$CRL_URL" > "$tmp" 2>/dev/null && grep -q '"entries"' "$tmp"; then
        mv "$tmp" "$CRL_CACHE"; return 0
    fi
    rm -f "$tmp"
    [ -s "$CRL_CACHE" ] && return 0    # fall back to previous cache
    return 1
}

kb_is_revoked() {
    # $1 = hex serial ; returns 0 (true) if serial is in the CRL
    serial="$1"
    [ -n "$serial" ] || return 1
    [ -s "$CRL_CACHE" ] || return 1
    grep -q "\"$serial\"" "$CRL_CACHE"
}

# --- notification (best effort) ---------------------------------------------
kb_notify() {
    # $1 = title ; $2 = text ; $3 = optional tag suffix
    # Must post as the shell uid (2000 / com.android.shell). Posting as root
    # (uid 0) is accepted by 'cmd' but never actually registers or displays.
    # A repeated call with the SAME tag silently updates the existing shade
    # entry instead of posting a new one - easy to miss over a multi-day
    # revoked-keybox reminder. Pass $3 (e.g. today's date) to force a fresh,
    # separately-alerting notification while the underlying state persists.
    iflag=""
    [ -f "$ICON_PUB" ] && iflag="-i file://$ICON_PUB"
    tag="trickystore_autofetch"
    [ -n "$3" ] && tag="${tag}_$3"
    su -lp 2000 -c "cmd notification post $iflag -t '$1' $tag '$2'" >/dev/null 2>&1
    kb_log "NOTIFY: $1 - $2"
}

# --- PIF fingerprint expiry (best effort, on-device only) --------------------
# Prints days left (may be negative) on stdout, returns 1 if unknown/not
# applicable (PIF not installed, or its prop has no expiry stamp - e.g. a
# manually-set non-canary fingerprint). No network involved, pure local read.
kb_pif_days_left() {
    [ -f "$PIF_PROP" ] || return 1
    exp_date="$(grep -m1 '^# Estimated Expiry:' "$PIF_PROP" 2>/dev/null | sed 's/^# Estimated Expiry: *//')"
    [ -n "$exp_date" ] || return 1
    exp_epoch="$(date -d "$exp_date" +%s 2>/dev/null)"
    [ -n "$exp_epoch" ] || return 1
    echo $(( (exp_epoch - $(date +%s)) / 86400 ))
}

# Notify once per day (tag = today's
# date) while within the warn window, and again (differently worded) once
# it's actually expired. $1 = warn window in days (default 5).
kb_check_pif_expiry() {
    window="${1:-5}"
    left_days="$(kb_pif_days_left)" || return 0
    if [ "$left_days" -lt 0 ]; then
        kb_notify "PIF fingerprint expired" "The spoofed build expired $(( -left_days )) day(s) ago. Play Integrity may start failing - run Apply (or enable RENEW_PIF) to fetch a fresh one." "$(date +%Y%m%d)"
    elif [ "$left_days" -le "$window" ]; then
        kb_notify "PIF fingerprint expiring soon" "The spoofed build expires in $left_days day(s). Run Apply soon to renew it." "$(date +%Y%m%d)"
    fi
}

# --- widget status file (best effort) -----------------------------------------
# Written after every check cycle for a home-screen widget (e.g. KWGT) to read.
# $1 = status: ok | revoked | missing | error
# $2 = keybox serial (may be empty)
# $3 = short human note
# $4 = candidate_ready: "true" when a replacement keybox is waiting for the user
#      to tap Apply (only meaningful with status=revoked); anything else -> false.
#      Always emitted, so the widget can rely on the field being present.
kb_write_widget_status() {
    st="$1"; ser="$2"; note="$3"
    cand_ready="false"; [ "$4" = "true" ] && cand_ready="true"
    ser_short=""
    [ -n "$ser" ] && ser_short="$(printf '%s' "$ser" | cut -c1-10)"
    pif_days="$(kb_pif_days_left 2>/dev/null)"
    [ -n "$pif_days" ] || pif_days="null"
    tmp="$WIDGET_STATUS.tmp"
    printf '{"status":"%s","serial_short":"%s","note":"%s","last_check":"%s","pif_days_left":%s,"candidate_ready":%s}\n' \
        "$st" "$ser_short" "$note" "$(date '+%d/%m %H:%M')" "$pif_days" "$cand_ready" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$WIDGET_STATUS" 2>/dev/null
    # Explicit target (-p) required: implicit broadcasts to manifest receivers
    # are blocked since Android 8 unless targeted at a specific package. No-ops
    # quietly (2>/dev/null) if WIDGET_APP_PACKAGE is unset or app isn't installed.
    [ -n "$WIDGET_APP_PACKAGE" ] && am broadcast -a "${WIDGET_APP_PACKAGE}.STATUS_UPDATED" -p "$WIDGET_APP_PACKAGE" >/dev/null 2>&1
}

# --- install -----------------------------------------------------------------
kb_install() {
    # $1 = validated xml file -> becomes the active keybox
    src="$1"
    [ -f "$TS_KEYBOX" ] && cp -f "$TS_KEYBOX" "$DATA_DIR/keybox.prev.xml" 2>/dev/null
    cp -f "$src" "$TS_KEYBOX" && chmod 644 "$TS_KEYBOX"
    kb_log "installed new keybox -> $TS_KEYBOX"
}
