# Tech Debt & Known Issues

Tracked issues that aren't blockers but should be addressed. Fix as you go or batch before they compound.

## Fixed

- ~~**Outbox filename collisions.**~~ Keeper now clears outbox before each breath (same as inbox). No more stale file collisions.

- ~~**Continuation checkpoints skip history.**~~ `do_checkpoint` now records `CheckpointMeta` in `checkpoint_history` for all paths (continuation, heartbeat, scheduled, crash).

- ~~**No checkpoint after final breath in wake loop.**~~ `breathe_loop` now checkpoints after the final breath internally. All callers get consistent behavior — no need to checkpoint manually after a wake.

- ~~**Heartbeat can sneak through during long breath.**~~ Heartbeats now check `last_breath_at` and skip if a breath completed within the last 60 seconds. OTP's sequential message handling already ensures budget is up to date; this prevents redundant wakes.

## Keeper

- **Scheduled wakes are in-memory.** `Process.send_after` is lost on keeper restart. Acceptable for now; needs persistent storage (or outbox history replay) when the keeper is deployed to production.

## Future

- **Dollar-cost tracking needs cache-aware accounting.** The Anthropic API caches prompt prefixes automatically within a breath (and with explicit breakpoints across breaths). Cached input tokens are billed at a lower rate. If we add dollar-cost budgets, we need to read `cache_read_input_tokens` and `cache_creation_input_tokens` from the usage response and apply discounted rates. Raw token count budgets (Sprint 2) are unaffected.

- ~~**Evaluate Agent SDK vs hand-rolled loop.**~~ Resolved by Rust rewrite. The bootstrap is now a static binary with direct HTTP calls. The Agent SDK is Python-only and too opinionated for the bootstrap's injection model.

- **Bootstrap crash vs agent crash distinction.** Both are nonzero exit codes. Consider having the bootstrap write a sentinel file after successful initialization so the keeper can tell whether the crash was pre-LLM or mid-breath.

- **Repeated crash detection.** Keeper currently retries against the same broken state. Should track consecutive crashes and alert after N failures.

- **uv pre-installation in Sprites.** AGENTS.md tells the agent to use uv, but it may not be installed in fresh Sprites. Consider adding `curl -LsSf https://astral.sh/uv/install.sh | sh` to the seed step.

- **Keeper-side human-friendly rendering.** Now that protocol files are JSON, the keeper should format them nicely when presenting to humans (checkpoint diffs, outbox display, status reports).
