// One request function for the command line and both MCP servers. The command line and the
// stdio server call a Pendenz API over HTTP with PENDENZ_API_URL and PENDENZ_API_TOKEN. The
// hosted endpoint calls the API router of its own process with the caller's token, so every
// call passes the same authentication, scope checks and hidden filter as a request from outside.
use axum::{
    Router,
    body::Body,
    http::{Method, Request, header},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Map, Value, json};
use std::time::Duration;
use tower::ServiceExt;

const LOOPBACK: [&str; 3] = ["localhost", "127.0.0.1", "[::1]"];
const TIMEOUT: &str = "The operation was aborted due to timeout";

pub enum Reply {
    Json(Value),
    Binary { mime: String, data: Vec<u8> },
}

impl Reply {
    pub fn json(self) -> Value {
        match self {
            Reply::Json(value) => value,
            Reply::Binary { .. } => Value::Null,
        }
    }
}

enum Transport {
    Http {
        http: reqwest::Client,
        base: String,
        token: Option<String>,
        // Where new items come from, such as "telegram". The server records "mcp" without it.
        source: Option<String>,
    },
    Local {
        router: Router,
        token: String,
    },
}

pub struct Client(Transport);

// A request as the tools describe it. A body makes it a write, which gets an idempotency key:
// the caller's key when it gave one, otherwise a fresh one, so each call is its own action.
#[derive(Default)]
pub struct Call<'a> {
    pub method: Option<Method>,
    pub body: Option<Value>,
    pub key: Option<&'a str>,
    // A successful answer comes back as bytes with its type instead of parsed JSON.
    pub binary: bool,
}

impl<'a> Call<'a> {
    pub fn write(method: Method, body: Value, key: Option<&'a str>) -> Self {
        Self {
            method: Some(method),
            body: Some(body),
            key,
            binary: false,
        }
    }
}

struct Raw {
    status: u16,
    content_type: Option<String>,
    body: Vec<u8>,
}

impl Client {
    pub fn from_env() -> Self {
        let env = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
        let http = reqwest::Client::builder()
            // A redirect could carry the token to another host.
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("the HTTP client starts");
        Client(Transport::Http {
            http,
            base: env("PENDENZ_API_URL").unwrap_or_else(|| "http://127.0.0.1:8080".into()),
            token: env("PENDENZ_API_TOKEN"),
            source: env("PENDENZ_SOURCE"),
        })
    }

    pub fn local(router: Router, token: String) -> Self {
        Client(Transport::Local { router, token })
    }

    pub async fn get(&self, path: &str) -> Result<Value, String> {
        Ok(self.request(path, Call::default()).await?.json())
    }

