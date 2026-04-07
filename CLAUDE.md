# Vivarium

A Sprites-native framework for semi-autonomous agents. Two components: a **keeper** (Elixir/OTP) that manages lifecycle, and a **bootstrap** (Rust) that animates the agent inside a Fly.io Sprite VM.

## Core Thesis

The environment is the agent. The LLM animates it; it doesn't live in it. Memory is the filesystem. Security is the VM boundary. Everything else is emergent.

Read `DESIGN.md` for the full philosophy and architecture. Read the `PLANS/` directory for implementation guides. This file is the operating context for development sessions.

## Architecture

```
Human (Telegram)
  ↓
Keeper (Elixir/OTP, runs outside terrarium)
  - Telegram bot: slash commands + message routing
  - Lifecycle: start, stop, checkpoint (git), restore, branch
  - Budget enforcement: tokens, breaths, compute
  - Credential vault: injects short-lived tokens
  - Scheduler: heartbeats, agent-requested wakes
  - Gallery sync: pushes /vivarium/public/ to static server after each breath
  ↓ Sprites API (exec, fs read/write) + git inside /vivarium/
Terrarium (Fly.io Sprite VM)
  - Bootstrap (Rust static binary): reads handoff → calls LLM → tool loop → writes handoff
  - Agent tools: bash, read_file, write_file, edit_file
  - Accumulated state: scripts, data, packages, notes
  - Protocol: JSON files in /vivarium/{inbox,outbox,context}/
```

## Language Decisions

**Bootstrap = Rust.** Static binary, zero runtime dependencies. The agent cannot corrupt it. Runs inside the Sprite, dies after every breath. Calls the Anthropic API directly via HTTP+JSON — no SDK needed. Includes explicit prompt cache breakpoints for token savings.

**Keeper = Elixir/OTP.** Long-lived concurrent lifecycle manager. Each terrarium is a GenServer. Supervision trees for fault tolerance. Message routing via pattern matching. Timer-based scheduling. The BEAM was built for this exact shape of problem.

**Protocol = JSON files on disk.** One serialization format for all structured data. Keeper writes inbox (JSON), reads outbox (JSON). Bootstrap reads inbox, writes outbox. Agent writes handoff (markdown) and log (JSONL) using its own tools.

## Key Design Principles

**Not a framework.** This is a lifecycle manager + a thin agent loop + a filesystem convention. No plugin systems. No skill registries. No memory architecture. The agent builds what it needs.

**Four tools, no more.** `bash`, `read_file`, `write_file`, `edit_file`. Everything else the agent gets through bash. The environment accretes capability through persistent packages and scripts, not through framework features.

**Handoff-driven continuity.** The agent writes a letter to its future self at the end of every breath. The bootstrap reads it at the start of the next breath. This is the primary orientation mechanism. The JSONL log is for retrieval. Checkpoints are for archaeology.

**Multi-breath as natural extension.** Tasks that exceed one context window produce a continuation handoff and immediately re-wake. The 80% negotiation gives the agent agency over when to hand off. The keeper enforces runaway protection.

**Git is the checkpoint system.** Every breath produces a git commit inside `/vivarium/`. Diffs show what changed. Branching is `git checkout -b`. Restore is `git reset --hard`. Sprites checkpoints (full VM snapshots) are reserved for disaster recovery. The agent can inspect its own history via `git log`.

**Keeper never enters the terrarium.** All interaction through Sprites API exec(). Credentials never enter the Sprite as long-lived secrets. The VM boundary is the security boundary.

## What NOT to Build

