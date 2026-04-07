# Sprint 2: Budget & Heartbeat

Goal: the keeper tracks resource consumption, enforces budget limits, and wakes the agent on a schedule. The agent sees its budget and can request scheduled wakes. Message routing is deferred — the infrastructure here (wake triggers, request parsing) is the foundation for it, but actual channel integrations are Sprint 3+.

## Success Criteria

1. Bootstrap writes token usage to a file after each breath. Keeper reads it and accumulates totals.
2. Keeper writes budget_status to `.keeper/budget_status` before each wake. Agent can see how much budget remains.
3. Keeper enforces daily limits: max tokens, max breaths, max compute time. When exhausted, heartbeat wakes are deferred.
4. Human-initiated wakes always go through regardless of budget.
5. Keeper runs a heartbeat timer. Agent wakes on schedule (e.g., every 30 minutes), does routine work, idles.
6. Agent can request a scheduled wake via outbox (`type: schedule`). Keeper honors it at the specified time.
7. Budget resets on period boundaries (daily at midnight UTC).

## What's In Scope

- Bootstrap: write usage summary after each breath.
- Keeper: budget tracking (tokens, breaths, compute_ms), budget enforcement, budget_status file.
- Keeper: heartbeat timer per terrarium, configurable interval.
- Keeper: outbox request parsing (schedule requests).
- Keeper: terrarium config (model, heartbeat interval, budget limits).
- Protocol: usage summary file, budget_status format (already specified in 03-protocol.md).

## What's Out of Scope

- Message routing from external channels (Sprint 3)
- Multiple terrariums managed concurrently (Sprint 3)
- Branching (Sprint 3)
- Checkpoint retention policies (Sprint 3)
- Cost-in-dollars tracking (nice-to-have, not essential)

## Implementation Order

### Step 1: Bootstrap writes usage summary

At the end of the agent loop (after the `while` breaks), the bootstrap writes a usage file to `/vivarium/.keeper/breath_usage.yaml`:

```yaml
input_tokens: 9236
output_tokens: 4821
total_tokens: 14057
api_calls: 19
```

Track cumulative `input_tokens` and `output_tokens` across all API calls in the loop. The `input_tokens` from each call includes the full conversation, so total billed input is just the *last* call's `input_tokens`. Output tokens sum across all calls. `total_tokens` = last_input + sum_of_outputs. `api_calls` = number of loop iterations.

Write this even on error paths (best-effort). The keeper reads it after each breath.

**Files:** `bootstrap/bootstrap.py`

### Step 2: Keeper reads usage, tracks budget

After each breath, the keeper reads `/vivarium/.keeper/breath_usage.yaml` from the Sprite. It also measures wall-clock compute time (start/end of `run_bootstrap`).

Add a `Budget` struct to the terrarium state:

```elixir
defstruct [
  tokens_used: 0,        # cumulative tokens this period
  breaths_used: 0,        # already have breath_count
  compute_ms: 0,          # cumulative wall-clock ms
  period_start: DateTime  # when current period began
]
```

After each breath:
1. Read breath_usage.yaml from Sprite
2. Add tokens to cumulative total
3. Add compute_ms (wall clock of bootstrap run)
4. Increment breaths (already done)

**Files:** `keeper/lib/keeper/budget.ex` (new), `keeper/lib/keeper/terrarium.ex`, `keeper/lib/keeper/wake.ex`

### Step 3: Keeper writes budget_status before each wake

Before writing the inbox message, the keeper writes the current budget status to `/vivarium/.keeper/budget_status`. The bootstrap already reads this file in context assembly.

Format (already specified in 03-protocol.md):
```yaml
period: daily
period_start: "2026-04-07T00:00:00Z"
tokens:
  used: 127500
  limit: 500000
  remaining: 372500
breaths:
  used: 8
  limit: 30
  remaining: 22
compute_ms:
  used: 180000
  limit: 900000
  remaining: 720000
```

**Files:** `keeper/lib/keeper/budget.ex`, `keeper/lib/keeper/wake.ex`

### Step 4: Terrarium config

The terrarium needs per-instance configuration. Add a config struct that's passed at creation time and stored in GenServer state:

```elixir
defstruct [
  model: "claude-sonnet-4-20250514",
  heartbeat_interval_ms: :timer.minutes(30),
  budget: %{
    daily_tokens: 500_000,
    daily_breaths: 30,
    daily_compute_ms: :timer.minutes(15)
  }
]
```

`Seed.create` writes `bootstrap_config.yaml` from this config. This also fixes the tech debt item about missing config files.

**Files:** `keeper/lib/keeper/config.ex` (new), `keeper/lib/keeper/seed.ex`, `keeper/lib/keeper/terrarium.ex`

### Step 5: Budget enforcement

Before each wake, check budget:

```
if wake_trigger == :heartbeat and budget_exhausted?(state):
  defer (skip this wake, log it)
elif wake_trigger == :scheduled and budget_exhausted?(state):
  defer with warning
elif wake_trigger == :human:
  always proceed (human override is sacred)
```

Budget is "exhausted" when any of the three dimensions (tokens, breaths, compute) hits 100% of its daily limit.

Period reset: at the start of each wake, check if we've crossed a day boundary since `period_start`. If so, reset counters.

**Files:** `keeper/lib/keeper/budget.ex`, `keeper/lib/keeper/terrarium.ex`

### Step 6: Heartbeat timer

The GenServer starts a timer on creation (if heartbeat is configured). On timer fire, it triggers a heartbeat wake:

```elixir
def handle_info(:heartbeat, state) do
  # Schedule next heartbeat first (so it fires even if this wake fails)
  schedule_heartbeat(state)
  
  if budget_exhausted?(state) do
    # Log deferral, don't wake
    {:noreply, state}
  else
    # Wake with heartbeat inbox
    case breathe_loop(state, "Heartbeat check-in", inbox_type: :heartbeat) do
      {:ok, outbox, state} ->
        state = handle_outbox_requests(state, outbox)
        do_checkpoint(state)
        {:noreply, %{state | status: :idle}}
      ...
    end
  end
end

defp schedule_heartbeat(%{config: %{heartbeat_interval_ms: ms}}) do
  Process.send_after(self(), :heartbeat, ms)
end
```

Heartbeat inbox message type is `heartbeat`, from `system`, channel `cron`.

**Files:** `keeper/lib/keeper/terrarium.ex`

### Step 7: Outbox request parsing

After each breath, the keeper parses the outbox `requests` field. For Sprint 2, handle two request types:

**`type: schedule`** — Agent requests a future wake.
```yaml
requests:
  - type: schedule
    when: "2026-04-07T09:00:00Z"
    prompt: "Check if the cron is working."
```
The keeper stores the scheduled wake and fires it at the specified time using `Process.send_after` with the delay computed from now. Simple, in-memory — if the keeper restarts, scheduled wakes are lost (acceptable for Sprint 2, persistent scheduling is Sprint 3+).

**`type: credential`** — Agent requests access to a service. For now, just log the request and surface it to the human. No automated credential provisioning yet.

**Files:** `keeper/lib/keeper/terrarium.ex`, `keeper/lib/keeper/wake.ex`

## Implementation Notes

### Token accounting accuracy

The bootstrap tracks tokens from the API's `usage` field, which is ground truth for billing. But "total tokens billed" isn't simply `sum(input + output)` per call — each call re-sends the full conversation, so input tokens overlap between calls. The meaningful budget metric is: sum of `output_tokens` across all calls + the final call's `input_tokens`. This represents what Anthropic actually bills.

Actually, for simplicity: just sum `input_tokens + output_tokens` per call. This overcounts input (since messages are re-sent), but it's conservative — you'll hit budget limits earlier than actual billing, which is the safe direction. Refine later if the overcounting matters in practice.

### Heartbeat as handle_info

Heartbeat wakes go through `handle_info`, not `handle_call`. This means:
- No caller waiting for a response
- The GenServer can decide to skip the wake without anyone blocking
- Heartbeat results are logged, not returned

Human-initiated wakes still go through `handle_call` (synchronous, caller gets the outbox).

### Budget period boundaries

Use calendar days in UTC. `period_start` is midnight UTC of the current day. On each wake, check `DateTime.utc_now()` against `period_start + 1 day`. If crossed, reset counters and update `period_start`.

### Wake triggers

Wakes now have an explicit trigger type that flows through the system:

| Trigger | Source | Budget check | Inbox type |
|---------|--------|-------------|------------|
| `:human` | `handle_call({:wake, ...})` | Always allow | `message` |
| `:heartbeat` | `handle_info(:heartbeat)` | Defer if exhausted | `heartbeat` |
| `:scheduled` | `handle_info({:scheduled, ...})` | Defer with warning | `scheduled` |
| `:continuation` | Internal (breathe_loop) | No check (mid-task) | `continuation` |

## Open Risks

- **Budget overcounting.** Summing input+output per call overcounts because input tokens are resent. This means the agent gets fewer total tokens than the budget allows. Conservative but potentially frustrating if limits are tight.
- **In-memory scheduled wakes.** If the keeper process restarts, scheduled wakes are lost. Acceptable for Sprint 2 but needs persistent storage (or re-reading from the agent's outbox history) in Sprint 3.
- **Heartbeat during long breath.** If a heartbeat timer fires while the GenServer is already processing a breath (in `handle_call`), the `handle_info` message queues. The heartbeat runs after the current breath completes. This is correct OTP behavior but means heartbeats can drift.
- **No alerting.** The budget system defers wakes but doesn't notify the human. Sprint 3 should add alerts when budget hits thresholds (80% warning, 100% pause).
