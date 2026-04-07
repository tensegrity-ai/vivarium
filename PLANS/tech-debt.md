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

- **Evaluate Agent SDK vs hand-rolled loop.** The bootstrap's agent loop is ~40 lines of hand-rolled tool dispatch. The Anthropic Agent SDK provides this out of the box and may handle caching, token tracking, and context management more robustly. Trade-off: we lose direct control over injection timing (80% negotiation) and add a dependency. Revisit when the hand-rolled loop starts accumulating complexity.
