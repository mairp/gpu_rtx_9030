#!/usr/bin/env bash
# Bring the RTX 3090 eGPU back after a --detach (or after powering the enclosure
# on). Rescans the PCIe bus, waits for the card to re-enumerate, restores
# persistence, and (optionally) restarts the inference server.
#
#   gpu-power-up.sh            # rescan + re-init the GPU
#   gpu-power-up.sh --serve    # …and `docker start llama-swap` afterward
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

SERVE=0
for a in "$@"; do case "$a" in --serve) SERVE=1 ;; -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac; done

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
