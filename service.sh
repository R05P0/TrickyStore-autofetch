#!/system/bin/sh
#
# service.sh - late_start service. Runs the background check/rotate loop.

MODDIR=${0%/*}
DATA_DIR="/data/adb/keybox_autofetch"
mkdir -p "$DATA_DIR"

# Seed persistent config on first run (survives module updates).
[ -f "$DATA_DIR/config.conf" ] || cp -f "$MODDIR/config.conf" "$DATA_DIR/config.conf"

. "$MODDIR/scripts/keybox_lib.sh"

# Wait for boot so pm/cmd/network are ready.
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 20   # let connectivity settle

run_once() {
    # (re)load config each cycle so edits apply without reinstall
    . "$DATA_DIR/config.conf"
    [ -n "$INTERVAL" ] || INTERVAL=43200
    [ "$INTERVAL" -ge 3600 ] 2>/dev/null || INTERVAL=3600
    [ -n "$AUTO_INSTALL" ] || AUTO_INSTALL=1

    if [ ! -d "$TS_DIR" ]; then
        kb_log "Tricky Store not installed ($TS_DIR missing) - skipping"
        return
    fi

    if ! kb_refresh_crl; then
        kb_log "could not obtain CRL (no network / cache) - skipping this cycle"
        return
    fi

    cur_serial="$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)"
    if [ -n "$cur_serial" ] && kb_is_revoked "$cur_serial"; then
        kb_log "ACTIVE keybox serial $cur_serial is REVOKED - looking for a replacement"
    elif [ -n "$cur_serial" ]; then
        kb_log "active keybox serial $cur_serial OK (not in CRL)"
        return   # current keybox is fine, nothing to do
    else
        kb_log "no valid active keybox found - will try to install one"
    fi

    # Current keybox is revoked or missing: find a fresh, non-revoked one.
    tmp="$DATA_DIR/candidate.xml"
    for src in $SOURCES; do
        kb_fetch_source "$src" "$CUSTOM_URL" "$tmp" || continue
        kb_structural_ok "$tmp" || { kb_log "$src: failed structural check"; continue; }
        cand_serial="$(kb_leaf_serial "$tmp")"
        if [ -z "$cand_serial" ]; then
            kb_log "$src: could not read serial - skipping"; continue
        fi
        if kb_is_revoked "$cand_serial"; then
            kb_log "$src: candidate $cand_serial is also revoked - trying next"; continue
        fi
        if [ "$cand_serial" = "$cur_serial" ]; then
            kb_log "$src: same key as current ($cand_serial) - trying next"; continue
        fi
        # Found a valid, different, non-revoked keybox.
        if [ "$AUTO_INSTALL" = "1" ]; then
            kb_install "$tmp"
            kb_notify "Keybox refreshed" "A fresh keybox ($src) was installed. Tap the module's Action to apply it (clears Play cache + reboots)."
        else
            cp -f "$tmp" "$PENDING"
            kb_notify "Keybox refresh available" "Active keybox is revoked. A valid one ($src) is ready. Tap the module's Action to install & apply."
        fi
        rm -f "$tmp"
        return
    done
    rm -f "$tmp"
    kb_notify "Keybox refresh failed" "Your keybox is revoked but no fresh valid keybox could be fetched. Try again later or add a custom source."
    kb_log "no valid replacement found from: $SOURCES"
}

# Run shortly after boot, then on the configured interval.
(
  while true; do
    run_once
    . "$DATA_DIR/config.conf" 2>/dev/null
    [ -n "$INTERVAL" ] && [ "$INTERVAL" -ge 3600 ] 2>/dev/null || INTERVAL=43200
    sleep "$INTERVAL"
  done
) &
