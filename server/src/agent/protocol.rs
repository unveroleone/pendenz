// The part of the Model Context Protocol that Pendenz serves: initialize, ping, tools/list and
// tools/call, over JSON-RPC 2.0. The stdio server and the hosted endpoint both hand each
// message to `Session::handle`.
use super::{client::Client, tools};
use serde_json::{Value, json};

pub const LATEST_VERSION: &str = "2025-11-25";
pub const VERSIONS: [&str; 5] = [
    LATEST_VERSION,
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
    "2024-10-07",
];

pub enum Message {
    // A request has an id and wants an answer.
    Request {
        id: Value,
        method: String,
        params: Option<Value>,
    },
    // A notification, or an answer from the client to a request of ours, which Pendenz never
    // sends. Neither gets an answer.
    Other,
}

// The shape of a JSON-RPC message, or None when it is not one.
pub fn parse(message: &Value) -> Option<Message> {
    let fields = message.as_object()?;
    if fields.get("jsonrpc")? != "2.0" {
        return None;
    }
    let id = fields
        .get("id")
        .filter(|id| id.is_string() || id.as_f64().is_some_and(|n| n.fract() == 0.0));
    let params = fields.get("params");
    if params.is_some_and(|p| !p.is_object()) {
        return None;
    }
    match fields.get("method") {
        Some(Value::String(method)) => match (fields.get("id"), id) {
            (None, _) => Some(Message::Other),
            (Some(_), Some(id)) => Some(Message::Request {
                id: id.clone(),
                method: method.clone(),
                params: params.cloned(),
            }),
            // An id that is neither a string nor a whole number makes it a notification, as
            // it did for the SDK that served these tools first.
            (Some(_), None) => Some(Message::Other),
        },
        Some(_) => None,
        None => {
            let answer = fields.get("result").is_some_and(Value::is_object);
            let error = fields.get("error").is_some_and(|e| {
                e.get("code")
                    .is_some_and(|c| c.as_f64().is_some_and(|n| n.fract() == 0.0))
                    && e.get("message").is_some_and(Value::is_string)
            });
            ((answer && id.is_some()) || error).then_some(Message::Other)
        }
    }
}

pub fn is_initialize(message: &Value) -> bool {
    message.get("method") == Some(&json!("initialize")) && message.get("id").is_some()
}

pub struct Session {
    pub client: Client,
    // The scopes of the token, or None when the API could not tell.
    pub scopes: Option<Vec<String>>,
    // Whether a path in a tool call means a file next to this server.
    pub files: bool,
}

fn answer(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

impl Session {
    pub async fn handle(&self, message: Message) -> Option<Value> {
        let Message::Request { id, method, params } = message else {
            return None;
        };
        let offered = tools::offered(self.scopes.as_deref(), self.files);
        let params = params.unwrap_or_else(|| json!({}));
        Some(match method.as_str() {
            "initialize" => {
                let Some(asked) = params.get("protocolVersion").and_then(Value::as_str) else {
                    return Some(error(id, -32602, "Invalid params"));
                };
                let version = if VERSIONS.contains(&asked) {
                    asked
                } else {
                    LATEST_VERSION
                };
                let capabilities = if offered.is_empty() {
                    json!({})
                } else {
                    json!({"tools": {"listChanged": true}})
                };
                answer(
                    id,
                    json!({
                        "protocolVersion": version,
                        "capabilities": capabilities,
                        "serverInfo": {"name": "pendenz", "version": "0.1.0"},
                        "instructions": tools::INSTRUCTIONS.trim_end(),
                    }),
                )
            }
            "ping" => answer(id, json!({})),
            // A token whose scopes allow no tool has no tool methods at all.
            "tools/list" | "tools/call" if offered.is_empty() => {
                error(id, -32601, "Method not found")
            }
            "tools/list" => answer(id, json!({"tools": offered})),
            "tools/call" => {
                let Some(name) = params.get("name").and_then(Value::as_str) else {
                    return Some(error(id, -32603, "Invalid params: name must be a string"));
                };
                let arguments = params.get("arguments").cloned();
                if arguments.as_ref().is_some_and(|a| !a.is_object()) {
                    return Some(error(
                        id,
                        -32603,
                        "Invalid params: arguments must be an object",
                    ));
                }
                answer(
                    id,
                    tools::call(
                        &self.client,
                        self.scopes.as_deref(),
                        self.files,
                        name,
                        arguments,
                    )
                    .await,
                )
            }
            _ => error(id, -32601, "Method not found"),
        })
    }
}