    pub async fn request(&self, path: &str, call: Call<'_>) -> Result<Reply, String> {
        // An image takes longer than a row, so it gets more time.
        let limit = if is_image(path) {
            Duration::from_secs(90)
        } else {
            Duration::from_secs(20)
        };
        let method = call.method.clone().unwrap_or(Method::GET);
        let mut body = call.body;
        let key = body.as_ref().map(|_| {
            call.key
                .map(str::to_owned)
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string())
        });
        let raw = match &self.0 {
            Transport::Http {
                http,
                base,
                token,
                source,
            } => {
                let base = url::Url::parse(base).map_err(|_| "Invalid URL".to_owned())?;
                let host = base.host_str().unwrap_or("");
                if base.scheme() != "https" && !LOOPBACK.contains(&host) {
                    return Err("Use HTTPS when sending a token to a remote API.".into());
                }
                let token = token
                    .as_deref()
                    .ok_or("Set PENDENZ_API_TOKEN to your Pendenz token.")?;
                if let (Some(source), Some(Value::Object(fields))) = (source, body.as_mut())
                    && method == Method::POST
                    && path == "/items"
                {
                    fields.insert("created_via".into(), Value::String(source.clone()));
                }
                let url = base
                    .join(&format!("/api{path}"))
                    .map_err(|_| "Invalid URL".to_owned())?;
                let mut request = http.request(method, url).bearer_auth(token).timeout(limit);
                if let (Some(body), Some(key)) = (&body, &key) {
                    request = request
                        .header(header::CONTENT_TYPE, "application/json")
                        .header("Idempotency-Key", key)
                        .body(body.to_string());
                }
                let response = request.send().await.map_err(|error| {
                    if error.is_timeout() {
                        TIMEOUT.to_owned()
                    } else {
                        format!("Could not reach the API: {}", reason(&error))
                    }
                })?;
                if response.status().is_redirection() {
                    return Err(format!(
                        "The API answered {} with a redirect, which is not followed. Check PENDENZ_API_URL.",
                        response.status().as_u16()
                    ));
                }
                let status = response.status().as_u16();
                let content_type = response
                    .headers()
                    .get(header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned);
                let body = tokio::time::timeout(limit, response.bytes())
                    .await
                    .map_err(|_| TIMEOUT.to_owned())?
                    .map_err(|error| format!("Could not read the answer: {}", reason(&error)))?;
                Raw {
                    status,
                    content_type,
                    body: body.to_vec(),
                }
            }
            Transport::Local { router, token } => {
                let mut request = Request::builder()
                    .method(method)
                    .uri(format!("/api{path}"))
                    // The API checks the host in local mode only, and this call never left the
                    // machine.
                    .header(header::HOST, "127.0.0.1")
                    .header(header::AUTHORIZATION, format!("Bearer {token}"));
                let body = match (&body, &key) {
                    (Some(body), Some(key)) => {
                        request = request
                            .header(header::CONTENT_TYPE, "application/json")
                            .header("Idempotency-Key", key);
                        Body::from(body.to_string())
                    }
                    _ => Body::empty(),
                };
                let request = request.body(body).map_err(|e| e.to_string())?;
                let response = tokio::time::timeout(limit, router.clone().oneshot(request))
                    .await
                    .map_err(|_| TIMEOUT.to_owned())?
                    .unwrap_or_else(|never| match never {});
                let status = response.status().as_u16();
                let content_type = response
                    .headers()
                    .get(header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned);
                let body = axum::body::to_bytes(response.into_body(), 64 * 1024 * 1024)
                    .await
                    .map_err(|e| e.to_string())?;
                Raw {
                    status,
                    content_type,
                    body: body.to_vec(),
                }
            }
        };
        let ok = (200..300).contains(&raw.status);
        if call.binary && ok {
            return Ok(Reply::Binary {
                mime: raw
                    .content_type
                    .unwrap_or_else(|| "application/octet-stream".into()),
                data: raw.body,
            });
        }
        if !raw
            .content_type
            .as_deref()
            .is_some_and(|t| t.contains("application/json"))
        {
            return Err(format!(
                "The API answered {} without JSON. Check PENDENZ_API_URL.",
                raw.status
            ));
        }
        let mut result: Value = serde_json::from_slice(&raw.body)
            .map_err(|_| format!("The API answered {} with invalid JSON.", raw.status))?;
        js_numbers(&mut result);
        if !ok {
            let message = result
                .get("error")
                .and_then(Value::as_str)
                .filter(|m| !m.is_empty())
                .unwrap_or("Request failed");
            return Err(format!("{}: {message}", raw.status));
        }
        Ok(Reply::Json(result))
    }
}

// JavaScript has one kind of number, so the first version of these tools wrote a position of
// 5.0 as 5. Whole numbers are written without the fraction here too.
fn js_numbers(value: &mut Value) {
    match value {
        Value::Number(n) if n.is_f64() => {
            if let Some(f) = n.as_f64()
                && f.fract() == 0.0
                && f.abs() <= 9_007_199_254_740_991.0
            {
                *value = Value::from(f as i64);
            }
        }
        Value::Array(items) => items.iter_mut().for_each(js_numbers),
        Value::Object(map) => map.values_mut().for_each(js_numbers),
        _ => {}
    }
}

fn is_image(path: &str) -> bool {
    path.strip_prefix("/items/")
        .and_then(|rest| rest.split_once('/'))
        .is_some_and(|(id, rest)| {
            !id.is_empty() && id.bytes().all(|c| c.is_ascii_digit()) && rest.starts_with("images")
        })
}

