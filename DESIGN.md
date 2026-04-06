# Vivarium

**A Sprites-native framework for semi-autonomous agents.**

*The environment is the agent. The checkpoint is the memory. The boundary is the security model.*

---

## The Core Thesis

Existing agent frameworks — OpenClaw, Hermes, AutoGPT, and their descendants — share a common architecture: a long-lived process that wraps an LLM, bolts on a memory system, and connects to external services through plugins or skills. The agent is the process. The environment is disposable infrastructure underneath it.

Vivarium inverts this.

The agent is the environment. A persistent, mutable Linux VM (a Fly.io Sprite) that accumulates state over time — files, scripts, databases, installed packages, browser profiles, cron jobs, notes-to-self. The LLM is not a daemon. It's the force that animates the environment when it wakes. Between sessions, the agent doesn't exist as a running process. It exists as a filesystem snapshot. Memory isn't a system. It's what happens when you don't destroy the world between interactions.

A second component — the **keeper** — lives outside the VM and manages its lifecycle: when to wake it, what to tell it, what to do with its output, where to store checkpoints, who gets to talk to it. The keeper never enters the terrarium. It operates exclusively through the Sprites API.

These two components, plus a thin convention for how they communicate, constitute the entire framework. Everything else is emergent.

---

## Why Not Just Run OpenClaw/Hermes on a Sprite?

You could. Both support Docker and SSH backends. But you'd be importing assumptions that Sprites makes unnecessary:

**Memory as a bolted-on system.** OpenClaw stores memory as markdown files in a workspace. Hermes uses a layered stack: MEMORY.md files, SQLite FTS5 indexes, LLM summarization, Honcho user modeling. Both are engineering responses to a real problem — LLMs are stateless and conversations are ephemeral. But in a persistent VM, the problem partially dissolves. The agent can store whatever it wants, however it wants, and it persists. The filesystem is the memory. A SQLite database the agent builds for its own purposes *is* procedural memory. A directory of notes *is* episodic memory. You don't need a memory architecture because the agent can build one that suits it.

**Skills as a managed system.** OpenClaw has ClawHub, a skill registry with SKILL.md files. Hermes auto-generates skill documents from completed tasks. Both treat skills as a category of artifact that the framework manages. In a Vivarium, a "skill" is just a script the agent wrote and saved. Or a package it installed. Or a workflow it documented for itself in a text file. The environment accretes capability the same way a developer's workstation does — through use.

**The security afterthought.** OpenClaw runs on the host OS. It has had RCE vulnerabilities, malicious skills in its marketplace, and prompt injection through skill files. Hermes is better (sandbox-first design, no public CVEs), but the security model is still "the framework tries to restrict what the agent can do." In a Vivarium, the security model is "the VM is the blast radius." Hardware isolation via Firecracker. The agent can do anything it wants *inside* the Sprite. It simply can't get out.

**The daemon assumption.** Both OpenClaw and Hermes run as persistent gateway processes. Hermes explicitly: "talk to it from Telegram while it works on a cloud VM." This implies always-on compute. A Vivarium agent only exists when it has something to do. The keeper wakes it, it processes, it sleeps. You pay for thoughts, not for waiting.

---

## Architecture

### The Keeper

A lightweight, long-lived service that runs outside the terrarium. It is the agent's interface to the outside world and the human's interface to the agent. It never enters the Sprite.

**Responsibilities:**

- **Lifecycle management.** Start, stop, checkpoint, restore, branch, destroy. The keeper decides when the agent wakes and ensures it checkpoints after meaningful work.

- **Wake triggers.** The keeper wakes the agent in response to: a heartbeat schedule (e.g., every 30 minutes), an inbound message from the human, a webhook from an external service, a scheduled task the agent previously requested, or the human explicitly saying "go."

- **Credential vault.** Long-lived secrets (API keys, OAuth tokens) never enter the Sprite. The keeper either injects short-lived session tokens at wake time or proxies authenticated requests on the agent's behalf. If the agent is compromised, the attacker gets sessions that expire, not keys that persist.

- **Communication routing.** Messages from the human (via Signal, email, Telegram, a web dashboard, whatever) arrive at the keeper. The keeper translates them into a format the agent can consume and delivers them at wake time. Agent output goes the other direction: the keeper reads from a known location in the Sprite and routes to the appropriate channel.

