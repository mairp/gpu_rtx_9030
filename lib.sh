#!/usr/bin/env bash
# Shared helpers for the RTX 3090 eGPU safety scripts.
# Sourced by gpu-status.sh / gpu-safe-shutdown.sh / gpu-power-up.sh.
#
# The card is an NVIDIA RTX 3090 (vendor 0x10de) in a Thunderbolt 4 eGPU
# enclosure. On this host it enumerates at PCI 0000:05:00.0 (VGA) + 0000:05:00.1
# (HDMI audio), but we DISCOVER the address dynamically so a re-plug at a
# different slot still works.
set -uo pipefail
export LC_ALL=C LANG=C

# Containers known to hold the GPU (current + legacy + benchmark harness).
GPU_CONTAINERS=(llama-swap llama-arc bench-llama)

log()  { printf '\033[36m[gpu]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[err]\033[0m %s\n' "$*" >&2; }

# All NVIDIA PCI functions, VGA/3D first and audio (.1+) last — but for REMOVAL
# we want the highest function first, so callers reverse as needed.
gpu_pci_funcs() {
  local d vendor
  for d in /sys/bus/pci/devices/*/; do
    vendor="$(cat "$d/vendor" 2>/dev/null || true)"
    [ "$vendor" = "0x10de" ] && basename "$d"
  done | sort
}

# The bus the GPU sits on (e.g. 0000:05) — used to confirm a clean detach.
gpu_bus() { gpu_pci_funcs | head -1 | cut -d: -f1,2; }

# PIDs with a compute context on the GPU (empty => idle).
gpu_compute_pids() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null \
    | tr -d ' ' | grep -E '^[0-9]+$' || true
}

gpu_present() {
  # present if any NVIDIA function exists on the PCI bus
  [ -n "$(gpu_pci_funcs)" ]
}

# Is the driver able to actually talk to the card? (present on the bus but
# unresponsive => "fallen off the bus" wedge.)
# NOTE: `nvidia-smi -L` exits 0 even when it prints "No devices found." on a
# dead card, so we must match an actual "GPU N:" line, not the exit code.
gpu_responsive() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  timeout 8 nvidia-smi -L 2>/dev/null | grep -qE '^GPU [0-9]+:'
}

# Detect the Xid 79 "GPU has fallen off the bus" wedge. In this state the PCI
# function stays ENUMERATED (so gpu_present is true) but the GPU is dead:
# nvidia-smi returns "No devices were found", pcie.link.width reads blank, and a
# thunderbolt kworker is typically stuck in uninterruptible (D) sleep. The
# driver's own Xid 154 recovery action is "OS Reboot". detach+rescan does NOT
# recover this — the PCIe remove/rescan queues onto the already-wedged
# thunderbolt kworker and hangs the same way. ONLY an OS reboot clears it.
# Returns 0 (true) when the wedge is detected.
gpu_off_bus_wedge() {
  gpu_present || return 1        # nothing on the bus => detached/off, not wedged
  gpu_responsive && return 1     # driver can talk to it => healthy, not wedged
  return 0
}

# Recent "fallen off the bus" / Xid 79 / Xid 154 evidence in the kernel ring
# buffer (best-effort; needs readable dmesg). Prints matching lines.
gpu_bus_fault_dmesg() {
  dmesg -T 2>/dev/null | grep -iE "fallen off the bus|Xid.*: (79|154)|recovery action" | tail -6 || true
}

# Thunderbolt worker threads stuck in uninterruptible (D) sleep — the signature
# that a PCIe remove/rescan will hang rather than recover.
gpu_tb_dstate_workers() {
  ps -eo stat,comm 2>/dev/null | awk '$1 ~ /^D/ && $2 ~ /thunderbolt/ {print $2}' || true
}

# Kill stray `nvidia-smi -l/--loop` pollers that keep an fd open on /dev/nvidia*
# against a dead card (they block a clean module unload and spin uselessly).
kill_stray_smi_pollers() {
  local pids
  pids="$(pgrep -f 'nvidia-smi.*(-l|--loop)' 2>/dev/null || true)"
  [ -z "$pids" ] && return 0
  log "killing stray nvidia-smi pollers: $pids"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 1
}

# Block until no compute apps remain, or timeout (seconds). Returns 0 if idle.
wait_for_gpu_idle() {
  local timeout="${1:-120}" t0 now
  t0=$(date +%s)
  while :; do
    [ -z "$(gpu_compute_pids)" ] && return 0
    now=$(date +%s)
    if [ $((now - t0)) -ge "$timeout" ]; then return 1; fi
    sleep 2
  done
}

# Stop any GPU-holding containers that are currently running.
stop_gpu_containers() {
  command -v docker >/dev/null 2>&1 || { warn "docker not found; skipping containers"; return 0; }
  local c running
  for c in "${GPU_CONTAINERS[@]}"; do
    running="$(docker ps -q -f "name=^${c}$" 2>/dev/null)"
    if [ -n "$running" ]; then
      log "stopping container: $c"
      docker stop -t 25 "$c" >/dev/null 2>&1 || warn "could not stop $c"
    fi
  done
}
