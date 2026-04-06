#!/bin/bash
# PostToolUse hook: syntax-check Python files after Edit/Write

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]] || [[ "$FILE_PATH" != *.py ]]; then
  exit 0
fi

if ! python3 -m py_compile "$FILE_PATH" 2>&1; then
  echo "syntax error in $FILE_PATH"
  exit 2
fi
