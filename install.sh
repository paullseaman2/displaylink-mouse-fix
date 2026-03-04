#!/bin/bash
# DisplayLink Mouse Fix — Installer
# Fixes USB mouse freezing when using a DisplayLink dock on Linux
#
# What this installs:
#   /usr/local/bin/mouse-recover   — manual recovery command
#   /usr/local/bin/mouse-watchdog  — background auto-recovery daemon
#   systemd service                — starts watchdog on boot
#   sudoers entry                  — passwordless sudo for recovery
#   udev rules                     — disable autosuspend (belt & suspenders)

set -e

# --- Auto-detect mouse ---
echo "=== Detecting USB mouse ==="

MOUSE_SYS=""
MOUSE_DEV=""
MOUSE_VENDOR=""
MOUSE_PRODUCT=""
MOUSE_NAME=""

for dev in /sys/bus/usb/devices/*/product; do
    if grep -qi "mouse" "$dev" 2>/dev/null; then
        MOUSE_SYS=$(dirname "$dev")
        MOUSE_DEV=$(basename "$MOUSE_SYS")
        MOUSE_VENDOR=$(cat "$MOUSE_SYS/idVendor" 2>/dev/null)
        MOUSE_PRODUCT=$(cat "$MOUSE_SYS/idProduct" 2>/dev/null)
        MOUSE_NAME=$(cat "$MOUSE_SYS/product" 2>/dev/null)
        break
    fi
done

if [ -z "$MOUSE_DEV" ]; then
    echo "ERROR: No USB mouse detected. Plug in your mouse and try again."
    exit 1
fi

MOUSE_IF0="${MOUSE_DEV}:1.0"
MOUSE_IF1="${MOUSE_DEV}:1.1"

# Detect event device path pattern
EVENT_PATTERN=""
for f in /dev/input/by-id/*; do
    if echo "$f" | grep -qi "mouse.*event-mouse"; then
        EVENT_PATTERN="$f"
        break
    fi
done

echo "  Mouse:     $MOUSE_NAME ($MOUSE_VENDOR:$MOUSE_PRODUCT)"
echo "  USB path:  $MOUSE_DEV"
echo "  Interface: $MOUSE_IF0, $MOUSE_IF1"
echo "  Event:     $EVENT_PATTERN"

CURRENT_USER=${SUDO_USER:-$USER}

# --- Install mouse-recover ---
echo ""
echo "=== Installing mouse-recover ==="

cat > /usr/local/bin/mouse-recover << SCRIPT
#!/bin/bash
# Recover frozen mouse by rebinding HID driver
# Restarts interrupt polling on the stalled endpoint

MOUSE_IF0="${MOUSE_IF0}"
MOUSE_IF1="${MOUSE_IF1}"
DRIVER="/sys/bus/usb/drivers/usbhid"

if [ ! -d "/sys/bus/usb/devices/${MOUSE_DEV}" ]; then
    echo "Mouse not found at ${MOUSE_DEV} — may be unplugged or on a different port"
    exit 1
fi

echo "Rebinding mouse HID driver..."
echo "\$MOUSE_IF0" > "\$DRIVER/unbind" 2>/dev/null
echo "\$MOUSE_IF1" > "\$DRIVER/unbind" 2>/dev/null
sleep 0.3
echo "\$MOUSE_IF0" > "\$DRIVER/bind" 2>/dev/null
echo "\$MOUSE_IF1" > "\$DRIVER/bind" 2>/dev/null
echo "Done — mouse should be back"
SCRIPT

chmod +x /usr/local/bin/mouse-recover
echo "  Installed /usr/local/bin/mouse-recover"

# --- Install mouse-watchdog ---
echo ""
echo "=== Installing mouse-watchdog v3 ==="

# Write config section with detected hardware values
cat > /usr/local/bin/mouse-watchdog << WATCHDOG_CONFIG
#!/bin/bash
# Mouse HID stall watchdog v3
# Monitors for real USB HID stalls (not just idle mouse).
# Only recovers when USB error counters increase or event device vanishes.
# Fixes v1/v2 feedback loop where idle mouse triggered constant rebinds.

LOG_TAG="mouse-watchdog"
MOUSE_IF0="${MOUSE_IF0}"
MOUSE_IF1="${MOUSE_IF1}"
DRIVER="/sys/bus/usb/drivers/usbhid"
EVENT_DEV="${EVENT_PATTERN}"
MOUSE_SYS="/sys/bus/usb/devices/${MOUSE_DEV}"
WATCHDOG_CONFIG

# Append the logic (no variable expansion)
cat >> /usr/local/bin/mouse-watchdog << 'WATCHDOG_BODY'

logger -t "$LOG_TAG" "Watchdog v3 started"

recover_mouse() {
    logger -t "$LOG_TAG" "Stall detected — rebinding HID driver"
    echo "$MOUSE_IF0" > "$DRIVER/unbind" 2>/dev/null
    echo "$MOUSE_IF1" > "$DRIVER/unbind" 2>/dev/null
    sleep 0.3
    echo "$MOUSE_IF0" > "$DRIVER/bind" 2>/dev/null
    echo "$MOUSE_IF1" > "$DRIVER/bind" 2>/dev/null
    logger -t "$LOG_TAG" "Recovery complete"
}

get_usb_errors() {
    local errs=0
    local files
    files=$(ls "$MOUSE_SYS"/ep_*/errors 2>/dev/null)
    for f in $files; do
        if [ -r "$f" ]; then
            errs=$((errs + $(cat "$f" 2>/dev/null || echo 0)))
        fi
    done
    for iface in "$MOUSE_IF0" "$MOUSE_IF1"; do
        local epath="/sys/bus/usb/devices/$iface"
        local ifiles
        ifiles=$(ls "$epath"/ep_*/errors 2>/dev/null)
        for f in $ifiles; do
            if [ -r "$f" ]; then
                errs=$((errs + $(cat "$f" 2>/dev/null || echo 0)))
            fi
        done
    done
    echo "$errs"
}

