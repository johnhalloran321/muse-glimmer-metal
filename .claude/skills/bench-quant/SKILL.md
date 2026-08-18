---
name: bench-quant
description: Evaluate a candidate GGUF or MLX quantization of Muse-Glimmer-30B (or a future onboarded model) against the currently configured build before switching. Use when asked to compare quantizations, evaluate a newly released quant, or decide whether to change which quant this repo ships.
---

# Evaluating a candidate quantization

This is the methodology actually used to pick the current default (Meta's K-Quant-17GB over
Unsloth's UD-Q4_K_XL) — repeat it before changing that choice, don't just swap on vibes or a
vendor's headline benchmark number.

## Steps

1. **Look for an existing head-to-head comparison first** — HF discussion tabs on the relevant
   model repos, r/LocalLLaMA, GitHub issues. A real community benchmark (even on different
   hardware) beats guessing, and often exists already (this is how the K-Quant vs UD-Q4_K_XL
   numbers in README.md were found).
2. **Check the memory footprint against the actual constraint, not the vendor's headline
   number.** Vendor "peak RAM" figures are frequently measured at short/chat-length context on
   different (often much larger) hardware than the target machine. Distinguish the *advertised*
   ratio (often the 8-bit/largest config) from the ratio at the quant/context size that actually
   fits — these can differ substantially (e.g. Muse-Glimmer's advertised 3.27x needs an 8-bit
   target that doesn't fit; the honest 4-bit number is ~1.57-1.94x).
3. **Measure on the real target hardware, not just trust reported numbers.** Load the candidate,
   run something equivalent to `test.sh` against it, and record: decode tok/s, prompt-eval tok/s,
   and (if a drafter is involved) draft acceptance rate. A vendor's speedup on M4/M5 Max is not a
   promise for an M2 — the DFlash regression in this repo is exactly this failure mode.
4. **Weigh quality against speed explicitly, don't assume one dominates.** A smaller/slower quant
   that scores better on task-quality benchmarks isn't automatically the right choice if the
   project is optimizing for throughput on constrained hardware — but say so explicitly rather
   than silently picking one axis.
5. **Document the decision and the numbers**, not just the conclusion — in README.md, next to the
   existing quant-comparison table, so the next evaluation has a baseline to check against instead
   of re-deriving everything from scratch.

## Don't

- Don't switch the default quant in `start-server.sh` based on a benchmark run on different
  hardware than the actual target machine.
- Don't drop the existing comparison table when adding a new one — extend it, so regressions are
  visible.
