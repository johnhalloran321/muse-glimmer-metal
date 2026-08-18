#!/usr/bin/env bash
# One-time setup: builds llama.cpp (Metal) and downloads the Muse-Glimmer-30B
# GGUF checkpoints. Safe to re-run — skips work that's already done.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MODEL_DIR="models/Muse-Glimmer-30B-GGUF"
LLAMA_CPP_DIR="llama.cpp"

# If you're behind a corporate TLS-inspecting proxy, point these at your CA
# bundle before running this script:
#   export REQUESTS_CA_BUNDLE=/path/to/ca-bundle.crt
#   export SSL_CERT_FILE=/path/to/ca-bundle.crt
# Hugging Face's "Xet" fast-transfer backend has its own HTTP client that
# ignores those variables and will corrupt downloads through such a proxy —
# HF_HUB_DISABLE_XET=1 below forces the classic downloader, which respects them.

echo "==> Checking build tooling..."
command -v cmake >/dev/null 2>&1 || { echo "Installing cmake via Homebrew..."; brew install cmake; }
command -v huggingface-cli >/dev/null 2>&1 || pip3 install -U huggingface_hub

echo "==> Downloading Muse-Glimmer-30B GGUF files (~20GB: text quant + mmproj + dflash drafter)..."
mkdir -p "$MODEL_DIR"
HF_HUB_DISABLE_XET=1 huggingface-cli download meta-models/Muse-Glimmer-30B-GGUF \
    --local-dir "$MODEL_DIR" \
    --include "*Q4_K_M.gguf"

echo "==> Cloning llama.cpp..."
if [ ! -d "$LLAMA_CPP_DIR" ]; then
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_CPP_DIR"
fi

echo "==> Building llama.cpp with Metal (requires build b10353+ for Muse-Glimmer support)..."
cmake -B "$LLAMA_CPP_DIR/build" -S "$LLAMA_CPP_DIR" -DBUILD_SHARED_LIBS=OFF
cmake --build "$LLAMA_CPP_DIR/build" --config Release -j \
    --target llama-cli llama-mtmd-cli llama-server

echo
echo "==> Setup complete. Run ./start-server.sh to launch."
echo "    If you have sudo and want more Metal memory headroom (optional, not required):"
echo "      sudo sysctl iogpu.wired_limit_mb=27000   # on a 32GB Mac; scale for your RAM"
