# DisplayLink Dock USB Mouse Fix for Linux

**Your USB mouse freezes when you alt-tab (or switch windows) while using a DisplayLink dock on Linux. Unplugging and replugging the mouse is the only way to get it back. This repo fixes that.**

## The Problem

When using a USB mouse through a DisplayLink dock (like the Dell D3100), the mouse randomly freezes — especially during alt-tab or window switching. The cursor stops moving completely. The only recovery is physically unplugging the mouse and plugging it back in.

This is extremely common on Linux with DisplayLink docks and has been misdiagnosed for years.

## The Real Root Cause

**It's NOT a USB disconnect.** The mouse never leaves the USB bus.

When you alt-tab, the DisplayLink adapter (which handles your external monitors) generates a burst of USB traffic for the display refresh. This traffic floods the shared xHCI controller, which causes the HID interrupt endpoint on your mouse to **stall**. The kernel's HID driver stops receiving events but doesn't notice or recover — so your mouse appears dead even though it's still physically connected.

Every "fix" you'll find online points to USB autosuspend (`usbcore.autosuspend=-1`, power management rules, etc.). **These do not work because autosuspend is not the problem.** The problem is at the HID driver layer, not the USB power management layer.

### How we confirmed this

When the mouse is "dead":
- `lsusb` still shows the mouse (USB device present)
- `/dev/input/by-id/*MOUSE*` still exists (event device present)
- `/sys/bus/usb/devices/1-1.2.4` still exists (kernel sees it)
- But `cat /dev/input/event*` produces zero output (no events flowing)
- `dmesg` shows no disconnect messages

The device is there. The driver is bound. But the interrupt endpoint is stalled and nobody is recovering it.

## The Fix

**Unbind and rebind the HID driver.** This restarts interrupt polling on the endpoint and the mouse immediately comes back — no physical unplug needed.

This repo provides:
1. **`mouse-recover`** — Manual instant recovery (run from keyboard when mouse is dead)
2. **`mouse-watchdog`** — Background service that auto-detects the stall and recovers in ~2-3 seconds
3. **`diagnose.sh`** — Diagnostic script to confirm you have the same issue

## Quick Install

```bash
git clone https://github.com/paullseaman2/displaylink-mouse-fix.git
cd displaylink-mouse-fix
sudo bash install.sh
```

This installs:
- `/usr/local/bin/mouse-recover` — manual recovery command
- `/usr/local/bin/mouse-watchdog` — background watchdog daemon
- Systemd service `mouse-watchdog` — starts on boot
- Passwordless sudo for the recovery commands
- Udev rules to disable autosuspend (belt and suspenders)

## Usage

### Automatic (recommended)
After install, the watchdog runs in the background. If your mouse stalls, it should recover automatically within ~3 seconds. Check it's running:

```bash
systemctl status mouse-watchdog
journalctl -t mouse-watchdog -f
```

### Manual recovery
If the watchdog hasn't caught it yet, open a terminal with your keyboard and run:

```bash
sudo mouse-recover
```

## Diagnosis

Not sure if you have the same issue? Run the diagnostic **while your mouse is frozen** (use keyboard to open a terminal):

```bash
bash diagnose.sh
```

If you see:
- "YES — mouse is still connected at USB level"
- Event device exists
- No input events flowing

Then you have the same problem and this fix will work for you.

## Affected Hardware

Confirmed on:
- **Dock:** Dell D3100 (DisplayLink DL-3900)
- **Hub chipset:** VIA VL812 (very common in USB docks)
- **Mouse:** Any low-speed (1.5Mbps) USB mouse through the dock
- **OS:** Ubuntu 24.04+ with Wayland (GNOME/Mutter)
- **Kernel:** 6.x+

Likely affects:
- Any DisplayLink dock on Linux
- Any USB hub that shares the xHCI controller with DisplayLink
- Both X11 and Wayland sessions
- Other HID devices (keyboards less affected since they're polled differently)

## Customization

The scripts assume your mouse is at USB path `1-1.2.4` through a hub at `1-1.2`. If your hardware is different, find your mouse path:

```bash
lsusb -t
# Look for your mouse (1.5M or 12M HID device)

# Or find it by vendor ID:
grep -r "MOUSE\|mouse" /sys/bus/usb/devices/*/product 2>/dev/null
```

Then edit the `MOUSE_IF0` and `MOUSE_IF1` variables in the installed scripts.

## What Doesn't Work

Things we tried that **did NOT fix this**:
- `usbcore.autosuspend=-1` (autosuspend was never the problem)
- USB quirks: `usbcore.quirks=VID:PID:bl` (NO_LPM + RESET_RESUME)
- Udev autosuspend rules for the mouse, hub, and DisplayLink adapter
- Resetting the USB hub via `usbreset`
- Unbinding/rebinding the USB hub driver (wrong layer — need HID, not USB)

## License

MIT — use it, share it, fix your mouse.
