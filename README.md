# gpu_rtx_3090 — RTX 3090 eGPU safety collaterals

Scripts to safely power-cycle the **NVIDIA RTX 3090** in its Thunderbolt-4 eGPU
enclosure (AOOSTAR AG02) without risking a wedged PCIe link, a hung `nvidia-smi`,
or corrupted in-flight work.

> Folder is named `gpu_rtx_3090` for the physical card, an RTX **3090**.

## Why this exists

The 3090 is an *external* GPU on a Thunderbolt tunnel. If the enclosure loses
power (or the cable is pulled) **while the driver is mid-DMA**, the PCIe link can
hang — symptoms: `nvidia-smi` freezes, containers stuck in `D` state, often a
host reboot to recover. These scripts **drain the GPU first**, and optionally
**hot-detach it from the OS**, so power-off is always clean.

PCI topology on this host (discovered dynamically, not hard-coded):
`0000:05:00.0` (VGA) + `0000:05:00.1` (HDMI audio), behind Thunderbolt.

## Scripts

| script | what it does |
|---|---|
| `gpu-status.sh` | Read-only health: util, VRAM, temp, power, fan, clocks, **PCIe link width** (TB-tunnel health), per-process VRAM. |
| `gpu-safe-shutdown.sh` | Stop GPU containers (`llama-swap`/`llama-arc`/`bench-llama`), wait for the card to go idle, force-kill stragglers. **Safe to power off after.** |
| `gpu-safe-shutdown.sh --detach` | …then PCIe hot-remove the device (`.1` then `.0`) after disabling persistence — a fully clean detach so you can hot power-off / unplug. |
| `gpu-power-up.sh [--serve]` | PCIe `rescan`, wait for re-enumeration, restore persistence; `--serve` also `docker start llama-swap`. Run after powering the enclosure back on. |
| `lib.sh` | Shared helpers (dynamic PCI discovery by vendor `0x10de`, `wait_for_gpu_idle`, container stop). |
| `gpu-safe-shutdown.service` | systemd unit that **drains** the GPU automatically on host shutdown/reboot. |

## Typical use

```bash
# check before doing anything
sudo ./gpu-status.sh

# you want to power the enclosure off for the night:
sudo ./gpu-safe-shutdown.sh --detach      # drains, then removes from the OS
#   -> "SAFE to power off"; flip the enclosure switch

# next morning, after switching the enclosure on:
sudo ./gpu-power-up.sh --serve            # rescans the bus + restarts serving
```

Just stopping workloads (no physical power-off), e.g. to free VRAM:
```bash
sudo ./gpu-safe-shutdown.sh               # drain only
```

## Install the shutdown guard (recommended)

```bash
sudo cp gpu-safe-shutdown.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-safe-shutdown.service
```
On every reboot/poweroff the GPU is drained first (drain-only — it does **not**
auto-detach, to avoid surprising PCIe removals during normal reboots).

## Recovery cheatsheet

- `nvidia-smi` hangs / card gone after an unclean unplug → power the enclosure
  off, wait 5 s, on; then `sudo ./gpu-power-up.sh`.
- `gpu-status.sh` says "no NVIDIA GPU on the bus" → you detached it; power on +
  `gpu-power-up.sh`.
- PCIe link width `< x4` → Thunderbolt tunnel degraded (reseat the USB4 cable);
  this is the eGPU's known flaky failure mode and is alerted in the observability
  stack too.
- **GPU "fallen off the bus" (Xid 79) — the wedge.** `gpu-status.sh` shows the card
  ENUMERATED but UNRESPONSIVE: `nvidia-smi` prints "No devices were found", the PCIe
  width is blank, and a `thunderbolt` kworker is stuck in uninterruptible (D) sleep.
  **Only an OS reboot recovers this** — the driver's Xid 154 recovery action is
  literally "OS Reboot". Do **not** `--detach` / PCIe-rescan / TB-reauthorize: each
  queues onto the wedged TB kworker and hangs in D-state (unkillable), and you still
  end up rebooting. All three scripts now detect the wedge and exit 3 instead of
  hanging. Correct path:
  ```
  sudo ./gpu-power-up.sh --clear-wedge   # safe: kills stray nvidia-smi pollers, diagnoses
  sudo reboot                            # fleet.service restarts llama-swap on boot
  ```
  Reliably triggered by sustained heavy load (e.g. the coder `code_hard` benchmark) —
  a physical eGPU/TB4 endurance fault, not VRAM.

> Requires root (PCIe remove/rescan + persistence control). All scripts are
> idempotent and no-op cleanly if the card is already absent/idle.
