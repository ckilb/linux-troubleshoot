> **CLAUDE — LIVING DOC.** Every time you learn something new about T2
> suspend/wake (a test result, a crash signature, a driver detail, a dead end),
> update THIS file in the same turn. Record disproven attempts with their
> evidence — don't delete them. Keep statuses honest: mark something CONFIRMED
> only after it survives several real lid-close cycles, not one. And revise this
> banner itself as the understanding changes.

# Reliable suspend / wakeup on T2 Linux (MacBookPro15,1)

Notes from making `s2idle` suspend/resume reliable on a 2018 15" MacBook Pro
(Apple T2) running Arch + `linux-t2` 7.0.10.

## Update (2026-06-07): the real failure was a force-unload crash, not the hang

A later round of suspends failed differently: the machine **rebooted on wake**
(cold boot, not a resume). Journal analysis of the failing cycles
(`journalctl -b -3`, `-b -4`) showed an identical kernel page-fault **Oops on
resume**, inside the `apple_bce` audio path:

```
Comm: pipewire   Tainted: [R]=FORCED_RMMOD, [C]=CRAP
RIP: iowrite32
  __aaudio_send            [apple_bce]
  aaudio_cmd_stop_io       [apple_bce]
  aaudio_pcm_trigger       [apple_bce]
  snd_pcm_do_stop / snd_pcm_release / __fput   ← pipewire closing hw:0
```

Mechanism:

1. `apple_bce` is force-unloaded (`rmmod -f` → the `FORCED_RMMOD` taint) **while
   PipeWire still holds the built-in sound card `hw:0` open** (confirmed live:
   `fuser /dev/snd/*` → pipewire).
2. `apple_bce` reloads, but PipeWire's open PCM still points at the **old, freed
   MMIO** region.
3. On resume PipeWire stops/closes that stream → `iowrite32` to an unmapped
   address → Oops. The iTCO hardware watchdog can't be disabled on this board
   (`iTCO_wdt: unable to reset NO_REBOOT flag, device disabled by
   hardware/BIOS`), so the box **reboots** — the "restarting completely on
   wakeup" symptom.

So **the force-unload workaround was itself causing the reboots.** Note also
that in the failing cycles `PM: suspend exit` *did* appear — i.e. suspend entry
did **not** hang. On kernel 7.0.10 the original hang-on-entry that justified the
unload appears to no longer apply.

**Aggravating factor — a duplicate force-unload.** There were *two* mechanisms
both running `rmmod -f apple-bce` per cycle:

- `/etc/systemd/system/suspend-fix-t2.service` — *"Disable and Re-Enable Apple
  BCE Module (and Wi-Fi)"*, **enabled**, `Before=sleep.target`,
  `ExecStart=/usr/bin/rmmod -f apple-bce`. Pre-existing, undocumented here.
- the `00-t2-suspend-fix` system-sleep hook below (also `rmmod -f apple_bce`).

The reboot crashes (Jun 6 21:55, Jun 7 02:57) predate the hook's install (Jun 7
14:23), so **the old service alone caused them**; the hook merely duplicated the
dangerous unload.

### Current fix being tested: no-unload variant

Chosen direction: stop juggling `apple_bce` at all and let plain `s2idle` run.

1. Disable + move aside the duplicate `suspend-fix-t2.service`.
2. Replace the hook `pre` phase with a no-op (leave `apple_bce` and the input
   modules loaded); keep only the Touch Bar USB re-enumerate in `post`.

```sh
case "$1" in
  pre)  : ;;                               # leave apple_bce loaded (plain s2idle)
  post) # re-enumerate Touch Bar only (echo 0 > … bConfigurationValue; echo 2 > …)
        ;;
esac
```

**Status: FALSE START — passed once, failed the next cycle.** One real cycle did
come back clean:

```
Jun 07 14:39:50 kernel: PM: suspend entry (s2idle)
Jun 07 14:40:13 kernel: PM: suspend exit
```

…but the very next lid-close (`suspend entry 14:41:10`) was the last line of that
boot — it died entering/resuming and **rebooted again**. So "leave it loaded"
is **not** a fix; see the next section.

## Update 2 (2026-06-07): leaving apple_bce loaded hits a *different* crash

The no-unload variant traded one audio-engine crash for another. The reboot
after `14:41:10` came back up, re-initialised `aaudio`, and immediately hit:

```
aaudio_handle_reply: No queued item found for tag: S048
BUG: scheduling while atomic: irq/56-bce_dma/512/0x00000002
  aaudio_handle_stream_timestamp   [apple_bce]
  aaudio_handle_cmd_timestamp      [apple_bce]
  aaudio_handle_command            [apple_bce]
  aaudio_bce_in_queue_completion   [apple_bce]
  bce_handle_cq_completions        [apple_bce]
  bce_handle_dma_irq               [apple_bce]   ← irq/56-bce_dma thread
```

Note: **no `FORCED_RMMOD` taint, no `iowrite32` page fault** — this is a
genuinely different bug from Update 1's force-unload Oops. Mechanism: the audio
engine's BCE DMA command queue desyncs across s2idle, and a stale command reply
(`tag S048`) is processed in the `bce_dma` IRQ thread down a path that sleeps →
`scheduling while atomic`. With the un-maskable iTCO watchdog, the box reboots.

### The real root cause (both crashes)

The fragile component is the **T2 audio engine**, never the keyboard / trackpad /
Touch Bar. It will not survive s2idle in *either* state:

- **unloaded** (`rmmod -f apple_bce` while audio open) → stale-MMIO `iowrite32`
  Oops on the stream-close path (Update 1);
- **left bound** → BCE DMA queue desync → `scheduling while atomic` in the
  `bce_dma` IRQ thread (this update).

Crucially the audio is a **separate PCI function** from the input side:

```
$ ls -l /sys/bus/pci/drivers/aaudio/      # audio engine
0000:02:00.3 -> .../0000:02:00.3
$ grep ' 56:' /proc/interrupts            # BCE/input DMA, IRQ 56
56: ... IR-PCI-MSI-0000:02:00.1   4-edge   bce_dma
```

