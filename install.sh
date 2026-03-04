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
echo "=== Installing mouse-watchdog v3.1 ==="

# Write config section with detected hardware values
cat > /usr/local/bin/mouse-watchdog << WATCHDOG_CONFIG
#!/bin/bash
# Mouse HID stall watchdog v3.1
# Hybrid: event monitoring with safe thresholds + hardware checks.
# v2 false-triggered on idle mouse (2s threshold). v3 missed stalls because
# event device stays present and no USB error counters exist on some hardware.
# v3.1: monitors events but requires 8s silence after recent activity,
# confirmed by 3 consecutive checks, with 15s cooldown to prevent loops.

LOG_TAG="mouse-watchdog"
MOUSE_IF0="${MOUSE_IF0}"
MOUSE_IF1="${MOUSE_IF1}"
DRIVER="/sys/bus/usb/drivers/usbhid"
EVENT_DEV="${EVENT_PATTERN}"
MOUSE_SYS="/sys/bus/usb/devices/${MOUSE_DEV}"
WATCHDOG_CONFIG

# Append the logic (no variable expansion)
cat >> /usr/local/bin/mouse-watchdog << 'WATCHDOG_BODY'

logger -t "$LOG_TAG" "Watchdog v3.1 started"

recover_mouse() {
    logger -t "$LOG_TAG" "Stall detected — rebinding HID driver"
    echo "$MOUSE_IF0" > "$DRIVER/unbind" 2>/dev/null
    echo "$MOUSE_IF1" > "$DRIVER/unbind" 2>/dev/null
    sleep 0.3
    echo "$MOUSE_IF0" > "$DRIVER/bind" 2>/dev/null
    echo "$MOUSE_IF1" > "$DRIVER/bind" 2>/dev/null
    logger -t "$LOG_TAG" "Recovery complete"
}

# Background event monitor: reads from mouse, updates timestamp file
LAST_EVENT_FILE=$(mktemp)
echo "0" > "$LAST_EVENT_FILE"

monitor_events() {
    while true; do
        if [ -e "$EVENT_DEV" ]; then
            if timeout 2 dd if="$EVENT_DEV" of=/dev/null bs=24 count=1 2>/dev/null; then
                date +%s > "$LAST_EVENT_FILE"
            fi
        else
            sleep 2
        fi
    done
}

monitor_events &
MONITOR_PID=$!
trap "kill $MONITOR_PID 2>/dev/null; rm -f $LAST_EVENT_FILE; exit" EXIT TERM INT

LAST_RECOVER=0
COOLDOWN=15
STALL_COUNT=0
SILENCE_THRESHOLD=8   # seconds of silence before suspecting stall
ACTIVITY_WINDOW=30    # only suspect stall if mouse was active within this many seconds
STALL_CONFIRM=3       # consecutive failed checks needed to confirm stall

while true; do
    sleep 2

    NOW=$(date +%s)

    # Is USB device present?
    if [ ! -d "$MOUSE_SYS" ]; then
        STALL_COUNT=0
        continue
    fi

    # Cooldown check
    if [ $((NOW - LAST_RECOVER)) -lt "$COOLDOWN" ]; then
        STALL_COUNT=0
        continue
    fi

    # Check 1: Event device vanished while USB is present
    if [ ! -e "$EVENT_DEV" ]; then
        logger -t "$LOG_TAG" "Event device gone while USB present"
        recover_mouse
        LAST_RECOVER=$NOW
        STALL_COUNT=0
        kill "$MONITOR_PID" 2>/dev/null
        sleep 1
        echo "0" > "$LAST_EVENT_FILE"
        monitor_events &
        MONITOR_PID=$!
        continue
    fi

    # Check 2: Event-based stall detection
    LAST_EVENT=$(cat "$LAST_EVENT_FILE" 2>/dev/null || echo 0)
    SILENT_SECS=$((NOW - LAST_EVENT))

    # Only suspect a stall if mouse was recently active and has gone silent
    if [ "$LAST_EVENT" -gt 0 ] && [ "$SILENT_SECS" -ge "$SILENCE_THRESHOLD" ] && [ "$SILENT_SECS" -le "$ACTIVITY_WINDOW" ]; then
        STALL_COUNT=$((STALL_COUNT + 1))
        if [ "$STALL_COUNT" -ge "$STALL_CONFIRM" ]; then
            logger -t "$LOG_TAG" "Silent ${SILENT_SECS}s after activity (${STALL_COUNT} checks)"
            recover_mouse
            LAST_RECOVER=$NOW
            STALL_COUNT=0
            kill "$MONITOR_PID" 2>/dev/null
            sleep 1
            echo "0" > "$LAST_EVENT_FILE"
            monitor_events &
            MONITOR_PID=$!
        fi
    else
        STALL_COUNT=0
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
