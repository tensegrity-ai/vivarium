//! Read vivarium context and assemble the system prompt.

use std::fs;
use std::path::Path;

const VIVARIUM: &str = "/vivarium";

/// Returns (system_blocks, user_message).
///
/// system_blocks: Vec of JSON objects with type/text fields (supports cache_control).
/// user_message: inbox contents as a plain string.
pub fn build_system_prompt() -> (Vec<serde_json::Value>, String) {
    let handoff = read_optional(&format!("{VIVARIUM}/context/handoff.md"));
    let log_entries = read_log_tail(&format!("{VIVARIUM}/context/wake.jsonl"), 10);
    let soul = read_soul();
    let budget = read_optional(&format!("{VIVARIUM}/.keeper/budget_status.json"));
    let inbox_raw = read_inbox();
    let inbox_meta = parse_inbox_meta();
    let warnings = sanity_check(handoff.as_deref(), &log_entries);

    let is_continuation = inbox_meta
        .get("type")
        .and_then(|v| v.as_str())
        .is_some_and(|t| t == "continuation")
        || inbox_meta
            .pointer("/context/continuation")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
    let is_crash_recovery = inbox_meta
        .pointer("/context/crash_recovery")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let is_heartbeat = inbox_meta
        .get("type")
        .and_then(|v| v.as_str())
        .is_some_and(|t| t == "heartbeat");

    // --- assemble system prompt parts ---
    let mut parts: Vec<String> = vec![SYSTEM_PREAMBLE.to_string()];

    if let Some(ref soul) = soul {
        parts.push(format!("[SOUL]\n{soul}"));
    }

    if is_heartbeat {
        parts.push(
            "[HEARTBEAT]\n\
             No one is asking you for anything right now. You have a full breath.\n\
             Check on anything that needs checking. Then do what interests you."
                .to_string(),
        );
        if let Some(ref h) = handoff {
            parts.push(format!("[HANDOFF — your note from last breath]\n{h}"));
        }
    } else if is_crash_recovery {
        parts.push(
            "[CRASH RECOVERY]\n\
             Your last breath was interrupted before you could write a \
             handoff. The filesystem may contain partial work from that \
             breath. Inspect before continuing."
                .to_string(),
        );
        if let Some(ref h) = handoff {
            parts.push(format!(
                "[LAST KNOWN HANDOFF — from before the crash]\n{h}"
            ));
        }
    } else if is_continuation {
        parts.push(
            "[CONTINUATION]\n\
             You're mid-task. Your handoff has the details. \
             Pick up where you left off."
                .to_string(),
        );
        if let Some(ref h) = handoff {
            parts.push(format!("[HANDOFF — your continuation note]\n{h}"));
        }
    } else if let Some(ref h) = handoff {
        parts.push(format!("[HANDOFF — your note from last breath]\n{h}"));
    } else {
        parts.push(
            "[FIRST BREATH]\n\
             This is your first breath. Read /vivarium/soul.md to understand \
             who you are. Look around. Make this place yours."
                .to_string(),
        );
    }

    if !log_entries.is_empty() {
        let formatted = log_entries.join("\n");
        parts.push(format!(
            "[RECENT LOG — last {} breaths]\n{formatted}",
            log_entries.len()
        ));
    }

    if let Some(ref b) = budget {
        parts.push(format!("[BUDGET]\n{b}"));
    }

    if !warnings.is_empty() {
        let formatted = warnings.iter().map(|w| format!("- {w}")).collect::<Vec<_>>().join("\n");
        parts.push(format!("[WARNINGS]\n{formatted}"));
    }

    // Single system block with cache breakpoint.
    // The entire system prompt is stable within a breath — one block, one cache marker.
    let system_text = parts.join("\n\n");
    let system_blocks: Vec<serde_json::Value> = vec![serde_json::json!({
        "type": "text",
        "text": system_text,
        "cache_control": {"type": "ephemeral"},
    })];

    let user_message = inbox_raw.unwrap_or_else(|| "Heartbeat — no inbox messages.".to_string());
    (system_blocks, user_message)
}

