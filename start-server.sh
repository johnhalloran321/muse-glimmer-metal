#!/usr/bin/env bash
# Launches llama-server for Muse-Glimmer-30B with the flags validated on a
# 32GB M2 MacBook Pro (no sudo / default macOS Metal memory ceiling):
#   - K-Quant-17GB text quant + mmproj vision encoder (~18-20GB resident)
#   - q8_0 KV cache quantization to keep long-context headroom cheap
#   - full 131072-token context (sliding-window + heavy GQA keep this small)
#   - disk-persisted slot cache (ds4-style prefix reuse across restarts)
#
# The DFlash speculative-decoding drafter is deliberately NOT enabled here:
# measured slower on this hardware (15.4 -> 12.8 tok/s, ~50% draft acceptance)
# rather than faster. Add --spec-type draft-dflash --spec-draft-model
# models/Muse-Glimmer-30B-GGUF/dflash-Muse-Glimmer-30B-Q4_K_M.gguf yourself
# to re-test it on different hardware.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MODEL_DIR="models/Muse-Glimmer-30B-GGUF"
mkdir -p slot-cache

exec ./llama.cpp/build/bin/llama-server \
    -m "$MODEL_DIR/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf" \
    --mmproj "$MODEL_DIR/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf" \
    -ngl 99 -c 131072 --jinja --temp 1.0 --top-p 0.95 --top-k 64 \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    --slot-save-path ./slot-cache \
    --port "${PORT:-8080}" \
    "$@"
