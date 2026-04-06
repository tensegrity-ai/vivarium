# Vivarium

A Sprites-native framework for semi-autonomous agents. Two components: a **keeper** (Elixir/OTP) that manages lifecycle, and a **bootstrap** (Python) that animates the agent inside a Fly.io Sprite VM.

## Core Thesis

The environment is the agent. The LLM animates it; it doesn't live in it. Memory is the filesystem. Security is the VM boundary. Everything else is emergent.

Read `DESIGN.md` for the full philosophy and architecture. Read the `PLANS/` directory for implementation guides. This file is the operating context for development sessions.

## Architecture

```
Human (Signal, email, CLI)
  ↓
Keeper (Elixir/OTP, runs outside terrarium)
  - Lifecycle: start, stop, checkpoint, restore, branch
  - Message routing: human ↔ agent
  - Budget enforcement: tokens, breaths, compute
  - Credential vault: injects short-lived tokens
  - Scheduler: heartbeats, agent-requested wakes
  ↓ Sprites API (exec, checkpoint, restore)
Terrarium (Fly.io Sprite VM)
  - Bootstrap (Python): reads handoff → calls LLM → tool loop → writes handoff
  - Agent tools: bash, read_file, write_file, edit_file
  - Accumulated state: scripts, data, packages, notes
  - Protocol: files in /vivarium/{inbox,outbox,context}/
```

## Language Decisions

**Bootstrap = Python.** Runs inside the Sprite. ~200 lines. Dies after every breath. LLM provider SDKs are Python-first. No performance requirements. Start with raw Anthropic SDK, add litellm or provider switch later.

**Keeper = Elixir/OTP.** Long-lived concurrent lifecycle manager. Each terrarium is a GenServer. Supervision trees for fault tolerance. Message routing via pattern matching. Timer-based scheduling. The BEAM was built for this exact shape of problem.

**Protocol = YAML files on disk.** Language-agnostic. Keeper writes inbox, reads outbox. Bootstrap reads inbox, writes outbox. Agent writes handoff and log using its own tools.

## Key Design Principles

**Not a framework.** This is a lifecycle manager + a thin agent loop + a filesystem convention. No plugin systems. No skill registries. No memory architecture. The agent builds what it needs.

**Four tools, no more.** `bash`, `read_file`, `write_file`, `edit_file`. Everything else the agent gets through bash. The environment accretes capability through persistent packages and scripts, not through framework features.

**Handoff-driven continuity.** The agent writes a letter to its future self at the end of every breath. The bootstrap reads it at the start of the next breath. This is the primary orientation mechanism. The JSONL log is for retrieval. Checkpoints are for archaeology.

**Multi-breath as natural extension.** Tasks that exceed one context window produce a continuation handoff and immediately re-wake. The 80% negotiation gives the agent agency over when to hand off. The keeper enforces runaway protection.

**Checkpoint everything.** Every breath produces a checkpoint. The keeper manages retention. Branching is native. Restore is the recovery mechanism for everything from corruption to experimentation.

**Keeper never enters the terrarium.** All interaction through Sprites API exec(). Credentials never enter the Sprite as long-lived secrets. The VM boundary is the security boundary.

## What NOT to Build

- Memory systems (the agent builds its own)
- Skill registries or marketplaces
- Plugin architectures
- Multi-model orchestration inside the bootstrap
- GUI/dashboard (keeper is CLI-first, observability via checkpoint diffs)
- Tool-discovery from /vivarium/tools/ headers (v2 — design accommodates it, don't build it yet)
- Provider abstraction layer (start with one provider, switch later)

## File Structure (Target)

```
vivarium/
├── CLAUDE.md              # This file
├── DESIGN.md              # Philosophy and architecture (the big doc)
├── PLANS/                 # Implementation guides
│   ├── 00-sprint.md       # First sprint scope and milestones
│   ├── 01-bootstrap.md    # Bootstrap implementation guide
│   ├── 02-keeper.md       # Keeper implementation guide
│   └── 03-protocol.md     # Protocol specification
├── bootstrap/             # Python bootstrap
│   ├── bootstrap.py       # The agent loop (~200 lines)
│   ├── tools.py           # Tool definitions (bash, read, write, edit)
│   ├── context.py         # Handoff reading, prompt construction
│   └── requirements.txt
├── keeper/                # Elixir keeper
│   ├── mix.exs
│   ├── lib/
│   │   ├── keeper.ex              # Application entry
│   │   ├── keeper/terrarium.ex    # GenServer per terrarium
│   │   ├── keeper/scheduler.ex    # Heartbeat and wake scheduling
│   │   ├── keeper/sprites.ex      # Sprites API client
│   │   ├── keeper/budget.ex       # Budget tracking and enforcement
│   │   └── keeper/router.ex       # Message routing (v2)
│   └── config/
│       └── config.exs
├── seed/                  # Default seed files for new terrariums
│   ├── soul.md            # Default soul document
│   └── bootstrap.py       # Canonical bootstrap (keeper copies this in)
└── README.md
```

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

## Python

Use `uv` for all Python needs — packages, venvs, running scripts.

## Conventions

- The bootstrap is the agent's interface to the LLM. Keep it boring.
- The keeper is infrastructure. Keep it deterministic. No LLM calls in the keeper.
- YAML for all protocol files (inbox, outbox, checkpoint metadata, budget status).
- JSONL for the wake log (append-only, one line per breath).
- Markdown for handoff notes and soul documents.
- All times in UTC ISO 8601.