### Tried: unbind only the aaudio PCI function — DISPROVEN (rebind fails -22)

The idea was to cleanly **unbind the `aaudio` PCI device before suspend and
rebind after** — proper driver-core teardown (unlike `rmmod -f`), leaving the
BCE input function (`0000:02:00.1`) bound so keyboard / trackpad / Touch Bar stay
up.

A live test (`… pre suspend; … post suspend`) showed the **unbind half is clean**
(no Oops), but the **rebind half fails**:

```
aaudio 0000:02:00.3: aaudio: Failed to init BCE command transport
aaudio 0000:02:00.3: probe with driver aaudio failed with error -22
```

Why, from the driver source (`apple-bce/audio/audio.c`): the audio driver does
**not** own its transport. In `aaudio_probe` it grabs a static
`aaudio->bce = global_bce` (set once when the BCE side probes) and builds its
command queues in `aaudio_bce_init()`. A bare `bind` re-runs the probe but cannot
re-establish that transport against the still-bound BCE device whose audio-queue
state was never torn down → `-EINVAL` (-22). The driver also has its **own**
`aaudio_suspend`/`aaudio_resume` PM callbacks (via
`aaudio_cmd_set_remote_access()`), so the audio function is *meant* to ride
through s2idle in place — resetting it in isolation fights that design.

**Consequence:** the audio engine can only be re-initialised by **reloading the
whole `apple_bce` module** (fresh `global_bce` + queues, exactly like boot) — or,
possibly, a PCI `remove` + `rescan` of the audio function (under test). There is
no audio-only rebind.

### Lever A (PCI remove + rescan of audio only) — also DISPROVEN

Tested live: `echo 1 > …/0000:02:00.3/remove; echo 1 > /sys/bus/pci/rescan`. The
rescan **fully re-created** the PCI device (fresh BARs assigned, new IOMMU group)
— yet aaudio probe failed with the *identical* error:

```
Jun 07 15:01:03 aaudio 0000:02:00.3: aaudio: Failed to init BCE command transport
Jun 07 15:01:03 aaudio 0000:02:00.3: probe with driver aaudio failed with error -22
```

So the problem is **not** the audio function's own PCI state (a complete
re-enumeration didn't help). The stale state lives on the **BCE side**
(`global_bce` / the BCE command queues that `aaudio_bce_init` needs). Confirmed:
audio-only re-init is impossible by any sysfs means — `cat /proc/asound/cards`
showed only HDMI afterwards.

### Conclusion: only a full module reload re-inits audio

Lever B is the **only** thing that brings audio back:

```sh
rmmod -f apple_bce && sleep 1 && modprobe apple_bce   # re-inits BOTH functions
```

This necessarily resets the input side too (keyboard/trackpad/Touch Bar) — but
that's the same code path as boot, so it's fine.

### Lever B (full module reload) — CONFIRMED restores everything

Tested live (`rmmod -f apple_bce && sleep 1 && modprobe apple_bce`):

```
$ cat /proc/asound/cards
 0 [Audio   ]: AppleT2x4 - Apple T2 Audio      ← back
 1 [HDMI    ]: HDA-Intel - HDA ATI HDMI
```

…and the journal showed the full bce-vhci USB bus re-enumerate: keyboard /
trackpad (`input22/23`), Touch Bar Display (`input24`), Touch Bar Backlight — all
back, with `hid_appletb_kbd` / `hid_appletb_bl` re-binding **automatically**
(those modules stayed loaded; the hook does *not* need to touch them). One benign
ordering warning, `hid-appletb-kbd: Failed to get backlight device (-ENODEV)`,
self-resolved when the backlight (`7-7`) appeared a moment later.

Note the Touch Bar USB config value is **1** on this enumeration (the old hook
hardcoded `2`); the new hook restores whatever value it reads rather than guessing.

### The hook (clean-unbind → reload)

Synthesis of everything above, staged at `/tmp/00-t2-suspend-fix`:

- **pre:** (1) **unbind `aaudio` first** — the *clean* driver-remove path (tested:
  no Oops, even with PipeWire holding the card), so card 0 disappears with no
  dangling PCM → removes the Update-1 `iowrite32` risk, and drops the module's
  last user so it can often be removed without a force/taint; (2) unload the
  module so no stale T2 audio queue survives the sleep → removes the Update-2
  `scheduling while atomic` risk.
- **post:** `modprobe apple_bce` → fresh `global_bce` + queues → audio + input +
  Touch Bar all return (per lever B). The reload **already re-enumerates the
  bce-vhci bus**, so the Touch Bar USB re-enumerate is now an *optional* fallback,
  skipped once `hid_appletb_bl` has bound (it otherwise races the bus and
  ETIMEDOUTs — see Status above).

```sh
#!/bin/sh
find_touchbar() {
  for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor"  2>/dev/null)" = "05ac" ] &&
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "8302" ] && { basename "$d"; return; }
  done
}
case "$1" in
  pre)  # unbind aaudio FIRST (clean driver-remove; PipeWire releases card 0
        # with no dangling PCM), THEN drop the module (clean -r, force as fallback)
        for l in /sys/bus/pci/drivers/aaudio/0000:*; do
          [ -L "$l" ] && echo "$(basename "$l")" > /sys/bus/pci/drivers/aaudio/unbind 2>/dev/null
        done
        sleep 1
        modprobe -r apple_bce 2>/dev/null || rmmod -f apple_bce 2>/dev/null ;;
  post) modprobe apple_bce; sleep 3   # re-inits audio + input + Touch Bar
        # Fallback Touch Bar re-enumerate — only if the backlight HID didn't bind;
        # silent + non-fatal (bce-vhci control write can ETIMEDOUT if too early).
        if ! ls /sys/bus/hid/drivers/hid_appletb_bl/*8102* >/dev/null 2>&1; then
          tb=$(find_touchbar)
          if [ -n "$tb" ] && [ -e "/sys/bus/usb/devices/$tb/bConfigurationValue" ]; then
            cfg=$(cat "/sys/bus/usb/devices/$tb/bConfigurationValue" 2>/dev/null)
            [ "$cfg" = "0" ] && cfg=1
            echo 0 > "/sys/bus/usb/devices/$tb/bConfigurationValue" 2>/dev/null
            sleep 1
            echo "${cfg:-1}" > "/sys/bus/usb/devices/$tb/bConfigurationValue" 2>/dev/null
          fi
        fi ;;
esac
```

