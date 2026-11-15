// The hosted MCP endpoint: a stateless POST /mcp that takes the caller's own Pendenz token.
// Each request is checked against the token store and then served with exactly that token's
// scopes. The tools call the API router of this process with the same token.
use super::{
    client::Client,
    protocol::{self, Message, Session, VERSIONS},
};
use crate::{AppState, auth};
use axum::{
    Router,
    extract::{ConnectInfo, Request, State},
    http::{HeaderMap, HeaderValue, Method, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

const BODY_LIMIT: usize = 1024 * 1024;
const PER_MINUTE: u32 = 180;
const AT_ONCE: usize = 32;
const TRACKED: usize = 10_000;
const MINUTE: Duration = Duration::from_secs(60);

pub struct Hosted {
    state: AppState,
    // The API routes under /api, called in process with the caller's token.
    api: Router,
    // What clients call the server, as https://<hostname>. Other hosts and origins are refused.
    host: String,
    origin: String,
    attempts: Mutex<Attempts>,
    active: AtomicUsize,
}

struct Attempts {
    buckets: HashMap<String, (Instant, u32)>,
    swept: Instant,
}

impl Hosted {
    pub fn new(state: AppState, api: Router, origin: &str) -> anyhow::Result<Self> {
        let url = url::Url::parse(origin).map_err(|_| {
            anyhow::anyhow!("PENDENZ_ORIGIN must be an origin like https://pendenz.example.com")
        })?;
        let host = url
            .host_str()
            .ok_or_else(|| anyhow::anyhow!("PENDENZ_ORIGIN needs a host name"))?;
        let host = match url.port() {
            Some(port) => format!("{host}:{port}"),
            None => host.to_owned(),
        };
        Ok(Self {
            state,
            api,
            host,
            origin: url.origin().ascii_serialization(),
            attempts: Mutex::new(Attempts {
                buckets: HashMap::new(),
                swept: Instant::now(),
            }),
            active: AtomicUsize::new(0),
        })
    }

    // Counts a request from this address. False when it is over the limit for this minute.
    fn admit(&self, ip: String) -> bool {
        let now = Instant::now();
        let mut attempts = self.attempts.lock().unwrap_or_else(|e| e.into_inner());
        if now.duration_since(attempts.swept) >= MINUTE {
            attempts
                .buckets
                .retain(|_, (at, _)| now.duration_since(*at) < MINUTE);
            attempts.swept = now;
        }
        let bucket = attempts.buckets.entry(ip).or_insert((now, 0));
        if now.duration_since(bucket.0) >= MINUTE {
            *bucket = (now, 0);
        }
        bucket.1 += 1;
        let count = bucket.1;
        if attempts.buckets.len() > TRACKED {
            attempts
                .buckets
                .retain(|_, (at, _)| now.duration_since(*at) < MINUTE);
            if attempts.buckets.len() > TRACKED
                && let Some(oldest) = attempts
                    .buckets
                    .iter()
                    .min_by_key(|(_, (at, _))| *at)
                    .map(|(ip, _)| ip.clone())
            {
                attempts.buckets.remove(&oldest);
            }
        }
        count <= PER_MINUTE
    }
}

// Counts a request that is being served, for as long as it is.
struct Active<'a>(&'a AtomicUsize);
impl Drop for Active<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

fn reply(status: StatusCode, message: &str) -> Response {
    (status, axum::Json(json!({"error": message}))).into_response()
}

fn rpc_error(status: StatusCode, code: i64, message: &str) -> Response {
    (
        status,
        axum::Json(
            json!({"jsonrpc": "2.0", "error": {"code": code, "message": message}, "id": null}),
        ),
    )
        .into_response()
}

fn unauthorized(message: &str) -> Response {
    let mut response = reply(StatusCode::UNAUTHORIZED, message);
    response
        .headers_mut()
        .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
    response
}

fn text(headers: &HeaderMap, name: header::HeaderName) -> Option<&str> {
    headers.get(name).and_then(|v| v.to_str().ok())
}

// A header that may come more than once, its values joined as Node's HTTP server joined them.
// Bytes that are not text still count, so they cannot make a header look absent.
fn joined(headers: &HeaderMap, name: &str) -> Option<String> {
    let values: Vec<String> = headers
        .get_all(name)
        .iter()
        .map(|v| String::from_utf8_lossy(v.as_bytes()).into_owned())
        .collect();
    (!values.is_empty()).then(|| values.join(", "))
}

// The token of an Authorization header that has the form of a Pendenz token.
fn bearer(headers: &HeaderMap) -> Option<&str> {
    let token = text(headers, header::AUTHORIZATION)?.strip_prefix("Bearer ")?;
    let hex = token.strip_prefix(auth::TOKEN_PREFIX)?;
    (hex.len() == 64
        && hex
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)))
    .then_some(token)
}

