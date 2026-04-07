#!/bin/bash
# PostToolUse hook: compile-check Elixir files after Edit/Write

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]] || [[ "$FILE_PATH" != *.ex && "$FILE_PATH" != *.exs ]]; then
  exit 0
fi

# Find mix project root
dir=$(dirname "$FILE_PATH")
mix_root=""
while [ "$dir" != "/" ]; do
  if [ -f "$dir/mix.exs" ]; then
    mix_root="$dir"
    break
  fi
  dir=$(dirname "$dir")
done

if [ -z "$mix_root" ]; then
  exit 0
fi

cd "$mix_root"
output=$(mix compile --warnings-as-errors 2>&1)
if [ $? -ne 0 ]; then
  echo "$output"
  exit 2
fi
