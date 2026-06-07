# Battery drain on T2 Linux (MacBookPro15,1)

## Current state (2026-06-07)

- **Discharge rate:** 37.2W (idle with display on)
- **Battery:** ~65% → ~1.5h estimated
- **Power profile:** balanced

## powertop findings

### PCI devices — all at 100% runtime PM

`pcie_aspm=off` in kernel cmdline prevents Active State Power Management on
all PCIe links. Expected 5-15W savings if removed or set to `default`.

High-draw devices:
- AMD Radeon Pro 560X (dGPU) — always on, D3cold too slow on resume
- Apple T2 Bridge Controller — required for keyboard/trackpad
- Apple ANS2 NVMe Controller
- Broadcom BCM4364 Wi-Fi
- Intel JHL7540 Thunderbolt 3 (×3 controllers)
- Intel DSL6540 Thunderbolt 3 (×1)
- Apple Audio Device

### Radios — both at 100%

- hci_uart_bcm (Bluetooth) — no runtime PM
- brcmfmac (Wi-Fi) — no runtime PM

### Display

- Backlight at 100% when on — normal, off on lid-close

## Fixes tried

| Fix | Result |
|-----|--------|
| `powerprofilesctl power-saver` | Minimal impact |
| `powertop --auto-tune` | USB autosuspend, minor savings |
| dGPU `power/control=auto` | Slow wakeup (D3cold exit ~seconds), reverted |
| rfkill during suspend | Works, in suspend hook |

## To try

1. **Remove `pcie_aspm=off` from kernel cmdline** — biggest potential win (5-15W)
2. **Wi-Fi powersave:** `iw dev wlan0 set power_save on`
3. **CPU governor:** already `powersave` — no turbo: `echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo`
4. **VM writeback:** `echo 1500 > /proc/sys/vm/dirty_writeback_centisecs`
5. **NMI watchdog:** `echo 0 > /proc/sys/kernel/nmi_watchdog`
