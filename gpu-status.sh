#!/usr/bin/env bash
# Read-only RTX 3090 health snapshot: util, VRAM, temp, power, fan, clocks,
# PCIe/Thunderbolt link width (tunnel health), and per-process VRAM.
# Safe to run any time; touches nothing.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

if ! gpu_present; then
  err "no NVIDIA GPU on the PCI bus (eGPU powered off or detached)."
  echo "  -> if you ran gpu-safe-shutdown.sh --detach, power the enclosure on then: $DIR/gpu-power-up.sh"
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  err "nvidia-smi not found."; exit 1
fi

# "Fallen off the bus" wedge: enumerated but unresponsive. detach+rescan will
# NOT fix it (hangs on the stuck TB kworker) — only an OS reboot recovers.
if gpu_off_bus_wedge; then
  echo "== RTX 3090 status =="
  err "GPU is ENUMERATED but UNRESPONSIVE — 'fallen off the bus' wedge (Xid 79)."
  fault="$(gpu_bus_fault_dmesg)"; [ -n "$fault" ] && { echo "  kernel:"; echo "$fault" | sed 's/^/    /'; }
  dstate="$(gpu_tb_dstate_workers)"; [ -n "$dstate" ] && echo "  thunderbolt kworker stuck in D-state: $dstate (detach/rescan WILL hang)"
  echo "  RECOVERY: an OS reboot is the ONLY fix (the driver's Xid 154 action is 'OS Reboot')."
  echo "    - detach+rescan / TB re-auth do NOT work here — they queue onto the wedged TB kworker."
  echo "    - safe pre-reboot cleanup: $DIR/gpu-power-up.sh --clear-wedge   (kills stray smi pollers; diagnoses)"
  echo "    - then reboot the HOST (fleet.service restarts llama-swap on boot). See README 'Recovery'."
  exit 3
fi

echo "== RTX 3090 status =="
nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,clocks.sm,pstate,pcie.link.width.current,pcie.link.width.max \
  --format=csv,noheader 2>/dev/null \
  | awk -F', ' '{
      printf "  %s\n", $1;
      printf "  util %-5s  vram %s / %s  temp %s\n", $2, $3, $4, $5;
      printf "  power %s / %s  fan %s  sm %s  pstate %s\n", $6, $7, $8, $9, $10;
      printf "  PCIe link width: x%s (max x%s)%s\n", $11, $12, ($11<4?"  <-- DEGRADED TB tunnel!":"");
    }'

echo "  PCI functions: $(gpu_pci_funcs | tr '\n' ' ')"

pids="$(gpu_compute_pids)"
if [ -z "$pids" ]; then
  echo "  compute: IDLE (no processes) — safe to detach/power off"
else
  echo "  compute processes:"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null \
    | sed 's/^/    /'
fi