// The innermost cause, which says more than reqwest's own summary.
fn reason(error: &(dyn std::error::Error + 'static)) -> String {
    let mut cause = error;
    while let Some(source) = cause.source() {
        cause = source;
    }
    cause.to_string()
}

// A local image file as the upload route takes it. The first bytes decide the type, as they do
// on the server, which also checks the size and refuses anything else.
pub fn image_body(path: &str) -> Result<Value, String> {
    let data = std::fs::read(path).map_err(|error| format!("Could not read {path}: {error}"))?;
    let mime = if data.starts_with(&[0xFF, 0xD8]) {
        "image/jpeg"
    } else if data.starts_with(b"\x89PNG") {
        "image/png"
    } else {
        return Err("Only JPEG and PNG images can be attached.".into());
    };
    if data.len() > 5 * 1024 * 1024 {
        return Err("An image can be at most 5 MB.".into());
    }
    Ok(json!({"mime": mime, "data": STANDARD.encode(&data)}))
}

fn positive(text: &str) -> bool {
    let mut chars = text.chars();
    matches!(chars.next(), Some('1'..='9')) && chars.all(|c| c.is_ascii_digit())
}

// The text a JavaScript String() would make of a value, which the IDs below are read from.
pub fn js_string(value: Option<&Value>) -> String {
    match value {
        None => "undefined".into(),
        Some(Value::String(text)) => text.clone(),
        Some(Value::Number(n)) => match n.as_f64() {
            Some(f) if f.fract() == 0.0 && f.abs() < 1e21 => format!("{}", f as i64),
            _ => n.to_string(),
        },
        Some(other) => other.to_string(),
    }
}

// Items are shown as P-12. Accepts that form or the plain number.
pub fn item_id(value: Option<&Value>) -> Result<String, String> {
    let text = js_string(value);
    let text = crate::agent::schema::js_trim(&text);
    let digits = match text.get(..2) {
        Some(prefix) if prefix.eq_ignore_ascii_case("p-") => &text[2..],
        _ => text,
    };
    if positive(digits) {
        Ok(digits.to_owned())
    } else {
        Err("Use an item ID like P-12 or 12.".into())
    }
}

// Notes have no prefix: the app never shows their ID.
pub fn note_id(value: Option<&Value>) -> Result<String, String> {
    let text = js_string(value);
    let text = crate::agent::schema::js_trim(&text);
    if positive(text) {
        Ok(text.to_owned())
    } else {
        Err("Use a note ID like 12.".into())
    }
}

// An image ID from the item's images list.
pub fn image_id(value: Option<&Value>) -> Result<String, String> {
    let text = js_string(value);
    let text = crate::agent::schema::js_trim(&text);
    if positive(text) {
        Ok(text.to_owned())
    } else {
        Err("Use an image ID from the item's images list.".into())
    }
}

// A project ID as the server makes it: lowercase letters, digits and hyphens.
pub fn project_id(value: Option<&Value>) -> Result<String, String> {
    let text = js_string(value);
    let text = crate::agent::schema::js_trim(&text);
    let bytes = text.as_bytes();
    let edge = |c: &u8| c.is_ascii_lowercase() || c.is_ascii_digit();
    let ok = !bytes.is_empty()
        && bytes.len() <= 40
        && edge(&bytes[0])
        && edge(&bytes[bytes.len() - 1])
        && bytes.iter().all(|c| edge(c) || *c == b'-');
    if ok {
        Ok(text.to_owned())
    } else {
        Err("Use a project ID from workspace, such as home-lab.".into())
    }
}

// A query string of the values that are set, as URLSearchParams writes it.
pub fn query(params: &Map<String, Value>) -> String {
    let mut out = url::form_urlencoded::Serializer::new(String::new());
    let mut any = false;
    for (key, value) in params {
        let text = match value {
            Value::Null => continue,
            Value::String(text) if text.is_empty() => continue,
            other => js_string(Some(other)),
        };
        out.append_pair(key, &text);
        any = true;
    }
    if any {
        format!("?{}", out.finish())
    } else {
        String::new()
    }
}
