#!/bin/sh

PATH=/usr/syno/bin:/usr/syno/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

TAG="AppsSSD-UASP"

SSD="/volumeUSB1/usbshare"

EMBY_TARGET="/volume3/@appdata/EmbyServer"
EMBY_SOURCE="EmbyLive/EmbyServer"

PROWLARR_TARGET="/volume3/@appdata/prowlarr"
PROWLARR_SOURCE="AppData/Prowlarr"

UAS_MODULE="/var/packages/uas/target/uas/uas.ko"
UAS_VENDOR="14b0"
UAS_PRODUCT="0206"


log_msg()
{
    logger -t "$TAG" "$1"
}


is_mounted()
{
    grep -qs " $1 " /proc/mounts
}


fail()
{
    log_msg "ERROR: $1"
    exit 1
}


# Large library limits
sysctl -w fs.inotify.max_user_watches=131072 >/dev/null 2>&1
sysctl -w fs.inotify.max_user_instances=1024 >/dev/null 2>&1


# ============================================================
# STOP SSD-DEPENDENT APPS FIRST
# ============================================================

synopkg stop ContainerManager >/dev/null 2>&1 || true
synopkg stop EmbyServer >/dev/null 2>&1 || true
synopkg stop prowlarr >/dev/null 2>&1 || true

log_msg "SSD-dependent applications stopped"


# Remove old native-app bind mounts if present

if is_mounted "$EMBY_TARGET"; then
    umount "$EMBY_TARGET" >/dev/null 2>&1 || fail "Could not unmount Emby bind mount"
fi

if is_mounted "$PROWLARR_TARGET"; then
    umount "$PROWLARR_TARGET" >/dev/null 2>&1 || fail "Could not unmount Prowlarr bind mount"
fi


# ============================================================
# WAIT FOR ALL FOUR USB VOLUMES
# ============================================================

i=0

while [ "$i" -lt 180 ]; do

    if is_mounted "/volumeUSB1/usbshare" &&
       is_mounted "/volumeUSB2/usbshare" &&
       is_mounted "/volumeUSB3/usbshare" &&
       is_mounted "/volumeUSB4/usbshare" &&
       [ -f "$SSD/.apps_ssd" ]; then
        break
    fi

    sleep 1
    i=$((i + 1))
done


if ! is_mounted "/volumeUSB1/usbshare"; then
    fail "USB1 not mounted"
fi

if ! is_mounted "/volumeUSB2/usbshare"; then
    fail "USB2 not mounted"
fi

if ! is_mounted "/volumeUSB3/usbshare"; then
    fail "USB3 not mounted"
fi

if ! is_mounted "/volumeUSB4/usbshare"; then
    fail "USB4 not mounted"
fi

if [ ! -f "$SSD/.apps_ssd" ]; then
    fail "Lexar SSD marker not found on USB1"
fi

log_msg "All four USB volumes detected in correct order"


# ============================================================
# LOAD CUSTOM UAS DRIVER
# ============================================================

if ! grep -q '^uas ' /proc/modules; then

    if [ ! -f "$UAS_MODULE" ]; then
        fail "Custom uas.ko not found"
    fi

    if ! /sbin/insmod "$UAS_MODULE"; then
        fail "Could not load custom UAS module"
    fi

    log_msg "Custom UAS module loaded"

else
    log_msg "UAS module already loaded"
fi


# ============================================================
# FIND THE LEXAR USB INTERFACE BY VID:PID 14b0:0206
# ============================================================

UAS_IF=""
UAS_IF_PATH=""

for iface_path in /sys/bus/usb/devices/*:*; do

    [ -e "$iface_path" ] || continue

    iface="${iface_path##*/}"
    usb_device="${iface%%:*}"

    vendor_file="/sys/bus/usb/devices/$usb_device/idVendor"
    product_file="/sys/bus/usb/devices/$usb_device/idProduct"

    [ -r "$vendor_file" ] || continue
    [ -r "$product_file" ] || continue

    vendor="$(cat "$vendor_file")"
    product="$(cat "$product_file")"

    if [ "$vendor" = "$UAS_VENDOR" ] &&
       [ "$product" = "$UAS_PRODUCT" ]; then

        UAS_IF="$iface"
        UAS_IF_PATH="$iface_path"
        break
    fi
done


if [ -z "$UAS_IF" ]; then
    fail "Lexar USB interface 14b0:0206 not found"
fi

log_msg "Lexar interface found: $UAS_IF"


# ============================================================
# CHECK CURRENT DRIVER
# ============================================================

CURRENT_DRIVER=""

if [ -L "$UAS_IF_PATH/driver" ]; then
    CURRENT_DRIVER="$(basename "$(readlink -f "$UAS_IF_PATH/driver")")"
fi


# ============================================================
# SWITCH LEXAR FROM BOT TO UASP
# ============================================================

