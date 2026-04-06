# Keeper Implementation Guide

The keeper is an Elixir/OTP application that manages terrarium lifecycles. It talks to the Sprites API, routes messages, enforces budgets, and maintains checkpoint history. It never enters the terrarium. It never calls an LLM.

## Sprint 0: Script First, GenServer Second

Start as a simple Mix project with a single module that performs the lifecycle steps sequentially. No GenServer, no supervision tree, no concurrency. Just prove the Sprites API integration works and the keeper-bootstrap handshake is correct.

### Minimal API

```elixir
# Step 1: Create and seed a terrarium
Keeper.create("my-terrarium", soul: "seed/soul.md")

# Step 2: Wake with a message  
Keeper.wake("my-terrarium", message: "You're alive. Read your soul.")

# Step 3: Read the result
Keeper.read_outbox("my-terrarium")

# Step 4: Checkpoint
Keeper.checkpoint("my-terrarium")

# Step 5: Wake again with a new message
Keeper.wake("my-terrarium", message: "How's the environment coming along?")
```

Each function is synchronous and does exactly what it says. Error handling is {:ok, result} / {:error, reason} tuples, standard Elixir.

## Sprites API Integration

The keeper interacts with Sprites through their HTTP API. Core operations:

```
POST   /sprites              → create a Sprite
POST   /sprites/:id/start    → start (resume from idle)
POST   /sprites/:id/stop     → stop (idle)
POST   /sprites/:id/exec     → execute a command in the Sprite
POST   /sprites/:id/checkpoint → create a checkpoint
POST   /sprites/:id/restore  → restore from a checkpoint
DELETE /sprites/:id           → destroy
```

Wrap these in a `Keeper.Sprites` module with typed functions:

```elixir
defmodule Keeper.Sprites do
  def create(opts \\ []) do ... end
  def start(sprite_id) do ... end
  def stop(sprite_id) do ... end
  def exec(sprite_id, command) do ... end
  def checkpoint(sprite_id, metadata \\ %{}) do ... end
  def restore(sprite_id, checkpoint_id) do ... end
  def destroy(sprite_id) do ... end
end
```

Use `Req` for HTTP. Parse responses into structs. Handle errors as tuples.

If the Elixir SDK ships before we get here, use it instead. Check https://sprites.dev for updates.

## Seeding a Terrarium

Creating a new terrarium means:

1. Create a Sprite via API.
2. Exec: create directory structure (`mkdir -p /vivarium/{inbox,outbox,context,tools,data}` and `/vivarium/.keeper/`).
3. Exec: write soul.md from seed/ directory.
4. Exec: write bootstrap files (bootstrap.py, tools.py, context.py, requirements.txt).
5. Exec: `pip install -r /vivarium/bootstrap/requirements.txt` (one-time, persists after checkpoint).
6. Exec: write bootstrap_config.yaml to /vivarium/.keeper/.
7. Exec: write first inbox message.
8. Exec: run bootstrap (`python3 /vivarium/bootstrap/bootstrap.py`).
9. Read outbox.
10. Checkpoint.

Steps 2-6 are the seed. Steps 7-10 are the first breath. After the first checkpoint, subsequent wakes skip the seed steps.

## The Wake Cycle (Keeper's Perspective)

```
1. Write inbox message(s) via exec
2. Write/update .keeper/budget_status via exec
3. Inject credentials as env vars or files via exec
4. Start the Sprite (resume from idle)
5. Exec: python3 /vivarium/bootstrap/bootstrap.py
   - This blocks until the bootstrap exits
   - Capture exit code
6. Read outbox via exec: cat /vivarium/outbox/{latest}.msg
7. Parse outbox YAML
8. Handle outbox type:
   - response → route message, checkpoint, idle
   - continuing → checkpoint, immediately re-wake (go to step 1)
   - request → route request to human, checkpoint, idle
   - silent → checkpoint, idle
9. Checkpoint the Sprite
10. Stop the Sprite (idle — costs nothing)
11. Record breath in keeper's own log (local, not in the Sprite)
```

