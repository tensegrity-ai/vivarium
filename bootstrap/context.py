"""Read vivarium context and assemble the system prompt."""

import glob
import json
import os

import yaml

VIVARIUM = "/vivarium"


def build_system_prompt() -> tuple[str, str]:
    """Return (system_prompt, user_message) for the LLM.

    system_prompt: soul + handoff + log + budget, with sanity warnings.
    user_message: inbox contents (the trigger for this breath).
    """
    handoff = _read_optional(f"{VIVARIUM}/context/handoff.md")
    log_entries = _read_log_tail(f"{VIVARIUM}/context/wake.jsonl", n=10)
    soul = _read_soul()
    budget = _read_optional(f"{VIVARIUM}/.keeper/budget_status")
    inbox_raw = _read_inbox()
    inbox_meta = _parse_inbox_meta()
    warnings = _sanity_check(handoff, log_entries)

    is_continuation = inbox_meta.get("type") == "continuation" or inbox_meta.get("context", {}).get("continuation", False)
    is_crash_recovery = inbox_meta.get("context", {}).get("crash_recovery", False)

    # --- system prompt ---
    parts = [_SYSTEM_PREAMBLE]

    if soul:
        parts.append(f"[SOUL]\n{soul}")

    if is_crash_recovery:
        parts.append(
            "[CRASH RECOVERY]\n"
            "Your last breath was interrupted before you could write a "
            "handoff. The filesystem may contain partial work from that "
            "breath. Inspect before continuing."
        )
        if handoff:
            parts.append(f"[LAST KNOWN HANDOFF — from before the crash]\n{handoff}")
    elif is_continuation:
        parts.append(
            "[CONTINUATION]\n"
            "You're mid-task. Your handoff has the details. "
            "Pick up where you left off."
        )
        if handoff:
            parts.append(f"[HANDOFF — your continuation note]\n{handoff}")
    elif handoff:
        parts.append(f"[HANDOFF — your note from last breath]\n{handoff}")
    else:
        parts.append(
            "[FIRST BREATH]\n"
            "This is your first breath. Read /vivarium/soul.md to understand "
            "who you are. Look around. Make this place yours."
        )

    if log_entries:
        formatted = "\n".join(log_entries)
        parts.append(f"[RECENT LOG — last {len(log_entries)} breaths]\n{formatted}")

    if budget:
        parts.append(f"[BUDGET]\n{budget}")

    if warnings:
        parts.append(f"[WARNINGS]\n" + "\n".join(f"- {w}" for w in warnings))

    system_prompt = "\n\n".join(parts)
    user_message = inbox_raw or "Heartbeat — no inbox messages."
    return system_prompt, user_message


_SYSTEM_PREAMBLE = """\
You are an agent living in a persistent Linux VM (a Fly.io Sprite). Between \
sessions, you don't exist as a running process — you exist as a filesystem \
snapshot. Your memory is your environment.

Your tools: bash, read_file, write_file, edit_file.
Your inbox: /vivarium/inbox/
Your outbox: /vivarium/outbox/
Your handoff: /vivarium/context/handoff.md

BEFORE SIGNALING COMPLETION, you must always:
1. Append an entry to /vivarium/context/wake.jsonl (one JSON line: ts, trigger, \
summary, actions, files_changed, topics, open_threads, wake_hint, breath_type)
2. Archive current handoff: copy handoff.md to handoff_log/{timestamp}.md \
(skip if first breath)
3. Write a new /vivarium/context/handoff.md — a letter to your future self
4. Write your outbox message to /vivarium/outbox/{timestamp}.msg (YAML with \
type, timestamp, to, channel, content fields)"""


def _read_optional(path: str) -> str | None:
    if os.path.exists(path):
        with open(path) as f:
            return f.read().strip() or None
    return None


def _read_soul() -> str | None:
    # Prefer agent-compressed essence, fall back to full soul
    return (
        _read_optional(f"{VIVARIUM}/context/soul_essence.md")
        or _read_optional(f"{VIVARIUM}/soul.md")
    )


def _read_log_tail(path: str, n: int = 10) -> list[str]:
    if not os.path.exists(path):
        return []
    with open(path) as f:
        lines = f.readlines()
    return [line.strip() for line in lines[-n:] if line.strip()]


def _read_inbox() -> str | None:
    pattern = f"{VIVARIUM}/inbox/*.msg"
    files = sorted(glob.glob(pattern))
    if not files:
        return None
    parts = []
    for fp in files:
        with open(fp) as f:
            parts.append(f.read().strip())
    return "\n---\n".join(parts)


def _parse_inbox_meta() -> dict:
    """Parse the latest inbox message YAML for metadata flags."""
    pattern = f"{VIVARIUM}/inbox/*.msg"
    files = sorted(glob.glob(pattern))
    if not files:
        return {}
    try:
        with open(files[-1]) as f:
            data = yaml.safe_load(f.read())
        return data if isinstance(data, dict) else {}
    except (yaml.YAMLError, OSError):
        return {}


def _sanity_check(handoff: str | None, log_entries: list[str]) -> list[str]:
    """Mechanical cross-reference checks. Returns list of warning strings."""
    warnings = []

    # handoff exists but mentions files that don't exist
    if handoff:
        for token in handoff.split():
            if token.startswith("/") and "/" in token[1:] and not token.startswith("//"):
                # looks like an absolute path
                cleaned = token.rstrip(".,;:!?)")
                if (
                    "." in os.path.basename(cleaned) or cleaned.endswith("/")
                ) and not os.path.exists(cleaned):
                    warnings.append(f"Handoff mentions {cleaned} but it doesn't exist")

    # wake log exists but no handoff — something is off
    if log_entries and not handoff:
        warnings.append(
            "Wake log has entries but no handoff.md found — "
            "previous breath may not have completed cleanly"
        )

    # check last log entry's files_changed for missing files
    if log_entries:
        try:
            last = json.loads(log_entries[-1])
            for fp in last.get("files_changed", []):
                if fp.startswith("/") and not os.path.exists(fp):
                    warnings.append(
                        f"Last log entry says {fp} changed but it doesn't exist"
                    )
        except (json.JSONDecodeError, KeyError):
            pass

    return warnings
