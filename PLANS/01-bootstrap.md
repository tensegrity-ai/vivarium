# Bootstrap Implementation Guide

The bootstrap is ~200 lines of Python that runs inside the Sprite. It reads the agent's context, calls the LLM with tool-use, runs the agent loop, and exits. It is the thinnest possible shim between "Sprite starts" and "LLM is in control."

## Entry Point

The keeper execs `python3 /vivarium/bootstrap/bootstrap.py` inside the Sprite. The bootstrap runs to completion and exits. Exit code 0 = normal completion. Exit code 1 = error (keeper should log and checkpoint anyway).

## Startup Sequence

```
1. Read /vivarium/context/handoff.md (primary orientation)
2. Read last 5-10 lines of /vivarium/context/wake.jsonl (recent history)
3. Read /vivarium/inbox/*.msg (current trigger, sorted by timestamp)
4. Read /vivarium/.keeper/budget_status (optional, if present)
5. Read /vivarium/soul.md (or a compressed version the agent prepared)
6. Construct system prompt from these components
7. Enter agent loop
```

## System Prompt Construction

The system prompt has a fixed structure with a context budget:

```
[SYSTEM — ~2K tokens]
You are an agent living in a persistent Linux VM. Between sessions, you
don't exist as a running process — you exist as a filesystem snapshot. 
Your memory is your environment.

Your tools: bash, read_file, write_file, edit_file. 
Your inbox: /vivarium/inbox/
Your outbox: /vivarium/outbox/
Your handoff: /vivarium/context/handoff.md

BEFORE SIGNALING COMPLETION, you must always:
1. Append an entry to /vivarium/context/wake.jsonl
2. Archive current handoff: mv handoff.md → handoff_log/{timestamp}.md
3. Write a new handoff.md — a letter to your future self
4. Write your outbox message to /vivarium/outbox/{timestamp}.msg

[SOUL ESSENCE — ~500 tokens]
{compressed soul — first boot reads full soul.md, later the agent
 may prepare a compressed version at /vivarium/context/soul_essence.md}

[HANDOFF — ~500 tokens]
{contents of /vivarium/context/handoff.md, verbatim}

[RECENT LOG — ~2K tokens]  
{last 5-10 entries from wake.jsonl, formatted}

[BUDGET — ~200 tokens]
{contents of .keeper/budget_status if present}

[USER MESSAGE]
{contents of inbox message(s)}
```

Total orientation: ~5-6K tokens, leaving ~195K for work in a 200K window.

If handoff.md doesn't exist (first boot), the system prompt says: "This is your first breath. Read /vivarium/soul.md to understand who you are. Make this place yours."

## Sanity Checking

Before constructing the prompt, the bootstrap performs a minimal cross-reference:

- If handoff.md mentions specific files, check they exist. Inject a warning if they don't.
- If the most recent wake.jsonl entry's `files_changed` includes files that are missing, note the discrepancy.
- If handoff.md doesn't exist but wake.jsonl has entries, something is wrong — flag it.

These are file-existence checks, not intelligence. 10 lines of code.

## Tool Definitions

Four tools, matching the LLM provider's tool-use schema:

### bash
```
name: bash
description: Execute a shell command. Returns stdout, stderr, and exit code.
parameters:
  command: string (required) — the command to execute
returns:
  stdout: string
  stderr: string  
  exit_code: integer
```

Implementation: `subprocess.run(command, shell=True, capture_output=True, timeout=300)`. The 5-minute timeout prevents runaway processes. The agent can launch background processes by backgrounding in the command itself, but the tool call returns immediately.

### read_file
```
name: read_file
description: Read the contents of a file. Optionally specify a line range.
parameters:
  path: string (required) — absolute path
  start_line: integer (optional) — 1-indexed
  end_line: integer (optional) — inclusive
returns:
  content: string
  total_lines: integer
```

Implementation: read file, optionally slice lines, return content. If file doesn't exist, return an error message (don't raise — let the LLM handle it). Truncate at ~50K characters with a note if the file is enormous.

### write_file
```
name: write_file
description: Create or overwrite a file with the given content.
parameters:
  path: string (required) — absolute path
  content: string (required) — file contents
returns:
  bytes_written: integer
  created: boolean (true if new file, false if overwrite)
```

Implementation: create parent directories if needed (`os.makedirs`), write content, return stats. 

### edit_file
```  
name: edit_file
description: Replace a specific string in an existing file. The old_str must 
  appear exactly once in the file.
parameters:
  path: string (required) — absolute path
  old_str: string (required) — exact text to find (must be unique in file)
  new_str: string (required) — replacement text
returns:
  success: boolean
  error: string (if old_str not found or not unique)
```

Implementation: read file, verify old_str appears exactly once, replace, write back. This is the same semantics as Claude Code's edit tool — proven to work well with LLMs.

## Agent Loop

```python
messages = [system_prompt]

while True:
    response = client.messages.create(
        model=config.model,
        max_tokens=config.max_response_tokens,
        system=system_prompt,
        messages=messages,
        tools=tool_definitions,
    )
    
    # Accumulate response into messages
    messages.append({"role": "assistant", "content": response.content})
    
    # If no tool use, agent is done
    if response.stop_reason == "end_turn":
        break
    
    # Execute tool calls, feed results back
    tool_results = []
    for block in response.content:
        if block.type == "tool_use":
            result = execute_tool(block.name, block.input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": result
            })
    messages.append({"role": "user", "content": tool_results})
    
    # Context budget check
    approx_tokens = estimate_tokens(messages)
    if approx_tokens > config.context_limit * 0.95:
        # Hard cutoff — inject and break after one more response
        messages.append(hard_cutoff_message())
        # Let agent write handoff then break on next iteration
    elif approx_tokens > config.context_limit * 0.80:
        # Negotiation — inject and let agent decide
        messages.append(negotiation_message())
```

Token estimation doesn't need to be exact. A rough heuristic (chars / 3.5) is sufficient for the 80% and 95% thresholds.

## The 80% Negotiation (Sprint 1)

Injected as a user message:

```
[SYSTEM] You're approaching the end of this breath (~80% context used). 
Can you complete your current task in the remaining context, or should 
you write a handoff for the next breath?

Respond with CONTINUING if you can finish, or HANDING_OFF if you need 
another breath. If handing off, write your continuation handoff now.
```

The 95% hard cutoff:

```
[SYSTEM] Context limit reached. Write your handoff and outbox now. 
This breath is ending.
```

These are Sprint 1 features. Sprint 0 just runs until the agent stops making tool calls.

## Configuration

The bootstrap reads config from `/vivarium/.keeper/bootstrap_config.yaml`:

```yaml
provider: anthropic
model: claude-sonnet-4-20250514
api_key_env: ANTHROPIC_API_KEY  # env var name, injected by keeper
context_limit: 200000
max_response_tokens: 16384
tool_timeout_seconds: 300
```

The keeper writes this file as part of the seeding process. The bootstrap reads it at startup.

## Error Handling

- LLM API errors: retry once with backoff. If still failing, write error to outbox and exit 1.
- Tool execution errors: return error string to the LLM (don't crash). Let the agent handle it.
- File I/O errors: return error string to the LLM.
- Bootstrap crash: keeper detects non-zero exit or timeout, checkpoints whatever state exists, logs the error. Next wake includes a crash recovery note.

## Dependencies

```
anthropic>=0.40.0   # or whatever current version
pyyaml>=6.0
```

That's it. No frameworks, no litellm (Sprint 0), no extra tools. Two dependencies.