if [ "$CURRENT_DRIVER" = "usb-storage" ]; then

    log_msg "Lexar is using BOT - switching to UASP"

    sync

    if ! umount "$SSD"; then
        fail "Could not safely unmount Lexar SSD"
    fi

    if is_mounted "$SSD"; then
        fail "Lexar SSD is still mounted"
    fi


    # Unbind ONLY the Lexar.
    # Synology synoboot remains attached to stock usb-storage.

    if ! printf '%s' "$UAS_IF" > /sys/bus/usb/drivers/usb-storage/unbind; then
        fail "Could not unbind Lexar from usb-storage"
    fi

    sleep 1


    # Bind only the Lexar to our UAS driver

    if ! printf '%s' "$UAS_IF" > /sys/bus/usb/drivers/uas/bind; then

        log_msg "UAS bind failed - attempting BOT recovery"

        printf '%s' "$UAS_IF" > /sys/bus/usb/drivers/usb-storage/bind 2>/dev/null || true

        fail "Could not bind Lexar to UAS"
    fi


elif [ "$CURRENT_DRIVER" = "uas" ]; then

    log_msg "Lexar is already using UASP"

else

    fail "Lexar has unexpected USB driver: $CURRENT_DRIVER"

fi


# ============================================================
# VERIFY UAS BIND
# ============================================================

i=0
CURRENT_DRIVER=""

while [ "$i" -lt 30 ]; do

    if [ -L "$UAS_IF_PATH/driver" ]; then
        CURRENT_DRIVER="$(basename "$(readlink -f "$UAS_IF_PATH/driver")")"
    fi

    [ "$CURRENT_DRIVER" = "uas" ] && break

    sleep 1
    i=$((i + 1))
done


if [ "$CURRENT_DRIVER" != "uas" ]; then
    fail "Lexar did not switch to UAS"
fi

log_msg "Lexar successfully bound to UAS"


# ============================================================
# WAIT FOR DSM TO REMOUNT THE LEXAR
# ============================================================

i=0

while [ "$i" -lt 60 ]; do

    if is_mounted "$SSD" &&
       [ -f "$SSD/.apps_ssd" ]; then
        break
    fi

    sleep 1
    i=$((i + 1))
done


if ! is_mounted "$SSD"; then
    fail "Lexar did not remount after UAS switch"
fi

if [ ! -f "$SSD/.apps_ssd" ]; then
    fail "SSD marker missing after UAS switch"
fi


# Make sure the SSD came back read-write

if ! awk -v p="$SSD" '
    $2 == p && $4 ~ /^rw,/ { found=1 }
    END { exit !found }
' /proc/mounts; then

    fail "Lexar mounted read-only after UAS switch"
fi

log_msg "Lexar remounted read-write under UASP"


# ============================================================
# VERIFY OTHER USB MEDIA DRIVES ARE STILL PRESENT
# ============================================================

if ! is_mounted "/volumeUSB2/usbshare"; then
    fail "USB2 disappeared during UAS switch"
fi

if ! is_mounted "/volumeUSB3/usbshare"; then
    fail "USB3 disappeared during UAS switch"
fi

if ! is_mounted "/volumeUSB4/usbshare"; then
    fail "USB4 disappeared during UAS switch"
fi


# ============================================================
# EMBY SSD BIND
# ============================================================

if [ ! -f "$SSD/$EMBY_SOURCE/.emby_live" ]; then
    fail "Emby SSD data marker not found"
fi

if ! mount --bind "$SSD/$EMBY_SOURCE" "$EMBY_TARGET"; then
    fail "Could not bind Emby SSD data"
fi

if [ ! -f "$EMBY_TARGET/.emby_live" ]; then
    fail "Emby bind verification failed"
fi

log_msg "Emby SSD bind mounted"


# ============================================================
# PROWLARR SSD BIND
# ============================================================

if [ ! -f "$SSD/$PROWLARR_SOURCE/.prowlarr_live" ]; then
    fail "Prowlarr SSD data marker not found"
fi

if ! mount --bind "$SSD/$PROWLARR_SOURCE" "$PROWLARR_TARGET"; then
    fail "Could not bind Prowlarr SSD data"
fi

if [ ! -f "$PROWLARR_TARGET/.prowlarr_live" ]; then
    fail "Prowlarr bind verification failed"
fi

log_msg "Prowlarr SSD bind mounted"


# ============================================================
# START APPS ONLY AFTER EVERYTHING IS VERIFIED
# ============================================================

if ! synopkg start EmbyServer >/dev/null 2>&1; then
    fail "Emby failed to start"
fi

log_msg "Emby started"


if ! synopkg start prowlarr >/dev/null 2>&1; then
    fail "Prowlarr failed to start"
fi

log_msg "Prowlarr started"


if ! synopkg start ContainerManager >/dev/null 2>&1; then
    fail "Container Manager failed to start"
fi

log_msg "Container Manager started"


log_msg "Cold-boot UASP setup completed successfully"

exit 0