const SYSTEM_PREAMBLE: &str = "\
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
4. Write your outbox message to /vivarium/outbox/{timestamp}.msg as a JSON object \
with fields: type, timestamp, to, channel, content (and optionally requests)

Outbox type values:
- \"response\" — task complete, message for the human
- \"continuing\" — task not done, you need another breath (keeper will re-wake you)
- \"request\" — you need something from the human before continuing
- \"silent\" — routine work done, nothing to report";

fn read_optional(path: &str) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .and_then(|s| {
            let trimmed = s.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        })
}

fn read_soul() -> Option<String> {
    read_optional(&format!("{VIVARIUM}/context/soul_essence.md"))
        .or_else(|| read_optional(&format!("{VIVARIUM}/soul.md")))
}

fn read_log_tail(path: &str, n: usize) -> Vec<String> {
    match fs::read_to_string(path) {
        Ok(data) => {
            let lines: Vec<String> = data
                .lines()
                .filter(|l| !l.trim().is_empty())
                .map(|l| l.to_string())
                .collect();
            let start = lines.len().saturating_sub(n);
            lines[start..].to_vec()
        }
        Err(_) => Vec::new(),
    }
}

fn read_inbox() -> Option<String> {
    let inbox_dir = format!("{VIVARIUM}/inbox");
    let mut files: Vec<_> = match fs::read_dir(&inbox_dir) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.path()
                    .extension()
                    .is_some_and(|ext| ext == "msg")
            })
            .map(|e| e.path())
            .collect(),
        Err(_) => return None,
    };

    if files.is_empty() {
        return None;
    }

    files.sort();
    let parts: Vec<String> = files
        .iter()
        .filter_map(|p| fs::read_to_string(p).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n---\n"))
    }
}

fn parse_inbox_meta() -> serde_json::Value {
    let inbox_dir = format!("{VIVARIUM}/inbox");
    let mut files: Vec<_> = match fs::read_dir(&inbox_dir) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.path()
                    .extension()
                    .is_some_and(|ext| ext == "msg")
            })
            .map(|e| e.path())
            .collect(),
        Err(_) => return serde_json::Value::Object(Default::default()),
    };

    if files.is_empty() {
        return serde_json::Value::Object(Default::default());
    }

    files.sort();
    let last = files.last().unwrap();

    match fs::read_to_string(last) {
        Ok(data) => serde_json::from_str(&data).unwrap_or(serde_json::Value::Object(Default::default())),
        Err(_) => serde_json::Value::Object(Default::default()),
    }
}

fn sanity_check(handoff: Option<&str>, log_entries: &[String]) -> Vec<String> {
    let mut warnings = Vec::new();

    // Handoff mentions files that don't exist
    if let Some(handoff) = handoff {
        for token in handoff.split_whitespace() {
            if token.starts_with('/') && token[1..].contains('/') && !token.starts_with("//") {
                let cleaned = token.trim_end_matches(|c| ".,;:!?)".contains(c));
                let basename = Path::new(cleaned)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("");
                if (basename.contains('.') || cleaned.ends_with('/'))
                    && !Path::new(cleaned).exists()
                {
                    warnings.push(format!("Handoff mentions {cleaned} but it doesn't exist"));
                }
            }
        }
    }

    // Wake log exists but no handoff
    if !log_entries.is_empty() && handoff.is_none() {
        warnings.push(
            "Wake log has entries but no handoff.md found — \
             previous breath may not have completed cleanly"
                .to_string(),
        );
    }

    // Check last log entry's files_changed for missing files
    if let Some(last_entry) = log_entries.last() {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(last_entry) {
            if let Some(files) = parsed.get("files_changed").and_then(|v| v.as_array()) {
                for fp in files {
                    if let Some(path) = fp.as_str() {
                        if path.starts_with('/') && !Path::new(path).exists() {
                            warnings.push(format!(
                                "Last log entry says {path} changed but it doesn't exist"
                            ));
                        }
                    }
                }
            }
        }
    }

    warnings
}
