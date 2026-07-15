#!/bin/bash
# TrickyStore Autofetch - Build & push via ADB
set -e

cd "$(dirname "$0")"

VERSION=$(grep '^version=' module.prop | cut -d= -f2)
ZIP_NAME="trickystore-autofetch-${VERSION}.zip"
DEVICE_TMP="/sdcard/Download/$ZIP_NAME"

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