LAST_ERRORS=$(get_usb_errors)
LAST_RECOVER=0
COOLDOWN=10  # minimum seconds between recoveries

while true; do
    sleep 2

    NOW=$(date +%s)

    # Is USB device present?
    if [ ! -d "$MOUSE_SYS" ]; then
        continue
    fi

    # Check 1: Event device vanished while USB is present — definite stall
    if [ ! -e "$EVENT_DEV" ]; then
        if [ $((NOW - LAST_RECOVER)) -ge "$COOLDOWN" ]; then
            logger -t "$LOG_TAG" "Event device gone while USB present"
            recover_mouse
            LAST_RECOVER=$NOW
        fi
        continue
    fi

    # Check 2: USB error counters increased — endpoint stall
    CUR_ERRORS=$(get_usb_errors)
    if [ "$CUR_ERRORS" -gt "$LAST_ERRORS" ]; then
        if [ $((NOW - LAST_RECOVER)) -ge "$COOLDOWN" ]; then
            logger -t "$LOG_TAG" "USB errors increased ($LAST_ERRORS -> $CUR_ERRORS)"
            recover_mouse
            LAST_RECOVER=$NOW
        fi
        LAST_ERRORS=$CUR_ERRORS
        continue
    fi
    LAST_ERRORS=$CUR_ERRORS

    # Check 3: dmesg shows endpoint halt/stall in last few seconds
    if dmesg --time-format iso 2>/dev/null | tail -20 | grep -qi "endpoint.*halt\|cannot submit.*urb\|device not responding" 2>/dev/null; then
        if [ $((NOW - LAST_RECOVER)) -ge "$COOLDOWN" ]; then
            logger -t "$LOG_TAG" "USB stall in dmesg"
            recover_mouse
            LAST_RECOVER=$NOW
        fi
    fi
done
WATCHDOG_BODY

chmod +x /usr/local/bin/mouse-watchdog
echo "  Installed /usr/local/bin/mouse-watchdog"

# --- Sudoers ---
echo ""
echo "=== Configuring passwordless sudo ==="

cat > /etc/sudoers.d/mouse-recover << SUDOERS
# Allow mouse HID recovery without password
${CURRENT_USER} ALL=(root) NOPASSWD: /usr/local/bin/mouse-recover
${CURRENT_USER} ALL=(root) NOPASSWD: /usr/local/bin/mouse-watchdog
SUDOERS
chmod 440 /etc/sudoers.d/mouse-recover
echo "  Passwordless sudo for $CURRENT_USER"

# --- Udev rules ---
echo ""
echo "=== Installing udev rules ==="

cat > /etc/udev/rules.d/50-displaylink-mouse-fix.rules << UDEV
# Disable autosuspend for the mouse and its parent hub (belt & suspenders)
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="${MOUSE_VENDOR}", ATTR{idProduct}=="${MOUSE_PRODUCT}", ATTR{power/control}="on"
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="17e9", ATTR{power/control}="on"
UDEV
udevadm control --reload-rules
udevadm trigger
echo "  Installed /etc/udev/rules.d/50-displaylink-mouse-fix.rules"

# --- Systemd service ---
echo ""
echo "=== Installing systemd service ==="

cat > /etc/systemd/system/mouse-watchdog.service << SERVICE
[Unit]
Description=USB Mouse HID Stall Watchdog (DisplayLink fix)
After=graphical.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mouse-watchdog
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
SERVICE

systemctl daemon-reload
systemctl enable mouse-watchdog.service
systemctl restart mouse-watchdog.service
echo "  Service enabled and started"

# --- Cleanup old fix attempts ---
echo ""
echo "=== Cleaning up old rules ==="
rm -f /etc/udev/rules.d/50-usb-mouse-watchdog.rules
rm -f /etc/udev/rules.d/50-usb-no-autosuspend.rules
rm -f /etc/udev/rules.d/50-usb-mouse-nosuspend.rules
rm -f /etc/udev/rules.d/99-disable-usb-autosuspend.rules
echo "  Removed stale udev rules"

# --- Done ---
echo ""
echo "========================================"
echo " Installation complete"
echo "========================================"
echo ""
echo " Mouse:    $MOUSE_NAME at $MOUSE_DEV"
echo " Watchdog: running (systemctl status mouse-watchdog)"
echo " Logs:     journalctl -t mouse-watchdog -f"
echo ""
echo " If mouse freezes, it should auto-recover in ~3 seconds."
echo " Manual recovery: sudo mouse-recover"
echo ""
