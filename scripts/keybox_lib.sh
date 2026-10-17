#!/system/bin/sh
#
# keybox_lib.sh - shared helpers for TrickyStore Autofetch
#
# Design rule (learned the hard way): NEVER modify Tricky Store's own module
# files. We only ever write to $TS_KEYBOX. Touching /data/adb/modules/tricky_store
# trips Tricky Store's integrity self-check and the engine refuses to start.

# Paths can be pre-set by the caller (the test harness points them at a sandbox);
# on the device nothing sets them, so the defaults apply.
: "${TS_DIR:=/data/adb/tricky_store}"
: "${TS_KEYBOX:=$TS_DIR/keybox.xml}"
: "${DATA_DIR:=/data/adb/trickystore_autofetch}"
LOG="$DATA_DIR/autofetch.log"
PENDING="$DATA_DIR/pending_keybox.xml"
CRL_CACHE="$DATA_DIR/crl.json"
# User-added sources (WebUI "Add source"): one per line, TAB separated:
#   name <TAB> https-url <TAB> optional "Header-Name: value" (e.g. an API key)
CUSTOM_LIST="$DATA_DIR/custom_sources.list"
# Optional private sources, deployed separately and NOT in the public repo/zip.
PRIVATE_LIB="$DATA_DIR/sources_private.sh"
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
: "${PIF_DIR:=/data/adb/modules/playintegrityfix}"
PIF_PROP="$PIF_DIR/custom.pif.prop"

# Source endpoints
URL_YURIKEY="https://raw.githubusercontent.com/Yurii0307/yurikey/main/key"
URL_DDEX="https://raw.githubusercontent.com/dare-devil-ex/keyboxxBot/main/keybox.xml"

# Fallback if config.conf is missing/old (service.sh sources config which sets this)
: "${CRL_URL:=https://android.googleapis.com/attestation/status}"

mkdir -p "$DATA_DIR" 2>/dev/null

# Known sources for the WebUI's "Keybox sources" card: name, short label,
# description (tab separated, one per line). Built-ins first, then the user's
# custom sources, then whatever the optional private file adds.
kb_known_sources() {
    printf '%s\t%s\t%s\n' \
        ddex    "DareDevilEx" "Different key (DeviceID wkaie), cert valid to 2030. Good fallback when others are revoked." \
        yurikey "Yurikey"     "The original default key (serial 3207...)."
    # Legacy single URL from config.conf (before the WebUI could add sources).
    [ -n "$CUSTOM_URL" ] && printf '%s\t%s\t%s\n' custom "Custom URL" "Legacy CUSTOM_URL from config.conf."
    if [ -s "$CUSTOM_LIST" ]; then
        while IFS="$(printf '\t')" read -r cn cu ch; do
            [ -n "$cn" ] || continue
            printf '%s\t%s\t%s\n' "$cn" "$cn" "$cu"
        done < "$CUSTOM_LIST"
    fi
    if command -v kb_private_known_sources >/dev/null 2>&1; then kb_private_known_sources; fi
}

# Print "url<TAB>header" for a custom source, nothing if there is no such source.
kb_custom_get() {
    [ -s "$CUSTOM_LIST" ] || return 0
    awk -F'\t' -v n="$1" '$1==n{print $2 "\t" $3; exit}' "$CUSTOM_LIST"
}

kb_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
    # keep the log small
    tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
}

# --- network -----------------------------------------------------------------
kb_download() {
    # $1 = url ; prints body to stdout
    # If $KB_EXTRA_HEADER is set ("Name: value"), it's sent as an extra header -
    # used for API-key-gated sources. Callers must clear it after use (see
    # kb_fetch_source, which resets it at the top of every call).
    if command -v curl >/dev/null 2>&1; then
        curl --connect-timeout 15 -m 60 -fsSL ${KB_EXTRA_HEADER:+-H "$KB_EXTRA_HEADER"} "$1" 2>/dev/null
    else
        toybox wget -T 15 -qO- "$1" 2>/dev/null
    fi
}

