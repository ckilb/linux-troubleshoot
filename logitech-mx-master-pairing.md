# Pairing a Logitech MX Master 3 over Bluetooth (Arch Linux)

Notes from fixing "mouse appears in the Bluetooth list, is in pairing mode, but won't pair."

## Summary

The Bluetooth stack was healthy the whole time. The MX Master 3 is a **BLE
(Bluetooth Low Energy) HID device with a random address**. The usual reason it
"shows up but won't pair" is a flaky first GATT handshake: a GUI (GNOME/KDE
settings or blueman) starts the bond, the device drops the link before its GATT
services resolve, and the GUI silently reports failure.

Pairing from `bluetoothctl` directly — with an active scan keeping the link
warm — let the full bond + service discovery complete on the first clean
attempt.

## Device details

- Address: `CB:C3:71:B4:AC:9C` (random / BLE)
- Advertised as: `MX Master 3`, Appearance `0x03c2` (mouse), Icon `input-mouse`
- Key service: Human Interface Device, UUID `00001812-0000-1000-8000-00805f9b34fb`
- Adapter used: Controller `F0:18:98:34:EA:40` (`hci0`)

## Health checks (all passed)

```bash
systemctl status bluetooth      # active (running)
rfkill list                     # hci0: Soft blocked: no, Hard blocked: no
bluetoothctl show               # Powered: yes, Pairable: yes
```

No stale/cached entry existed for the mouse (`bluetoothctl devices Paired` was
empty), so there was nothing to conflict with.

## The fix

Put the mouse in pairing mode (hold the Bluetooth/Easy-Switch button until the
LED blinks fast), then run:

```bash
DEV="CB:C3:71:B4:AC:9C"

# Keep an active scan running so the BLE link stays warm during the handshake
bluetoothctl --timeout 6 scan on >/dev/null 2>&1

bluetoothctl pair    "$DEV"   # -> "Pairing successful" (Bonded: yes)
bluetoothctl trust   "$DEV"   # auto-reconnect on future power-ups, no re-pair
bluetoothctl connect "$DEV"   # -> "Connection successful"
```

Verify state:

```bash
bluetoothctl info "$DEV" | grep -iE "Name|Paired|Bonded|Trusted|Connected"
# Paired: yes / Bonded: yes / Trusted: yes / Connected: yes
```

Confirm the kernel registered it as a real input device:

```bash
grep -iA5 "MX Master" /proc/bus/input/devices
# N: Name="Logitech Wireless Mouse MX Master 3"
# H: Handlers=sysrq kbd event19 mouse1
```

## Notes / gotchas

- **`trust` matters**: without it, the mouse may not auto-reconnect after
  power-cycle and you'd have to reconnect manually each time.
- If a GUI still shows a leftover "failed"/disconnected tile after this, remove
  that stale entry in the GUI — the working connection is the CLI one. You can
  also clear it with `bluetoothctl remove "$DEV"` and redo the steps above.
- The kernel reports the BLE mouse as USB-style VID/PID `046d:b023`
  (Logitech MX Master 3) via the `uhid` virtual HID layer — this is normal for
  BLE HID and does **not** mean it's on the USB/Unifying receiver.
- If pairing still fails from the CLI, retry once or twice (BLE first-contact is
  flaky), make sure no other host (Easy-Switch channel) is grabbing the mouse,
  and ensure it's actively advertising (LED blinking fast, not slow).

---
_Documented 2026-06-07. Arch Linux, BlueZ / bluetoothd._
