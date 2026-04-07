//! Anthropic Messages API client — blocking HTTP with retries.

use std::thread;
use std::time::Duration;

use serde::Deserialize;

const API_URL: &str = "https://api.anthropic.com/v1/messages";
const API_VERSION: &str = "2023-06-01";
const MAX_RETRIES: u32 = 3;

pub struct ApiClient {
    http: reqwest::blocking::Client,
    api_key: String,
}

/// What we send to the API.
pub struct Request<'a> {
    pub model: &'a str,
    pub max_tokens: u64,
    pub system: &'a [serde_json::Value],
    pub messages: &'a [serde_json::Value],
    pub tools: &'a [serde_json::Value],
}

/// Parsed API response.
pub struct Response {
    pub content: Vec<ContentBlock>,
    pub stop_reason: StopReason,
    pub usage: Usage,
}

#[derive(Debug)]
pub enum ContentBlock {
    Text {
        text: String,
    },
    ToolUse {
        id: String,
        name: String,
        input: serde_json::Value,
    },
}

#[derive(Debug, PartialEq)]
pub enum StopReason {
    EndTurn,
    ToolUse,
    MaxTokens,
    Other(String),
}

pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

// --- Raw deserialization types ---

#[derive(Deserialize)]
struct RawResponse {
    content: Vec<RawContentBlock>,
    stop_reason: String,
    usage: RawUsage,
}

#[derive(Deserialize)]
struct RawContentBlock {
    #[serde(rename = "type")]
    block_type: String,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    input: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct RawUsage {
    input_tokens: u64,
    output_tokens: u64,
}

#[derive(Deserialize)]
struct ErrorResponse {
    error: ErrorDetail,
}

#[derive(Deserialize)]
struct ErrorDetail {
    message: String,
}

impl ApiClient {
    pub fn new(api_key: &str) -> Self {
        let http = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(600))
            .build()
            .expect("failed to build HTTP client");
        Self {
            http,
            api_key: api_key.to_string(),
        }
    }

    pub fn create_message(&self, request: &Request) -> Result<Response, String> {
        let body = serde_json::json!({
            "model": request.model,
            "max_tokens": request.max_tokens,
            "system": request.system,
            "messages": request.messages,
            "tools": request.tools,
        });

        let mut last_err = String::new();

        for attempt in 0..=MAX_RETRIES {
            if attempt > 0 {
                let delay = Duration::from_millis(1000 * 2u64.pow(attempt - 1));
                thread::sleep(delay);
            }

            let result = self
                .http
                .post(API_URL)
                .header("x-api-key", &self.api_key)
                .header("anthropic-version", API_VERSION)
                .header("content-type", "application/json")
                .json(&body)
                .send();

            match result {
                Ok(resp) => {
                    let status = resp.status().as_u16();
                    let resp_body = resp.text().unwrap_or_default();

                    if status == 200 {
                        return parse_response(&resp_body);
                    }

                    // Retryable: 429 (rate limit), 529 (overloaded), 5xx
                    if status == 429 || status == 529 || status >= 500 {
                        last_err = extract_error_message(&resp_body, status);
                        eprintln!(
                            "API {status} (attempt {}/{}): {last_err}",
                            attempt + 1,
                            MAX_RETRIES + 1
                        );
                        continue;
                    }

                    // Non-retryable error
                    return Err(extract_error_message(&resp_body, status));
                }
                Err(e) => {
                    last_err = format!("request failed: {e}");
                    eprintln!(
                        "API error (attempt {}/{}): {last_err}",
                        attempt + 1,
                        MAX_RETRIES + 1
                    );
                    continue;
                }
            }
        }

        Err(format!("API failed after {} retries: {last_err}", MAX_RETRIES))
    }
}

fn parse_response(body: &str) -> Result<Response, String> {
    let raw: RawResponse =
        serde_json::from_str(body).map_err(|e| format!("failed to parse API response: {e}"))?;

    let content = raw
        .content
        .into_iter()
        .filter_map(|block| match block.block_type.as_str() {
            "text" => Some(ContentBlock::Text {
                text: block.text.unwrap_or_default(),
            }),
            "tool_use" => Some(ContentBlock::ToolUse {
                id: block.id.unwrap_or_default(),
                name: block.name.unwrap_or_default(),
                input: block.input.unwrap_or(serde_json::Value::Object(Default::default())),
            }),
            _ => None,
        })
        .collect();

    let stop_reason = match raw.stop_reason.as_str() {
        "end_turn" => StopReason::EndTurn,
        "tool_use" => StopReason::ToolUse,
        "max_tokens" => StopReason::MaxTokens,
        other => StopReason::Other(other.to_string()),
    };

    Ok(Response {
        content,
        stop_reason,
        usage: Usage {
            input_tokens: raw.usage.input_tokens,
            output_tokens: raw.usage.output_tokens,
        },
    })
}

fn extract_error_message(body: &str, status: u16) -> String {
    if let Ok(err) = serde_json::from_str::<ErrorResponse>(body) {
        format!("{status}: {}", err.error.message)
    } else {
        format!("{status}: {body}")
    }
}
