# Sprint 1: Multi-Breath

Goal: the agent can work across multiple breaths on a single task. The bootstrap negotiates context boundaries. The keeper orchestrates continuation cycles and protects against runaways. Crash recovery handles the ugly cases.

## Success Criteria

1. Agent hits 80% context during a long task, receives the negotiation prompt, and responds CONTINUING or HANDING_OFF.
2. If HANDING_OFF: agent writes a continuation handoff, outbox `type: continuing`. Keeper checkpoints and immediately re-wakes. Next breath picks up from the continuation handoff.
3. If CONTINUING: agent keeps working. At 95%, hard cutoff fires. Agent writes handoff and exits.
4. Keeper tracks consecutive continuations. After N (default 5), it pauses and surfaces a warning instead of re-waking.
5. If the bootstrap crashes (exit code != 0, no outbox written), keeper checkpoints whatever exists and flags the next wake as crash recovery.
6. On crash recovery wake, the bootstrap injects a warning: "Your last breath was interrupted. Inspect the filesystem for partial work."

## What's In Scope

- Bootstrap: token estimation, 80% negotiation injection, 95% hard cutoff, continuation-aware prompting.
- Keeper: outbox type parsing, continuation re-wake loop, runaway detection, crash recovery flagging.
- Protocol: continuation inbox messages, crash_recovery flag.

## What's Out of Scope

- Budget enforcement (Sprint 2)
- Heartbeat scheduling (Sprint 2)
- Message routing (Sprint 2)
- Multiple terrariums (Sprint 3)
- Branching (Sprint 3)

## Implementation Order

### Step 1: Token tracking in the bootstrap

Track actual token usage from the API response. The Anthropic SDK exposes `response.usage.input_tokens` after each call — use that directly instead of estimating. Accumulate `input_tokens + output_tokens` across loop iterations to get total context consumption.

No heuristic needed. The API gives us ground truth on every response.

**Files:** `bootstrap/bootstrap.py`
**Test:** Run a breath, log token counts at each loop iteration. Verify they grow as expected.

### Step 2: 80% negotiation and 95% hard cutoff

After each tool result, check token estimate against `config["context_limit"]`.

