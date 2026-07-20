#!/bin/bash
# Uninstall the DisplayLink mouse fix

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This must be run as root." >&2
    echo "  sudo bash uninstall.sh" >&2
    exit 1
fi

echo "=== Uninstalling DisplayLink Mouse Fix ==="

echo "Stopping watchdog..."
systemctl stop mouse-watchdog.service 2>/dev/null || true
systemctl disable mouse-watchdog.service 2>/dev/null || true

echo "Removing files..."
rm -f /usr/local/bin/mouse-recover
rm -f /usr/local/bin/mouse-watchdog
rm -f /etc/systemd/system/mouse-watchdog.service
rm -f /etc/sudoers.d/mouse-recover
rm -f /etc/udev/rules.d/50-displaylink-mouse-fix.rules

systemctl daemon-reload || true
systemctl reset-failed mouse-watchdog.service 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true

echo ""
echo "Done — all components removed."
