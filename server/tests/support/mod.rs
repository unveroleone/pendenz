// Shared harness for the agent tests: a scratch server, tokens, an MCP client over HTTP and
// stdio, and the transcripts that the tests compare with their fixtures.
//
// Every test starts its own server in token mode on a scratch database, so IDs and versions are
// the same on every run. A transcript records each call with its answer, with times and UUIDs
// replaced, and is compared with `server/tests/fixtures/<name>.json`.
// PENDENZ_RECORD_FIXTURES=1 writes the fixtures instead of comparing them.
//
// The fixtures were first recorded from the Node adapters that these tools replaced (agent/ at
// commit a28d0da, run with PENDENZ_AGENT=node). Every tool call still answers as it did there.
// Steps of the protocol itself (the answers to malformed requests, initialize) were recorded
// again when the protocol moved to rmcp. Record them again only for a change in what an agent
// should see, and read the diff of the fixtures before committing it.
#![allow(dead_code)]

use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child as AsyncChild, ChildStdin, ChildStdout, Command as AsyncCommand},
};

pub const BIN: &str = env!("CARGO_BIN_EXE_pendenz");
pub const ACCEPT: &str = "application/json, text/event-stream";

// A 1x1 PNG.
pub const PNG: [u8; 67] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

pub fn png_base64() -> String {
    STANDARD.encode(PNG)
}

pub fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