# --- keybox normalisation ----------------------------------------------------
# Sources encode the keybox differently:
#   ddex     : already <AndroidAttestation> XML (raw)
#   yurikey  : base64  -> XML
#   others   : hex     -> base64 -> XML
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

    return 1
}

# Download URL ($1), decode whatever encoding it uses, write the XML to $2.
# $3 = label for the log. Uses $KB_EXTRA_HEADER if set.
kb_fetch_url() {
    url="$1"; out="$2"; label="${3:-source}"
    [ -n "$url" ] || { kb_log "source '$label' has no url"; return 1; }
    kb_download "$url" | kb_normalise > "$out" 2>/dev/null
    [ -s "$out" ] || { kb_log "source '$label' returned nothing"; return 1; }
    return 0
}

kb_fetch_source() {
    # $1 = source name ; $2 = legacy CUSTOM_URL (optional) ; writes XML to $3
    src="$1"; custom="$2"; out="$3"
    KB_EXTRA_HEADER=""    # reset every call - only sources with a header set it
    url=""
    case "$src" in
        yurikey)  url="$URL_YURIKEY" ;;
        ddex)     url="$URL_DDEX" ;;
        custom)   url="$custom" ;;
        *)
            # 1) optional private sources  2) user-added custom sources
            if command -v kb_private_fetch >/dev/null 2>&1; then
                kb_private_fetch "$src" "$out"; prc=$?
                [ "$prc" -eq 127 ] || return "$prc"
            fi
            entry="$(kb_custom_get "$src")"
            if [ -z "$entry" ]; then kb_log "unknown source '$src'"; return 1; fi
            url="$(printf '%s' "$entry" | cut -f1)"
            KB_EXTRA_HEADER="$(printf '%s' "$entry" | cut -f2)"
            ;;
    esac
    kb_fetch_url "$url" "$out" "$src"
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

# Extract the leaf (first) certificate's notAfter date as "YYYY-MM-DD" (UTC).
# Same DER walk as kb_leaf_serial, but continues past the serialNumber through
# signature + issuer into the validity SEQUENCE and reads notAfter. Handles both
# UTCTime (0x17, years < 2050) and GeneralizedTime (0x18). Date-only output on
# purpose: it feeds `date -d`, exactly like kb_pif_days_left's expiry stamp, and
# day granularity is all the warn/rotate logic needs. Prints nothing if the cert
# can't be parsed (caller treats "unknown expiry" as "don't act on expiry").
kb_leaf_notafter() {
    # $1 = xml file ; prints YYYY-MM-DD or nothing
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
              if(t!=2) exit                     # INTEGER serialNumber
              sl=rlen(); p+=sl*2                 # skip serial value
              t=rb(); al=rlen(); p+=al*2         # skip signature AlgorithmIdentifier
              t=rb(); il=rlen(); p+=il*2         # skip issuer Name
              t=rb(); if(t!=48) exit             # validity must be SEQUENCE (0x30)
              rlen()                             # descend into validity (do not skip)
              t=rb(); nbl=rlen(); p+=nbl*2       # skip notBefore Time
              t=rb(); nal=rlen()                 # notAfter Time
              if(t!=23 && t!=24) exit            # 0x17 UTCTime / 0x18 GeneralizedTime
              d=""
              for(i=0;i<nal;i++){b=rb(); if(b>=48 && b<=57) d=d sprintf("%d",b-48)}
              if(t==23){ yy=substr(d,1,2)+0; pre=(yy>=50)?"19":"20"; yr=pre substr(d,1,2); r=substr(d,3) }
              else { yr=substr(d,1,4); r=substr(d,5) }
              if(length(yr)<4 || length(r)<4) exit
              printf "%s-%s-%s\n", yr, substr(r,1,2), substr(r,3,2) }'
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

