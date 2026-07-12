# bebop: Claude Code via cc-compass-shim (127.0.0.1:8088). First arg picks a backend;
# everything after passes through to `claude`, e.g.  bebop qwen -p "hi".
#
#   bebop            -> Compass (STAGE), default model claude-opus-4.8   (no arg = compass)
#   bebop compass    -> same, explicit
# Local models on the RTX 3090 (fully local via llama-swap; one loads at a time):
#   bebop qwen       -> Qwen3.6-27B   (dense Q4_K_M, fast, no thinking)
#   bebop qwen-big   -> Qwen3.6-35B-A3B  (MoE, larger)          alias: qwen35
#   bebop auto       -> qwen-auto (LiteLLM picks: reasoning cues->gpt-5, big jobs->35B, else sticky local)
#   bebop qwen-fp4   -> Qwen3.6-27B NVFP4  (only after Step 6 promotion; else falls back to 27B)
#   add "-think" for the reasoning variant, e.g.  bebop qwen-think / bebop qwen-big-think
#
# To add/repoint a local model: edit the `models` table below (alias -> llama-swap name).
# The shim injects the real backend keys, so ANTHROPIC_AUTH_TOKEN is a placeholder.
#
# Version-controlled in github.com/mairp/gpu_rtx_3090 (bebop.sh); ~/.bashrc sources this
# file, so edit HERE and commit — not in .bashrc.
unalias bebop 2>/dev/null   # drop any stale alias so the function below always parses on re-source
bebop() {
  # alias -> llama-swap model name. Add a line here to expose a new local model.
  # NVFP4 is commented until the benchmark promotes it (see llama-swap/config.yaml + shim QWEN_MODELS).
  local -A models=(
    [qwen]=qwen3.6-27b
    [qwen-big]=qwen3.6-35b-a3b
    [qwen35]=qwen3.6-35b-a3b
    [auto]=qwen-auto           # LiteLLM auto-router: reasoning->gpt-5, big->35b, else sticky/27b
    # [qwen-fp4]=qwen3.6-27b-nvfp4
  )
  # Real served context per backend (llama-swap `-c`, raised 2026-07-12). Claude Code
  # honors CLAUDE_CODE_MAX_CONTEXT_TOKENS for non-claude-* models: telling it the true
  # window makes it AUTO-COMPACT before the shim's overflow 400 — frontier behavior
  # instead of "prompt exceeds context, start a new session". auto uses the 35B window
  # because the qwen-auto router sends every big job to the 35B.
  local -A ctxs=(
    [qwen]=98304
    [qwen-big]=131072
    [qwen35]=131072
    [auto]=131072
  )
  local sel=${1:-compass} think=
  case "$sel" in
    -*) sel=compass ;;                 # no backend given, just claude args -> compass
    *-think) sel=${sel%-think}; think=1; shift ;;
    *) shift ;;
  esac

  # Compass passthrough (default / explicit).
  if [ "$sel" = compass ]; then
    ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy claude "$@"
    return
  fi

  local model=${models[$sel]}
  if [ -z "$model" ]; then
    echo "bebop: unknown backend '$sel' (try: compass, ${!models[*]}, or append -think)" >&2
    return 2
  fi

  # ANTHROPIC_SMALL_FAST_MODEL is deliberately the SAME model as the main one:
  # llama-swap holds one model in 24 GB, so background subagent calls to any
  # OTHER local model would force a full disk reload each way (35B<->27B swap
  # thrash, minutes per switch). Same model = zero swaps; the "cost" of running
  # a title-gen on the big model is noise next to a single reload.
  # MAX_THINKING_TOKENS makes Claude Code request thinking; the shim auto-detects it
  # and streams qwen's reasoning back as Anthropic thinking blocks (context-hungry).
  local ctx=${ctxs[$sel]:-98304}
  if [ -n "$think" ]; then
    ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy \
    ANTHROPIC_MODEL=$model ANTHROPIC_SMALL_FAST_MODEL=$model \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=$ctx \
    MAX_THINKING_TOKENS=8000 CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000 \
    claude "$@"
  else
    ANTHROPIC_BASE_URL=http://127.0.0.1:8088 ANTHROPIC_AUTH_TOKEN=dummy \
    ANTHROPIC_MODEL=$model ANTHROPIC_SMALL_FAST_MODEL=$model \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=$ctx \
    CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000 \
    claude "$@"
  fi
}