pub async fn handle(
    State(hosted): State<Arc<Hosted>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
) -> Response {
    let mut response = serve(&hosted, peer, request).await;
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

async fn serve(hosted: &Hosted, peer: SocketAddr, request: Request) -> Response {
    // The endpoint is /mcp exactly, without a query.
    if request.uri().query().is_some() {
        return reply(StatusCode::NOT_FOUND, "Not found.");
    }
    let headers = request.headers();
    // An empty Origin counts as none, as it did before.
    let origin_ok = joined(headers, "origin").is_none_or(|o| o.is_empty() || o == hosted.origin);
    let host = headers
        .get(header::HOST)
        .map(|v| String::from_utf8_lossy(v.as_bytes()).into_owned());
    if host.as_deref() != Some(hosted.host.as_str()) || !origin_ok {
        return reply(StatusCode::FORBIDDEN, "Unrecognized host or origin.");
    }
    if request.method() != Method::POST {
        let mut response = reply(
            StatusCode::METHOD_NOT_ALLOWED,
            "Use a stateless MCP POST request.",
        );
        response
            .headers_mut()
            .insert(header::ALLOW, HeaderValue::from_static("POST"));
        return response;
    }
    let ip = headers
        .get("cf-connecting-ip")
        .and_then(|v| v.to_str().ok())
        .filter(|v| !v.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| peer.ip().to_string());
    // The place among the requests served at once is taken here, in one step, so two requests
    // cannot both take the last one. A request that fails below gives it back.
    let admitted = hosted.admit(ip)
        && hosted
            .active
            .try_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                (n < AT_ONCE).then_some(n + 1)
            })
            .is_ok();
    if !admitted {
        let mut response = reply(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many requests. Retry shortly.",
        );
        response
            .headers_mut()
            .insert(header::RETRY_AFTER, HeaderValue::from_static("60"));
        return response;
    }
    let _active = Active(&hosted.active);
    let Some(token) = bearer(headers).map(str::to_owned) else {
        return unauthorized("Send a valid Pendenz bearer token.");
    };
    let lookup = tokio::time::timeout(Duration::from_secs(5), auth::lookup(&hosted.state, &token));
    let identity = match lookup.await {
        Ok(Ok(identity)) => identity,
        Ok(Err(error)) if error.0 == StatusCode::UNAUTHORIZED => {
            return unauthorized("This token is invalid, expired or revoked.");
        }
        _ => return reply(StatusCode::SERVICE_UNAVAILABLE, "The API is unavailable."),
    };
    let content_type = text(headers, header::CONTENT_TYPE).unwrap_or("").to_owned();
    if !content_type.starts_with("application/json") {
        return reply(StatusCode::UNSUPPORTED_MEDIA_TYPE, "Use application/json.");
    }
    let accept = joined(headers, "accept").unwrap_or_default();
    let version = joined(headers, "mcp-protocol-version");
    let body = request.into_body();
    let bytes = match tokio::time::timeout(
        Duration::from_secs(30),
        axum::body::to_bytes(body, BODY_LIMIT),
    )
    .await
    {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(error)) if too_large(&error) => {
            return reply(StatusCode::PAYLOAD_TOO_LARGE, "The request is too large.");
        }
        _ => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "MCP is temporarily unavailable.",
            );
        }
    };
    let Ok(message) = serde_json::from_slice::<Value>(&bytes) else {
        return reply(StatusCode::BAD_REQUEST, "Invalid JSON.");
    };
    if message.is_array() {
        return reply(
            StatusCode::BAD_REQUEST,
            "Send one JSON-RPC request per call.",
        );
    }
    // The rules of the Streamable HTTP transport, in stateless mode with JSON answers.
    if !accept.contains("application/json") || !accept.contains("text/event-stream") {
        return rpc_error(
            StatusCode::NOT_ACCEPTABLE,
            -32000,
            "Not Acceptable: Client must accept both application/json and text/event-stream",
        );
    }
    let media = content_type.split(';').next().unwrap_or("").trim();
    if !media.eq_ignore_ascii_case("application/json") {
        return rpc_error(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            -32000,
            "Unsupported Media Type: Content-Type must be application/json",
        );
    }
    let initialize = protocol::is_initialize(&message);
    let Some(parsed) = protocol::parse(&message) else {
        return rpc_error(
            StatusCode::BAD_REQUEST,
            -32700,
            "Parse error: Invalid JSON-RPC message",
        );
    };
    if !initialize
        && let Some(version) = version
        && !VERSIONS.contains(&version.as_str())
    {
        return rpc_error(
            StatusCode::BAD_REQUEST,
            -32000,
            &format!(
                "Bad Request: Unsupported protocol version: {version} (supported versions: {})",
                VERSIONS.join(", ")
            ),
        );
    }
    if !matches!(parsed, Message::Request { .. }) {
        return StatusCode::ACCEPTED.into_response();
    }
    let session = Session {
        client: Client::local(hosted.api.clone(), token),
        scopes: Some(identity.scopes),
        files: false,
    };
    match session.handle(parsed).await {
        Some(answer) => axum::Json(answer).into_response(),
        None => StatusCode::ACCEPTED.into_response(),
    }
}

fn too_large(error: &axum::Error) -> bool {
    let mut cause: Option<&(dyn std::error::Error + 'static)> = Some(error);
    while let Some(current) = cause {
        if current.is::<http_body_util::LengthLimitError>() {
            return true;
        }
        cause = current.source();
    }
    false
}
