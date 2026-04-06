# Sprint 0: The First Breath

Goal: prove the core loop works end-to-end. Keeper wakes a Sprite, bootstrap animates the agent, agent does something meaningful and writes a handoff, keeper checkpoints. Then do it again and verify the handoff provides continuity.

## Success Criteria

1. Keeper creates a Sprite and seeds it (soul.md, bootstrap, first inbox message).
2. Keeper execs the bootstrap. Agent wakes, reads soul, reads inbox, does work, writes outbox + handoff + log entry.
3. Keeper reads outbox, checkpoints the Sprite, idles it.
4. Keeper writes a second inbox message, re-wakes the Sprite, execs the bootstrap again.
5. Agent reads its own handoff from the first breath and demonstrates continuity — it knows what it did before.
6. Keeper checkpoints again. Two checkpoints exist in history.

That's it. If this works, the thesis holds. Everything else is refinement.

## What's In Scope

- Bootstrap: agent loop with four tools, handoff writing, JSONL log append.
- Keeper: single-terrarium lifecycle (create, exec, checkpoint, idle, re-wake). No scheduling, no budget, no routing.
- Protocol: inbox/outbox YAML, handoff markdown, wake.jsonl.
- Seed: a minimal soul.md that establishes the handoff norm.
- One LLM provider (Anthropic API, direct SDK, API key auth).

## What's Out of Scope

- Multi-breath / continuation handoffs (Sprint 1)
- 80% negotiation (Sprint 1)
- Budget enforcement (Sprint 2)
- Heartbeat scheduling (Sprint 2)
- Message routing from external channels (Sprint 2)
- Multiple terrariums (Sprint 3)
- Branching (Sprint 3)
- Checkpoint diffing and retention (Sprint 3)

## Implementation Order

### Step 1: Bootstrap, tested manually in a Sprite

Create a Sprite by hand (`sprite create`). SSH in. Copy the bootstrap files. Write a fake inbox message. Run the bootstrap. Verify: agent reads inbox, does something, writes outbox + handoff + log. No keeper involved yet.

### Step 2: Bootstrap, second breath

Without destroying the Sprite, write another inbox message by hand. Run bootstrap again. Verify: agent reads its own handoff from step 1, demonstrates awareness of prior context. The handoff chain works.

### Step 3: Keeper, lifecycle only

Build the minimal keeper that can: create a Sprite, exec files into it (soul.md, bootstrap, inbox message), exec the bootstrap, wait for completion, read the outbox, call checkpoint. No GenServer yet — just a script that does the steps sequentially.

### Step 4: Keeper + bootstrap integration

Run the keeper. It creates the Sprite, seeds it, wakes it (step 1), reads the result, checkpoints, writes a new inbox message, wakes it again (step 2), reads the result, checkpoints. Two breaths, fully automated.

### Step 5: Promote to GenServer

Refactor the keeper script into a proper GenServer that holds terrarium state. This is the foundation for everything in Sprint 1+.

## Open Risks

- Sprites API latency for exec() — if writing files and reading files through exec() is slow, the keeper-terrarium communication pattern might need rethinking.
- Bootstrap startup time inside the Sprite — if Python cold-start plus dependency loading is slow, it affects the economics.
- Context budget allocation — the 10K-token orientation budget is a guess. Real testing will validate or revise it.
- Handoff quality — will the LLM actually write useful handoffs with just soul.md guidance?