### Credential Injection

The keeper writes credentials as temporary files or environment variables before running the bootstrap:

```elixir
# Write API key as env var for the bootstrap process
Sprites.exec(sprite_id, ~s|export ANTHROPIC_API_KEY="#{api_key}" && python3 /vivarium/bootstrap/bootstrap.py|)
```

Or write to a file the bootstrap reads:

```elixir
Sprites.exec(sprite_id, ~s|echo '#{api_key}' > /tmp/.anthropic_key|)
Sprites.exec(sprite_id, ~s|ANTHROPIC_API_KEY=$(cat /tmp/.anthropic_key) python3 /vivarium/bootstrap/bootstrap.py|)
# Key is in /tmp which may or may not persist — test this
```

The exact mechanism depends on how Sprites handles environment variables across exec() calls. Test during Sprint 0.

## Terrarium State (GenServer — Sprint 0, Step 5)

When we promote to a GenServer, the state struct:

```elixir
defmodule Keeper.Terrarium do
  use GenServer

  defstruct [
    :id,                  # Sprite ID
    :name,                # Human-readable name
    :status,              # :idle | :waking | :breathing | :settling
    :current_checkpoint,  # Latest checkpoint ID
    :checkpoint_history,  # List of {checkpoint_id, metadata}
    :breath_count,        # Total breaths since creation
    :consecutive_continuations, # For runaway detection
    :budget,              # %Budget{tokens_used, breaths_used, compute_ms}
    :config               # %Config{model, heartbeat_interval, ...}
  ]
end
```

The GenServer handles:
- `{:wake, message}` → execute wake cycle, update state
- `{:checkpoint, opts}` → call Sprites API, record in history
- `{:restore, checkpoint_id}` → restore, reset relevant state
- `{:status}` → return current state for inspection

## Checkpoint Metadata

The keeper maintains its own record of checkpoints (not inside the Sprite):

```elixir
%CheckpointMeta{
  id: "cp_abc123",
  sprite_id: "sprite_xyz",
  timestamp: ~U[2026-04-06 15:35:00Z],
  trigger: :message,           # :message | :heartbeat | :scheduled | :continuation
  breath_number: 42,
  tokens_used: 34_500,
  compute_ms: 45_000,
  outbox_type: :response,      # :response | :continuing | :request | :silent
  outbox_summary: "Set up weekly digest pipeline",
  pinned: false,               # Pinned checkpoints are never pruned
  branch_parent: nil           # Set if this checkpoint started a branch
}
```

Store this in a local SQLite database or a simple JSON file. Nothing fancy for Sprint 0.

## Configuration

```elixir
# config/config.exs
config :keeper,
  sprites_api_url: "https://api.sprites.dev",
  sprites_token: System.get_env("SPRITES_TOKEN"),
  
  # Default terrarium config (overridable per terrarium)
  default_model: "claude-sonnet-4-20250514",
  default_heartbeat_interval: :timer.minutes(30),
  
  # Budget defaults
  daily_token_limit: 500_000,
  daily_breath_limit: 30,
  daily_compute_limit_ms: :timer.minutes(15) |> :timer.seconds() |> Kernel.*(1000),
  
  # Credentials (keeper holds these, never written to Sprite as persistent files)
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY")
```

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:req, "~> 0.5"},       # HTTP client
    {:yaml_elixir, "~> 2.9"}, # YAML parsing for outbox
    {:jason, "~> 1.4"}      # JSON for JSONL log reading
  ]
end
```

Minimal. Add more as needed (e.g., SQLite for checkpoint metadata in Sprint 2+).

## Sprint 0 Deliverable

A Mix project with:
- `Keeper.Sprites` — HTTP wrapper for the Sprites API
- `Keeper.Seed` — creates and seeds a new terrarium
- `Keeper.Wake` — executes one wake cycle (write inbox, run bootstrap, read outbox, checkpoint)
- A mix task or script that runs: seed → wake → read → checkpoint → wake → read → checkpoint

No GenServer. No concurrency. No scheduling. Just the loop.
