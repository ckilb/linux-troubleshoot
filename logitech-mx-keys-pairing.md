# Pairing a Logitech MX Keys over Bluetooth (Arch Linux)

Notes from fixing "MX Keys won't pair via the KDE Bluetooth UI."

See also: [logitech-mx-master-pairing.md](./logitech-mx-master-pairing.md) — the
mouse is simpler because it uses **Just Works** pairing (no passkey). The
keyboard is harder because it requires a **passkey typed on the keyboard itself**.

## Summary

The MX Keys is a **BLE (random-address) HID keyboard**. Its pairing uses SSP
**Passkey Entry**: the host displays a 6-digit code, and you must type that code
**on the MX Keys and press Enter** to complete the bond.

The KDE UI (and a plain piped `bluetoothctl pair`) fails because the passkey
prompt isn't surfaced / answered reliably, and the radio's constant scan churn
plus leftover half-pairings wedge BlueZ into `org.bluez.Error.InProgress`. The
fix is a clean, scripted `bluetoothctl` session with a `KeyboardDisplay` agent
that shows the passkey so you can enter it on the keyboard.

## Device details

- Address: `D0:6C:68:42:FB:C9` (random / BLE)
- Advertised as: `MX Keys`, Appearance `0x03c1` (keyboard), Icon `input-keyboard`
- Key service: Human Interface Device, UUID `00001812-0000-1000-8000-00805f9b34fb`
- Adapter: Controller `F0:18:98:34:EA:40` (`hci0`)
- After pairing the kernel registers TWO nodes:
  `MX Keys Keyboard` (event20, kbd) and `MX Keys Mouse` (event21, consumer keys)

## Why it kept failing (the traps)

1. **Passkey not surfaced.** A keyboard needs Passkey Entry. `bluetoothctl pair`
   piped non-interactively, or the KDE agent, may not display/handle the prompt,
   so the link connects then drops with no bond.
2. **Session dying = pairing aborted.** If the `bluetoothctl` process gets EOF on
   stdin (e.g. the shell that launched it exits), bluetoothctl quits and
   bluetoothd cancels the in-flight pairing. The driver session must stay alive
   the whole time you're typing the passkey.
3. **`Error.InProgress`.** Firing `pair` repeatedly stacks attempts; a stuck one
   blocks all new ones. Clear it with `cancel-pairing` (+ `remove`).
4. **Scan churn / "not available".** With discovery running, BlueZ ages the
   device out of its cache between discovery and `pair`, giving
   `Device ... not available`. Make sure the device is freshly cached
   (`bluetoothctl info <dev>` succeeds) right before `pair`.
5. **Don't `remove` then immediately `pair`.** `remove` wipes it from cache;
   you must re-`scan` until it's rediscovered before pairing again.

## The fix (working procedure)

Put the MX Keys in pairing mode: hold an Easy-Switch channel button (1/2/3)
until its LED **blinks fast**.

The key requirement is a **persistent** bluetoothctl session (survives across
commands) with a `KeyboardDisplay` agent. One reliable way — a FIFO whose
write-end is held open by `sleep infinity` so bluetoothctl never sees EOF:

```bash
DEV="D0:6C:68:42:FB:C9"

# 1. Persistent session: FIFO held open by sleep infinity, bluetoothctl reads it
rm -f /tmp/btc_in /tmp/btc_out
mkfifo /tmp/btc_in
sleep infinity > /tmp/btc_in &                       # holds write-end open
bluetoothctl < /tmp/btc_in > /tmp/btc_out 2>&1 &     # background, stays alive

# 2. Set up the agent that DISPLAYS the passkey
echo "agent KeyboardDisplay" > /tmp/btc_in
echo "default-agent"         > /tmp/btc_in
echo "power on"              > /tmp/btc_in

# 3. Discover, confirm it's cached, THEN pair (keep scan on)
echo "scan on" > /tmp/btc_in
until bluetoothctl info "$DEV" >/dev/null 2>&1; do sleep 1; done
echo "pair $DEV" > /tmp/btc_in

# 4. Read the displayed passkey from the log
grep -aoE "Passkey: [0-9]{6}" /tmp/btc_out | tail -1
```

Then **type that 6-digit passkey on the MX Keys and press Enter** (the digits do
not echo to screen). Within a few seconds:

```bash
bluetoothctl info "$DEV" | grep -iE "Paired|Bonded|Connected"
# Paired: yes / Bonded: yes / Connected: yes
```

Finalise so it auto-reconnects on future power-ups, and verify the input nodes:

```bash
echo "trust $DEV"   > /tmp/btc_in
echo "connect $DEV" > /tmp/btc_in

grep -iA5 "MX Keys" /proc/bus/input/devices | grep -iE "Name|Handlers"
# N: Name="MX Keys Keyboard"   H: Handlers=sysrq kbd leds event20
# N: Name="MX Keys Mouse"      H: Handlers=event21 mouse2
```

Cleanup the helper session when done:

```bash
echo "quit" > /tmp/btc_in; pkill -x bluetoothctl; rm -f /tmp/btc_in /tmp/btc_out
```

## If it wedges again

- `Error.InProgress` / hung "Attempting to pair":
  `cancel-pairing $DEV`, then `disconnect $DEV`, then `remove $DEV`.
- `Device ... not available`: re-`scan on` and wait until
  `bluetoothctl info $DEV` succeeds before `pair`.
- Keyboard stopped advertising (each failed cycle can drop it out of pairing
  mode): re-enter pairing mode (hold the channel button until LED blinks fast).
- Make sure no other paired host is grabbing the keyboard on that Easy-Switch
  channel.
- Nuclear option for a thoroughly wedged BlueZ: `sudo systemctl restart bluetooth`
  (trusted devices like the MX Master 3 auto-reconnect), then redo from step 2.

## Notes

- `trust` matters: without it the keyboard may not auto-reconnect after a
  power-cycle.
- The BLE keyboard appears with a USB-style Logitech VID/PID via the `uhid`
  virtual-HID layer — normal, not the Unifying receiver.
- KDE's GUI may still show a stale "failed"/disconnected tile; the working bond
  is the CLI one. Remove the stale tile in the GUI, or `bluetoothctl remove`
  and redo if you want to start over.

---
_Documented 2026-06-07. Arch Linux, BlueZ / bluetoothd. Pairing completed with a
live passkey (example from this session: 409594)._
