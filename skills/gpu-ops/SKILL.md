---
name: gpu-ops
description: >
  Operate and inspect the RTX 3090 eGPU (Thunderbolt-4 enclosure) on the mairp host via the
  proven scripts in /root/gpu_rtx_3090. Use when asked to "check GPU / eGPU status", "how's the
  GPU", "free VRAM", "drain the GPU", "safe shutdown / power the GPU down", "detach the eGPU",
  "power the GPU back up", "restart llama-swap", or when nvidia-smi hangs / the PCIe (Thunderbolt)
  link is degraded. For every coding agent (Claude Code + bebop variants) — do NOT hand-roll
  docker stop / nvidia-smi / raw PCIe pokes; use these scripts.
---

# RTX 3090 eGPU operations

Thin wrapper over the host's existing, idempotent GPU safety scripts in `/root/gpu_rtx_3090`.
The card is an external GPU on a Thunderbolt tunnel — yanking power mid-DMA can wedge the PCIe
link and hang `nvidia-smi` (often a host reboot to recover). These scripts drain first, and
optionally hot-detach, so power-off is always clean. **Read the script output and relay it — add
no new logic.**

## Status (read-only, safe any time)

```
/root/gpu_rtx_3090/gpu-status.sh     # util / VRAM / temp / power / fan / PCIe link width + per-process VRAM
```

PCIe link width should be **x4** on TB4; `< x4` means a degraded Thunderbolt tunnel.

## Free VRAM / drain only (no physical power-off)

```
/root/gpu_rtx_3090/gpu-safe-shutdown.sh          # stop GPU containers, wait for idle, force-kill stragglers
```

## Before powering the enclosure OFF

```
/root/gpu_rtx_3090/gpu-safe-shutdown.sh --detach        # drain + PCIe hot-remove; then flip the enclosure switch
/root/gpu_rtx_3090/gpu-safe-shutdown.sh --detach --yes   # same, no confirm prompt (automation only)
```

## After powering the enclosure back ON

```
/root/gpu_rtx_3090/gpu-power-up.sh            # PCIe rescan + re-init the driver
/root/gpu_rtx_3090/gpu-power-up.sh --serve    # …and also `docker start llama-swap` (resume local inference)
```

## Recovery cheatsheet

- `nvidia-smi` hangs / card gone after an unclean unplug → power the enclosure off, wait 5s, on;
  then `gpu-power-up.sh`.
- `gpu-status.sh` says "no NVIDIA GPU on the bus" → it's detached; power on + `gpu-power-up.sh`.
- PCIe link width `< x4` → Thunderbolt tunnel degraded; reseat the USB4 cable (known flaky mode,
  also alerted in the observability stack).

## HARD RULES

- `gpu-status.sh` is read-only — run it any time.
- `gpu-safe-shutdown.sh` and `gpu-power-up.sh` **CHANGE state** and stop/start local inference
  (`llama-swap`). Confirm with the user before draining, detaching, or powering the GPU — other
  agents depend on it. Powering the GPU down only affects local qwen; Compass/gpt-5 via the shim
  keep working.
- Scripts require **root** (PCIe remove/rescan + persistence). Agents on this host already run as
  root, so no `sudo` is needed here; prefix with `sudo` only when running as a non-root user.
- Keep arguments literal — no `$(...)`/backticks/vars (avoids OpenClaw exec-approval prompts).
- Keep output concise. No emojis.

## Notes

- For the whole-fleet view (LLM core + observability + this GPU together), see the `fleet-control`
  skill. This skill is the GPU-only path.
- Full background, PCI topology, and the systemd drain-on-shutdown guard: `/root/gpu_rtx_3090/README.md`.
