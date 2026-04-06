"""Four tools for the vivarium agent: bash, read_file, write_file, edit_file."""

import os
import subprocess

TOOL_DEFINITIONS = [
    {
        "name": "bash",
        "description": "Execute a shell command. Returns stdout, stderr, and exit code.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "The command to execute"},
            },
            "required": ["command"],
        },
    },
    {
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
    },
    {
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
    },
    {
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
    },
]

MAX_OUTPUT = 50_000  # chars


def execute_tool(name: str, input: dict, timeout: int = 300) -> str:
    """Dispatch a tool call. Returns a string result for the LLM."""
    try:
        if name == "bash":
            return _bash(input["command"], timeout)
        elif name == "read_file":
            return _read_file(input["path"], input.get("start_line"), input.get("end_line"))
        elif name == "write_file":
            return _write_file(input["path"], input["content"])
        elif name == "edit_file":
            return _edit_file(input["path"], input["old_str"], input["new_str"])
        else:
            return f"Error: unknown tool '{name}'"
    except Exception as e:
        return f"Error: {e}"


def _bash(command: str, timeout: int) -> str:
    try:
        r = subprocess.run(
            command, shell=True, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return f"Error: command timed out after {timeout}s"
    parts = []
    if r.stdout:
        out = r.stdout if len(r.stdout) <= MAX_OUTPUT else r.stdout[:MAX_OUTPUT] + "\n[truncated]"
        parts.append(out)
    if r.stderr:
        err = r.stderr if len(r.stderr) <= MAX_OUTPUT else r.stderr[:MAX_OUTPUT] + "\n[truncated]"
        parts.append(f"[stderr]\n{err}")
    if r.returncode != 0:
        parts.append(f"[exit code: {r.returncode}]")
    return "\n".join(parts) if parts else "(no output)"


def _read_file(path: str, start_line: int | None, end_line: int | None) -> str:
    if not os.path.exists(path):
        return f"Error: file not found: {path}"
    with open(path, "r") as f:
        lines = f.readlines()
    total = len(lines)
    if start_line or end_line:
        s = (start_line or 1) - 1
        e = end_line or total
        lines = lines[s:e]
    content = "".join(lines)
    if len(content) > MAX_OUTPUT:
        content = content[:MAX_OUTPUT] + "\n[truncated]"
    return f"{content}\n[{total} lines total]"


def _write_file(path: str, content: str) -> str:
    created = not os.path.exists(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        n = f.write(content)
    return f"Wrote {n} bytes ({'created' if created else 'overwritten'})"


def _edit_file(path: str, old_str: str, new_str: str) -> str:
    if not os.path.exists(path):
        return f"Error: file not found: {path}"
    with open(path, "r") as f:
        content = f.read()
    count = content.count(old_str)
    if count == 0:
        return "Error: old_str not found in file"
    if count > 1:
        return f"Error: old_str appears {count} times (must be unique)"
    with open(path, "w") as f:
        f.write(content.replace(old_str, new_str, 1))
    return "OK"
