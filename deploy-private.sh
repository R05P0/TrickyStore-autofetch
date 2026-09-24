#!/bin/bash
# Push the private sources file (./private/, gitignored) to the device.
# It lives in the module's DATA dir, not the module dir, so module updates
# (which replace the module dir) never wipe it. keybox_lib.sh picks it up on the
# next check cycle - no reboot needed.
set -e
cd "$(dirname "$0")"
DATA_DIR=/data/adb/trickystore_autofetch
SRC=private/sources_private.sh

[ -f "$SRC" ] || { echo "no $SRC - nothing to deploy"; exit 1; }
bash -n "$SRC" || { echo "syntax error in $SRC"; exit 1; }

adb push "$SRC" /data/local/tmp/ts_private.sh >/dev/null
adb shell "su -c 'sh -n /data/local/tmp/ts_private.sh && cp /data/local/tmp/ts_private.sh $DATA_DIR/sources_private.sh && chmod 644 $DATA_DIR/sources_private.sh; rm -f /data/local/tmp/ts_private.sh'"
adb shell "su -c 'md5sum $DATA_DIR/sources_private.sh'"
md5sum "$SRC"
