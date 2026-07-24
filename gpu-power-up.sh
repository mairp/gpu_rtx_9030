#!/usr/bin/env bash
# Bring the RTX 3090 eGPU back after a --detach (or after powering the enclosure
# on). Rescans the PCIe bus, waits for the card to re-enumerate, restores
# persistence, and (optionally) restarts the inference server.
#
#   gpu-power-up.sh            # rescan + re-init the GPU
#   gpu-power-up.sh --serve    # …and `docker start llama-swap` afterward
#   gpu-power-up.sh --clear-wedge  # safe cleanup for a "fallen off the bus" wedge
#                                  # (kills stray smi pollers, diagnoses) — then reboot the host.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

SERVE=0; CLEAR_WEDGE=0
for a in "$@"; do case "$a" in --serve) SERVE=1 ;; --clear-wedge) CLEAR_WEDGE=1 ;; -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac; done

# --clear-wedge: the GPU fell off the bus (Xid 79). We CANNOT bring it back
# without an OS reboot — the driver's Xid 154 recovery action is "OS Reboot",
# and any PCIe rescan/remove hangs on the stuck thunderbolt kworker. All this
# does is the safe pre-reboot cleanup + diagnosis, then tells you to reboot.
if [ "$CLEAR_WEDGE" -eq 1 ]; then
  if gpu_responsive; then
    ok "GPU is responsive — no wedge to clear. Use plain gpu-power-up.sh / gpu-status.sh."
    exit 0
  fi
  warn "GPU 'fallen off the bus' wedge — performing safe pre-reboot cleanup only."
  kill_stray_smi_pollers
  fault="$(gpu_bus_fault_dmesg)"; [ -n "$fault" ] && { echo "  kernel:"; echo "$fault" | sed 's/^/    /'; }
  dstate="$(gpu_tb_dstate_workers)"; [ -n "$dstate" ] && warn "thunderbolt kworker stuck in D-state: $dstate (unkillable — confirms reboot needed)"
  err "This wedge is NOT software-recoverable. Reboot the host to restore the GPU."
  echo "  fleet.service restarts llama-swap etc. on boot. See README 'Recovery'."
  exit 3
fi

# A wedged card can't be rescanned back — catch it early with a clear message.
if gpu_present && ! gpu_responsive; then
  err "GPU is on the bus but unresponsive (fallen off the bus). A PCIe rescan will not help."
  echo "  -> run: $DIR/gpu-power-up.sh --clear-wedge   then reboot the host." >&2
  exit 3
fi

if gpu_present; then
  ok "GPU already present on the bus."
else
  log "rescanning PCIe bus…"
  echo 1 > /sys/bus/pci/rescan 2>/dev/null || { err "PCIe rescan failed (need root)."; exit 1; }
  for _ in $(seq 1 15); do gpu_present && break; sleep 1; done
  if ! gpu_present; then
    err "GPU did not re-enumerate. Check the enclosure power + Thunderbolt cable, then retry."
    exit 1
  fi
  ok "GPU re-enumerated: $(gpu_pci_funcs | tr '\n' ' ')"
fi

# Re-init the driver/persistence so nvidia-smi is responsive.
if systemctl list-unit-files 2>/dev/null | grep -q '^nvidia-persistenced'; then
  systemctl start nvidia-persistenced 2>/dev/null || true
fi
nvidia-smi -pm 1 >/dev/null 2>&1 || true

# Wait for nvidia-smi to answer (driver re-attach can take a couple seconds).
for _ in $(seq 1 15); do
  if nvidia-smi >/dev/null 2>&1; then ok "driver ready."; break; fi
  sleep 1
done
nvidia-smi --query-gpu=name,memory.used,memory.total,pcie.link.width.current --format=csv,noheader 2>/dev/null | sed 's/^/  /'

if [ "$SERVE" -eq 1 ]; then
  if docker ps -a -q -f 'name=^llama-swap$' >/dev/null 2>&1 && [ -n "$(docker ps -aq -f 'name=^llama-swap$')" ]; then
    log "starting llama-swap…"; docker start llama-swap >/dev/null 2>&1 && ok "llama-swap started." || warn "could not start llama-swap"
  else
    warn "llama-swap container not found; start your serving stack manually."
  fi
fi
ok "power-up complete."
