# Tech Debt & Known Issues

Tracked issues that aren't blockers but should be addressed. Fix as you go or batch before they compound.

## Bootstrap

- **No bootstrap_config.yaml written during seed.** `Seed.create` doesn't write a config file, so bootstrap always uses `DEFAULT_CONFIG`. The keeper has no way to configure model, context_limit, or max_response_tokens per-terrarium. Fix: have `Seed.create` accept config opts and write the YAML.

- **Outbox filename collisions.** The agent uses ISO timestamps as outbox filenames (e.g., `2026-04-07T01:03:25Z.msg`). If two breaths happen in the same second, or the agent reuses a timestamp, `ls -t | head -1` may return the wrong file. Fix: use unix timestamps with subsecond precision, or have the keeper clear outbox before each breath (like inbox).

## Keeper

- **Continuation checkpoints skip history.** `do_checkpoint` in the continuation loop calls `Sprites.checkpoint` directly, bypassing the GenServer's `handle_call(:checkpoint)`. These checkpoints aren't recorded in `checkpoint_history`. Fix: either call through the GenServer or inline the history update in `do_checkpoint`.

- **No checkpoint after final breath in wake loop.** The `breathe_loop` returns the outbox but doesn't checkpoint — the caller is expected to do it. But the continuation path checkpoints between breaths internally. Inconsistent. The caller (sprint0 task) checkpoints manually, but a future caller might forget.