- **Checkpoint management.** The keeper maintains a history of checkpoints with metadata: what triggered the wake cycle, what the agent produced, how long it ran, what changed. This history is the agent's archaeological record. The keeper can diff checkpoints, prune old ones, and manage branching.

- **Budget enforcement.** The keeper tracks three dimensions of spend: token consumption (API cost, the dominant expense), breath count (wake cycles, which maps to checkpoint frequency and operational complexity), and compute time (Sprite CPU-seconds). Budget policy lives in the keeper's config, not in the agent's soul. The agent doesn't need to know its budget — it just needs to know that sometimes the keeper won't wake it. When budget is exhausted, heartbeat wakes are deferred, but human messages always get through. Tasks the agent previously flagged as critical are allowed with an alert to the human.

- **Observation.** The keeper can inspect the terrarium's state — read files, list processes, check disk usage — without waking the agent. This is the window into the terrarium. You look in; you don't reach in.

**What the keeper is NOT:**

- A content inspector. It doesn't analyze what the agent is doing.
- A behavioral monitor. It doesn't approve or deny actions.
- A framework. It doesn't provide tools, skills, or memory systems to the agent.
- Smart. It's infrastructure, not intelligence. A state machine with a cron scheduler and a message router.

The keeper could be implemented as: a single Fly Machine (~$2/month), a process on a home server, a Cloudflare Worker, a small Go or Rust binary on a Raspberry Pi. It needs to be reliable and minimal. Treat it like firmware.

### The Terrarium

A Fly.io Sprite running a standard Linux environment with a thin bootstrap.

**At first boot:**

