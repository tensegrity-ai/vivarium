# Protocol Specification

The keeper and terrarium communicate exclusively through files in the `/vivarium/` directory, written and read via Sprites API `exec()`. No RPC, no WebSocket, no shared state. This document specifies every file format.

## Directory Structure

```
/vivarium/
├── soul.md                     # Seed document (keeper writes once at creation)
├── inbox/                      # Keeper writes before each wake
│   └── {unix_timestamp}.msg    # YAML message file
├── outbox/                     # Agent writes during breath
│   └── {unix_timestamp}.msg    # YAML message file
├── context/                    # Continuity system
│   ├── handoff.md              # Current handoff (agent writes at end of each breath)
│   ├── handoff_log/            # Archived handoffs
│   │   └── {unix_timestamp}.md
│   ├── wake.jsonl              # Append-only structured log
│   └── soul_essence.md         # Optional compressed soul (agent writes if it wants)
├── tools/                      # Agent-created scripts and utilities
├── data/                       # Agent-created data stores
├── .keeper/                    # Keeper-managed metadata (agent reads, doesn't write)
│   ├── bootstrap_config.yaml   # Bootstrap configuration
│   └── budget_status           # Current budget remaining
└── bootstrap/                  # Bootstrap code (keeper writes, restores on each wake)
    ├── bootstrap.py
    ├── tools.py
    ├── context.py
    └── requirements.txt
```

## Inbox Message Format

Written by the keeper to `/vivarium/inbox/{unix_timestamp}.msg` before each wake. YAML.

```yaml
type: message          # message | heartbeat | scheduled | webhook | continuation
timestamp: "2026-04-06T15:30:00Z"
from: human            # human | system | external
channel: signal        # signal | email | web | cli | cron | internal
content: |
  Hey, can you look into the weekly digest setup?
context:
  tokens_injected:     # Optional — only if credentials were injected
    - name: github
      expires: "2026-04-06T16:30:00Z"
      env: GITHUB_TOKEN
  continuation: false  # true if this is a re-wake after a continuation handoff
  crash_recovery: false # true if previous breath crashed without writing handoff
```

For continuation re-wakes, the keeper writes:
```yaml
type: continuation
timestamp: "2026-04-06T15:36:00Z"
from: system
channel: internal
content: "Continuation — pick up from your handoff."
context:
  continuation: true
```

## Outbox Message Format

Written by the agent to `/vivarium/outbox/{unix_timestamp}.msg` during breath. YAML.

```yaml
type: response         # response | continuing | request | silent
timestamp: "2026-04-06T15:35:00Z"
to: human              # human | system
channel: signal        # signal | email | web | any
content: |
  I set up the weekly digest pipeline. It pulls from the bookmarks
  database and drafts a summary. There's a date formatting bug I
  haven't fixed yet. I'll get to it next time.
requests:              # Optional — things the agent wants from the keeper
  - type: schedule
    when: "2026-04-07T09:00:00Z"
    prompt: "Check if the digest cron is working."
  - type: credential
    service: slack
    reason: "I want to post the weekly digest to #updates."
```

For continuation:
```yaml
type: continuing
timestamp: "2026-04-06T15:40:00Z"
to: system
channel: internal
content: "Mid-task, need another breath."
```

For requests that need human input:
```yaml
type: request
timestamp: "2026-04-06T15:35:00Z"
to: human
channel: signal
content: |
  I'm setting up HN monitoring but I'm not sure what your threshold
  for 'interesting' is. Everything over 100 points? AI-related only?
requests:
  - type: human_input
    context: "HN monitoring threshold"
```

## Handoff Format

Written by the agent to `/vivarium/context/handoff.md` at the end of every breath. Archived to `handoff_log/{unix_timestamp}.md` before overwriting.

Free-form markdown. No schema enforced. The soul.md establishes norms for what makes a good handoff. Typical structure:

```markdown
# Handoff — 2026-04-06T15:35:00Z

## Status
Set up the weekly digest pipeline. Partially working.

## What I did
- Created tools/digest.py — pulls from data/bookmarks.db, formats with tools/digest_template.md
- Tested once, output looks good except date formatting (strftime format string wrong)
- Sent a schedule request to keeper for Monday 9am digest check

## Open threads
- Date formatting bug in digest — the %B format gives full month name, I want abbreviated
- Human asked about HN monitoring — haven't started yet

## Next breath
If heartbeat: check if the cron schedule request went through. Fix the date bug.
If message about HN: start research on feed parsing options.

## Environment notes
- Installed feedparser, requests, jinja2 (these persist)
- bookmarks.db has 347 entries as of now
```

For continuation handoffs (mid-task):
```markdown
# Continuation Handoff — 2026-04-06T15:40:00Z

## Status: CONTINUING
Setting up HN monitoring pipeline. Need more breaths.

## Progress
- Installed feedparser
- Created tools/hn_fetch.py — fetches top stories, returns list of dicts
- Tested on 3 feeds, working

## Still need
- Scoring logic (keyword + points threshold)
- Storage schema (probably SQLite)
- Digest formatting

## Next breath
Start with scoring logic. The fetch script outputs:
  [{"title": "...", "url": "...", "score": 142, "comments": 89}, ...]
I was leaning toward a simple keyword match + minimum score threshold.

## Estimated remaining: 1-2 more breaths
```

## Wake Log Format (JSONL)

Appended to `/vivarium/context/wake.jsonl` at the end of every breath. One JSON object per line.

```json
{"ts":"2026-04-06T15:35:00Z","trigger":"message","from":"human","summary":"Set up weekly digest pipeline","actions":["created tools/digest.py","created tools/digest_template.md","tested pipeline on sample data","sent cron schedule request"],"files_changed":["tools/digest.py","tools/digest_template.md","data/bookmarks.db"],"topics":["digest","pipeline","bookmarks"],"open_threads":["date formatting bug","HN monitoring not started"],"wake_hint":"heartbeat → check digest cron; message about HN → start monitoring research","breath_type":"complete"}
```

Fields:
- `ts` — ISO 8601 UTC timestamp
- `trigger` — what caused this wake (message, heartbeat, scheduled, webhook, continuation)
- `from` — who triggered it (human, system, external)
- `summary` — one-line description of what happened this breath
- `actions` — list of notable things done
- `files_changed` — list of files created or modified
- `topics` — keywords for future retrieval
- `open_threads` — unfinished work
- `wake_hint` — pre-computed context retrieval strategy for future self
- `breath_type` — "complete" | "continuing" | "interrupted"

## Bootstrap Config Format

Written by the keeper to `/vivarium/.keeper/bootstrap_config.yaml` during seeding.

```yaml
provider: anthropic
model: claude-sonnet-4-20250514
api_key_env: ANTHROPIC_API_KEY
context_limit: 200000
max_response_tokens: 16384
tool_timeout_seconds: 300
```

## Budget Status Format

Written by the keeper to `/vivarium/.keeper/budget_status` before each wake.

```yaml
period: daily
period_start: "2026-04-06T00:00:00Z"
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

## Soul Document Format

Written by the keeper to `/vivarium/soul.md` during seeding. Free-form markdown. A default seed is provided in `seed/soul.md`. The human customizes it.

The soul establishes:
- Who the agent is (name, purpose, personality)
- The human's preferences and expectations
- Core practices (handoff writing, log maintenance, outbox norms)
- Boundaries (what it should and shouldn't do)
- Transparency norms (the agent knows it can be observed)

## Timestamps

All timestamps in UTC, ISO 8601 format: `2026-04-06T15:35:00Z`.
Unix timestamps for filenames: `1712420100.msg`.
This avoids timezone ambiguity and sorts lexicographically.

## File Ownership

| Path | Written by | Read by |
|------|-----------|---------|
| soul.md | Keeper (once) | Agent |
| inbox/*.msg | Keeper | Agent (bootstrap) |
| outbox/*.msg | Agent | Keeper |
| context/handoff.md | Agent | Agent (bootstrap) |
| context/handoff_log/*.md | Agent | Agent (optional) |
| context/wake.jsonl | Agent | Agent (bootstrap), Keeper (observation) |
| .keeper/* | Keeper | Agent (bootstrap) |
| bootstrap/* | Keeper (restores each wake) | Bootstrap |
| tools/* | Agent | Agent |
| data/* | Agent | Agent |
