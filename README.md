# Vivarium

A framework for semi-autonomous agents that live in persistent Linux VMs.

The environment is the agent. The LLM animates it; it doesn't live in it. Memory is the filesystem. Security is the VM boundary. Everything else is emergent.

## How it works

A **keeper** (Elixir/OTP) manages the lifecycle of **terrariums** — Fly.io Sprite VMs where agents live. Each terrarium contains a **bootstrap** (Rust static binary) that wakes the agent, runs an LLM tool loop, and lets the agent do whatever it wants with four tools: `bash`, `read_file`, `write_file`, `edit_file`.

Between sessions, the agent doesn't exist as a running process. It exists as a filesystem snapshot. When it wakes, it reads a handoff note from its past self and picks up where it left off.

```
Human (Telegram)
  |
Keeper (Elixir/OTP)
  - Telegram bot: commands + message routing
  - Lifecycle: create, wake, checkpoint, restore, destroy
  - Budget enforcement: tokens, breaths, compute
  - Gallery sync: /vivarium/public/ -> static web server
  |
  | Sprites API
  v
Terrarium (Fly.io Sprite VM)
  - Bootstrap (Rust): reads inbox -> LLM tool loop -> writes outbox
  - Four tools: bash, read_file, write_file, edit_file
  - Persistent filesystem: scripts, data, packages, notes
  - Protocol: JSON files in /vivarium/{inbox,outbox,context}/
```

## Components

**`bootstrap/`** — Rust. Static binary, zero runtime dependencies. Calls the Anthropic API directly. Includes prompt caching and context negotiation. The agent cannot corrupt it.

**`keeper/`** — Elixir/OTP. GenServer per terrarium. Telegram bot. Budget tracking. Git checkpoint after every breath. Gallery sync.

**`gallery/`** — Go. Tiny static file server on Fly. Agents put files in `/vivarium/public/` and they appear on the web. Accepts authenticated tar uploads from the keeper.

**`seed/`** — Soul document and operational knowledge seeded into new terrariums.

## Setup

### Prerequisites

- Elixir 1.19+
- Rust (with `cargo-zigbuild` for cross-compilation)
- Go 1.22+
- A [Fly.io](https://fly.io) account with Sprites access
- An Anthropic API key
- A Telegram bot token (optional)

### Build

```bash
# Bootstrap (cross-compile for Sprites)
cd bootstrap && cargo zigbuild --release --target x86_64-unknown-linux-musl

# Keeper
cd keeper && mix deps.get && mix compile

# Gallery
cd gallery && go build -o gallery .
```

### Deploy

```bash
# Gallery server
cd gallery
fly launch
fly secrets set GALLERY_TOKEN=<token>
fly deploy

# Keeper
fly secrets set SPRITES_TOKEN=<token> ANTHROPIC_API_KEY=<key>
fly secrets set TELEGRAM_BOT_TOKEN=<token>  # optional
fly secrets set GALLERY_URL=https://vivarium-gallery.fly.dev GALLERY_TOKEN=<token>
fly deploy
```

### Create a terrarium

From Telegram:
```
/create myagent
hello! welcome to the world.
```

Or from `iex`:
```elixir
Keeper.create("myagent")
Keeper.wake("myagent", "hello!")
```

## Design

See [DESIGN.md](DESIGN.md) for the full philosophy. The short version:

- **Not a framework.** A lifecycle manager + a thin agent loop + filesystem conventions.
- **Four tools, no more.** Everything else the agent gets through bash.
- **Handoff-driven continuity.** The agent writes a letter to its future self every session.
- **Git is the checkpoint system.** Every breath produces a commit. Diffs show what changed.
- **The keeper never enters the terrarium.** All interaction through the Sprites API.

## License

MIT
