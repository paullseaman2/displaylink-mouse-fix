# DisplayLink Dock USB Mouse Fix for Linux

**Your USB mouse freezes when you alt-tab (or switch windows) while using a DisplayLink dock on Linux. Unplugging and replugging the mouse is the only way to get it back. This repo fixes that.**

## The Problem

When using a USB mouse through a DisplayLink dock (like the Dell D3100), the mouse randomly freezes — especially during alt-tab or window switching. The cursor stops moving completely. The only recovery is physically unplugging the mouse and plugging it back in.

This is extremely common on Linux with DisplayLink docks and has been misdiagnosed for years.

## The Real Root Cause

**It's NOT a USB disconnect.** The mouse never leaves the USB bus.

When you alt-tab, the DisplayLink adapter (which handles your external monitors) generates a burst of USB traffic for the display refresh. If your mouse is plugged into the dock, both the video data and mouse polling share the dock's internal USB hub — specifically its **Transaction Translator (TT)**. The TT chokes during the video burst, the mouse's interrupt transfer silently never completes, and the kernel's HID driver has no timeout for a URB that never returns — so your mouse appears dead even though it's still physically connected.

The USB spec guarantees interrupt endpoint bandwidth over bulk transfers at the xHCI controller level. But the TT inside the dock's hub is the real bottleneck — it sits below that guarantee.

Every "fix" you'll find online points to USB autosuspend (`usbcore.autosuspend=-1`, power management rules, etc.). **These do not work because autosuspend is not the problem.** The problem is at the hub's Transaction Translator layer.

### How we confirmed this

When the mouse is "dead":
- `lsusb` still shows the mouse (USB device present)
- `/dev/input/by-id/*MOUSE*` still exists (event device present)
- `/sys/bus/usb/devices/1-1.2.4` still exists (kernel sees it)
- But `cat /dev/input/event*` produces zero output (no events flowing)
- `dmesg` shows no disconnect messages

The device is there. The driver is bound. But the interrupt endpoint is stalled and nobody is recovering it.

## The Fix

### Best fix: Plug your mouse into the motherboard

If your computer has a USB port that connects directly to the motherboard (not through the dock), **plug your mouse there.** This bypasses the dock's hub and its shared Transaction Translator entirely. The mouse gets its own path to the xHCI controller and DisplayLink traffic can't interfere. Problem solved, no software needed.

Check `lsusb -t` — if your mouse is under a hub that's also under the DisplayLink device, that's the shared TT causing your problem.

### Software fix: HID driver rebind (when you can't avoid the dock)

If all your USB ports go through the dock (common on laptops with only one port), the workaround is to **unbind and rebind the HID driver.** This restarts interrupt polling on the stalled endpoint and the mouse immediately comes back — no physical unplug needed.

This repo provides:
1. **`mouse-recover`** — Manual instant recovery (run from keyboard when mouse is dead)
2. **`mouse-watchdog`** — Background service that auto-detects the stall and recovers in ~5 seconds
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
After install, the watchdog runs in the background. It monitors for real USB HID stalls using event silence detection with safe thresholds — it will **not** false-trigger when you simply stop moving your mouse. If your mouse stalls, it should recover automatically within ~5 seconds. Check it's running:

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

## Watchdog v3.2 — How It Detects Stalls

Earlier versions had problems:
- **v1/v2**: Tried to read mouse events with a 2-second timeout. Idle mouse (user typing) looked identical to a stalled mouse, causing constant false-positive recoveries that themselves caused freezes — a feedback loop.
- **v3**: Switched to hardware-only checks (USB error counters, event device removal, dmesg). But on some hardware the event device stays present during a stall and no error counters exist, so real stalls were missed entirely.
- **v3.1**: Hybrid approach that worked but was conservative — 8s silence threshold + 3 confirms at 2s intervals = ~14s recovery. Safe but slow.

**v3.2** tightens the thresholds while keeping the feedback-loop protection:
1. **Event device vanishes** while USB is present — instant recovery
2. **Event silence detection** — if the mouse was active within the last 30 seconds but has been silent for 4+ seconds, AND 2 consecutive checks confirm it (at 1s intervals), trigger recovery
3. **8-second cooldown** between recoveries prevents cascading rebinds

This means a real stall recovers in ~5 seconds, but normal idle periods (typing, reading) don't trigger false positives. The cooldown is still 25x longer than the rebind operation (0.3s), so the v2 feedback loop cannot occur.

## What Doesn't Work

Things we tried that **did NOT fix this**:
- `usbcore.autosuspend=-1` (autosuspend was never the problem)
- USB quirks: `usbcore.quirks=VID:PID:bl` (NO_LPM + RESET_RESUME)
- `HID_QUIRK_ALWAYS_POLL` (URB is already submitted — it's just not completing)
- Udev autosuspend rules for the mouse, hub, and DisplayLink adapter
- Resetting the USB hub via `usbreset`
- Unbinding/rebinding the USB hub driver (wrong layer — need HID, not USB)
- eBPF/HID-BPF (operates above USB transport, can't detect URB non-completion)

## Why the Kernel Doesn't Self-Recover

The HID driver (`hid-core.c`) has proper error handling for every URB failure code — stalls, protocol errors, timeouts. But in this scenario, the URB **never completes at all**. The TT silently drops the transfer, no error is reported, `hid_irq_in()` is never called, and `HID_IN_RUNNING` stays set. The driver thinks everything is fine. There is no timeout on pending interrupt URBs in the kernel's HID driver.

A [February 2026 LKML patch](https://lkml.org/lkml/2026/2/8/329) ("usbhid: tolerate intermittent errors") is being reviewed by USB maintainers and may improve upstream handling of related failure modes.

## License

MIT — use it, share it, fix your mouse.