- Memory systems (the agent builds its own)
- Skill registries or marketplaces
- Plugin architectures
- Multi-model orchestration inside the bootstrap
- GUI/dashboard (keeper is CLI-first, observability via checkpoint diffs)
- Tool-discovery from /vivarium/tools/ headers (v2 — design accommodates it, don't build it yet)
- Provider abstraction layer (start with one provider, switch later)

## File Structure

```
vivarium/
├── CLAUDE.md                  # This file
├── DESIGN.md                  # Philosophy and architecture
├── PLANS/
│   ├── 00-sprint.md           # Sprint 0: first breath (done)
│   ├── 01-sprint.md           # Sprint 1: multi-breath (done)
│   ├── 02-sprint.md           # Sprint 2: budget & heartbeat (done)
│   ├── 01-bootstrap.md        # Bootstrap implementation guide
│   ├── 02-keeper.md           # Keeper implementation guide
│   ├── 03-protocol.md         # Protocol specification
│   └── tech-debt.md           # Known issues and future work
├── bootstrap/                 # Rust bootstrap (static binary)
│   ├── Cargo.toml             # serde, serde_json, reqwest
│   └── src/
│       ├── main.rs            # Agent loop with token tracking + negotiation + prompt caching
│       ├── api.rs             # Anthropic Messages API client (blocking HTTP, retries)
│       ├── context.rs         # Prompt assembly (continuation/crash-aware)
│       └── tools.rs           # Four tools (bash, read, write, edit)
├── keeper/                    # Elixir keeper (~500 lines)
│   ├── mix.exs
│   ├── lib/
│   │   ├── keeper.ex              # Top-level API
│   │   ├── keeper/application.ex  # OTP app + supervision tree
│   │   ├── keeper/terrarium.ex    # GenServer per terrarium
│   │   ├── keeper/sprites.ex          # Sprites HTTP API client (CLI fallback)
│   │   ├── keeper/git.ex              # Git operations via Sprites.exec
│   │   ├── keeper/seed.ex             # Terrarium creation + seeding (incl git init)
│   │   ├── keeper/wake.ex             # Breath execution + outbox parsing
│   │   ├── keeper/budget.ex           # Budget tracking + enforcement
│   │   ├── keeper/config.ex           # Per-terrarium configuration
│   │   ├── keeper/checkpoint_meta.ex  # Git commit metadata struct
│   │   ├── keeper/telegram.ex         # Telegram bot (polling + commands)
│   │   ├── keeper/gallery.ex          # Gallery sync (public/ → static server)
│   │   └── mix/tasks/sprint0.ex       # Sprint 0 demo task
│   └── test/
├── gallery/                   # Static file server for agent galleries
│   ├── main.go                # Go binary: serves files + accepts tar uploads
│   ├── Dockerfile
│   └── fly.toml               # Separate Fly app (vivarium-gallery)
├── seed/
│   ├── soul.md                # Default agent soul document
│   └── AGENTS.md              # Agent operational knowledge (seeded into terrarium)
```

## Environment

- `ANTHROPIC_API_KEY` — available in env, injected by keeper into Sprite at wake time
- `SPRITES_TOKEN` — required; keeper uses Sprites HTTP API directly.
- `TELEGRAM_BOT_TOKEN` — optional; when set, starts the Telegram bot on keeper startup.
- `GALLERY_URL` — optional; gallery server URL (e.g. `https://vivarium-gallery.fly.dev`). Enables gallery sync.
- `GALLERY_TOKEN` — required if GALLERY_URL is set; Bearer token for gallery upload API.
- `sprite` CLI available for manual operations (org: `tensegrity-systems`)

## Development Workflow

1. Work on bootstrap and keeper independently — they only interact through files and the Sprites API.
2. Test the bootstrap by running it manually inside a Sprite: `sprite create`, ssh in, run the bootstrap, inspect results.
3. Test the keeper locally with `mix run`, pointed at a Fly.io account.
4. Integration: keeper creates Sprite, execs bootstrap, reads outbox, checkpoints.

## Git

Commit early and often. Use conventional commits, lowercase, brief:

```
feat: bootstrap agent loop with four tools
fix: handle missing handoff on first breath
refactor: extract prompt assembly into context.py
docs: add sprint 0 plan
```

## Rust

The bootstrap is built with `cargo`. Cross-compile for Sprites via `cargo-zigbuild`:

```
cd bootstrap && cargo zigbuild --release --target x86_64-unknown-linux-musl
```

## Python

Use `uv` for all Python needs — packages, venvs, running scripts. (Python is not used by the bootstrap, but may be used by the agent inside the Sprite.)

## Conventions

- The bootstrap is the agent's interface to the LLM. Keep it boring.
- The keeper is infrastructure. Keep it deterministic. No LLM calls in the keeper.
- JSON for all structured protocol files (inbox, outbox, budget status, bootstrap config).
- JSONL for the wake log (append-only, one line per breath).
- Markdown for handoff notes, soul documents, and AGENTS.md.
- All times in UTC ISO 8601.