# --- keybox leaf-cert expiry (best effort, on-device only) -------------------
# The leaf attestation cert has a fixed notAfter; once past it, DEVICE/STRONG
# attestation fails even though the serial is NOT in Google's CRL (expiry !=
# revocation - the old code only ever checked the CRL, so an expired-but-not-
# revoked keybox read as "ok" and nothing warned). Pure local cert read, no
# network - mirrors kb_pif_days_left so it can run even when the CRL is offline.
# Prints days left (may be negative), returns 1 if the expiry can't be read.
kb_leaf_days_left() {
    # $1 = keybox xml file ; prints integer days (may be negative) or nothing
    d="$(kb_leaf_notafter "$1")"
    [ -n "$d" ] || return 1
    exp_epoch="$(date -d "$d" +%s 2>/dev/null)"
    [ -n "$exp_epoch" ] || return 1
    echo $(( (exp_epoch - $(date +%s)) / 86400 ))
}

# Notify once per day (tag = today's date) while the active keybox's leaf cert
# is within the warn window, and again (differently worded) once it has lapsed.
# $1 = keybox xml (default $TS_KEYBOX) ; $2 = warn window in days (default
# $EXPIRY_WARN_DAYS or 14). The actual rotation to a fresh keybox is driven by
# service.sh's run_once (it needs the CRL to vet the replacement); this only
# surfaces the warning, independent of network, exactly like the PIF check.
kb_check_keybox_expiry() {
    kbf="${1:-$TS_KEYBOX}"
    window="${2:-${EXPIRY_WARN_DAYS:-14}}"
    left_days="$(kb_leaf_days_left "$kbf")" || return 0
    if [ "$left_days" -lt 0 ]; then
        kb_notify "Keybox certificate expired" "The active keybox's attestation certificate expired $(( -left_days )) day(s) ago. DEVICE/STRONG attestation will fail until it's replaced - a fresh keybox is fetched automatically, or rotate one from the WebUI." "$(date +%Y%m%d)"
    elif [ "$left_days" -le "$window" ]; then
        kb_notify "Keybox certificate expiring soon" "The active keybox's attestation certificate expires in $left_days day(s). A fresh keybox will be fetched automatically when it lapses; you can rotate early from the WebUI." "$(date +%Y%m%d)"
    fi
}

# --- widget status file (best effort) -----------------------------------------
# Written after every check cycle for a home-screen widget (e.g. KWGT) to read.
# $1 = status: ok | expiring | revoked | expired | missing | error
#      (expiring = valid but inside the expiry warn window; expired = leaf cert
#      past notAfter, as useless as revoked)
# $2 = keybox serial (may be empty)
# $3 = short human note
# $4 = candidate_ready: "true" when a replacement keybox is waiting for the user
#      to tap Apply (meaningful with status=revoked or expired); else -> false.
#      Always emitted, so the widget can rely on the field being present.
# keybox_days_left: int days until the leaf cert's notAfter (negative = expired),
#      or null when it can't be read. Added field; older widgets ignore it.
kb_write_widget_status() {
    st="$1"; ser="$2"; note="$3"
    cand_ready="false"; [ "$4" = "true" ] && cand_ready="true"
    ser_short=""
    [ -n "$ser" ] && ser_short="$(printf '%s' "$ser" | cut -c1-10)"
    pif_days="$(kb_pif_days_left 2>/dev/null)"
    [ -n "$pif_days" ] || pif_days="null"
    kb_days="$(kb_leaf_days_left "$TS_KEYBOX" 2>/dev/null)"
    [ -n "$kb_days" ] || kb_days="null"
    tmp="$WIDGET_STATUS.tmp"
    printf '{"status":"%s","serial_short":"%s","note":"%s","last_check":"%s","pif_days_left":%s,"keybox_days_left":%s,"candidate_ready":%s}\n' \
        "$st" "$ser_short" "$note" "$(date '+%d/%m %H:%M')" "$pif_days" "$kb_days" "$cand_ready" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$WIDGET_STATUS" 2>/dev/null
    # Explicit target (-p) required: implicit broadcasts to manifest receivers
    # are blocked since Android 8 unless targeted at a specific package. No-ops
    # quietly (2>/dev/null) if WIDGET_APP_PACKAGE is unset or app isn't installed.
    kb_widget_broadcast "$WIDGET_APP_PACKAGE"
}

