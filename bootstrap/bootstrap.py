#!/usr/bin/env python3
"""Vivarium bootstrap — the thinnest shim between Sprite and LLM."""

import os
import sys

import anthropic
import yaml

from context import build_system_prompt
from tools import TOOL_DEFINITIONS, execute_tool

CONFIG_PATH = "/vivarium/.keeper/bootstrap_config.yaml"
DEFAULT_CONFIG = {
    "model": "claude-sonnet-4-20250514",
    "api_key_env": "ANTHROPIC_API_KEY",
    "context_limit": 200_000,
    "max_response_tokens": 16384,
    "tool_timeout_seconds": 300,
}


def load_config() -> dict:
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            return {**DEFAULT_CONFIG, **yaml.safe_load(f)}
    return DEFAULT_CONFIG


def main():
    config = load_config()
    api_key = os.environ.get(config["api_key_env"])
    if not api_key:
        print(f"Error: {config['api_key_env']} not set", file=sys.stderr)
        sys.exit(1)

    client = anthropic.Anthropic(api_key=api_key)
    system_prompt, user_message = build_system_prompt()

    messages = [{"role": "user", "content": user_message}]

    while True:
        response = client.messages.create(
            model=config["model"],
            max_tokens=config["max_response_tokens"],
            system=system_prompt,
            messages=messages,
            tools=TOOL_DEFINITIONS,
        )

        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason == "end_turn":
            break

        # Execute tool calls
        tool_results = []
        for block in response.content:
            if block.type == "tool_use":
                result = execute_tool(
                    block.name, block.input, config["tool_timeout_seconds"]
                )
                tool_results.append(
                    {
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result,
                    }
                )

        if not tool_results:
            break

        messages.append({"role": "user", "content": tool_results})


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Bootstrap error: {e}", file=sys.stderr)
        sys.exit(1)
