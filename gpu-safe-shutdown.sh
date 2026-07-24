#!/usr/bin/env bash
# Gracefully quiesce the RTX 3090 so the eGPU enclosure can be powered off
# WITHOUT corrupting work or hanging the Thunderbolt/PCIe link.
#
#   gpu-safe-shutdown.sh            # drain only: stop GPU workloads, wait for idle
#   gpu-safe-shutdown.sh --detach   # drain + PCIe hot-remove (then safe to power off)
#   gpu-safe-shutdown.sh --detach --yes   # no confirmation prompt (for automation)
#
# Why: yanking power / unplugging TB while the driver is mid-DMA can wedge the
# PCIe link, hang nvidia-smi, and require a host reboot. Draining first (and
# detaching the PCI device) makes power-off clean. Recover with gpu-power-up.sh.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

DETACH=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --detach) DETACH=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown arg: $a"; exit 2 ;;
  esac
done

if ! gpu_present; then
  warn "no NVIDIA GPU on the bus already — nothing to drain."
  exit 0
fi

# Refuse to hot-remove a card that has fallen off the bus: the PCIe remove
# queues onto the stuck thunderbolt kworker and hangs this script in D-state
# too (unkillable), and it STILL needs a reboot. Detect and bail out.
if gpu_off_bus_wedge; then
  err "GPU has fallen off the bus (enumerated but unresponsive, Xid 79)."
  err "Do NOT --detach: PCIe remove will hang on the wedged TB kworker and needs a reboot anyway."
  echo "  -> run: $DIR/gpu-power-up.sh --clear-wedge   (safe cleanup) then reboot the host." >&2
  exit 3
fi

# --- 1. stop GPU-holding containers ---
log "draining GPU workloads…"
stop_gpu_containers

# --- 2. wait for the card to go idle; force-kill stragglers ---
if wait_for_gpu_idle 60; then
  ok "GPU idle (no compute processes)."
else
  warn "still busy after 60s; terminating stragglers."
  for p in $(gpu_compute_pids); do kill -TERM "$p" 2>/dev/null || true; done
  sleep 5
  for p in $(gpu_compute_pids); do kill -KILL "$p" 2>/dev/null || true; done
  if wait_for_gpu_idle 20; then ok "GPU idle after kill."; else
    err "GPU still busy; aborting before detach to avoid a wedged link."; exit 1
  fi
fi

if [ "$DETACH" -eq 0 ]; then
  ok "Drain complete. The card is idle — safe to power off the enclosure."
  echo "  (run with --detach to also PCIe-remove it for a fully clean hot power-off.)"
  exit 0
fi

# --- 3. detach: release the driver, then PCIe-remove the device ---
if [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "Detach the GPU from the OS (PCIe remove $(gpu_bus):00)? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { warn "aborted."; exit 0; }
fi

log "disabling persistence mode…"
nvidia-smi -pm 0 >/dev/null 2>&1 || warn "nvidia-smi -pm 0 failed (continuing)"
if systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
  log "stopping nvidia-persistenced…"
  systemctl stop nvidia-persistenced 2>/dev/null || warn "could not stop nvidia-persistenced"
fi

# Remove highest function first (audio .1) then the VGA function (.0).
mapfile -t FUNCS < <(gpu_pci_funcs | sort -r)
for f in "${FUNCS[@]}"; do
  if [ -e "/sys/bus/pci/devices/$f/remove" ]; then
    log "PCIe remove $f"
    echo 1 > "/sys/bus/pci/devices/$f/remove" 2>/dev/null || warn "remove $f failed"
    sleep 1
  fi
done

sleep 2
if gpu_present; then
  err "GPU still present after remove — do NOT power off; investigate (lspci)."
  exit 1
fi
ok "GPU detached from the OS. It is now SAFE to power off / unplug the enclosure."
echo "  To bring it back: power the enclosure on, then run:  $DIR/gpu-power-up.sh"
