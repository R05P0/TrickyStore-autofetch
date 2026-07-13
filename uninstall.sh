#!/system/bin/sh
#
# uninstall.sh - runs when the module is removed.
#
# We deliberately DO NOT touch /data/adb/tricky_store/keybox.xml - whatever
# keybox is active stays active. We only remove our own working data.
# Comment the next line out if you want to keep logs/config.
rm -rf /data/adb/keybox_autofetch