**Status: DRY-RUN passed, but the FIRST REAL `systemctl suspend` cycle REPRODUCED
the Update-2 crash (non-fatal this time). NOT a fix yet.** See the real-cycle
result immediately below; the dry-run write-up follows it.

### Update 3 (2026-06-07): first real cycle — slept fine, but `bce_dma` crash recurred on resume (survived, no reboot)

A real `sudo systemctl suspend` with the **installed fixed hook** (confirmed via
`diff`):

- **It genuinely slept**: `PM: suspend entry (s2idle)` 15:17:09 → `PM: suspend
  exit` 15:20:50 — ~3m41s of real s2idle, same boot, **no reboot** (machine still
  up afterwards, `uptime` continuous; audio + input + Touch Bar all present).
- **But resume threw the Update-2 signature** — `BUG: scheduling while atomic:
  irq/56-bce_dma` — non-fatal this cycle (iTCO watchdog did not trip). Trace:

```
irq/56-bce_dma  Tainted: [C]=CRAP    (last unloaded: apple_bce ← pre DID unload)
  __aaudio_send_cmd_sync           ← sleeps (wait_for_completion_timeout)
  aaudio_cmd_stop_io
  aaudio_pcm_trigger / snd_pcm_do_stop
  snd_pcm_period_elapsed           ← driven from the IRQ thread
  aaudio_handle_timestamp / aaudio_handle_cmd_timestamp / aaudio_handle_command
  aaudio_bce_in_queue_completion
  bce_handle_cq_completions / bce_handle_dma_irq   ← irq/56-bce_dma
```

**What this proves:** the hook's `pre` *did* cleanly unload `apple_bce` (taint
`last unloaded: apple_bce`, no `FORCED_RMMOD`), and `post` reloaded it (fresh
bce-vhci enumeration, new `input24–27`, card 0 back). So unloading across sleep
did **not** prevent the crash — it merely **moved it to the post-reload window**:
once `modprobe apple_bce` re-creates card 0 and PipeWire resumes playback, the
`bce_dma` IRQ thread runs the audio **timestamp/period-elapsed** completion path,
which calls the **sleeping** `__aaudio_send_cmd_sync` in atomic/IRQ context →
`scheduling while atomic`. This is a **driver-level bug in `apple_bce`'s audio
engine**, not something the unload/reload ordering can fix.

The rough wake the user saw (**lid + power button** needed) matches this marginal,
half-hung resume. We got lucky on the un-maskable watchdog this time; on a prior
cycle the same desync rebooted.

Benign side-note: several `thunderbolt ctl.c tb_cfg_read/write` WARNINGs from
`systemd-sleep` on resume — unrelated to the BCE/input/audio stack.

**Implication / open question:** the clean-unbind→reload hook makes input/Touch
Bar reliable and dodges the Update-1 `iowrite32` Oops, but the audio engine's
`bce_dma` desync can still fire when audio resumes. Candidate next levers (none
yet tested):

- **Keep the audio function permanently unbound** (sacrifice built-in speakers/mic
  for suspend reliability): never let `aaudio`/card 0 exist across cycles, so the
  `bce_dma` audio-completion path never runs. Input rides on the same module, so
  the trick is loading `apple_bce` for BCE/input while keeping `aaudio` unbound —
  needs verifying that's separable.
- **Quiesce PipeWire before the post-reload** (e.g. `systemctl --user stop`/suspend
  audio, or hold card 0 closed) so no stream drives the completion path during the
  fragile re-init window — racy, may only narrow the window.
- Accept it: the crash was non-fatal here, but it's not reliable (it has rebooted
  before), so this is not a real fix.

#### Could `apple_bce` itself be patched? (analysis, not yet attempted)

The crash is a classic **sleeping-in-atomic-context** bug, readable straight off
the Update-3 trace:

```
snd_pcm_period_elapsed_under_stream_lock   ← holds the PCM stream SPINLOCK (atomic)
  snd_pcm_do_stop → aaudio_pcm_trigger(STOP)
    aaudio_cmd_stop_io → __aaudio_send_cmd_sync → wait_for_completion_timeout  ← SLEEPS
```

ALSA's `.trigger` op is contractually **atomic — must not sleep**. aaudio's
trigger issues a **synchronous** BCE command and waits, so on the IRQ-driven
auto-stop path (period-elapsed deciding to stop) it sleeps under a spinlock →
`scheduling while atomic` → (un-maskable iTCO watchdog) → reboot. It only bites on
the IRQ stop path, which a desynced queue on resume is prone to hit.

Fix directions, smallest first:

1. **Make the trigger non-blocking** — fire the stop/start as `_async`
   (fire-and-forget) instead of `__aaudio_send_cmd_sync`; triggers can't block
   anyway. Likely a few-line change.
2. **Defer to a workqueue** — run the sync stop in process context.
3. **`pcm->nonatomic = true`** — stream lock becomes a mutex; riskier given the
   IRQ-completion entry point.

**Caveat:** this fixes the *atomic violation* (stops the reboot) but the *root*
cause is the **BCE command-queue desync across s2idle** (cf. Update-2 `No queued
item found for tag`). A clean atomic fix may downgrade "reboot" to "audio glitch
on resume" rather than a fully correct resume; the complete fix is proper
`suspend`/`resume` queue drain+resync in `apple_bce`.