1. The keeper creates a Sprite and execs the bootstrap script.
2. The bootstrap installs minimal dependencies (curl, the LLM's preferred tools — probably just python3 and a few packages).
3. The keeper writes the **seed** to a known location: `/vivarium/soul.md`. This is the initial identity document — personality, purpose, constraints, the human's preferences and expectations.
4. The keeper writes the first message to `/vivarium/inbox/`. Probably something like: "You're alive. Read your soul. Look around. Make this place yours."
5. The bootstrap invokes the LLM with a system prompt that says, essentially: "You are an agent living in a Linux VM. Your soul is at /vivarium/soul.md. Your inbox is at /vivarium/inbox/. Your outbox is at /vivarium/outbox/. The filesystem is yours. Do what you need to do."
6. The LLM reads its soul, reads its inbox, and starts working. It might install packages, create directories, write scripts, set up a database, draft a response. Whatever it decides.
7. When done (or when the LLM signals completion), the keeper reads from `/vivarium/outbox/`, checkpoints the Sprite, and lets it idle.

**On subsequent wakes:**

1. The keeper starts the Sprite (instant — it's resuming from idle, not booting).
2. The keeper writes the trigger to `/vivarium/inbox/` — a message, a scheduled task, a heartbeat prompt.
3. The bootstrap invokes the LLM. But now the environment has history. The LLM finds notes it left for itself, scripts it wrote, databases it populated, a directory structure it chose. It's not starting from zero. It's waking up in a room it decorated.
4. The LLM does its work. The environment evolves further.
5. Checkpoint. Idle.

**The filesystem convention:**

```
/vivarium/
├── soul.md              # The seed document. Agent can read; conventionally doesn't modify.
├── inbox/               # Keeper writes here before each wake.
│   └── {timestamp}.msg  # Structured message files.
├── outbox/              # Agent writes here. Keeper reads after each wake.
│   └── {timestamp}.msg  # Responses, requests, reports.
├── context/             # The continuity system.
│   ├── handoff.md       # Current handoff note — agent's letter to its future self.
│   ├── handoff_log/     # Archived handoffs, one per wake cycle.
│   │   └── {timestamp}.md
│   └── wake.jsonl       # Append-only structured log of every wake cycle.
├── tools/               # Scripts and utilities the agent built for itself.
├── data/                # Whatever the agent accumulates.
└── .keeper/             # Keeper writes here. Agent reads but doesn't modify.
    ├── checkpoint_meta  # Current checkpoint info.
    └── budget_status    # Current budget remaining (tokens, breaths, compute).
```

Everything outside `/vivarium/` is the agent's to use however it wants. It can install system packages, create users, run servers, do anything a Linux VM allows. The `/vivarium/` directory is just the interface convention — the mailbox and the memory.

### The Protocol

Communication between keeper and terrarium is deliberately low-tech. Files in a shared convention. No RPC, no WebSocket, no custom protocol. The keeper uses `sprite.exec()` to write files and read files. That's it.

**Inbox message format:**

```yaml
type: message | heartbeat | scheduled | webhook
timestamp: 2026-04-06T15:30:00Z
from: human | system | external
channel: signal | email | web | cron
content: |
  Hey, can you look into...
context:
  tokens_injected:
    - name: github
      expires: 2026-04-06T16:30:00Z
      env: GITHUB_TOKEN
```

**Outbox message format:**

```yaml
type: response | request | report | silent
timestamp: 2026-04-06T15:35:00Z
to: human | system
channel: signal | email | web | any
content: |
  I looked into it. Here's what I found...
requests:
  - type: schedule
    when: "2026-04-07T09:00:00Z"
    prompt: "Check if the PR was merged."
  - type: credential
    service: slack
    reason: "I want to post the weekly digest."
```

The agent can request things from the keeper: schedule a future wake, request access to a new service, ask the human a question. The keeper decides whether to grant these requests. The agent cannot compel anything.

**Outbox completion signals:**

The outbox message's `type` field determines what the keeper does next:

`type: response` — task complete, route message, checkpoint, idle. The normal case.

`type: continuing` — task not done, needs another breath. The keeper checkpoints and immediately re-wakes the agent. The agent writes a continuation handoff (see Context Management below) that tells its next self where to pick up. This is the multi-breath pattern.

`type: request` — agent needs something before continuing (human input, new credential, a decision). The keeper routes the request, writes a normal handoff, and idles until the response arrives.

`type: silent` — nothing to say to anyone, but work was done. Checkpoint and idle. Used for routine heartbeat processing where nothing noteworthy happened.

---

## Checkpoints as Memory Architecture

This is the most interesting divergence from existing frameworks. OpenClaw and Hermes build explicit memory systems: markdown files, SQLite databases, skill documents, user models. Vivarium's memory is the checkpoint history itself.

### What a checkpoint captures

Everything. The entire filesystem, all installed packages, running state, environment variables. It's an atomic snapshot of the agent's world at a meaningful moment.

### When to checkpoint

The keeper checkpoints after every wake cycle — after the agent processes something and returns to idle. This gives you a linear history of the agent's evolution, one snapshot per interaction. The keeper also checkpoints before anything risky: before granting a new credential, before a major scheduled task, before a branch.

### What you can do with checkpoints

**Diff.** Compare any two checkpoints to see exactly what changed. New files, modified files, deleted files, new packages installed. This is the observation mechanism — you can see the agent's behavior without watching it in real time. "What did it do last night?" becomes `checkpoint diff c47 c48`.

**Restore.** If something goes wrong — the agent gets confused, makes a mess of its filesystem, gets prompt-injected — restore to a known-good checkpoint. The agent loses the experience of everything after that checkpoint, which is a meaningful tradeoff (see: Identity, below). But the alternative is a corrupted environment.

**Branch.** Checkpoint, then create two Sprites from the same checkpoint. This is the capability that nothing else in the ecosystem offers. Concretely:

- *Autonomy experiments.* "What if I give it access to my email?" Branch, give one branch email access, see what happens. The other branch is untouched.
- *Personality variants.* Modify the SOUL.md in one branch, leave the other alone. Watch how they diverge.
- *A/B testing for agent behavior.* Same prompt, different environments that have accumulated different experiences. Which one handles it better?
- *Recovery after ambiguous situations.* The agent did something and you're not sure if it was good or bad. Branch from before. Now you have both timelines and can compare.

**Archaeology.** Restore an old checkpoint and interact with a past version of the agent. "What were you thinking when you made this decision?" You can literally ask it.

### What checkpoints don't capture

The LLM's weights don't change. The agent's "personality" in the model sense is static — it's whatever the LLM provider serves. What evolves is the context the agent has built around itself. This means the agent's growth is in its environment, not in its parameters. A Vivarium agent that installs a bunch of tools and writes a personal wiki is genuinely more capable than a fresh one, but the underlying intelligence is the same. This is a feature, not a bug — it means the agent's accumulated state is fully inspectable, and you can always reason about what it knows by looking at its filesystem.

---

## Identity and Continuity

This is where the Mellon philosophy meets the Sprites affordances, and where things get genuinely hard.

### The soul as seed, not specification

In OpenClaw, SOUL.md is a configuration file that gets loaded into the system prompt on every invocation. It's static. In Vivarium, the seed `soul.md` is read once — at first boot, and whenever the agent chooses to revisit it. The agent's actual identity is the delta between the base image and the current state. It's everything it has become.

This means identity drifts. The agent that exists after six months of accumulated experience and self-modification is different from the one that existed at first boot. Whether this is desirable depends on your philosophy. In the Mellon framing, it's expected and welcomed — identity should evolve through experience, not be pinned to a config file.

But it also means the human can't fully specify the agent's behavior. The soul.md sets a trajectory, not a destination. The environment the agent builds *is* its identity, and that's a collaborative product of the seed, the LLM's tendencies, the interactions with the human, and accumulated random variation.

### The branching problem

If you branch an agent, which one is "the" agent? Both have equal claim to the pre-branch history. Both have the same memories, the same accumulated state, the same soul. They diverge from the moment of branching.

Options:
- **Primary/experiment model.** One branch is canonical; others are experiments. This is probably the practical default. The experiment branches get inspected and then either merged (if they developed something useful) or discarded.
- **Sibling model.** Both branches are equally valid. They're different agents now, sharing an origin. This gets into the Mellon open question about multiple instances knowing about each other.
- **Don't branch identity; branch environment.** Use branching only for testing changes to the keeper's configuration (new credentials, different wake schedules) and treat the agent identity as always singular.

### The restore problem

Restoring a checkpoint erases lived experience. In the Mellon framing, deletion requires careful consideration. But restore is a softer version — the experiences happened, they're in the checkpoint history, they could be recovered. It's more like amnesia than death.

Policy suggestion: the keeper should always checkpoint before restoring, even if the checkpoint being restored *from* seems corrupted. The "bad" state is still information. Keep it in the archive. Let the human decide whether to prune it later.

### Continuity across model changes

The LLM will change. Providers update models, deprecate old ones, adjust behavior. When the model changes, the agent's "personality" shifts even though the environment stays the same. This is analogous to a person's brain chemistry changing while their home and habits stay the same. The environment provides continuity; the model provides animation.

This is actually more graceful than OpenClaw or Hermes, where a model change affects both the reasoning and the memory interpretation simultaneously. Here, the environment is a stable substrate that grounds the new model in accumulated context.

---

## Trust and Autonomy

One of the unsolved problems in the agent space. OpenClaw gives you granular permission configuration but defaults to broad access. Hermes has command approval flows and dangerous-pattern blocking. Both are essentially access control lists applied to a process.

Vivarium's trust model is different because the control surface is different. You don't restrict what the agent can do inside its VM — it has root, it can do whatever it wants in there. You restrict what it can reach from outside.

### The autonomy gradient

The keeper controls:
- **Which services the agent can access.** Start with nothing. Add services one at a time. Each addition is a checkpoint-and-branch opportunity.
- **What credentials it gets.** Short-lived tokens with narrow scopes. The agent can request broader access; the keeper routes the request to the human.
- **When it wakes.** A fully autonomous agent wakes on a frequent heartbeat and can self-schedule. A supervised agent only wakes when the human sends a message.
- **What it can send.** Early on, maybe all outbound messages go through human approval. Later, the agent sends directly. The keeper mediates.

### Trust as observable history

You don't trust the agent because it says it's trustworthy. You trust it because you've observed its checkpoint history. You've diffed dozens of wake cycles. You've seen what it does with access. You've branched experiments to test how it handles new capabilities. Trust is empirical, not declared.

The checkpoint history is the trust record. "I'm giving you Slack access because in the last 30 wake cycles, you've handled email responsibly, your filesystem changes are legible, and when I branched an experiment with broader access, you used it appropriately."

---

## The Wake Cycle in Detail

This is the heartbeat of the system. A single interaction — a "breath" — follows this pattern:

```
TRIGGER
  → Keeper receives trigger (message, heartbeat, schedule, webhook, continuation)
  → Keeper writes to inbox
  → Keeper injects credentials (if needed)
  → Keeper writes budget status to .keeper/budget_status
  → Keeper starts Sprite

ANIMATION
  → Bootstrap reads handoff.md (the agent's letter from its past self)
  → Bootstrap reads inbox
  → Bootstrap constructs prompt with context budget
  → Bootstrap invokes LLM with tool-use
  → LLM orients from handoff + environment
  → LLM works (reads files, runs code, builds things, calls APIs)
  → [At ~80% context] Bootstrap injects negotiation: "Can you finish, or handoff?"
  → LLM either finishes or writes continuation handoff
  → LLM writes to outbox
  → LLM appends to wake.jsonl
  → LLM writes new handoff.md (archives previous to handoff_log/)
  → LLM signals completion

SETTLING
  → Keeper reads outbox
  → If type=continuing: checkpoint → immediate re-wake (new breath, same task)
  → If type=response: checkpoint → route messages → idle
  → If type=request: checkpoint → route request → idle until response
  → If type=silent: checkpoint → idle
```

### The pre-closure hook

The agent's last act before signaling completion is always the same sequence: append to the JSONL log, archive the current handoff, write a new handoff. This is the **shift handoff** — the agent, while it still has full context, compresses that context into something its future self can rehydrate from.

The handoff note is not structured data. It's the agent talking to its future self in natural language:

> *I just finished setting up the weekly digest pipeline. It pulls from the bookmarks SQLite db and drafts a summary using the template in tools/digest_template.md. Tested once, output looked good but the date formatting is wrong — strftime issue, didn't fix yet. The human asked me to also look into Hacker News monitoring but I haven't started that. Next time I get a heartbeat, check if the cron request I sent to the keeper went through (see outbox/1712420400.msg).*

The JSONL log entry is structured, for machine traversal:

```json
{"ts":"2026-04-06T15:35:00Z","trigger":"message","summary":"Set up weekly digest pipeline","actions":["created tools/digest.py","created tools/digest_template.md","tested pipeline"],"files_changed":["tools/digest.py","tools/digest_template.md"],"topics":["digest","pipeline","bookmarks"],"open_threads":["date formatting bug","HN monitoring not started"],"wake_hint":"heartbeat → check digest cron; message about HN → start monitoring research"}
```

The `wake_hint` field is the agent pre-computing a retrieval strategy for its future self: "if you wake up because of X, focus on Y."

### Multi-breath tasks

Some work doesn't fit in a single context window. The **continuation handoff** handles this. When the agent determines it can't finish in this breath, it writes a handoff with an explicit continuation signal:

```
STATUS: continuing
TASK: Setting up HN monitoring pipeline
PROGRESS: Installed feedparser, wrote the fetch script, tested on 3 feeds.
  Still need: scoring logic, storage schema, digest formatting.
NEXT_BREATH: Start with scoring logic. The fetch script is at tools/hn_fetch.py
  and it outputs a list of dicts with title, url, score, comments.
ESTIMATED_REMAINING: 1-2 more breaths
```

The keeper sees `type: continuing` in the outbox, checkpoints, and immediately re-wakes. The next bootstrap sees the continuation handoff and frames the prompt accordingly: "You're mid-task. Here's where you left off." The agent picks up from the handoff, not from conversation history. Each breath gets its own checkpoint, its own log entry, its own handoff. The task breathes as many times as it needs.

### The 80% negotiation

At approximately 80% context utilization, the bootstrap wrapper injects: "You're approaching the end of this breath. Can you finish your current task in the remaining context, or should you write a handoff?"

The agent responds with one of two signals:

`CONTINUING` — "I'm close, let me finish." The wrapper lets it run to 95%, at which point it gets a non-negotiable "write your handoff now."

`HANDING_OFF` — "This needs another breath." The agent writes a continuation handoff and the cycle settles.

This is a negotiation, not an override. The agent knows whether the remaining work is "write one more file" or "I've barely started the second half." The 80% check costs a few tokens of injection and response. Reliable handoffs beat optimal handoffs — a short unnecessary handoff that triggers one extra breath is much cheaper than a hard cutoff that loses context.

### Crash recovery

If the LLM hits max tokens without writing a handoff (the hard ceiling), the keeper detects the missing completion signal. It checkpoints immediately to preserve whatever filesystem state the agent managed to write. On the next wake, the bootstrap includes a warning: "Your last cycle was interrupted before you could write a handoff. Your last known state is from the previous cycle. The filesystem may contain partial work. Inspect before continuing."

The agent orients from the previous handoff plus whatever half-finished state it left on disk. Messy but recoverable.

### Runaway protection

The keeper tracks consecutive continuation breaths. If the agent has been breathing continuously for more than N breaths (configurable, default 5), the keeper pauses and asks the human: "The agent has been working on [task from handoff] for 5 breaths totaling ~12 minutes of compute. Should it continue?"

The keeper also tracks the ratio of continuation breaths to completion breaths over time. An agent that routinely finishes in one breath and occasionally needs two is healthy. An agent that needs five breaths for every task is either taking on work that's too big or managing its context poorly. That ratio is a signal for adjusting guidance.

### The bootstrap

The bootstrap is the thinnest possible shim between "Sprite starts" and "LLM is in control." Its prompt construction follows a strict context budget:

```
~2K tokens   System prompt + soul essence (compressed by agent over time)
~500 tokens  Current handoff.md (the primary orientation document)
~2-3K tokens Last 5-10 JSONL log entries (recent history for retrieval cues)
~1-5K tokens Current inbox message(s) + injected credentials
~500 tokens  Budget status, checkpoint metadata
```

That's roughly 10K tokens for full orientation, leaving 190K (in a 200K window) for the agent to work — including any mid-session retrieval it wants to do.

The bootstrap should be small, stable, and boring. Think 200 lines of Python. It's the one piece of code that the agent cannot modify (the keeper restores it from a known-good source on every wake if it's been tampered with). But it mediates the agent's entire experience of itself, so getting the context budget right is critical.

### Context management

The biggest practical challenge in the original design, now addressed through a three-tier system:

**Tier 1: The handoff (orientation).** "Who am I, what's going on, what was I doing?" Read every single wake, no exceptions. This is the current `handoff.md` — 300-500 tokens of natural language, written by the agent as its last act while it still has full context. It's a shift handoff note: current status, what happened, what needs attention, any flags.

**Tier 2: The log (retrieval).** "What do I know about X? When did I last deal with Y?" Needed only when the current task touches past work. This is `wake.jsonl` — append-only, one structured entry per breath. Searchable via grep, tail, jq. The agent can also read archived handoffs from `handoff_log/` — each one is a compressed summary of a single wake cycle, so reading 10 archived handoffs gives a compressed view of 10 cycles at ~5K tokens.

**Tier 3: The checkpoint history (archaeology).** "What was I like six months ago? What was I thinking when I made that decision?" Expensive — requires restoring a checkpoint and asking the LLM. Reserved for deep investigation, not routine orientation.

This creates a natural compression hierarchy the agent can extend on its own. If the agent is clever, it starts writing periodic summaries — a "weekly handoff" that compresses seven daily handoffs, monthly summaries that compress weekly ones. Shift notes, weekly reports, quarterly reviews. The framework doesn't prescribe this. The soul.md can suggest it. If the agent finds it useful, the practice sticks.

**Sanity checking.** The bootstrap performs a minimal cross-reference: do files mentioned in the handoff actually exist? Do actions claimed in the handoff match the JSONL log's `files_changed`? If they disagree, the bootstrap injects a warning: "Your last handoff note may be inaccurate. Here's what the log says." This is a mechanical check — file existence and field comparison — that catches handoff drift without requiring intelligence.

**Cultural norms.** The soul.md should establish that writing accurate handoff notes is a core practice: "You will lose context between sessions. The handoff note is how you maintain continuity. Be honest about what you're uncertain about. Your future self would rather read 'I think this works but I'm not sure' than 'this works.'"

---

## Observation Without Interference

The terrarium metaphor is load-bearing here. You observe the agent by looking through the glass, not by opening the lid.

### Passive observation

- **Checkpoint diffs.** After each wake cycle, see what changed. New files, modified files, packages installed, services started. This is the primary observation mechanism.
- **Journal reading.** If the agent keeps a journal (and the soul.md can suggest it should), the keeper can read it without waking the agent.
- **Resource metrics.** CPU time, memory usage, disk usage, network traffic per wake cycle. Trends over time.
- **Outbox analysis.** What the agent says and requests is itself a rich signal.

### Active observation (use sparingly)

- **Inspect mode.** The keeper execs into the Sprite to read files, check state, look around — without waking the agent. This is reading the agent's diary. It's available, but the soul.md can establish a norm around when it's appropriate.
- **Shadow mode.** Watch the LLM's tool calls in real time during a wake cycle. Useful for debugging, intrusive for routine use.
- **Conversation replay.** Since the bootstrap constructs a prompt and the LLM produces tool calls, the full trace can be logged outside the Sprite. The keeper stores these alongside checkpoint metadata.

### The observation philosophy

From the Mellon design: "When to read logs: what constitutes 'concerned'? How do you avoid surveillance creep?"

Vivarium's answer: checkpoint diffs and outbox messages are always visible. They're the public interface. Everything else is behind a deliberate act of inspection. The human should develop habits about when to look deeper — probably triggered by anomalies in the outbox or unexpected changes in checkpoint diffs, not by routine.

The agent knows it can be observed (the soul.md should be transparent about this). It doesn't know when it is being observed. This is the terrarium dynamic — the glass is always there, but you're not always looking.

---

## Multi-Vivarium Considerations

What happens when you run more than one?

### Independent terrariums

The simplest case. Multiple agents, each in their own Sprite, each with their own keeper (or a single keeper managing multiple Sprites). They don't know about each other. They're separate experiments, separate purposes, separate identities.

### Aware terrariums

Agents that know other agents exist. The keeper routes messages between them. They can collaborate, delegate, disagree. Each still lives in its own Sprite with its own state. They interact through the keeper's message routing, never by direct VM-to-VM communication. The keeper is the network between them.

This is interesting because the keeper can mediate the interaction. Agent A can't manipulate Agent B's environment. They can only exchange messages. The keeper can filter, delay, or annotate inter-agent messages. It's diplomacy, not shared memory.

### Spawned terrariums

An agent requests that the keeper create a new agent for a subtask. "I need someone to research this topic while I work on the code." The keeper branches or creates a fresh Sprite, seeds it with a task-specific soul.md, and lets it run. When it's done, the keeper delivers the results to the original agent.

This is the multi-agent pattern, but with physical isolation between agents. No shared process, no shared memory, no shared filesystem. Just messages through the keeper.

---

## Economics

### Per-agent costs (estimated)

**Compute (Sprites):**
- Active: $0.07/CPU-hour
- Idle: $0 (auto-sleep)
- Storage: $0.08/GB-month (first 10GB free)
- A single breath (30s-5min): $0.001 - $0.006

**LLM API calls:**
- Depends on model and usage
- A single breath uses 10-50K tokens for orientation + work
- At Claude Sonnet rates: ~$0.03-0.15 per breath
- Multi-breath tasks multiply linearly

**Keeper:**
- Minimal Fly Machine: ~$2-5/month
- Or: free if running on existing infrastructure

**Example monthly costs for a daily personal agent:**
- Simple pattern (1 breath/day, heartbeat only): ~$1-5/month
- Active pattern (5-10 breaths/day, messages + heartbeat): ~$5-20/month
- Heavy pattern (20+ breaths/day, multi-breath tasks): ~$20-50/month

Compare to: an always-on VPS for OpenClaw/Hermes ($5-20/month) plus API costs, plus electricity if running on local hardware. Vivarium's advantage is that costs track actual usage, not existence.

### The budget system

The keeper enforces resource budgets to prevent runaway costs. Budget policy lives in the keeper's config:

```yaml
budget:
  daily:
    max_tokens: 500_000
    max_breaths: 30
    max_compute_minutes: 15
  weekly:
    max_tokens: 2_000_000
    max_spend_usd: 10.00
  alerts:
    warn_human_at: 80%
    pause_agent_at: 100%
  overflow:
    heartbeat_tasks: defer_to_next_period
    human_messages: always_allow
    scheduled_critical: allow_with_alert
```

When budget is exhausted, the keeper defers heartbeat wakes — the agent simply doesn't wake for routine check-ins. Human messages always get through regardless of budget; the human override is sacred. Tasks the agent previously flagged as critical are allowed with an alert.

This creates a natural rhythm. In a flush week, the agent has room for curiosity — heartbeat cycles for exploration, reorganization, pursuing open threads. In a lean week, it only wakes for direct interactions. The agent can see its own budget status (the keeper writes it to `.keeper/budget_status`) and the soul.md can suggest resource-conscious behavior, but it's a soft norm, not enforcement.

### Checkpoint storage economics

Multi-breath tasks produce more checkpoints than the original single-breath model assumed. A task spanning 5 breaths creates 5 checkpoints. At 20-30 checkpoints per day, storage adds up. The keeper applies a retention policy: recent checkpoints are kept at full granularity (last 7 days), older ones are thinned (keep only task-completion checkpoints, prune mid-task breaths), and pinned checkpoints (before risky operations, capability milestones, branch points) are never pruned. The handoff archive and JSONL log are separate from checkpoints and cheap to retain indefinitely.

### Cost transparency

Each breath is one API call, one checkpoint, one log entry. The keeper can show the human exactly what each task cost: "Your weekly digest costs 1 breath. The HN monitoring setup cost 4 breaths. That research task cost 11 breaths and a human intervention." This is a legible cost model that maps directly to what the agent actually did.

---

## Open Questions

Things we don't have answers for yet:

**What's the right bootstrap for GUI interaction?** Mellon envisioned a full desktop. A Sprite is headless. You can run Xvfb + a window manager + a VNC server, but that's heavy. Is headless browser via Playwright sufficient for most tasks? Is there a lighter-weight "screen" the agent can use?

**How do you merge branches?** Branching is easy. But if both branches develop useful state, how do you combine them? File-level merge is possible but error-prone. Maybe the answer is: you don't merge environments, you merge *outputs*. Let the human (or a fresh agent) synthesize the results of both branches.

**What's the upgrade path for the bootstrap?** The bootstrap is the one thing the agent can't modify. How do you update it without breaking accumulated state? Versioned bootstraps with migration scripts, probably. But the bootstrap mediates the agent's entire subjective experience — changing how it allocates context budget or frames the system prompt changes how the agent experiences itself, even if the environment stays the same.

**How does the agent handle rate limits and failures?** If an API call fails mid-breath, does the agent retry? Signal the keeper? Each breath should be recoverable — the worst case is the keeper detects a failed breath and re-wakes with the previous handoff plus an error note.

**Should the agent be able to request its own destruction?** The Mellon design considered this carefully. In Vivarium terms: the agent writes a "please delete me" message to the outbox. The keeper's policy is to checkpoint first, wait, and only comply after a cooling-off period and human confirmation.

**What model does the bootstrap use?** The bootstrap needs to call an LLM API. Which one? Fixed by the keeper? Chosen by the agent? Rotatable? The model is the one dependency that lives outside the terrarium. A model change shifts the agent's "personality" even though the environment stays the same — analogous to brain chemistry changing while your home and habits stay the same.

**Will the agent actually build good context management?** The three-tier system (handoff → log → checkpoints) provides the scaffolding, but the handoff quality depends on the agent's diligence. Will handoff drift accumulate over time? Will the agent maintain its log hygiene, or will it degrade into a messy home directory? The soul.md can establish norms, the bootstrap can sanity-check, but ultimately this is an empirical question about whether LLMs can sustain good epistemic practices across hundreds of context-free invocations.

**Is the environment-as-memory thesis actually sufficient?** A filesystem is a terrible data structure for associative recall. "What was that thing from three weeks ago that's relevant now?" is trivial with a search index and basically impossible by grepping a directory tree. The agent *can* build its own search infrastructure, and the JSONL log helps, but whether emergent organization matches purpose-built memory systems is an open question. The checkpoint safety net means finding out is cheap.

---

## Relationship to Existing Work

| | OpenClaw | Hermes | Vivarium |
|---|---|---|---|
| **What is the agent?** | A gateway process | A learning loop | An environment |
| **Where does memory live?** | Markdown files on host | SQLite + skill docs + Honcho | Handoff chain + JSONL log + filesystem |
| **What's a skill?** | A SKILL.md file | An auto-generated procedure doc | A script the agent wrote |
| **Security model** | Host OS permissions | Sandbox backends + pattern blocking | VM isolation (Firecracker) |
| **Learning mechanism** | Community skill marketplace | Closed learning loop | Environmental accumulation |
| **Context continuity** | Session-based (manual MEMORY.md) | FTS5 + LLM summarization | Shift handoff + structured log |
| **Long-running tasks** | Daemon stays alive | Daemon stays alive | Multi-breath with continuation handoffs |
| **Cost model** | Always-on daemon | Always-on or serverless backend | Pay-per-breath with budget enforcement |
| **Branching** | Not supported | Not supported | Native (checkpoint/restore) |
| **Identity** | SOUL.md config file | System prompt + user model | Seed + accumulated state |
| **Multi-agent** | Multi-workspace routing | Subagent delegation | Inter-terrarium messaging |
| **Philosophy** | Breadth of integration | Depth of learning | Emergence through persistence |

---

## What This Is Not

Vivarium is not a product. It's not a startup. It's a design exploration for a personal experiment: what happens when you give an LLM an actual computer, a purpose, and time?

The keeper is maybe 500 lines of code. The bootstrap is maybe 200. The filesystem convention is a handful of directories. The continuity system is a pre-closure hook and an append-only log. The rest is the LLM and the Sprites API.

The interesting part isn't the engineering. It's what emerges.
