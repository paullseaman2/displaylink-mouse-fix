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
echo "=== Installing mouse-watchdog ==="

cat > /usr/local/bin/mouse-watchdog << 'WATCHDOG_SCRIPT'
#!/bin/bash
# Background watchdog: detects mouse HID stall and auto-recovers
# When the mouse was recently producing events and suddenly stops
# while still connected at USB level, rebind the HID driver.

LOG_TAG="mouse-watchdog"
WATCHDOG_SCRIPT

# Append the config with actual values (not escaped)
cat >> /usr/local/bin/mouse-watchdog << WATCHDOG_CONFIG
MOUSE_IF0="${MOUSE_IF0}"
MOUSE_IF1="${MOUSE_IF1}"
MOUSE_SYS_PATH="/sys/bus/usb/devices/${MOUSE_DEV}"
DRIVER="/sys/bus/usb/drivers/usbhid"
EVENT_DEV="${EVENT_PATTERN}"
WATCHDOG_CONFIG

cat >> /usr/local/bin/mouse-watchdog << 'WATCHDOG_BODY'

logger -t "$LOG_TAG" "Watchdog started (mouse at $MOUSE_IF0)"

recover_mouse() {
    logger -t "$LOG_TAG" "Stall detected — rebinding HID driver"
    echo "$MOUSE_IF0" > "$DRIVER/unbind" 2>/dev/null
    echo "$MOUSE_IF1" > "$DRIVER/unbind" 2>/dev/null
    sleep 0.3
    echo "$MOUSE_IF0" > "$DRIVER/bind" 2>/dev/null
    echo "$MOUSE_IF1" > "$DRIVER/bind" 2>/dev/null
    sleep 1
    logger -t "$LOG_TAG" "Recovery complete"
}

# State tracking
LAST_EVENT_TIME=0
LAST_BYTES=0
STALL_CHECKS=0

while true; do
    sleep 1

    # Is USB device present?
    if [ ! -d "$MOUSE_SYS_PATH" ]; then
        STALL_CHECKS=0
        LAST_EVENT_TIME=0
        continue
    fi

    # Is the event device there?
    if [ ! -e "$EVENT_DEV" ]; then
        # USB present but no event device — try recovery
        recover_mouse
        STALL_CHECKS=0
        continue
    fi

    # Try to read any event data (non-blocking, 0.5s timeout)
    BYTES=$(timeout 0.5 dd if="$EVENT_DEV" of=/dev/null bs=24 count=1 2>&1 | grep -o '[0-9]* bytes' | head -1 | grep -o '[0-9]*')
    BYTES=${BYTES:-0}
    NOW=$(date +%s)

    if [ "$BYTES" -gt 0 ]; then
        # Mouse is alive and producing events
        LAST_EVENT_TIME=$NOW
        STALL_CHECKS=0
    else
        # No events in this window
        if [ "$LAST_EVENT_TIME" -gt 0 ]; then
            SILENT=$((NOW - LAST_EVENT_TIME))
            # Mouse was recently active (within 10 sec) but now silent
            if [ "$SILENT" -ge 2 ] && [ "$SILENT" -le 10 ]; then
                STALL_CHECKS=$((STALL_CHECKS + 1))
                if [ "$STALL_CHECKS" -ge 2 ]; then
                    recover_mouse
                    STALL_CHECKS=0
                    LAST_EVENT_TIME=0
                fi
            elif [ "$SILENT" -gt 10 ]; then
                # User probably just not using mouse — reset
                STALL_CHECKS=0
            fi
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
