#!/bin/bash
# DisplayLink Mouse Stall Diagnostic
# Run this WHILE YOUR MOUSE IS FROZEN (use keyboard to open a terminal)
#
# This determines whether your mouse freeze is a USB disconnect
# or a HID endpoint stall (which this repo fixes).

echo "========================================"
echo " DisplayLink Mouse Stall Diagnostic"
echo "========================================"
echo ""

# Try to auto-detect the mouse
MOUSE_SYS=""
MOUSE_EVENT=""

for dev in /sys/bus/usb/devices/*/product; do
    if grep -qi "mouse" "$dev" 2>/dev/null; then
        MOUSE_SYS=$(dirname "$dev")
        MOUSE_DEV=$(basename "$MOUSE_SYS")
        break
    fi
done

if [ -z "$MOUSE_SYS" ]; then
    echo "[!] No USB mouse found in /sys — device may have truly disconnected"
    echo "    This fix may not apply to your situation."
    echo ""
    echo "Checking lsusb for any HID devices..."
    lsusb | grep -iE 'mouse|hid'
    exit 1
fi

VENDOR=$(cat "$MOUSE_SYS/idVendor" 2>/dev/null)
PRODUCT=$(cat "$MOUSE_SYS/idProduct" 2>/dev/null)
PRODUCT_NAME=$(cat "$MOUSE_SYS/product" 2>/dev/null)
SPEED=$(cat "$MOUSE_SYS/speed" 2>/dev/null)

echo "=== 1. USB Device Status ==="
echo "  Found: $PRODUCT_NAME"
echo "  Path:  $MOUSE_DEV"
echo "  ID:    ${VENDOR}:${PRODUCT}"
echo "  Speed: ${SPEED}Mbps"
echo "  STATUS: YES — mouse is still connected at USB level"

echo ""
echo "=== 2. Event Device ==="
MOUSE_EVENT=$(ls /dev/input/by-id/*MOUSE*event-mouse 2>/dev/null | head -1)
if [ -z "$MOUSE_EVENT" ]; then
    MOUSE_EVENT=$(ls /dev/input/by-id/*mouse*event-mouse 2>/dev/null | head -1)
fi

if [ -n "$MOUSE_EVENT" ]; then
    echo "  Found: $MOUSE_EVENT -> $(readlink -f "$MOUSE_EVENT")"
    echo "  STATUS: Event device exists"
else
    echo "  STATUS: NO event device found"
fi

echo ""
echo "=== 3. Input Events (move your mouse for 3 seconds) ==="
if [ -n "$MOUSE_EVENT" ]; then
    EVENT_DATA=$(timeout 3 cat "$MOUSE_EVENT" 2>/dev/null | wc -c)
    if [ "$EVENT_DATA" -gt 0 ]; then
        echo "  STATUS: Events ARE flowing ($EVENT_DATA bytes)"
        echo "  Your mouse might not be stalled — or it recovered"
    else
        echo "  STATUS: NO events received (0 bytes in 3 seconds)"
        echo "  >>> HID endpoint is stalled — this fix applies to you <<<"
    fi
else
    echo "  Skipped (no event device)"
fi

echo ""
echo "=== 4. HID Driver Binding ==="
for intf in "$MOUSE_SYS"/${MOUSE_DEV}:*; do
    INTF_NAME=$(basename "$intf")
    DRIVER=$(readlink "$intf/driver" 2>/dev/null | xargs basename 2>/dev/null)
    echo "  $INTF_NAME -> driver: ${DRIVER:-NONE}"
done

echo ""
echo "=== 5. USB Hub Chain ==="
echo "  Device tree:"
lsusb -t 2>/dev/null | head -20

echo ""
echo "=== 6. DisplayLink Present? ==="
if lsusb 2>/dev/null | grep -qi "displaylink\|17e9"; then
    echo "  YES — DisplayLink adapter detected"
    lsusb | grep -i "17e9"
else
    echo "  No DisplayLink adapter found"
fi

echo ""
echo "=== 7. Recent Kernel Messages ==="
sudo dmesg 2>/dev/null | grep -iE 'usb|mouse|hub|disconnect|reset|xhci' | tail -10 || \
    echo "  (run with sudo for kernel messages)"

echo ""
echo "========================================"
echo " DIAGNOSIS"
echo "========================================"
echo ""

if [ -n "$MOUSE_SYS" ] && [ -n "$MOUSE_EVENT" ] && [ "$EVENT_DATA" -eq 0 ] 2>/dev/null; then
    echo "  HID ENDPOINT STALL CONFIRMED"
    echo ""
    echo "  Your mouse is connected, the event device exists, but no events"
    echo "  are flowing. This is the HID stall caused by DisplayLink bus"
    echo "  contention. Run install.sh to fix it."
    echo ""
    echo "  Quick test — to recover your mouse right now, run:"
    echo "    sudo bash -c 'echo ${MOUSE_DEV}:1.0 > /sys/bus/usb/drivers/usbhid/unbind; sleep 0.3; echo ${MOUSE_DEV}:1.0 > /sys/bus/usb/drivers/usbhid/bind'"
elif [ -n "$MOUSE_SYS" ] && [ "$EVENT_DATA" -gt 0 ] 2>/dev/null; then
    echo "  Mouse appears to be working. Run this again when it freezes."
elif [ -z "$MOUSE_SYS" ]; then
    echo "  TRUE USB DISCONNECT — mouse is gone from the bus."
    echo "  This fix targets HID stalls, not USB disconnects."
    echo "  You may have a different issue (hub power, cable, etc.)"
fi
