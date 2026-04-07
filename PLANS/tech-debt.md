# Tech Debt & Known Issues

Tracked issues that aren't blockers but should be addressed. Fix as you go or batch before they compound.

## Bootstrap

- **Outbox filename collisions.** The agent uses ISO timestamps as outbox filenames (e.g., `2026-04-07T01:03:25Z.msg`). If two breaths happen in the same second, or the agent reuses a timestamp, `ls -t | head -1` may return the wrong file. Fix: use unix timestamps with subsecond precision, or have the keeper clear outbox before each breath (like inbox).

## Keeper

- **Continuation checkpoints skip history.** `do_checkpoint` in the continuation loop calls `Sprites.checkpoint` directly, bypassing the GenServer's `handle_call(:checkpoint)`. These checkpoints aren't recorded in `checkpoint_history`. Fix: either call through the GenServer or inline the history update in `do_checkpoint`.

- **No checkpoint after final breath in wake loop.** The `breathe_loop` returns the outbox but doesn't checkpoint — the caller is expected to do it. But the continuation path checkpoints between breaths internally. Inconsistent. The caller (sprint0 task) checkpoints manually, but a future caller might forget.

- **Heartbeat can sneak through during long breath.** If a heartbeat timer fires while the GenServer is handling a synchronous wake, the heartbeat queues and runs immediately after — potentially before budget reflects the in-progress breath. The heartbeat gets a stale budget view and may run one extra breath. Not dangerous (budget catches up on the next check) but imprecise.

- **Scheduled wakes are in-memory.** `Process.send_after` is lost on keeper restart. Acceptable for now; needs persistent storage (or outbox history replay) in a later sprint.

## Future

- **Dollar-cost tracking needs cache-aware accounting.** The Anthropic API caches prompt prefixes automatically within a breath (and with explicit breakpoints across breaths). Cached input tokens are billed at a lower rate. If we add dollar-cost budgets, we need to read `cache_read_input_tokens` and `cache_creation_input_tokens` from the usage response and apply discounted rates. Raw token count budgets (Sprint 2) are unaffected.

- **Evaluate Agent SDK vs hand-rolled loop.** The bootstrap's agent loop is ~40 lines of hand-rolled tool dispatch. The Anthropic Agent SDK provides this out of the box and may handle caching, token tracking, and context management more robustly. Trade-off: we lose direct control over injection timing (80% negotiation) and add a dependency. Revisit when the hand-rolled loop starts accumulating complexity.
