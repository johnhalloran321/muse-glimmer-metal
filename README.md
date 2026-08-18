# Muse-Glimmer-30B on a 32GB Apple Silicon Mac

Runs Meta's [Muse-Glimmer-30B](https://huggingface.co/meta-models/Muse-Glimmer-30B) (dense
30B, text+image, agentic tool-use) locally on Apple Silicon via
[llama.cpp](https://github.com/ggml-org/llama.cpp) + Metal — validated on a 32GB M2 MacBook
Pro **without admin/sudo access**.

This repo is tooling and scripts only. No model weights are vendored — `setup.sh` pulls the
official GGUF checkpoints directly from Meta's own Hugging Face repo (see
[Model hosting](#model-hosting) for why we don't mirror them ourselves).

## Quick start

```bash
./setup.sh          # builds llama.cpp with Metal, downloads ~20GB of GGUF checkpoints
./start-server.sh    # launches llama-server on http://127.0.0.1:8080
./test.sh            # smoke-tests health, chat, and tool-calling
```

Then either:
- open `http://127.0.0.1:8080` for the built-in chat web UI, or
- point any OpenAI-compatible client at `http://127.0.0.1:8080/v1`.

### Corporate proxy note

If Hugging Face downloads need to go through a corporate TLS-inspecting proxy, export these
before running `setup.sh`:

```bash
export REQUESTS_CA_BUNDLE=/path/to/your/ca-bundle.crt
export SSL_CERT_FILE=/path/to/your/ca-bundle.crt
```

`setup.sh` also sets `HF_HUB_DISABLE_XET=1` — Hugging Face's "Xet" fast-transfer backend uses
its own HTTP client that ignores the variables above and will silently corrupt downloads
through an inspecting proxy (`IncompleteBody` errors). Disabling it forces the classic
`requests`-based downloader, which respects your CA bundle.

## What's actually running

- **Quant**: Meta's own official `K-Quant-17GB` (`Q4_K_M`, ~16.8GB) — chosen over Unsloth's
  third-party `UD-Q4_K_XL` (15.9GB) deliberately: a community benchmark
  ([HF discussion](https://huggingface.co/unsloth/Muse-Glimmer-30B-GGUF/discussions/13))
  measured Meta's quant ~40% faster decode (36.6 vs 26 tok/s) with much better speculative-decoding
  drafter acceptance (60.7% vs 36%), at the cost of being marginally behind on 4 of 6 task-quality
  benchmarks (by 1-3 points out of ~100). We're optimizing for throughput on constrained hardware,
  so speed won.
- **Memory**: text quant + mmproj vision encoder resident (~18-20GB). Fits inside macOS's
  *default* Metal wired-memory ceiling (~75% of physical RAM, ~24GB on a 32GB Mac) — no
  `sudo sysctl iogpu.wired_limit_mb` needed. If you do have admin rights and want more headroom
  (e.g. for the DFlash drafter, see below), `setup.sh` prints the command.
- **Context**: full 131072 tokens, cheap in KV cache thanks to Muse-Glimmer's `[Local, Local,
  Local, Global]` sliding-window attention + 16:1 GQA ratio — only ~2-4GB even at full context.
  `--cache-type-k/-v q8_0` shrinks it further.
- **Measured on this hardware**: ~15.4 tok/s generation, ~57 tok/s prompt-eval.
- **DFlash speculative decoding — deliberately OFF.** Meta ships a DFlash drafter
  (`dflash-Muse-Glimmer-30B-Q4_K_M.gguf`, downloaded but unused by default). Measured here: it
  made things *slower* (15.4 → 12.8 tok/s, ~50% draft acceptance) — the extra drafter forward
  pass cost more than it saved on this hardware. The model card's advertised 1.5-1.8x speedup
  is real on M4/M5 Max; it didn't reproduce on an M2. Try it yourself:
  ```bash
  ./start-server.sh --spec-type draft-dflash \
    --spec-draft-model models/Muse-Glimmer-30B-GGUF/dflash-Muse-Glimmer-30B-Q4_K_M.gguf
  ```
- **Disk-persisted KV cache** (`--slot-save-path ./slot-cache`) — the same prefix-reuse trick
  [antirez/ds4](https://github.com/antirez/ds4) hand-built for DeepSeek, available in stock
  llama.cpp: `POST /slots/{id}?action=save|restore` saves/restores warmed KV state across
  restarts instead of re-prefilling every session.

## Tool-calling and MCP

Muse-Glimmer natively emits a custom XML tool-call format (ATEM-style tags), not OpenAI JSON —
but llama.cpp's embedded Jinja chat template (baked into the GGUF) translates it automatically.
No extra flags needed; confirmed working via `test.sh`, producing standard
`"tool_calls": [{"function": {...}}]` in the API response.

**MCP specifically**: llama.cpp's MCP client lives in the *browser* web UI (merged upstream
~March 2026), not the C++ backend — the server only adds `--webui-mcp-proxy`, a CORS proxy for
that browser-side client. To drive this from MCP tool servers via the API instead, point an
MCP-aware agent (Claude Code, opencode, etc.) at `http://127.0.0.1:8080/v1` and let the agent
handle the MCP↔tool-call translation against the already-working tool-calling endpoint above.
There's also a built-in `--tools` flag (`read_file`, `grep_search`, `exec_shell_command`, …) for
testing tool-use without any MCP server at all — server-implemented, experimental/untrusted-only.

## Model hosting

The GGUF checkpoints are **not** mirrored in this repo or on a separate Hugging Face repo of our
own. They're Meta's unmodified official release
([`meta-models/Muse-Glimmer-30B-GGUF`](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF)) —
we haven't quantized, fine-tuned, or otherwise changed the weights, so there's nothing of ours to
publish, and a duplicate copy would just go stale the next time Meta ships an update.
`setup.sh` downloads directly from Meta's repo; that's already the seamless path. If corporate-
network download friction is the actual problem, the fix is an internal mirror (shared drive,
private artifact store) for teammates on the same network, not a public re-upload.

## mlx-dspark (submodule)

[`mlx-dspark`](https://github.com/johnhalloran321/mlx-dspark) is vendored as a git submodule
(a fork, so local edits are pushable). Not yet wired up here — cloned but no venv/install done.
Two intended uses:

- **Bonsai-27B (ternary)**: new capability, not duplicated elsewhere — ~15GB total (8GB target +
  7GB drafter), and per the project's docs this is the first working speculative decoding for
  this model family on Apple Silicon (also the only real way to run it locally at all; stock HF
  transformers doesn't support it well on Apple Silicon).
- **Muse-Glimmer via MLX+DSpark**: lower priority — the registry's honest (non-headline) 4-bit
  number is ~1.57-1.94x, not the advertised 3.27x (which needs the 8-bit/~40GB target that
  doesn't fit here), and peak RAM (~26GB target+drafter+cache) is tighter than what we're
  already running comfortably via GGUF. Worth a side-by-side benchmark, not a required migration.

```bash
git submodule update --init --recursive mlx-dspark
cd mlx-dspark && pip install -e .
```

## Troubleshooting

**A request hangs indefinitely (especially one that follows a client-timeout on a previous
request).** Observed in testing: a request cancelled client-side (curl timeout, Ctrl-C) doesn't
always tear down cleanly server-side, and can leave the single Metal GPU queue contended enough
that the *next* request stalls well past what its prompt size should cost. Restarting
`start-server.sh` clears it — a clean server handled the same 404-token tool-calling request in
7.6s that had twice failed to complete within 60-90s on the contended one. If you hit a hang,
restart before assuming it's a config/flag problem.

## Repo layout

```
setup.sh          # one-time: build llama.cpp, download GGUF checkpoints
start-server.sh   # launch llama-server with the validated flags
test.sh           # health / chat / tool-calling smoke tests
mlx-dspark/       # submodule (johnhalloran321/mlx-dspark fork)
llama.cpp/        # gitignored — cloned/built fresh by setup.sh
models/           # gitignored — downloaded fresh by setup.sh (~20GB)
```