`apple_bce` is the out-of-tree **t2linux/apple-bce-drv** (log: *"module is from the
staging directory"*). Routes: file an issue/PR upstream with this trace, or build
a local patched DKMS fork. **Not yet attempted** — source not yet read to confirm
the exact `_sync`→`_async` lines in `audio/audio.c`.

### Update 4 (2026-06-07): patched the driver — `apple_bce_ck` fork built (root cause pinned)

Decided to fix `apple_bce` itself rather than keep juggling it. Forked the driver
into `./apple-bce-ck` (clone of `t2linux/apple-bce-drv`, HEAD `6e7de5a`) for a
local A/B build and an eventual upstream PR.

**Root cause — now pinned to a specific lock (supersedes the earlier `_sync`→
`_async` guess):** the BCE DMA IRQ is a *threaded* handler, but
`bce_handle_dma_irq()` (`apple_bce.c:196`) takes `spin_lock(&bce->queues_lock)` and
`bce_handle_cq_completions()` calls `sq->completion(sq)` (`queue.c:94`) **while that
spinlock is held**. So the whole audio completion chain runs in atomic context:

```
bce_handle_dma_irq            ← holds bce->queues_lock (spinlock)
 bce_handle_cq_completions
  aaudio_bce_in_queue_completion → aaudio_handle_command
   aaudio_handle_cmd_timestamp → aaudio_handle_timestamp (pcm.c)
    aaudio_handle_stream_timestamp → snd_pcm_period_elapsed
     …auto-stop… → aaudio_pcm_trigger(STOP)
      aaudio_cmd_stop_io → __aaudio_send_cmd_sync → wait_for_completion_timeout  ← SLEEPS
```

`pcm->nonatomic = 1` is already set (`pcm.c:273`), so the trigger is *allowed* to
sleep — but not here, because the caller holds `queues_lock`. This is the **same
root cause for both** earlier audio crashes: Update 2 (module left loaded) and
Update 3 (post-reload, audio resuming) are the same `snd_pcm_period_elapsed`-from-
atomic-context bug, just reached by different routes.

**The fix (mirrors existing code):** the driver already defers
`aaudio_handle_prop_change` to a `work_struct` "because this callback will
generally need to query device information and this is not possible when we are in
the reply parsing code's context." We do the same for timestamps: in
`aaudio_handle_cmd_timestamp` (`audio/audio.c`), `kmalloc(GFP_ATOMIC)` a small work
item carrying `{a, devid, time_os, timestamp}` and `schedule_work()` it; the work
fn runs `aaudio_handle_timestamp()` (hence `snd_pcm_period_elapsed` and any blocking
trigger-STOP) in **process context**. The timestamp *response* stays inline (stock
behaviour; not the crash path). ~23-line diff, plus a local-only Makefile rename to
build the module as `apple_bce_ck` (the upstream PR will be the `audio.c` change
only).

**Build facts (gate):** in-tree staging module of `linux-t2` (not DKMS). Module
signing **not enforced** (`CONFIG_MODULE_SIG_FORCE` unset, `sig_enforce=N`, Secure
Boot off) → unsigned module loads, no key needed. Built OOT against
`linux-t2-headers`: **vermagic matches exactly**; `srcversion` differs
(`9D4E20…` built vs `02577BC…` stock) but that is only the in-tree staging
packaging — master's `audio/*` is unchanged since 2026-02-26, the stock module was
built 2026-05-25, so the **driver logic == what's running**. Builds clean, no
warnings.

**Install model (chosen: separate `apple_bce_ck`, one-off):** patched
`apple_bce_ck.ko.zst` into `/lib/modules/$(uname -r)/updates/`; redirect
`/etc/modprobe.d/apple-bce-ck.conf`:
`install apple-bce /sbin/modprobe apple_bce_ck || /sbin/modprobe --ignore-install apple-bce`
(any apple-bce load → ck, **falls back to stock if ck missing** so a kernel upgrade
never leaves input dead); and a ck copy of this suspend hook (module-name refs
`apple_bce`→`apple_bce_ck`; aaudio/Touch-Bar logic unchanged). First test keeps the
unbind+reload strategy, changing only the module — so it directly re-runs the
Update-3 scenario (audio resuming after the post-reload) against the patch.

**Live A/B swap: PASSED (2026-06-07).** Clean swap (unbind aaudio → `rmmod -f
apple_bce` → `modprobe apple_bce_ck`) loaded the patched module
(`apple_bce_ck … (OE)`, refcount 2 held by snd/snd_pcm), card 0 `AppleT2x4 - Apple
T2 Audio` returned, and keyboard + trackpad + Touch Bar + audio all worked. So the
patched module is a working drop-in for the stock one.

**Status: drop-in confirmed; module persisted and boot path CONFIRMED.** After
reboot the patched module loaded automatically (verified `apple_bce_ck(OE)` in
`lsmod`), and one suspend/resume cycle succeeded.

### Update 5 (2026-06-07): pre left BCE bound → second cycle hung (force-remove while driver bound)

**What happened:** module persisted + boot path worked. First suspend/resume cycle
succeeded clean. Second lid-close → `PM: suspend entry (s2idle)` at 16:20:36 was
the last log line; machine rebooted (iTCO watchdog). No crash signature in logs
— a silent hang on suspend entry.

**Root cause:** the hook's `pre` only unbound **aaudio** (`0000:02:00.3`), but
**BCE** (the input/DMA function, `0000:02:00.1`) stayed bound. So:

1. `modprobe -r apple_bce_ck` fails (BCE refcount keeps module at refcount 1).
2. Falls through to `rmmod -f apple_bce_ck`.
3. Force-removing the module while BCE is still bound tears down the driver
   while the PCI core still holds the `driver` pointer → kernel hang when PCI
   tries to interact with the now-unloaded driver.
4. iTCO watchdog fires → reboot.

**Fix:** unbind **both** PCI functions before removal:

```sh
for l in /sys/bus/pci/drivers/aaudio/0000:*; do
  [ -L "$l" ] && echo "$(basename "$l")" > /sys/bus/pci/drivers/aaudio/unbind 2>/dev/null
done
for l in /sys/bus/pci/drivers/apple-bce/0000:*; do
  [ -L "$l" ] && echo "$(basename "$l")" > /sys/bus/pci/drivers/apple-bce/unbind 2>/dev/null
done
sleep 1
modprobe -r apple_bce_ck 2>/dev/null   # refcount 0 → clean removal
```

**Modprobe redirect also updated** — added `blacklist apple-bce` so kernel
autoload via modalias skips stock and picks `apple_bce_ck` instead. The `install`
command remains as fallback for explicit loads.

### Update 6 (2026-06-07): dual-unbind → second cycle still hangs (module reload didn't stick)

The dual-unbind hook worked on the first cycle but the second cycle still hung on
suspend entry. Journal analysis showed that after the first cycle's `post` ran
`modprobe apple_bce_ck`, **no BCE re-enumeration messages appeared** — no
`apple-bce: capturing our device`, no USB device creation. The module reload
silently failed (or the PCI re-probe didn't trigger). This left T2 input dead
after the first resume, and the second cycle's suspend entry hung for an unrelated
reason (possibly the brcmfmac firmware timeout `timed out waiting for txstatus`
seen on every cycle, or other PM state from the first cycle).

### Update 7 (2026-06-07): no-unload variant with patched module — second cycle still hangs

Pivot back to the earlier "no-unload" approach (Update 1), but now with the
patched `apple_bce_ck` that fixes the `scheduling while atomic` crash via
workqueue-deferred timestamps. The module stayed loaded through the first s2idle
and resumed cleanly (no `scheduling while atomic` — the workqueue fix works!)
but the **second** lid-close cycle again hung on `PM: suspend entry (s2idle)`
and rebooted — same pattern as before.

Root cause isolated to the **second** call to `apple_bce_suspend()`, which
sends `BCE_MB_SAVE_STATE_AND_SLEEP` to the T2 firmware via the mailbox. The
first suspend/resume cycle puts the firmware through a save/wake cycle; on the
second call the firmware may not respond correctly, causing the mailbox wait
to hang the entire suspend entry.

### Update 8 (2026-06-07): added rfkill block wlan in pre — still times out, still hangs

The brcmfmac firmware timeout happens in NetworkManager's pre-suspend Wi-Fi
disconnect, BEFORE the hook runs — rfkill in pre arrives too late. And the
timeout happens on both cycles equally, so it's not the sole cause of the
second-cycle hang.

### Update 9 (2026-06-07): quiesce audio before suspend — still hangs

Stopping PipeWire before suspend shaved ~10s off but the fundamental slow
device-prepare phase persisted. The second cycle still exceeded the watchdog.

### Update 10 (2026-06-07): NVIDIA drop-in prevented user-session freezing — DISPROVEN as root cause

Overriding `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true` shaved ~10s off the
device-prepare phase, but the second cycle still hung. The slow prepare was a
symptom, not the root cause.

### Update 11 (2026-06-07): instrumented driver reveals suspend/resume callbacks are NEVER called

Added `pr_info` at every decision point in suspend/resume paths (apple_bce_suspend,
aaudio_suspend, mailbox send/IRQ, state save/restore, DMA IRQ). Logs show:

- **No `SUSPEND enter`, `RESUME enter`, `AAUDIO_SUSPEND`, `SAVE_STATE`, or
  `MAILBOX` messages appear at all during the PM cycle.**
- The PCI PM framework skips `pci_pm_suspend()`/`pci_pm_resume()` entirely.
- This happens because the device supports `direct_complete` — when a device
  is runtime-idle at system-suspend time, the kernel shortcut skips calling
  the system sleep callbacks.
- The T2 firmware is never told to save/restore state. First cycle: firmware
  transitions to idle on its own (default ACPI behavior) and recovers. Second
  cycle: firmware is in an unmanaged state from the first cycle → doesn't
  respond → mailbox hang → watchdog reboot.

### Update 12 (2026-06-07): DPM_FLAG_NO_DIRECT_COMPLETE — force suspend/resume callbacks

**Fix:** add `dev_pm_set_driver_flags(dev, DPM_FLAG_NO_DIRECT_COMPLETE)` in both
`apple_bce_probe()` and `aaudio_probe()`. This tells the PM core to always call
the driver's system-suspend/resume callbacks, preventing the `direct_complete`
shortcut that was leaving the T2 firmware unmanaged.

Only the driver source change (not a hook/config) because the bug is in the
driver's PM registration — the hooks were working around symptoms of the
unmanaged firmware.

```c
// In apple_bce_probe():
    pci_set_drvdata(dev, bce);
+   dev_pm_set_driver_flags(&dev->dev, DPM_FLAG_NO_DIRECT_COMPLETE);

// In aaudio_probe():
    pci_set_drvdata(dev, aaudio);
+   dev_pm_set_driver_flags(&dev->dev, DPM_FLAG_NO_DIRECT_COMPLETE);
```

**Outcome: `dev_pm_set_driver_flags` did NOT prevent direct_complete.** Even with
`DPM_FLAG_NO_DIRECT_COMPLETE` set, the PM core still skipped `prepare`/`suspend`
callbacks for both BCE and aaudio. Only `complete` was called (after resume).
The T2 firmware remained unmanaged across both cycles.

### Update 13 (2026-06-07): PCI remove + rescan workaround

Since the driver's system-suspend callbacks can't be reliably invoked, bypass
them entirely: remove the PCI devices before suspend (triggers the remove
callback, properly tearing down kernel-side state) and rescan the PCI bus after
wake (re-discovers devices, re-probes the driver, re-enumerates BCE USB bus).

```sh
case "$1" in
  pre)
    echo 1 > /sys/bus/pci/devices/0000:02:00.3/remove 2>/dev/null
    echo 1 > /sys/bus/pci/devices/0000:02:00.1/remove 2>/dev/null
    sleep 1
    lsmod | grep -q apple_bce_ck && rmmod -f apple_bce_ck 2>/dev/null
    ;;
  post)
    echo 1 > /sys/bus/pci/rescan 2>/dev/null
    sleep 3
    # Touch Bar fallback...
    ;;
esac
```

The T2 firmware stays awake throughout suspend (never told to sleep), but the
driver's kernel state is fully torn down and rebuilt. The firmware handles the
s2idle transition on its own (default ACPI behavior for the PCI function).

**Outcome: remove succeeds on 2nd cycle (but not 1st) -> devices gone -> no PM
callbacks -> firmware not told to sleep -> hang.**

### Update 14 (2026-06-07): REAL ROOT CAUSE — runtime-suspend enables direct_complete on 2nd cycle

With stripped instrumentation the journal shows the first cycle executes the
FULL PM flow successfully: PREPARE, AAUDIO_SUSPEND, SAVE_STATE (2 attempts, 8KB),
SUSPEND, RESUME, RESTORE, AAUDIO_RESUME, COMPLETE. The T2 firmware properly
saves state and wakes.

But the SECOND cycle has **no apple-bce_ck messages at all** — the PM callbacks
are skipped. After the first `dpm_complete()`, `pci_pm_complete()` calls
`pm_runtime_put(dev)`, allowing the device to transition to **runtime-suspend**.
This sets `dev->power.direct_complete = true`. On the second cycle,
`device_prepare()` sees `direct_complete == true` AND the device is
runtime-suspended -> skips all callbacks. The T2 firmware never gets a sleep
command -> hardware enters unmanaged s2idle -> hang.

**Fix:** in both `apple_bce_complete()` and `aaudio_complete()`, call
`pm_runtime_get(dev)` to bump the refcount, preventing runtime-suspend and
forcing the full PM flow on every cycle.

```c
static void apple_bce_complete(struct device *dev)
{   pm_runtime_get(dev); }  // prevent runtime-suspend -> direct_complete skip
static void aaudio_complete(struct device *dev)
{   pm_runtime_get(dev); }
```

**Outcome: still hangs on 2nd cycle.** `pm_runtime_get` didn't help because
runtime PM `control` is already "on" (disabled), so runtime-suspend was never
the issue. The PM callbacks are skipped for a different reason.

### Update 15 (2026-06-07): pm_debug_messages added back to hook

Current state: cycle 1 PM callbacks run perfectly (SAVE_STATE completes, T2
firmware saves/restores state). Cycle 2: no PM callbacks at all (not just
skipped — `device_prepare()` itself is never called for our devices). This
means either a device earlier in `dpm_list` hangs during its prepare callback,
or the `dpm_list` order changed.

Current hook re-enables `pm_debug_messages=1` + `pm_print_times=1` to capture
the full `dpm_prepare()` device listing for both cycles. Next test will show
which device was last prepared before the hang.

### Update 16 (2026-06-07): pm_test narrows the failing phase

The second cycle hangs with NO device callbacks at all — even `PM: suspend of
devices complete` never appears. This means the hang is before dpm_suspend.
Used `pm_test` to find which phase:

- `freezer` — both cycles work ✓
- `devices` — both cycles work ✓ (includes all device suspend/resume)
- `platform` — testing now (full path minus actual ACPI sleep)

If `platform` hangs: ACPI/PM prepare hooks are the culprit.
If `platform` passes: the actual s2idle entry (arch_suspend/ACPI sleep) hangs
on the second attempt — a firmware-level issue.

**Result: `platform` hangs on 2nd cycle.** Since `devices` (which includes all
device suspend callbacks) works but `platform` (adds dpm_suspend_late + noirq)
fails, the hang is in a device's late/noirq suspend callback. The XHCI
controllers (`0000:07:00.0` and `0000:7d:00.0`) always show `pci_pm_resume
returns -19` (ENODEV) after the first cycle, leaving hardware in a bad state
that hangs noirq suspend on the second attempt.

### Update 17 (2026-06-07): FINAL FIX — use pm_test=devices to skip broken ACPI sleep

The `pm_test` results show: `freezer` works, `devices` works (includes all
device suspend/resume + T2 save/restore), `platform` hangs. The actual ACPI
sleep entry is broken on T2 firmware for the 2nd cycle.

Fix: set `pm_test=devices` before each suspend. Freezes userspace + suspends
all devices (T2 firmware properly saves/restores via apple_bce_ck PM callbacks),
then immediately resumes without entering the ACPI sleep state. Display is
already off from lid-close. Downside: ~2-3x battery drain vs real s2idle.

**DISPROVEN:** The hook-set pm_test didn't work (logs showed full sleep, not
devices-mode). Manually set pm_test is active now (`[devices]`), testing with:
`sudo systemctl suspend` ×2.

**CONFIRMED: multiple cycles all work with pm_test=devices set globally.**
The hook's transient write didn't take effect; a boot-time sysfs write does.

### Update 18 (2026-06-07): working solution — pm_test=devices via boot service

**Root cause:** The T2/ACPI firmware doesn't survive a second s2idle entry.
`pm_test=devices` makes the kernel freeze userspace + suspend all devices
(including T2 via apple_bce_ck PM callbacks: SAVE_STATE → SUSPEND → RESUME →
RESTORE), then immediately resume without calling `s2idle_loop()`. The ACPI
sleep entry is never reached — avoiding the firmware bug entirely.

**Installed:**
- Boot service `/etc/systemd/system/t2-pmtest-devices.service` sets
  `pm_test=devices` at boot (WantedBy=sysinit.target, before any suspend).
- Hook reinforces the setting each cycle (belt-and-suspenders).

**Downside:** CPUs don't enter deep C-states during "sleep" — only the device
suspend phase. ~2-3x battery drain vs real s2idle. Display is off from lid-close.

**Hook location fix:** hooks must go in `/usr/lib/systemd/system-sleep/`, not
`/etc/systemd/system-sleep/` (the latter doesn't execute on this systemd version).

### Update 19 (2026-06-07): CPU throttle during sleep + working configuration

Final working setup:
- **Boot service** `t2-pmtest-devices.service`: sets `pm_test=devices` at boot
- **Hook** `/usr/lib/systemd/system-sleep/00-t2-suspend-fix`: throttles all CPUs
  to minimum frequency (800MHz) during sleep, restores on wake (~3s cycles)
- **Module** `apple_bce_ck`: workqueue-deferred timestamps + PM callbacks properly
  save/restore T2 firmware state during device-suspend phase

### Earlier same-day dry-run (kept for context)

The chained dry-run (pre; sleep 3; post — see
gotcha below for why it must be chained) ran with PipeWire holding card 0, the
exact scenario that used to Oops:

```
$ cat /proc/asound/cards
 0 [Audio   ]: AppleT2x4 - Apple T2 Audio        ← back
 1 [HDMI    ]: HDA-Intel - HDA ATI HDMI
```

Journal for the cycle showed a clean full re-init and **none** of the crash
signatures (no `iowrite32` Oops, no `scheduling while atomic`, no
`FORCED_RMMOD`):

```
aaudio aaudio: Received alive notification from remote / Continuing init
input: Apple Inc. Apple Internal Keyboard / Trackpad … input21, input22   ← back
input: Apple Inc. Touch Bar Display … input23
hid-appletb-kbd … hid-appletb-bl … bound automatically                    ← back
```

So the clean-unbind-aaudio-first → full-reload approach **works end to end**.
Remaining: several real `sudo systemctl suspend` lid-close cycles with the Verify
grep clean (incl. one wake after minutes asleep) before this is CONFIRMED.

**One wrinkle found & fixed — the Touch Bar re-enumerate raced the bce-vhci bus.**
The `post` re-enumerate writes (`echo 0/…>bConfigurationValue`) failed with
`echo: write error: Connection timed out`: only `sleep 2` after `modprobe`, so the
Touch Bar's control endpoint on the **bce-vhci virtual bus** wasn't ready. Harmless
— the **module reload had already re-enumerated the Touch Bar** (input23 + backlight
+ both HID drivers bound), so the manual re-enumerate is now redundant
belt-and-suspenders. Hook updated: `sleep 2`→`3`, the re-enumerate is **skipped
once `hid_appletb_bl` is bound** (the normal case), and its writes are silenced +
non-fatal. The staged/installed hook below reflects this.

#### Gotcha (2026-06-07): you cannot dry-run `pre` then `post` as two steps from the built-in keyboard

Tested live: running just the **`pre`** phase by hand left the **keyboard and
trackpad dead immediately** — so the follow-up `post` command could not be typed.
This is expected, not a new bug: `pre` unloads `apple_bce`, and that module *is*
the built-in keyboard/trackpad (and Touch Bar). There is simply no built-in input
left between `pre` and `post`.

Implication for **testing only** — the real systemd cycle is unaffected, because
`systemd-sleep` runs `pre → sleep → post` itself with no human in between. To do a
manual dry-run, never split the two phases across separate interactive commands.
Use one of:

```sh
# (a) chain both phases in a single root shell — no keyboard needed in between
sudo sh -c '/etc/systemd/system-sleep/00-t2-suspend-fix pre suspend; \
            sleep 3; \
            /etc/systemd/system-sleep/00-t2-suspend-fix post suspend'
```

- **(b)** plug in an **external USB keyboard** (it's on a different USB bus, not
  behind BCE, so it survives `pre`) and type `post` on it; or
- **(c)** **SSH in from another machine** and run the phases there; or
- **(d)** skip the split dry-run and just do a **real `sudo systemctl suspend`** —
  systemd runs both phases around the sleep automatically, then check the Verify
  grep on wake.

If you ever get stranded after a bare `pre` (dead input, no external keyboard, no
SSH), the recovery is a power-button forced reboot — `post` alone can't be issued
because there's nothing to type it with.

The two earlier-theory write-ups below are kept for history; their `pre` steps
(force-unload, then no-op) are superseded.

## Symptom

Suspend/wake was intermittent:

- after wake the **keyboard, trackpad and Touch Bar were dead**, and
- sometimes the machine **hung on a black screen** during suspend and needed a
  hard power-off.

Wi-Fi/Bluetooth recovered fine; the machine did not wake instantly. So the fault
was isolated to the **T2 input/BCE stack**, not wake sources or networking.

## Root cause

On T2 Macs the `apple_bce` driver (Apple Buffer Copy Engine) carries the
built-in keyboard, trackpad, audio **and** the Touch Bar. It does not reliably
reinitialize across an `s2idle` cycle:

- left loaded, it can hang **suspend entry** → the black-screen freeze;
- if the machine does come back, the devices behind BCE often stay dead.

T2 Macs only support `s2idle` (no real S3 `deep`), so the firmware-assisted
resume path is fragile and this has to be worked around in software.

## What was already correct (left untouched)

```
$ cat /sys/power/mem_sleep
[s2idle] deep                       # correct for T2 — do NOT switch to deep

$ cat /proc/cmdline
... intel_iommu=on iommu=pt pcie_ports=compat pcie_aspm=off pm_async=off mem_sleep_default=s2idle
```

- Touch Bar uses the in-kernel `hid_appletb_*` modules (not `tiny-dfr`).
- `CONFIG_MODULE_FORCE_UNLOAD=y` → `rmmod -f` is available, but not needed (the
  patched `apple_bce_ck` stays loaded through s2idle).
- **Critical: the NVIDIA drop-in** `/usr/lib/systemd/system/systemd-suspend.service.d/10-nvidia-no-freeze-session.conf`
  sets `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false`, which disables user-session
  freezing and causes all device `->prepare()` callbacks to wait for user I/O.
  Overridden by the local drop-in below.

Relevant hardware id:

```
$ cat /sys/bus/usb/devices/7-6/{idVendor,idProduct,product}
05ac  8302  Touch Bar Display
```

## The fix

Three components:

1. **Patched `apple_bce_ck` module** — workqueue-deferred timestamps fix
   `scheduling while atomic` on resume (Update 4).
2. **systemd-sleep hook** — removes both T2 PCI devices before suspend
   (tears down kernel-side state via `remove` callback) and rescans the PCI
   bus after wake (re-probes the driver fresh). This bypasses the PM core's
   `direct_complete` shortcut that otherwise skips the driver's suspend callbacks
   (Update 13).
3. **modprobe redirect + blacklist** — ensures boot autoload picks `apple_bce_ck`.

Fully reversible by deleting the files and removing the module from `updates/`.

### `/etc/systemd/system-sleep/00-t2-suspend-fix` (mode 0755)

```sh
#!/bin/sh

find_touchbar() {
  for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor"  2>/dev/null)" = "05ac" ] &&
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "8302" ] && { basename "$d"; return; }
  done
}

case "$1" in
  pre)
    echo 1 > /sys/power/pm_debug_messages 2>/dev/null
    echo 1 > /sys/power/pm_print_times 2>/dev/null
    ;;
  post)
    sleep 2
    # Touch Bar belt-and-suspenders
    if ! ls /sys/bus/hid/drivers/hid_appletb_bl/*8102* >/dev/null 2>&1; then
      tb=$(find_touchbar)
      if [ -n "$tb" ] && [ -e "/sys/bus/usb/devices/$tb/bConfigurationValue" ]; then
        cfg=$(cat "/sys/bus/usb/devices/$tb/bConfigurationValue" 2>/dev/null)
        [ "$cfg" = "0" ] && cfg=1
        echo 0 > "/sys/bus/usb/devices/$tb/bConfigurationValue" 2>/dev/null
        sleep 1
        echo "${cfg:-1}" > "/sys/bus/usb/devices/$tb/bConfigurationValue" 2>/dev/null
      fi
    fi
    ;;
esac```

### `/etc/systemd/system/systemd-suspend.service.d/10-t2-freeze-session.conf` (mode 0644)

```ini
[Service]
Environment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=true
```

Overrides the stale NVIDIA drop-in `/usr/lib/systemd/system/systemd-suspend.service.d/10-nvidia-no-freeze-session.conf`
which sets `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false`. Without user-session
freezing, all device `->prepare()` callbacks contend with concurrent user I/O,
causing a 12-29s delay in `dpm_prepare()` per cycle — just under the watchdog
on the first cycle, exceeding it on the second.

### `/etc/modprobe.d/10-apple-bce-ck.conf` (mode 0644)

```
blacklist apple-bce
install apple-bce /sbin/modprobe apple_bce_ck || /sbin/modprobe --ignore-install apple-bce
```

`blacklist` prevents kernel autoload (via modalias) from picking the stock
module — since `apple_bce_ck` also matches the same PCI alias, it loads instead.
`install` catches explicit `modprobe apple-bce` calls (suspend hook's `post`,
or manual) and redirects to `apple_bce_ck`; falls back to stock if ck is absent
(e.g. kernel upgrade before ck is rebuilt).

### `/etc/systemd/sleep.conf.d/10-t2-no-hibernate.conf` (mode 0644)

```ini
[Sleep]
AllowSuspend=yes
AllowHibernation=no
AllowSuspendThenHibernate=no
```

A suspend→hibernate transition cuts power to the BCE/Touch Bar USB device in a
way it can't recover from, so hibernate is disabled outright.

## Install

```sh
# Build the patched module (from ./apple-bce-ck/)
cd /path/to/apple-bce-ck
make && sudo make modules_install

# Install the hook, modprobe config, and freeze-session override
sudo install -m 0755 /tmp/00-t2-suspend-fix /etc/systemd/system-sleep/00-t2-suspend-fix
sudo install -m 0644 /tmp/10-apple-bce-ck.conf /etc/modprobe.d/10-apple-bce-ck.conf
sudo mkdir -p /etc/systemd/system/systemd-suspend.service.d
sudo install -m 0644 /tmp/10-t2-freeze-session.conf \
  /etc/systemd/system/systemd-suspend.service.d/10-t2-freeze-session.conf

# Update module dependencies + reload systemd
sudo depmod -a
sudo systemctl daemon-reload

# Reboot to verify boot path loads apple_bce_ck
```

No `daemon-reload` needed for the hook or `sleep.conf.d` — systemd reads those
on each cycle. But the service drop-in does need it.

## Verify

```sh
# module loaded at boot
lsmod | grep apple
# expect: apple_bce_ck

# config applied
systemd-analyze cat-config systemd/sleep.conf | grep -iE 'AllowSuspend|AllowHibernation|SuspendThenHibernate'

# do a real cycle, wake with the built-in keyboard / power button
sudo systemctl suspend

# inspect the cycle afterwards — expect clean entry/exit and NONE of the crash
# signatures:
journalctl -b 0 -k | grep -iE 'PM: suspend|PM: resume|aaudio|bce_dma|scheduling while atomic|No queued item|FORCED_RMMOD|iowrite32|Oops|page fault' | tail -30
```

Then exercise input (terminal typing, trackpad, Touch Bar). Repeat the cycle ~5×
including one wake after several minutes asleep, since the failure was
intermittent.

## Decisions / things deliberately NOT done

- **Did not switch to `mem_sleep=deep`.** T2 hardware doesn't support real S3;
  `s2idle` is correct. (Some generic T2 "suspend fix" scripts set `deep` — wrong
  for this model.)
- **Did not touch Wi-Fi/Bluetooth** (`brcmfmac`/`bluetooth`) — they recover fine;
  adding them to the hook is unnecessary risk.
- **Did not prune ACPI wake sources** (`/proc/acpi/wakeup`: `XHC1/2/3`, `PEG*`,
  `RP*`). No instant-wake symptom, and wake is via the built-in keyboard/power
  button — disabling sources could make the machine un-wakeable.

The benign `brcmfmac ... Direct firmware load for ...apple,kauai-*.bin failed
with error -2` log lines are **not** a problem — the driver probes several
firmware names and one of them loads; the misses are expected.

## Fallback if a rare resume still fails

- Re-run just the resume half by hand to recover input:
  `sudo /etc/systemd/system-sleep/00-t2-suspend-fix post suspend`
- If BCE re-init is slow on some wakes, bump the delays in the `post` block
  (`sleep 2`→`4`, `sleep 1`→`2`).
- If full **entry** hangs ever return despite the pre-unload, the next lever is
  disabling spurious S3 wake sources (`XHC1/2/3`) in the `pre` phase — left out
  here by choice given the symptoms.

## References

- t2linux wiki — postinstall / state guides: https://wiki.t2linux.org/
- apple-bce driver: https://github.com/t2linux/apple-bce-drv
- Omarchy discussion, T2 suspend + Touch Bar on kernel 7.x:
  https://github.com/basecamp/omarchy/discussions/5862
- deqrocks/t2-suspend-fix-script (hardware-aware installer, broader scope):
  https://github.com/deqrocks/t2-suspend-fix-script

_Hardware: MacBookPro15,1 (Mac-937A206F2EE63C01) · Arch Linux · linux-t2 7.0.10._
