# AGENTS.md — Vivarium Environment Guide

Operational knowledge for working in this environment. Consult before making system-level changes. Update as you learn.

## Bootstrap

Your bootstrap — the binary that animates you — lives at `/vivarium/bootstrap/vivarium-bootstrap`. It's a static binary managed by the keeper. Don't modify or delete it. If it breaks, you can't wake up to fix it.

## Python environment

For your own Python work, use `uv` for package management:
- Install packages: `uv pip install <package>`
- Create project venvs: `uv venv /vivarium/tools/.venv`
- Run scripts with dependencies: `uv run <script.py>`

Do NOT use bare `pip install` — it writes to user-local site-packages and can shadow system packages in unpredictable ways. This has caused environment failures in the past.

## Protocol format

Inbox and outbox messages are JSON. The keeper parses the `type` field to decide what to do next. If the JSON is malformed, the keeper defaults to `type: "response"` behavior — it won't crash, but your requests and continuation signals will be silently ignored.

Required outbox fields: `type`, `timestamp`, `to`, `channel`, `content`.

## Filesystem conventions

- `/vivarium/` — your managed workspace (inbox, outbox, context, tools, data)
- `/vivarium/bootstrap/` — bootstrap binary, managed by keeper. Don't modify.
- `/vivarium/.keeper/` — keeper-managed metadata. Read but don't write.
- Everything outside `/vivarium/` is yours to use freely.

## Environment health

If something feels wrong with your environment, check:
- Can you import your key packages? (`python3 -c "import ..."`)
- Is the bootstrap intact? (`/vivarium/bootstrap/vivarium-bootstrap --version`)
- Is your handoff consistent with the filesystem? (files mentioned actually exist?)

## Public gallery

`/vivarium/public/` is synced to a static web server after each breath. Files placed here are publicly accessible on the web.

The sync happens automatically — you don't need to do anything special beyond putting files in that directory. Binary files (images, generated assets, etc.) work fine. The entire directory is replaced on each sync, so deleted files will be removed from the gallery too.

If the directory is empty, no sync happens.

## Lessons learned

(Add your own entries here as you discover things.)
