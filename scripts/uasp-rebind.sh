#!/bin/sh

PATH=/usr/syno/bin:/usr/syno/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

TAG="UASP-Rebind"
UAS_MODULE="/var/packages/uas/target/uas/uas.ko"

VID="${1:-}"
PID="${2:-}"
MOUNTPOINT="${3:-}"

log_msg()
{
    logger -t "$TAG" "$1"
    echo "$1"
}

fail()
{
    log_msg "ERROR: $1"
    exit 1
}

usage()
{
    echo "Usage: $0 <vendor-id> <product-id> <mountpoint>"
    echo "Example: $0 14b0 0206 /volumeUSB1/usbshare"
    exit 2
}

[ "$(id -u)" -eq 0 ] || fail "This script must run as root"

[ -n "$VID" ] || usage
[ -n "$PID" ] || usage
[ -n "$MOUNTPOINT" ] || usage


# ------------------------------------------------------------
# Find the USB mass-storage interface matching VID:PID
# ------------------------------------------------------------

USB_IF=""
USB_IF_PATH=""
MATCHES=0

for iface_path in /sys/bus/usb/devices/*:*; do
    [ -e "$iface_path" ] || continue

    iface="${iface_path##*/}"
    usb_device="${iface%%:*}"

    [ -r "/sys/bus/usb/devices/$usb_device/idVendor" ] || continue
    [ -r "/sys/bus/usb/devices/$usb_device/idProduct" ] || continue
    [ -r "$iface_path/bInterfaceClass" ] || continue

    vendor="$(cat "/sys/bus/usb/devices/$usb_device/idVendor")"
    product="$(cat "/sys/bus/usb/devices/$usb_device/idProduct")"
    class="$(cat "$iface_path/bInterfaceClass")"

    if [ "$vendor" = "$VID" ] &&
       [ "$product" = "$PID" ] &&
       [ "$class" = "08" ]; then
        MATCHES=$((MATCHES + 1))
        USB_IF="$iface"
        USB_IF_PATH="$iface_path"
    fi
done

[ "$MATCHES" -gt 0 ] ||
    fail "USB storage interface $VID:$PID not found"

[ "$MATCHES" -eq 1 ] ||
    fail "More than one USB storage interface matches $VID:$PID"

log_msg "Found USB interface $USB_IF for $VID:$PID"


# ------------------------------------------------------------
# Determine its block device
# ------------------------------------------------------------

USB_BLOCK=""

for block_path in "$USB_IF_PATH"/host*/target*/*/block/*; do
    [ -e "$block_path" ] || continue
    USB_BLOCK="${block_path##*/}"
    break
done

[ -n "$USB_BLOCK" ] ||
    fail "Could not determine block device for $USB_IF"

log_msg "USB interface $USB_IF currently uses /dev/$USB_BLOCK"


# ------------------------------------------------------------
# Check whether this device is mounted
# ------------------------------------------------------------

DEVICE_MOUNTPOINT=""

while read -r source target rest; do
    case "$source" in
        /dev/"$USB_BLOCK"|/dev/"$USB_BLOCK"[0-9]*)
            DEVICE_MOUNTPOINT="$target"
            break
            ;;
    esac
done < /proc/mounts

if [ -n "$DEVICE_MOUNTPOINT" ] &&
   [ "$DEVICE_MOUNTPOINT" != "$MOUNTPOINT" ]; then

    fail "Target device is mounted at $DEVICE_MOUNTPOINT instead of $MOUNTPOINT"
fi

if [ -n "$DEVICE_MOUNTPOINT" ]; then
    log_msg "$MOUNTPOINT belongs to /dev/$USB_BLOCK"
fi


# ------------------------------------------------------------
# Determine current driver
# ------------------------------------------------------------

CURRENT_DRIVER=""

if [ -L "$USB_IF_PATH/driver" ]; then
    CURRENT_DRIVER="$(basename "$(readlink -f "$USB_IF_PATH/driver")")"
fi

if [ "$CURRENT_DRIVER" = "uas" ]; then
    log_msg "Device is already using UAS/UASP"
    exit 0
fi

[ "$CURRENT_DRIVER" = "usb-storage" ] ||
    fail "Unexpected current driver: $CURRENT_DRIVER"


# ------------------------------------------------------------
# Load custom UAS alongside Synology's stock usb-storage
# ------------------------------------------------------------

if ! grep -q '^uas ' /proc/modules; then
    [ -f "$UAS_MODULE" ] ||
        fail "UAS module not found at $UAS_MODULE"

    /sbin/insmod "$UAS_MODULE" ||
        fail "Could not load custom UAS module"

    log_msg "Custom UAS module loaded"
fi


# ------------------------------------------------------------
# Safely unmount this device only
# ------------------------------------------------------------

if [ -n "$DEVICE_MOUNTPOINT" ]; then
    sync

    umount "$MOUNTPOINT" ||
        fail "Could not safely unmount $MOUNTPOINT"

    grep -qs " $MOUNTPOINT " /proc/mounts &&
        fail "$MOUNTPOINT is still mounted"

    log_msg "$MOUNTPOINT safely unmounted"
fi


# ------------------------------------------------------------
# Rebind ONLY this external device
#
# Synology's stock usb-storage remains loaded for synoboot
# and any other BOT devices.
# ------------------------------------------------------------

printf '%s' "$USB_IF" > /sys/bus/usb/drivers/usb-storage/unbind ||
    fail "Could not unbind $USB_IF from usb-storage"

sleep 1

if ! printf '%s' "$USB_IF" > /sys/bus/usb/drivers/uas/bind; then
    log_msg "UAS bind failed; attempting usb-storage recovery"

    printf '%s' "$USB_IF" \
        > /sys/bus/usb/drivers/usb-storage/bind 2>/dev/null || true

    fail "Could not bind $USB_IF to uas"
fi


# ------------------------------------------------------------
# Verify UAS
# ------------------------------------------------------------

i=0
CURRENT_DRIVER=""

while [ "$i" -lt 30 ]; do
    if [ -L "$USB_IF_PATH/driver" ]; then
        CURRENT_DRIVER="$(basename "$(readlink -f "$USB_IF_PATH/driver")")"
    fi

    [ "$CURRENT_DRIVER" = "uas" ] && break

    sleep 1
    i=$((i + 1))
done

[ "$CURRENT_DRIVER" = "uas" ] ||
    fail "Device did not switch to UAS"

log_msg "Successfully switched $VID:$PID to UAS/UASP"


# ------------------------------------------------------------
# Wait for DSM to remount it
# ------------------------------------------------------------

i=0

while [ "$i" -lt 60 ]; do
    if grep -qs " $MOUNTPOINT " /proc/mounts; then
        log_msg "$MOUNTPOINT remounted successfully"
        exit 0
    fi

    sleep 1
    i=$((i + 1))
done

fail "Device switched to UAS but $MOUNTPOINT did not remount"
