# Kernel-Level Fix Research: USB HID Interrupt Endpoint Stalls

## The Big Finding

The USB spec **guarantees** bandwidth for interrupt endpoints — bulk transfers (DisplayLink video) are not supposed to be able to starve interrupt endpoints (your mouse). The xHCI hardware controller is required to enforce this. So why does it happen?

**The real bottleneck is the Transaction Translator (TT) in the dock's USB hub.** Your mouse is a USB 2.0 low-speed device connected through the dock's internal hub. Both DisplayLink's bulk traffic and the mouse's interrupt traffic pass through the same TT. The TT becomes the chokepoint — it can't service both the video burst and the mouse polling simultaneously. The interrupt endpoint's NAK response isn't relayed back to the xHCI in time, the transfer ring entry times out silently, the URB never completes, and the HID driver has no idea anything is wrong.

This explains why unbind/rebind works: it tears down the interface, clears all endpoint state, and resubmits fresh URBs after the burst has passed.

## Immediate Quick Win: Plug Mouse Into Motherboard

Run `lsusb -t` — if the mouse is under a hub that's also under the DisplayLink device, plugging the mouse directly into a motherboard USB port bypasses the shared TT entirely. **This might eliminate the problem with zero software changes.**

## Three Tiers of Fix

### Tier 1: Faster Detection (no kernel changes)

**usbmon approach** — Replace our `/dev/input/event*` silence detection with `/dev/usbmon*` monitoring. usbmon sees USB-level events and can distinguish between "user not moving mouse" and "interrupt URB not completing." Detection in ~200ms instead of 4 seconds. Recovery still via unbind/rebind, but total stall time drops to <1 second.

**`usbhid.mousepoll=1`** — Force 1ms polling interval. Won't prevent the stall but may help with marginal timing. Add to kernel command line: `usbhid.mousepoll=1`

### Tier 2: Hardware Isolation ($15-25, permanent fix)

Buy a **PCIe USB controller card** (Renesas/NEC uPD720201 chipset, ~$15-25). Plug mouse into the PCIe card. The mouse gets its own xHCI controller with its own transfer rings, bandwidth allocation, and interrupt handler. The DisplayLink dock stays on the motherboard controller. They physically cannot interfere with each other.

Verify isolation after install:
```bash
lspci | grep -i xhci
# Should show two entries on different bus numbers
```

### Tier 3: Kernel Module (<200ms recovery)

Write an out-of-tree kernel module that:
1. Uses kprobes on `hid_irq_in()` to track last successful interrupt URB completion
2. Timer fires every 200ms — if no completion in 500ms, calls `usb_clear_halt()` on the interrupt endpoint and resubmits the URB
3. Recovery happens in kernel context — no unbind/rebind needed, no userspace latency

This is the "real fix" — sub-200ms recovery, invisible to the user. Requires kernel development but is feasible as an out-of-tree module (no upstream changes needed).

Sketch:
```c
static struct timer_list watchdog_timer;
static unsigned long last_irq_completion;

// kprobe on hid_irq_in to track completions
static int hid_irq_in_handler(struct kprobe *p, struct pt_regs *regs) {
    last_irq_completion = jiffies;
    return 0;
}

// Timer fires every 200ms
static void watchdog_check(struct timer_list *t) {
    if (jiffies - last_irq_completion > msecs_to_jiffies(500)) {
        usb_clear_halt(usbdev, pipe);
        usb_submit_urb(urbin, GFP_ATOMIC);
    }
    mod_timer(&watchdog_timer, jiffies + msecs_to_jiffies(200));
}
```

## Relevant Upstream Activity

**Very recent (Feb 2026):** A patch "usbhid: tolerate intermittent errors" was submitted to LKML by Liam Mitchell, reviewed by the usbhid maintainer (Oliver Neukum) and USB core maintainer (Alan Stern). It addresses exactly this class of failure — EPROTO errors on interrupt endpoints causing unnecessary resets. This may land upstream and improve the driver's resilience.

## Why the Kernel HID Driver Misses This

In `drivers/hid/usbhid/hid-core.c`, the `hid_irq_in()` completion handler has proper recovery for every error code (-EPIPE, -EPROTO, -ETIME, etc.). **But if the URB never completes at all** — which is what happens when the TT silently drops the interrupt transfer — none of these error paths trigger. `HID_IN_RUNNING` stays set, and the driver thinks everything is fine. There is no timeout on pending interrupt URBs.

## What Doesn't Help

- `usbcore.autosuspend=-1` — Not a suspend issue
- `USB_QUIRK_RESET_RESUME` — Not a suspend/resume issue
- `HID_QUIRK_ALWAYS_POLL` — URB is already submitted, it's just not completing
- DisplayLink driver tuning — No user-configurable bandwidth throttling
- eBPF/HID-BPF — Operates above USB transport; can't detect URB non-completion

## Sources

- [hid-core.c](https://github.com/torvalds/linux/blob/master/drivers/hid/usbhid/hid-core.c) — HID interrupt URB management
- [xhci-ring.c](https://github.com/torvalds/linux/blob/master/drivers/usb/host/xhci-ring.c) — xHCI transfer ring scheduling
- [LKML: "usbhid: tolerate intermittent errors" (Feb 2026)](https://lkml.org/lkml/2026/2/8/329)
- [RTAS 2024: USB Interrupt Differentiated Service](https://cs-people.bu.edu/njavro/papers/rtas2024-final.pdf) — Academic paper confirming this is a real, recognized problem
- [fix-linux-mouse project](https://github.com/sriemer/fix-linux-mouse) — Related HID polling quirks
- [usbmon documentation](https://docs.kernel.org/usb/usbmon.html)
