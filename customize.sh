#!/system/bin/sh
#
# customize.sh - install-time setup

SKIPUNZIP=0

ui_print " "
ui_print "  Keybox Autofetch for Tricky Store"
ui_print "  ---------------------------------"

# Root manager info
if [ "$KSU" ]; then
    ui_print "- Root manager: KernelSU ($KSU_VER_CODE)"
elif [ "$APATCH" ]; then
    ui_print "- Root manager: APatch ($APATCH_VER_CODE)"
elif [ "$MAGISK_VER_CODE" ]; then
    ui_print "- Root manager: Magisk ($MAGISK_VER)"
    ui_print "! Magisk has no module Action button."
    ui_print "! To use one-tap Apply, install KsuWebUIStandalone,"
    ui_print "! or run: su -c 'sh /data/adb/keybox_autofetch/action.sh'"
else
    ui_print "! Unknown / unsupported environment"
fi

# Tricky Store presence
if [ -d "/data/adb/modules/tricky_store" ]; then
    ui_print "- Tricky Store detected"
else
    ui_print "! Tricky Store NOT found - install it first."
    ui_print "! This module only manages /data/adb/tricky_store/keybox.xml"
fi

# Persistent data dir + config (survives module updates)
DATA_DIR="/data/adb/keybox_autofetch"
mkdir -p "$DATA_DIR"
if [ -f "$DATA_DIR/config.conf" ]; then
    ui_print "- Keeping your existing config.conf"
else
    cp -f "$MODPATH/config.conf" "$DATA_DIR/config.conf"
    ui_print "- Wrote default config to $DATA_DIR/config.conf"
fi
# Copy action.sh so it can be run manually even without the module dir mounted
cp -f "$MODPATH/action.sh" "$DATA_DIR/action.sh" 2>/dev/null

# Publish notification icon to shared storage (readable by SystemUI)
if [ -f "$MODPATH/icon.png" ]; then
    cp -f "$MODPATH/icon.png" /sdcard/.keybox_autofetch_icon.png 2>/dev/null
    chmod 644 /sdcard/.keybox_autofetch_icon.png 2>/dev/null
    ui_print "- Published notification icon"
fi

ui_print "- Permissions"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh"          0 0 0755
set_perm "$MODPATH/action.sh"           0 0 0755
set_perm "$MODPATH/scripts/keybox_lib.sh" 0 0 0755
set_perm "$DATA_DIR/action.sh"          0 0 0755

ui_print " "
ui_print "- Done. It checks on boot and every ~12h (edit config.conf)."
ui_print "- Not affiliated with Tricky Store. Do not report Tricky Store"
ui_print "  issues because of this module."
ui_print " "
