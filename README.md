# Muse-Glimmer-30B on a 32GB Apple Silicon Mac

**Meta's 30B dense vision + agentic-tool-use model, running comfortably on a Mac that isn't
supposed to fit it — no admin access, no cloud, no compromises on tool-calling.**

![Platform](https://img.shields.io/badge/platform-Apple%20Silicon-111111?logo=apple&logoColor=white)
![Engine](https://img.shields.io/badge/engine-llama.cpp%20%2B%20Metal-2563eb)
![RAM](https://img.shields.io/badge/RAM-32GB%2C%20no%20sudo-2e7d32)

Runs Meta's [Muse-Glimmer-30B](https://huggingface.co/meta-models/Muse-Glimmer-30B) (dense
30B, text+image, agentic tool-use) locally on Apple Silicon via
[llama.cpp](https://github.com/ggml-org/llama.cpp) + Metal — validated on a 32GB M2 MacBook
Pro **without admin/sudo access**.

This repo is tooling and scripts only. No model weights are vendored — `setup.sh` pulls the
official GGUF checkpoints directly from Meta's own Hugging Face repo (see
[Model hosting](#model-hosting) for why we don't mirror them ourselves).

## Quickstart

### 1. Serve

```bash
./setup.sh                          # one-time: builds llama.cpp with Metal, downloads ~20GB of GGUF checkpoints
./start-server.sh > server.log 2>&1 &    # launches llama-server on http://127.0.0.1:8080
```

Wait for `llama_server: model loaded` in `server.log` — a cold load (nothing in the OS page
cache yet) takes ~30-45s, a warm one closer to ~3s. Confirm it's up:

```bash
curl http://127.0.0.1:8080/health   # {"status":"ok"}
```

**Corporate proxy note**: if Hugging Face downloads need to go through a corporate
TLS-inspecting proxy, export these before running `setup.sh`:

```bash
export REQUESTS_CA_BUNDLE=/path/to/your/ca-bundle.crt
export SSL_CERT_FILE=/path/to/your/ca-bundle.crt
```

`setup.sh` also sets `HF_HUB_DISABLE_XET=1` — Hugging Face's "Xet" fast-transfer backend uses
its own HTTP client that ignores the variables above and will silently corrupt downloads
through an inspecting proxy (`IncompleteBody` errors). Disabling it forces the classic
`requests`-based downloader, which respects your CA bundle.

### 2. The front end

Open `http://127.0.0.1:8080` in a browser. This is llama.cpp's own bundled, first-party chat
web UI (SvelteKit, lives in `tools/server` upstream) — not a separate project, not something
this repo adds. It ships a full chat interface plus a **built-in MCP client**: under its
settings you can point it directly at MCP tool servers and chat with tool use enabled, no
external agent needed. That MCP wiring is entirely browser-side JavaScript talking to this
same OpenAI-compatible API underneath — see [Tool-calling and MCP](#tool-calling-and-mcp) for
exactly how that connects to the backend.

Prefer code? Point any OpenAI SDK at the base URL instead:

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="not-needed")
resp = client.chat.completions.create(
    model="muse-glimmer",  # ignored — only one model is ever loaded
    messages=[{"role": "user", "content": "hello"}],
)
```

### 3. Tool use

```bash
./test.sh   # health check, a plain chat completion, and a tool-calling request
```

The tool-calling request in `test.sh` sends a standard OpenAI-style `tools` array; the
response comes back with a standard `tool_calls` array — even though the model itself speaks
a custom XML format internally. llama.cpp detects this model from its embedded chat template
and compiles a per-request grammar that both *constrains* generation to valid tool-call syntax
and *parses* it back into that structured JSON — no flags, no separate parser to configure.
Full mechanism (worth reading if you're debugging a malformed tool call, or onboarding a
different model that needs its own handler) is in
[Tool-calling and MCP](#tool-calling-and-mcp).

### 4. Teardown

```bash
pkill -f "llama.cpp/build/bin/llama-server"
```

If you're tearing down *because* a request seemed to hang, don't bother debugging flags first —
just kill and restart with `./start-server.sh`. See
[Troubleshooting](#troubleshooting): a cancelled client request can leave the GPU queue
contended enough to stall the next one for 60-90s+, and a clean restart has reliably fixed it.

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

## Batching / serving architecture

**Continuous batching isn't something llama.cpp lacks — it's on by default and already active
here.** Every server log line on load shows `n_slots = 4`: that's 4-way continuous (dynamic)
batching, a mature, default-enabled `llama-server` feature (2026 refinements added decode-maximal
scheduling and chunked prefill on top). We didn't configure this — it was already running before
either of us touched a batching flag.

Checked the "just use vLLM/MLX-serve instead" alternatives concretely rather than assume they're
better:

- [`vllm-metal`](https://github.com/vllm-project/vllm-metal) — a real, fast-improving community
  plugin bringing vLLM's engine to Apple Silicon via MLX. But its supported-models list does
  **not** include Muse-Glimmer-30B, or any custom VLM architecture like it — only Qwen3-VL and
  PaddleOCR-VL, both still experimental. Not usable for this model today, independent of the
  batching question.
- **`mlx-lm`'s server** does have confirmed continuous batching (Apple's own WWDC26 session
  covers it directly). But that's the text-only package — Muse-Glimmer's vision path needs
  `mlx-vlm` specifically, which per mlx-dspark's own README needed a custom hidden-state-tap
  workaround just to run at all. Whether `mlx-vlm`'s serving stack has the same batching
  maturity as `mlx-lm`'s is genuinely unconfirmed here — not verified true or false.

For this repo's actual use case (single local user, agentic dev/testing) the batching question
doesn't bite either way. If that changes to serving multiple concurrent users, re-check
`vllm-metal`'s model coverage again before assuming it's still unsupported — it's moving fast.

## Tool-calling and MCP

Muse-Glimmer natively emits a custom XML tool-call format (ATEM-style tags: `<atem:function_calls>`,
`<atem:invoke name="...">`, `<atem:parameter name="...">`), not OpenAI JSON — but llama.cpp
translates it automatically. No extra flags needed; confirmed working via `test.sh`, producing
standard `"tool_calls": [{"function": {...}}]` in the API response. The actual mechanism, read
directly from `common/chat.cpp` in the exact build this repo runs:

- **Detection has no flag** (unlike vLLM's `--tool-call-parser`). llama.cpp scans the model's own
  embedded Jinja template source for `<atem:function_calls>` + `<|eom|>` and routes to a
  dedicated, hand-written `common_chat_params_init_muse_glimmer()` handler built for this model.
- **The Jinja template still renders the prompt** — turning your `messages`/`tools` JSON into
  the literal ATEM/channel-syntax text the model was trained on.
- **A per-request PEG grammar does the rest, in both directions.** For every request with a
  `tools` array, llama.cpp compiles a parsing grammar — one rule per tool, generated straight
  from that tool's JSON schema — and uses it twice: as a **hard constraint during sampling**
  (the model literally cannot emit invalid ATEM syntax or an unknown tool/argument shape when
  tools are offered), and again to **parse** the generated text back into `tool_calls[].function.
  {name,arguments}`, cleanly separated from the reasoning channel (`to=self`) and the
  user-facing channel (`to=user`). This is why the tool call in `test.sh` comes back
  well-formed every time, not just usually.

**MCP specifically**: llama.cpp's MCP client lives in the *browser* web UI (merged upstream
~March 2026), not the C++ backend — the server only adds `--webui-mcp-proxy`, a CORS proxy for
that browser-side client. Everything above is identical regardless of who's calling it — the
backend has no concept of MCP at all, only the generic OpenAI `tools`/`tool_calls` schema. The
browser UI's MCP client does its own MCP↔JSON translation client-side (query the MCP server's
tools, send them as the same `tools` array shown above, execute whatever comes back in
`tool_calls` against the real MCP server, feed the result back as a `role: "tool"` message) —
from the server's point of view, that's indistinguishable from a raw `curl` call. To drive this
from an external agent instead of the browser, point an MCP-aware client (Claude Code, opencode,
etc.) at `http://127.0.0.1:8080/v1` and let it do the same translation.
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
