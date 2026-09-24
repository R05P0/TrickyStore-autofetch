#!/bin/bash
# TrickyStore Autofetch - Build & push via ADB
set -e

cd "$(dirname "$0")"

VERSION=$(grep '^version=' module.prop | cut -d= -f2)
ZIP_NAME="trickystore-autofetch-${VERSION}.zip"
DEVICE_TMP="/sdcard/Download/$ZIP_NAME"

# Safety net: the public zip must never carry the private sources. private/ is
# not in the file list below, but names could still end up in a public file by
# mistake - check what actually ships. The patterns live in private/ (gitignored)
# so this script doesn't spell them out itself.
SHIP="module.prop customize.sh service.sh action.sh uninstall.sh config.conf scripts webroot"
if [ -f private/deny-patterns.txt ]; then
    if grep -rIiF -f private/deny-patterns.txt $SHIP >/dev/null 2>&1; then
        echo "ABORT: private source names found in files that would be zipped:" >&2
        grep -rIilF -f private/deny-patterns.txt $SHIP >&2
        exit 1
    fi
else
    echo "WARNING: private/deny-patterns.txt missing - skipping the private-name check" >&2
fi

echo "==> Building $ZIP_NAME..."
rm -f "$ZIP_NAME"
zip -r "$ZIP_NAME" \
    module.prop \
    icon.png \
    customize.sh \
    service.sh \
    action.sh \
    uninstall.sh \
    config.conf \
    scripts/ \
    webroot/ \
    -x "*.DS_Store" "*.gitkeep"

echo "==> Pushing to device..."
adb push "$ZIP_NAME" "$DEVICE_TMP"

echo ""
echo "Done! Install via Magisk/KSU > Modules > Install from storage"
echo "File: $DEVICE_TMP"
echo ""
