#!/system/bin/sh
#
# service.sh - late_start service. Runs the background check/rotate loop.

MODDIR=${0%/*}
DATA_DIR="/data/adb/trickystore_autofetch"
mkdir -p "$DATA_DIR"

# Seed persistent config on first run (survives module updates).
[ -f "$DATA_DIR/config.conf" ] || cp -f "$MODDIR/config.conf" "$DATA_DIR/config.conf"

. "$MODDIR/scripts/keybox_lib.sh"   # first load; run_once() re-sources it every cycle

# Wait for boot so pm/cmd/network are ready.
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 20   # let connectivity settle

# Publish the notification icon to shared storage (SystemUI, uid system, must be
# able to read it; the module dir under /data/adb is root-only).
if [ -f "$MODDIR/icon.png" ]; then
    cp -f "$MODDIR/icon.png" "$ICON_PUB" 2>/dev/null && chmod 644 "$ICON_PUB" 2>/dev/null
fi

run_once() {
    # Re-source the lib every cycle: this loop lives for the whole uptime, and a
    # shell never reloads function bodies it already sourced, so after a
    # self-update the old keybox_lib.sh functions would keep running until reboot
    # (that's how pif_days_left silently vanished from status.json). The `sh -n`
    # guard keeps a half-written/broken file from killing the loop: a syntax
    # error in a sourced file can abort a non-interactive shell.
    if sh -n "$MODDIR/scripts/keybox_lib.sh" 2>/dev/null; then
        . "$MODDIR/scripts/keybox_lib.sh"
    else
        kb_log "keybox_lib.sh fails syntax check - keeping previously loaded functions"
    fi
    # (re)load config each cycle so edits apply without reinstall
    . "$DATA_DIR/config.conf"
    [ -n "$INTERVAL" ] || INTERVAL=21600
    [ "$INTERVAL" -ge 3600 ] 2>/dev/null || INTERVAL=3600
    [ -n "$AUTO_INSTALL" ] || AUTO_INSTALL=1

    # The PIF spoofed fingerprint's expiry is independent of
    # keybox state, so check it every cycle regardless of what happens below.
    kb_check_pif_expiry

    if [ ! -d "$TS_DIR" ]; then
        kb_log "Tricky Store not installed ($TS_DIR missing) - skipping"
        kb_write_widget_status "error" "" "Tricky Store not installed"
        return
    fi

    if ! kb_refresh_crl; then
        kb_log "could not obtain CRL (no network / cache) - skipping this cycle"
        kb_write_widget_status "error" "$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)" "No network / CRL unavailable"
        return
    fi

    cur_serial="$(kb_leaf_serial "$TS_KEYBOX" 2>/dev/null)"
    if [ -n "$cur_serial" ] && kb_is_revoked "$cur_serial"; then
        kb_log "ACTIVE keybox serial $cur_serial is REVOKED - looking for a replacement"
        kb_write_widget_status "revoked" "$cur_serial" "Revoked, looking for a replacement"
    elif [ -n "$cur_serial" ]; then
        kb_log "active keybox serial $cur_serial OK (not in CRL)"
        # Status widget covers the "all fine" case now - no notification for it
        # (kept only for things that actually need your attention: revoked
        # keybox, refresh failed, source API key expiring).
        kb_write_widget_status "ok" "$cur_serial" "OK"
        return   # current keybox is fine, nothing to do
    else
        kb_log "no valid active keybox found - will try to install one"
        kb_write_widget_status "missing" "" "No active keybox installed"
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
            kb_write_widget_status "revoked" "$cand_serial" "New keybox installed ($src), pending Apply" true
        else
            cp -f "$tmp" "$PENDING"
            kb_notify "Keybox refresh available" "Active keybox is revoked. A valid one ($src) is ready. Tap the module's Action to install & apply." "$(date +%Y%m%d)"
            kb_write_widget_status "revoked" "$cur_serial" "Replacement ($src) ready, tap Apply" true
        fi
        rm -f "$tmp"
        return
    done
    rm -f "$tmp"
    kb_notify "Keybox refresh failed" "Your keybox is revoked but no fresh valid keybox could be fetched. Try again later or add a custom source." "$(date +%Y%m%d)"
    kb_write_widget_status "revoked" "$cur_serial" "No replacement found yet"
    kb_log "no valid replacement found from: $SOURCES"
}

# Run shortly after boot, then on the configured interval.
(
  while true; do
    run_once
    . "$DATA_DIR/config.conf" 2>/dev/null
    [ -n "$INTERVAL" ] && [ "$INTERVAL" -ge 3600 ] 2>/dev/null || INTERVAL=21600
    sleep "$INTERVAL"
  done
) &