# Fire-and-forget: `am broadcast` waits until the receiver has finished. When the
# widget app itself runs us (its refresh button / WebUI run check-now through its
# root shell), its receiver needs that same shell to re-read status.json, so a
# waiting broadcast deadlocks both until the broadcast times out. Backgrounded
# (not `--async`, which older Android lacks) and with stdin from /dev/null so
# `cmd` can't eat the caller's shell input.
kb_widget_broadcast() {
    [ -n "$1" ] || return 0
    am broadcast -a "$1.STATUS_UPDATED" -p "$1" </dev/null >/dev/null 2>&1 &
}

# --- companion widget app ----------------------------------------------------
# A small home-screen widget app (TSA Companion) reads status.json. The module
# invites the user to install it (WebUI banner) and, once it is installed, points
# WIDGET_APP_PACKAGE at it so the refresh broadcast reaches it.
: "${COMPANION_PKG:=dev.r05p0.tsacompanion}"
: "${COMPANION_URL:=https://github.com/R05P0/TSA-companion/releases/latest}"
COMPANION_DISMISSED="$DATA_DIR/companion_dismissed"

kb_pkg_installed() { [ -n "$1" ] && pm path "$1" >/dev/null 2>&1; }

# Set WIDGET_APP_PACKAGE to the companion when it is installed, unless a widget
# app that is still installed is already configured (a custom/third-party one).
# Returns 0 if the companion is installed (linked or left as configured), 1 if not.
kb_companion_sync() {
    case "$COMPANION_PKG" in ''|*[!a-zA-Z0-9._]*) return 1 ;; esac
    kb_pkg_installed "$COMPANION_PKG" || return 1
    [ "$WIDGET_APP_PACKAGE" = "$COMPANION_PKG" ] && return 0
    if [ -n "$WIDGET_APP_PACKAGE" ] && kb_pkg_installed "$WIDGET_APP_PACKAGE"; then return 0; fi
    cfg="$DATA_DIR/config.conf"
    if grep -q '^WIDGET_APP_PACKAGE=' "$cfg" 2>/dev/null; then
        sed -i "s/^WIDGET_APP_PACKAGE=.*/WIDGET_APP_PACKAGE=\"$COMPANION_PKG\"/" "$cfg"
    else
        echo "WIDGET_APP_PACKAGE=\"$COMPANION_PKG\"" >> "$cfg"
    fi
    WIDGET_APP_PACKAGE="$COMPANION_PKG"
    kb_log "companion app installed - WIDGET_APP_PACKAGE set to $COMPANION_PKG"
    kb_widget_broadcast "$COMPANION_PKG"
    return 0
}

# --- install -----------------------------------------------------------------
kb_install() {
    # $1 = validated xml file -> becomes the active keybox
    src="$1"
    [ -f "$TS_KEYBOX" ] && cp -f "$TS_KEYBOX" "$DATA_DIR/keybox.prev.xml" 2>/dev/null
    cp -f "$src" "$TS_KEYBOX" && chmod 644 "$TS_KEYBOX"
    kb_log "installed new keybox -> $TS_KEYBOX"
}

# --- optional private sources ---------------------------------------------------
# Loaded last so it can rely on everything above. The `sh -n` guard means a
# broken file is skipped instead of aborting the shell that sources us.
if [ -f "$PRIVATE_LIB" ] && sh -n "$PRIVATE_LIB" 2>/dev/null; then
    . "$PRIVATE_LIB"
fi
