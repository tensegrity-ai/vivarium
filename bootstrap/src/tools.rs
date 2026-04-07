//! Four tools for the vivarium agent: bash, read_file, write_file, edit_file.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::Command;
use std::sync::LazyLock;
use std::time::Duration;

use serde_json::Value;

const MAX_OUTPUT: usize = 50_000;

pub static TOOL_DEFINITIONS: LazyLock<Vec<Value>> = LazyLock::new(tool_definitions);

fn tool_definitions() -> Vec<Value> {
    vec![
        serde_json::json!({
            "name": "bash",
            "description": "Execute a shell command. Returns stdout, stderr, and exit code.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The command to execute"},
                },
                "required": ["command"],
            },
        }),
        serde_json::json!({
            "name": "read_file",
            "description": "Read the contents of a file. Optionally specify a line range.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to the file"},
                    "start_line": {"type": "integer", "description": "1-indexed start line (optional)"},
                    "end_line": {"type": "integer", "description": "1-indexed end line, inclusive (optional)"},
                },
                "required": ["path"],
            },
        }),
        serde_json::json!({
            "name": "write_file",
            "description": "Create or overwrite a file with the given content. Creates parent directories if needed.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to the file"},
                    "content": {"type": "string", "description": "File contents to write"},
                },
                "required": ["path", "content"],
            },
        }),
        serde_json::json!({
            "name": "edit_file",
            "description": "Replace a specific string in an existing file. The old_str must appear exactly once.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to the file"},
                    "old_str": {"type": "string", "description": "Exact text to find (must be unique in file)"},
                    "new_str": {"type": "string", "description": "Replacement text"},
                },
                "required": ["path", "old_str", "new_str"],
            },
        }),
    ]
}

pub fn execute_tool(name: &str, input: &Value, timeout_secs: u64) -> String {
    let result = match name {
        "bash" => {
            let command = input
                .get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            bash(command, timeout_secs)
        }
        "read_file" => {
            let path = input.get("path").and_then(|v| v.as_str()).unwrap_or("");
            let start_line = input.get("start_line").and_then(|v| v.as_u64());
            let end_line = input.get("end_line").and_then(|v| v.as_u64());
            read_file(path, start_line, end_line)
        }
        "write_file" => {
            let path = input.get("path").and_then(|v| v.as_str()).unwrap_or("");
            let content = input.get("content").and_then(|v| v.as_str()).unwrap_or("");
            write_file(path, content)
        }
        "edit_file" => {
            let path = input.get("path").and_then(|v| v.as_str()).unwrap_or("");
            let old_str = input.get("old_str").and_then(|v| v.as_str()).unwrap_or("");
            let new_str = input.get("new_str").and_then(|v| v.as_str()).unwrap_or("");
            edit_file(path, old_str, new_str)
        }
        _ => format!("Error: unknown tool '{name}'"),
    };
    result
}

fn truncate(s: &str) -> String {
    if s.len() <= MAX_OUTPUT {
        s.to_string()
    } else {
        format!("{}\n[truncated]", &s[..MAX_OUTPUT])
    }
}

fn bash(command: &str, timeout_secs: u64) -> String {
    let mut child = match Command::new("sh")
        .arg("-c")
        .arg(command)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return format!("Error: failed to spawn shell: {e}"),
    };

    // Read stdout/stderr before wait to avoid deadlock on full pipe buffers.
    // Take ownership of the handles so the child can be waited on.
    let stdout_handle = child.stdout.take();
    let stderr_handle = child.stderr.take();

    let stdout_thread = std::thread::spawn(move || {
        let mut buf = String::new();
        if let Some(mut r) = stdout_handle {
            let _ = std::io::Read::read_to_string(&mut r, &mut buf);
        }
        buf
    });
    let stderr_thread = std::thread::spawn(move || {
        let mut buf = String::new();
        if let Some(mut r) = stderr_handle {
            let _ = std::io::Read::read_to_string(&mut r, &mut buf);
        }
        buf
    });

    // Wait with timeout using a separate thread
    let pid = child.id();
    let timeout = Duration::from_secs(timeout_secs);
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let status = child.wait();
        let _ = tx.send(status);
    });

    match rx.recv_timeout(timeout) {
        Ok(Ok(status)) => {
            let stdout = stdout_thread.join().unwrap_or_default();
            let stderr = stderr_thread.join().unwrap_or_default();
            let mut parts = Vec::new();
            if !stdout.is_empty() {
                parts.push(truncate(&stdout));
            }
            if !stderr.is_empty() {
                parts.push(format!("[stderr]\n{}", truncate(&stderr)));
            }
            if !status.success() {
                parts.push(format!(
                    "[exit code: {}]",
                    status.code().unwrap_or(-1)
                ));
            }
            if parts.is_empty() {
                "(no output)".to_string()
            } else {
                parts.join("\n")
            }
        }
        Ok(Err(e)) => format!("Error: failed to wait on process: {e}"),
        Err(_) => {
            // Timeout — kill the process via kill command (portable across unix)
            let _ = Command::new("kill").arg("-9").arg(pid.to_string()).status();
            format!("Error: command timed out after {timeout_secs}s")
        }
    }
}

fn read_file(path: &str, start_line: Option<u64>, end_line: Option<u64>) -> String {
    if !Path::new(path).exists() {
        return format!("Error: file not found: {path}");
    }
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => return format!("Error: {e}"),
    };

    let lines: Vec<&str> = content.lines().collect();
    let total = lines.len();

    let output = if start_line.is_some() || end_line.is_some() {
        let s = start_line.unwrap_or(1).saturating_sub(1) as usize;
        let e = end_line.unwrap_or(total as u64) as usize;
        let selected = &lines[s..e.min(total)];
        selected.join("\n")
    } else {
        lines.join("\n")
    };

    let output = truncate(&output);
    format!("{output}\n[{total} lines total]")
}

fn write_file(path: &str, content: &str) -> String {
    let created = !Path::new(path).exists();

    if let Some(parent) = Path::new(path).parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            return format!("Error: {e}");
        }
    }

    match fs::File::create(path).and_then(|mut f| f.write_all(content.as_bytes())) {
        Ok(()) => {
            let action = if created { "created" } else { "overwritten" };
            format!("Wrote {} bytes ({action})", content.len())
        }
        Err(e) => format!("Error: {e}"),
    }
}

fn edit_file(path: &str, old_str: &str, new_str: &str) -> String {
    if !Path::new(path).exists() {
        return format!("Error: file not found: {path}");
    }
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => return format!("Error: {e}"),
    };

    let count = content.matches(old_str).count();
    if count == 0 {
        return "Error: old_str not found in file".to_string();
    }
    if count > 1 {
        return format!("Error: old_str appears {count} times (must be unique)");
    }

    let new_content = content.replacen(old_str, new_str, 1);
    match fs::write(path, new_content) {
        Ok(()) => "OK".to_string(),
        Err(e) => format!("Error: {e}"),
    }
}
