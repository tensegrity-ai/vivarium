# Keeper

Elixir/OTP lifecycle manager for Vivarium terrariums. Manages Sprite VMs through the Sprites API — creates them, wakes the agent, reads results, checkpoints, and enforces budgets. Never enters the terrarium. Never calls an LLM.

## Quick Start

```bash
# Ensure environment
export ANTHROPIC_API_KEY="..."
export FLY_API_TOKEN="..."  # or: sprite login

# Run the two-breath demo
cd keeper
mix deps.get
mix run -e "Mix.Tasks.Sprint0.run([])"
```

## API

```elixir
# Create a terrarium with default config
Keeper.create("my-agent")

# Create with custom config
Keeper.create("my-agent",
  model: "claude-sonnet-4-20250514",
  heartbeat_interval_ms: :timer.minutes(30),
  budget: [daily_tokens: 500_000, daily_breaths: 30]
)

# Wake with a message (blocks until breath completes)
{:ok, %{type: :response, raw: outbox_yaml}} =
  Keeper.wake("my-agent", "What's the status of the project?")

# Checkpoint
{:ok, output} = Keeper.checkpoint("my-agent")

# Check status (breath count, budget, checkpoint history)
status = Keeper.status("my-agent")
```

## Architecture

Each terrarium is a GenServer registered by name. The supervision tree:

```
Application
├── Registry (name lookup)
└── DynamicSupervisor
    ├── Terrarium GenServer ("agent-1")
    ├── Terrarium GenServer ("agent-2")
    └── ...
```

## Modules

| Module | Purpose |
|--------|---------|
| `Keeper` | Top-level API — delegates to Terrarium GenServers |
| `Keeper.Terrarium` | GenServer per terrarium — lifecycle, breath loop, heartbeat, budget |
| `Keeper.Wake` | Executes one breath — inbox writing, bootstrap exec, outbox parsing |
| `Keeper.Sprites` | Wraps `sprite` CLI — create, exec, checkpoint, restore |
| `Keeper.Seed` | Creates new terrarium — dirs, soul, bootstrap, config, deps |
| `Keeper.Budget` | Tracks tokens/breaths/compute, enforces daily limits |
| `Keeper.Config` | Per-terrarium configuration struct |

## Wake Cycle

```
Keeper.wake(name, message)
  → clear inbox
  → write budget_status
  → write inbox message
  → exec bootstrap (timed)
  → read outbox + parse YAML type
  → read breath_usage.yaml (tokens)
  → return {type, raw, usage, compute_ms}
```

If outbox type is `continuing`, the Terrarium GenServer checkpoints and immediately re-wakes (up to 5 consecutive continuations before runaway protection kicks in).

## Budget Enforcement

Three dimensions tracked per day: tokens, breaths, compute_ms. When any limit is hit:
- Heartbeat wakes are deferred (logged, not executed)
- Human-initiated wakes always go through
- Scheduled wakes are deferred with a warning

Budget resets at UTC midnight.

## Dependencies

- `yaml_elixir` — YAML parsing for outbox and usage files
- `jason` — JSON (for future use with JSONL log reading)
