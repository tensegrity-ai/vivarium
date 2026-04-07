mod api;
mod context;
mod tools;

use std::fs;
use std::process;

use api::{ApiClient, ContentBlock, Request, StopReason};
use context::build_system_prompt;
use tools::{execute_tool, TOOL_DEFINITIONS};

const CONFIG_PATH: &str = "/vivarium/.keeper/bootstrap_config.json";
const USAGE_PATH: &str = "/vivarium/.keeper/breath_usage.json";

#[derive(serde::Deserialize)]
struct Config {
    #[serde(default = "default_model")]
    model: String,
    #[serde(default = "default_api_key_env")]
    api_key_env: String,
    #[serde(default = "default_context_limit")]
    context_limit: u64,
    #[serde(default = "default_max_response_tokens")]
    max_response_tokens: u64,
    #[serde(default = "default_tool_timeout")]
    tool_timeout_seconds: u64,
}

fn default_model() -> String {
    "claude-sonnet-4-20250514".into()
}
fn default_api_key_env() -> String {
    "ANTHROPIC_API_KEY".into()
}
fn default_context_limit() -> u64 {
    200_000
}
fn default_max_response_tokens() -> u64 {
    16384
}
fn default_tool_timeout() -> u64 {
    300
}

impl Default for Config {
    fn default() -> Self {
        Self {
            model: default_model(),
            api_key_env: default_api_key_env(),
            context_limit: default_context_limit(),
            max_response_tokens: default_max_response_tokens(),
            tool_timeout_seconds: default_tool_timeout(),
        }
    }
}

fn load_config() -> Config {
    match fs::read_to_string(CONFIG_PATH) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Config::default(),
    }
}

fn write_usage(api_calls: u32, last_input: u64, total_output: u64) {
    let usage = serde_json::json!({
        "api_calls": api_calls,
        "input_tokens": last_input,
        "output_tokens": total_output,
        "total_tokens": last_input + total_output,
    });
    let _ = fs::write(USAGE_PATH, serde_json::to_string_pretty(&usage).unwrap_or_default());
}

fn main() {
    if let Err(e) = run() {
        eprintln!("Bootstrap error: {e}");
        process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = load_config();
    let api_key = std::env::var(&config.api_key_env)
        .map_err(|_| format!("{} not set", config.api_key_env))?;

    let client = ApiClient::new(&api_key);
    let (system_blocks, user_message) = build_system_prompt();

    let mut messages: Vec<serde_json::Value> = vec![serde_json::json!({
        "role": "user",
        "content": user_message,
    })];

    let context_limit = config.context_limit;
    let mut negotiation_sent = false;
    let mut cutoff_sent = false;
    let mut api_calls: u32 = 0;
    let mut total_output_tokens: u64 = 0;
    let mut last_input_tokens: u64 = 0;

    loop {
        let request = Request {
            model: &config.model,
            max_tokens: config.max_response_tokens,
            system: &system_blocks,
            messages: &messages,
            tools: &TOOL_DEFINITIONS,
        };

        let response = client.create_message(&request).map_err(|e| format!("API error: {e}"))?;

        api_calls += 1;
        last_input_tokens = response.usage.input_tokens;
        total_output_tokens += response.usage.output_tokens;

        // Build assistant content as JSON value for the conversation
        let assistant_content: Vec<serde_json::Value> = response
            .content
            .iter()
            .map(|block| match block {
                ContentBlock::Text { text } => serde_json::json!({
                    "type": "text",
                    "text": text,
                }),
                ContentBlock::ToolUse { id, name, input } => serde_json::json!({
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input,
                }),
            })
            .collect();

        messages.push(serde_json::json!({
            "role": "assistant",
            "content": assistant_content,
        }));

        if cutoff_sent {
            break;
        }

        if response.stop_reason == StopReason::EndTurn {
            break;
        }

        // Execute tool calls
        let mut tool_results: Vec<serde_json::Value> = Vec::new();
        for block in &response.content {
            if let ContentBlock::ToolUse { id, name, input } = block {
                let result = execute_tool(name, input, config.tool_timeout_seconds);
                tool_results.push(serde_json::json!({
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": result,
                }));
            }
        }

        if tool_results.is_empty() {
            break;
        }

        // Check context budget
        let tokens_used = last_input_tokens;
        if !cutoff_sent && tokens_used >= (context_limit as f64 * 0.95) as u64 {
            tool_results.push(serde_json::json!({
                "type": "text",
                "text": "[SYSTEM] Context limit reached (95%). Write your handoff and outbox now. This breath is ending.",
            }));
            cutoff_sent = true;
        } else if !negotiation_sent && tokens_used >= (context_limit as f64 * 0.80) as u64 {
            tool_results.push(serde_json::json!({
                "type": "text",
                "text": concat!(
                    "[SYSTEM] You're approaching the end of this breath ",
                    "(~80% context used). Can you complete your current task ",
                    "in the remaining context, or should you write a handoff ",
                    "for the next breath?\n\n",
                    "If you can finish: say CONTINUING and keep working.\n",
                    "If you need another breath: say HANDING_OFF, then ",
                    "write your continuation handoff (handoff.md) and ",
                    "outbox with type: \"continuing\". The keeper will ",
                    "checkpoint and re-wake you immediately."
                ),
            }));
            negotiation_sent = true;
        }

        messages.push(serde_json::json!({
            "role": "user",
            "content": tool_results,
        }));
    }

    write_usage(api_calls, last_input_tokens, total_output_tokens);
    Ok(())
}

