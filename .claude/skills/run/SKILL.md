---
name: run
description: Launch, test, and restart the local Muse-Glimmer-30B llama.cpp server for this repo. Use whenever asked to run, start, serve, test, or check this project's model server, or when a request against it hangs.
---

# Running the Muse-Glimmer-30B server

This repo has a working, validated setup — don't hand-invent a different `llama-server`
invocation. Use the scripts as-is; pass extra flags as arguments if an experiment needs them.

## Steps

1. First run only: `./setup.sh` — builds llama.cpp with Metal, downloads the GGUF checkpoints
   (~20GB) from Meta's official repo. Idempotent, safe to re-run.
2. Start the server: `./start-server.sh > server.log 2>&1 &` (or foreground if you want to watch
   load progress directly). Listens on `:8080` by default (`PORT=xxxx ./start-server.sh` to change).
3. Wait for `llama_server: model loaded` in `server.log` before sending requests — a cold load
   (nothing in the OS page cache yet) takes ~30-45s; a warm one is closer to ~3s.
4. Verify: `./test.sh` — runs health check, a plain chat completion, and a tool-calling request,
   printing full JSON responses. All three should complete in well under a minute on a healthy
   server.
5. Interactive testing: open `http://127.0.0.1:8080` in a browser for the built-in chat web UI,
   or point any OpenAI-compatible client at `http://127.0.0.1:8080/v1`.

## If a request hangs

A request cancelled client-side (timeout, Ctrl-C) can leave the Metal GPU queue contended enough
that the *next* request stalls for 60-90s+ instead of its normal cost (a clean server handles the
same tool-calling request in ~7.6s). Kill the process and restart via `./start-server.sh` rather
than debugging flags — this has reliably fixed it in testing.

```bash
pkill -f "llama.cpp/build/bin/llama-server"
sleep 3
./start-server.sh > server.log 2>&1 &
```

## Don't

- Don't add `sudo sysctl iogpu.wired_limit_mb` as a required step — it's optional, the target
  machine has no admin rights, and the default ceiling already fits the current setup.
- Don't enable the DFlash drafter (`--spec-type draft-dflash ...`) as a "speed improvement" without
  re-measuring — it tested slower (15.4 → 12.8 tok/s) on the validated hardware.