At 80%: inject a text block into the tool_results user message asking the agent to decide. The Anthropic API supports mixing `tool_result` and `text` blocks in a single user message — the model sees both. Append `{"type": "text", "text": "[SYSTEM] ..."}` to the tool_results list. The agent responds with CONTINUING (keep working, I'm close) or HANDING_OFF (need another breath). If HANDING_OFF, the agent writes its continuation handoff and outbox in the same turn, then the loop breaks on `end_turn`.

At 95%: same injection mechanism, non-negotiable — "Write your handoff and outbox now. This breath is ending." Break the loop after the agent's next response regardless of stop_reason.

Both injections are one-shot: use a flag to avoid re-injecting at the same threshold on subsequent iterations.

**Files:** `bootstrap/bootstrap.py`
**Test:** Manually test with a task that generates enough context to hit 80%. A good prompt: "Write a detailed analysis of the /etc directory structure and every file in it." Or artificially lower `context_limit` in bootstrap_config.yaml for testing.

### Step 3: Continuation-aware context assembly

When the inbox message has `continuation: true` or `type: continuation`, the bootstrap should frame the prompt differently. Instead of the normal preamble, emphasize: "You're mid-task. Your handoff has the details. Pick up where you left off."

Also: if `crash_recovery: true` in the inbox context, inject the crash warning instead of the normal handoff framing.

**Files:** `bootstrap/context.py`
**Test:** Write a fake continuation inbox message, write a continuation-style handoff.md, run the bootstrap. Verify the prompt framing is correct.

### Step 4: Outbox parsing in the keeper

The keeper currently reads the outbox as a raw string. It needs to parse the YAML and branch on `type`:

- `response` → route message, checkpoint, idle (current behavior)
- `continuing` → checkpoint, re-wake immediately with a continuation inbox message
- `request` → route to human, checkpoint, idle
- `silent` → checkpoint, idle

Start with `response` and `continuing` — those are the ones that matter for multi-breath. `request` and `silent` can remain stubs that behave like `response` for now.

**Files:** `keeper/lib/keeper/wake.ex`, `keeper/lib/keeper/terrarium.ex`
**Test:** Manually trigger a multi-breath task. Verify: first breath writes `type: continuing`, keeper checkpoints, re-wakes, second breath reads continuation handoff, completes with `type: response`.

### Step 5: Continuation loop in the terrarium GenServer

The wake handler in `Terrarium` needs to loop on continuations:

```
wake(message) →
  breathe(message) →
  parse outbox →
  if continuing:
    increment consecutive_continuations
    check runaway limit
    checkpoint
    breathe(continuation_message) →
    loop
  else:
    reset consecutive_continuations
    return outbox
```

Track `consecutive_continuations` in the GenServer state (already in the struct). After N consecutive continuations (default 5), return `{:runaway, state}` instead of re-waking. The caller decides what to do (surface to human, pause, etc.).

**Files:** `keeper/lib/keeper/terrarium.ex`
**Test:** Lower the context_limit to force multi-breath, then give a task that requires 2-3 breaths. Verify the keeper loops correctly and checkpoints between each breath.

### Step 6: Crash recovery

If `Wake.breathe/3` returns an error (bootstrap exited non-zero) or the outbox is missing/unparseable:

1. Keeper checkpoints immediately (preserve whatever filesystem state exists).
2. Keeper sets a `crash_recovery` flag on the terrarium state.
3. On next wake, keeper includes `crash_recovery: true` in the inbox message context.
4. Bootstrap sees the flag and injects the crash warning (Step 3).

The flag clears after the next successful breath.

**Files:** `keeper/lib/keeper/terrarium.ex`, `keeper/lib/keeper/wake.ex`
**Test:** Kill the bootstrap mid-breath (or make it crash intentionally). Verify: keeper checkpoints, next wake includes crash warning, agent orients correctly.

## Implementation Notes

### Token tracking

The Anthropic SDK exposes `response.usage.input_tokens` and `response.usage.output_tokens` on every response. Use actual counts, not estimates. Track cumulative `input_tokens` from the most recent response (which reflects the full conversation so far) as the basis for threshold checks. No heuristics needed.

### Negotiation message format

The Anthropic API supports mixing `tool_result` and `text` content blocks in a single user message. The negotiation injection appends a `{"type": "text", "text": "..."}` block to the tool_results list. The model sees both the tool results and the injected text. This keeps the conversation structure clean — no extra messages, no alternation issues.

If the 80% threshold is crossed on a turn with no tool calls (agent sent only text), the agent has already signaled `end_turn` and the loop breaks normally. The 80% check only fires after tool results, which is the common case during active work.

### Outbox parsing robustness

The outbox might not be valid YAML. It might not have a `type` field. The keeper should default to `response` behavior if parsing fails — checkpoint and idle. Don't crash the keeper because the agent wrote bad YAML.

### Continuation vs. new task

A continuation re-wake is different from a new task wake. The inbox message type is `continuation`, from `system`, channel `internal`. The bootstrap uses this to frame the prompt correctly. The keeper tracks it separately from human-initiated wakes for budget accounting (Sprint 2).

## Open Risks

- **Negotiation reliability.** Will the agent actually respond with CONTINUING or HANDING_OFF, or will it ignore the injection and keep working? The system prompt needs to establish this pattern clearly. Soul.md should reinforce it.
- **Continuation handoff quality.** The agent needs to write handoffs that are good enough for a fresh context to pick up mid-task. This is harder than end-of-task handoffs. Testing will reveal if the handoff norms in soul.md are sufficient.
- **Token count edge cases.** The API's `usage.input_tokens` reflects the full conversation each time, but tool results can vary in size. The 15% gap between 80% and 95% thresholds provides plenty of margin.
- **Runaway tasks that aren't runaways.** Some legitimate tasks need 10+ breaths. The runaway limit needs to be a guideline, not a wall. The keeper should warn, not kill.