pub fn scratch_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("pendenz-test-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

pub struct Server {
    api: Child,
    pub dir: PathBuf,
    pub port: u16,
    db: String,
    pub owner: String,
}

impl Server {
    pub async fn start() -> Self {
        Self::start_in(scratch_dir()).await
    }

    // A server on the database already in `dir`, if there is one.
    pub async fn start_in(dir: PathBuf) -> Self {
        let port = free_port();
        let db = format!("sqlite://{}/pendenz.db", dir.display());
        let api = Command::new(BIN)
            .env("DATABASE_URL", &db)
            .env("PENDENZ_AUTH_MODE", "token")
            .env("PENDENZ_BIND", format!("127.0.0.1:{port}"))
            .env("PENDENZ_ORIGIN", format!("http://127.0.0.1:{port}"))
            .env("PENDENZ_TIMEZONE", "Europe/Zurich")
            .env("RUST_LOG", "warn")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut server = Self {
            api,
            dir,
            port,
            db,
            owner: String::new(),
        };
        wait_for(&format!("{}/healthz", server.url())).await;
        server.owner = server.token("owner", "read,write,propose,approve");
        server
    }

    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    // The hosted MCP endpoint is on the API itself.
    pub fn mcp_origin(&self) -> String {
        self.url()
    }

    pub fn mcp_url(&self) -> String {
        format!("{}/mcp", self.mcp_origin())
    }

    // An admin command of the binary on this server's database.
    pub fn admin(&self, args: &[&str]) -> Value {
        let out = Command::new(BIN)
            .args(args)
            .env("DATABASE_URL", &self.db)
            .env("RUST_LOG", "warn")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "pendenz {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }

    // A token for an actor. An actor other than the owner is added as an agent first.
    pub fn token(&self, actor: &str, scopes: &str) -> String {
        if actor != "owner" {
            let known = self.admin(&["list-tokens"]);
            let exists = known
                .as_array()
                .unwrap()
                .iter()
                .any(|t| t["actor"] == actor);
            if !exists {
                let _ = Command::new(BIN)
                    .args(["add-agent", "--id", actor, "--name", actor])
                    .env("DATABASE_URL", &self.db)
                    .output();
            }
        }
        let issued = self.admin(&[
            "issue-token",
            "--actor",
            actor,
            "--label",
            &format!("{actor}-{scopes}"),
            "--scopes",
            scopes,
        ]);
        issued["token"].as_str().unwrap().to_owned()
    }

    // A direct API call, for setting up what the tools cannot do themselves.
    pub async fn api(&self, token: &str, method: &str, path: &str, body: Option<Value>) -> Value {
        let client = reqwest::Client::new();
        let mut request = client
            .request(method.parse().unwrap(), format!("{}/api{path}", self.url()))
            .bearer_auth(token);
        if let Some(body) = body {
            request = request
                .header("Idempotency-Key", uuid::Uuid::new_v4().to_string())
                .json(&body);
        }
        let response = request.send().await.unwrap();
        let status = response.status();
        let value: Value = response.json().await.unwrap();
        assert!(status.is_success(), "{method} {path}: {status} {value}");
        value
    }

    // A file upload as the apps send it: the raw bytes, with the name and type in headers.
    pub async fn upload(
        &self,
        token: &str,
        item: i64,
        file: (&str, &str, Vec<u8>),
        key: &str,
        upload_id: Option<&str>,
    ) -> reqwest::Response {
        self.upload_to(token, &format!("/items/{item}"), file, key, upload_id)
            .await
    }

    // The same upload to whatever holds files: `/items/<id>` or `/notes/<id>`.
    pub async fn upload_to(
        &self,
        token: &str,
        holder: &str,
        (name, mime, data): (&str, &str, Vec<u8>),
        key: &str,
        upload_id: Option<&str>,
    ) -> reqwest::Response {
        let mut request = reqwest::Client::new()
            .post(format!("{}/api{holder}/files", self.url()))
            .bearer_auth(token)
            .header("Idempotency-Key", key)
            .header("Content-Type", mime)
            .header(
                "Pendenz-File-Name",
                percent_encoding::utf8_percent_encode(name, percent_encoding::NON_ALPHANUMERIC)
                    .to_string(),
            )
            .body(data);
        if let Some(upload_id) = upload_id {
            request = request.header("Pendenz-Upload-Id", upload_id);
        }
        request.send().await.unwrap()
    }

    pub fn hosted(&self, token: &str) -> Hosted {
        Hosted {
            http: reqwest::Client::new(),
            url: self.mcp_url(),
            token: token.to_owned(),
        }
    }

    // The command line of the agent tools, with this server and token.
    pub fn cli(&self, token: &str, args: &[&str]) -> Run {
        run_cli(&self.url(), token, args, &[])
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.api.kill();
        let _ = self.api.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

async fn wait_for(url: &str) {
    let client = reqwest::Client::new();
    for _ in 0..200 {
        if let Ok(response) = client.get(url).send().await
            && response.status().is_success()
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("{url} did not come up");
}

pub struct Run {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Run {
    // The run as a transcript entry: the JSON it printed, or its error.
    pub fn record(&self) -> Value {
        let out = serde_json::from_str::<Value>(&self.stdout)
            .unwrap_or_else(|_| Value::String(self.stdout.trim().to_owned()));
        json!({"code": self.code, "stdout": out, "stderr": self.stderr.trim()})
    }
}

pub fn run_cli(api: &str, token: &str, args: &[&str], env: &[(&str, &str)]) -> Run {
    let mut command = Command::new(BIN);
    command
        .args(args)
        .env("PENDENZ_API_URL", api)
        .env("PENDENZ_API_TOKEN", token)
        .env_remove("PENDENZ_SOURCE")
        .env_remove("DATABASE_URL");
    for (key, value) in env {
        command.env(key, value);
    }
    let out = command.output().unwrap();
    Run {
        code: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

// One HTTP answer, as a transcript records it.
pub async fn answer(response: reqwest::Response) -> Value {
    let status = response.status().as_u16();
    let mut headers = serde_json::Map::new();
    for name in [
        "content-type",
        "cache-control",
        "x-content-type-options",
        "www-authenticate",
        "allow",
        "retry-after",
    ] {
        if let Some(value) = response.headers().get(name) {
            let value = value.to_str().unwrap();
            // Only the media type: the charset parameter is a detail of the HTTP stack.
            let value = if name == "content-type" {
                value.split(';').next().unwrap().trim()
            } else {
                value
            };
            headers.insert(name.into(), value.into());
        }
    }
    let text = response.text().await.unwrap();
    let body = if text.is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&text).unwrap_or(Value::String(text))
    };
    json!({"status": status, "headers": headers, "body": body})
}

pub struct Hosted {
    pub http: reqwest::Client,
    pub url: String,
    pub token: String,
}

impl Hosted {
    pub async fn post(&self, message: Value) -> reqwest::Response {
        self.http
            .post(&self.url)
            .bearer_auth(&self.token)
            .header("Accept", ACCEPT)
            .json(&message)
            .send()
            .await
            .unwrap()
    }

    // A JSON-RPC request, answered with the whole JSON-RPC response.
    pub async fn rpc(&self, method: &str, params: Option<Value>) -> Value {
        let mut message = json!({"jsonrpc": "2.0", "id": 1, "method": method});
        if let Some(params) = params {
            message["params"] = params;
        }
        let response = self.post(message).await;
        assert_eq!(response.status(), 200, "{method}");
        response.json().await.unwrap()
    }

    pub async fn call(&self, name: &str, arguments: Value) -> Value {
        let response = self
            .rpc(
                "tools/call",
                Some(json!({"name": name, "arguments": arguments})),
            )
            .await;
        tool_result(&response)
    }

    pub async fn tools(&self) -> Value {
        self.rpc("tools/list", None).await["result"]["tools"].clone()
    }
}

// A tool result as a transcript keeps it: JSON text parsed, an image by its type and bytes.
pub fn tool_result(response: &Value) -> Value {
    let Some(result) = response.get("result") else {
        return json!({"rpc_error": response["error"]});
    };
    let content: Vec<Value> = result["content"]
        .as_array()
        .unwrap()
        .iter()
        .map(|part| match part["type"].as_str().unwrap() {
            "text" => {
                let text = part["text"].as_str().unwrap();
                match serde_json::from_str::<Value>(text) {
                    Ok(value) if value.is_object() || value.is_array() => json!({"json": value}),
                    _ => json!({"text": text}),
                }
            }
            "image" => json!({"image": part["mimeType"], "data": part["data"]}),
            other => json!({"other": other}),
        })
        .collect();
    let mut entry = json!({"content": content});
    if result.get("isError") == Some(&Value::Bool(true)) {
        entry["isError"] = Value::Bool(true);
    }
    entry
}

// Whether a tool call failed with an input validation error. The wording of such an error is
// not part of the contract, only that it names the tool and starts like this.
pub fn validation_error(result: &Value, tool: &str) -> bool {
    let prefix =
        format!("MCP error -32602: Input validation error: Invalid arguments for tool {tool}: ");
    result["isError"] == true
        && result["content"][0]["text"]
            .as_str()
            .is_some_and(|text| text.starts_with(&prefix) && text.len() > prefix.len())
}

// The stdio MCP server, as an agent next to it starts it.
pub struct StdioMcp {
    child: AsyncChild,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next: u64,
}

impl StdioMcp {
    pub fn start(api: &str, token: Option<&str>, env: &[(&str, &str)]) -> Self {
        let mut command = AsyncCommand::new(BIN);
        command
            .arg("mcp")
            .env("PENDENZ_API_URL", api)
            .env_remove("PENDENZ_SOURCE")
            .env_remove("DATABASE_URL")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        match token {
            Some(token) => command.env("PENDENZ_API_TOKEN", token),
            None => command.env_remove("PENDENZ_API_TOKEN"),
        };
        for (key, value) in env {
            command.env(key, value);
        }
        let mut child = command.spawn().unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            stdin,
            stdout,
            next: 0,
        }
    }

    pub async fn send(&mut self, message: &Value) {
        let mut line = serde_json::to_vec(message).unwrap();
        line.push(b'\n');
        self.stdin.write_all(&line).await.unwrap();
        self.stdin.flush().await.unwrap();
    }

    pub async fn read(&mut self) -> Value {
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(20), self.stdout.read_line(&mut line))
            .await
            .expect("the stdio server did not answer")
            .unwrap();
        serde_json::from_str(&line).unwrap_or_else(|_| panic!("not JSON: {line:?}"))
    }

    pub async fn rpc(&mut self, method: &str, params: Option<Value>) -> Value {
        self.next += 1;
        let mut message = json!({"jsonrpc": "2.0", "id": self.next, "method": method});
        if let Some(params) = params {
            message["params"] = params;
        }
        self.send(&message).await;
        let response = self.read().await;
        assert_eq!(response["id"], self.next, "{response}");
        response
    }

    pub async fn initialize(&mut self) -> Value {
        let result = self
            .rpc(
                "initialize",
                Some(json!({
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"}
                })),
            )
            .await;
        self.send(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
            .await;
        result
    }

    pub async fn call(&mut self, name: &str, arguments: Value) -> Value {
        let response = self
            .rpc(
                "tools/call",
                Some(json!({"name": name, "arguments": arguments})),
            )
            .await;
        tool_result(&response)
    }

    // The names of the tools offered, or the whole answer when there is no list.
    pub async fn tool_names(&mut self) -> Value {
        let response = self.rpc("tools/list", None).await;
        match response["result"]["tools"].as_array() {
            Some(_) => json!(names(&response["result"]["tools"])),
            None => response,
        }
    }
}

impl Drop for StdioMcp {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

pub fn names(tools: &Value) -> Vec<String> {
    tools
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect()
}

// What a transcript keeps of a value: times, UUIDs and scratch paths vary between runs.
pub fn normalize(value: &Value, dir: Option<&Path>) -> Value {
    match value {
        Value::String(text) => Value::String(normalize_text(text, dir)),
        Value::Array(items) => Value::Array(items.iter().map(|v| normalize(v, dir)).collect()),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| {
                    let v = normalize(v, dir);
                    // Checklist lines get a random ID from the server.
                    if k == "checklist"
                        && let Value::Array(lines) = &v
                    {
                        let lines = lines
                            .iter()
                            .map(|line| {
                                let mut line = line.clone();
                                if line.get("id").is_some_and(Value::is_string) {
                                    line["id"] = "<line>".into();
                                }
                                line
                            })
                            .collect();
                        return (k.clone(), Value::Array(lines));
                    }
                    (k.clone(), v)
                })
                .collect(),
        ),
        other => other.clone(),
    }
}

fn normalize_text(text: &str, dir: Option<&Path>) -> String {
    let mut text = text.to_owned();
    if let Some(dir) = dir {
        text = text.replace(&dir.display().to_string(), "<dir>");
    }
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        if let Some(len) = timestamp_at(&bytes[i..]) {
            out.push_str("<time>");
            i += len;
        } else if let Some(len) = uuid_at(&bytes[i..]) {
            out.push_str("<uuid>");
            i += len;
        } else {
            let ch = text[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

// 2026-11-15T10:00:00.123Z or without the fraction.
fn timestamp_at(b: &[u8]) -> Option<usize> {
    let digits =
        |r: std::ops::Range<usize>| r.clone().all(|i| b.get(i).is_some_and(u8::is_ascii_digit));
    if !(digits(0..4)
        && b.get(4) == Some(&b'-')
        && digits(5..7)
        && b.get(7) == Some(&b'-')
        && digits(8..10)
        && b.get(10) == Some(&b'T')
        && digits(11..13)
        && b.get(13) == Some(&b':')
        && digits(14..16)
        && b.get(16) == Some(&b':')
        && digits(17..19))
    {
        return None;
    }
    let mut end = 19;
    if b.get(end) == Some(&b'.') {
        end += 1;
        while b.get(end).is_some_and(u8::is_ascii_digit) {
            end += 1;
        }
    }
    (b.get(end) == Some(&b'Z')).then_some(end + 1)
}

fn uuid_at(b: &[u8]) -> Option<usize> {
    let groups = [8, 4, 4, 4, 12];
    let mut i = 0;
    for (n, len) in groups.iter().enumerate() {
        for _ in 0..*len {
            if !b.get(i).is_some_and(|c| c.is_ascii_hexdigit()) {
                return None;
            }
            i += 1;
        }
        if n < 4 {
            if b.get(i) != Some(&b'-') {
                return None;
            }
            i += 1;
        }
    }
    Some(i)
}

pub struct Transcript {
    name: String,
    dir: Option<PathBuf>,
    entries: Vec<Value>,
}

impl Transcript {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_owned(),
            dir: None,
            entries: Vec::new(),
        }
    }

    // Paths below this folder are written as <dir>.
    pub fn scratch(mut self, dir: &Path) -> Self {
        self.dir = Some(dir.to_owned());
        self
    }

    pub fn add(&mut self, label: &str, value: Value) -> Value {
        let value = normalize(&value, self.dir.as_deref());
        self.entries
            .push(json!({"step": label, "answer": value.clone()}));
        value
    }

    pub fn finish(self) {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(format!("{}.json", self.name));
        if std::env::var("PENDENZ_RECORD_FIXTURES").is_ok_and(|v| v == "1") {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let mut text = serde_json::to_string_pretty(&self.entries).unwrap();
            text.push('\n');
            std::fs::write(&path, text).unwrap();
            return;
        }
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|_| panic!("missing fixture {}", path.display()));
        let expected: Vec<Value> = serde_json::from_str(&text).unwrap();
        for (i, (got, want)) in self.entries.iter().zip(&expected).enumerate() {
            if got != want {
                let mut found = Vec::new();
                differences(got, want, String::new(), &mut found);
                panic!(
                    "{}: step {i} ({}) differs from the fixture:\n{}",
                    self.name,
                    want["step"],
                    found.join("\n")
                );
            }
        }
        assert_eq!(
            self.entries.len(),
            expected.len(),
            "{}: the number of steps differs from the fixture",
            self.name
        );
    }
}

// Where two values differ, as JSON paths with both sides.
fn differences(got: &Value, want: &Value, path: String, found: &mut Vec<String>) {
    match (got, want) {
        (Value::Object(a), Value::Object(b)) => {
            for key in a.keys().chain(b.keys().filter(|k| !a.contains_key(*k))) {
                match (a.get(key), b.get(key)) {
                    (Some(x), Some(y)) => differences(x, y, format!("{path}.{key}"), found),
                    (x, y) => found.push(format!("{path}.{key}: got {x:?}, fixture {y:?}")),
                }
            }
        }
        (Value::Array(a), Value::Array(b)) if a.len() == b.len() => {
            for (i, (x, y)) in a.iter().zip(b).enumerate() {
                differences(x, y, format!("{path}[{i}]"), found);
            }
        }
        _ if got != want => found.push(format!("{path}: got {got}, fixture {want}")),
        _ => {}
    }
}
