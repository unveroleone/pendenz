// Status reports: who may send and read them, what the server keeps, and the command that sends
// one. Each test runs its own scratch server.
mod support;

use serde_json::{Value, json};
use support::*;

async fn put(server: &Server, token: &str, body: Value) -> (u16, Value) {
    let response = reqwest::Client::new()
        .put(format!("{}/api/agents/me/report", server.url()))
        .bearer_auth(token)
        .json(&body)
        .send()
        .await
        .unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap_or(Value::Null))
}

async fn agents(server: &Server, token: &str) -> (u16, Value) {
    let response = reqwest::Client::new()
        .get(format!("{}/api/agents", server.url()))
        .bearer_auth(token)
        .send()
        .await
        .unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap_or(Value::Null))
}

fn report(sent_at: &str) -> Value {
    json!({
        "schema": 1,
        "sent_at": sent_at,
        "agent": {"software": "Test Agent", "version": "1.0", "health": "online"},
        "jobs": [{"name": "triage", "schedule": "Every 5 min", "enabled": true,
                  "last_status": "error", "failure_streak": 2,
                  "last_error": "failed with key sk-ant-abc123 at /x"}],
        "host": {"name": "box", "cpu_percent": 250.0, "memory_used": 1, "memory_total": 2},
    })
}

#[tokio::test]
async fn only_agents_with_the_report_scope_send() {
    let server = Server::start().await;
    let reporter = server.token("box", "report");
    let worker = server.token("worker", "read,write");

    let (status, body) = put(&server, &reporter, report("2026-11-18T10:00:00Z")).await;
    assert_eq!(status, 200, "{body}");
    assert!(body["received_at"].is_string());

    // An agent token without the scope, and the owner, who is no agent.
    assert_eq!(
        put(&server, &worker, report("2026-11-18T10:00:00Z"))
            .await
            .0,
        403
    );
    assert_eq!(
        put(&server, &server.owner, report("2026-11-18T10:00:00Z"))
            .await
            .0,
        403
    );

    // A report token can do nothing else.
    let response = reqwest::Client::new()
        .get(format!("{}/api/items", server.url()))
        .bearer_auth(&reporter)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 403);
}

#[tokio::test]
async fn reports_are_checked_and_bounded() {
    let server = Server::start().await;
    let reporter = server.token("box", "report");

    let mut wrong = report("2026-11-18T10:00:00Z");
    wrong["schema"] = json!(2);
    assert_eq!(put(&server, &reporter, wrong).await.0, 400);
    let mut unknown = report("2026-11-18T10:00:00Z");
    unknown["extra"] = json!(1);
    assert_eq!(put(&server, &reporter, unknown).await.0, 400);

    // A clock far ahead would hold back every later report.
    assert_eq!(
        put(&server, &reporter, report("2999-01-01T00:00:00Z"))
            .await
            .0,
        400
    );

    let mut long = report("2026-11-18T10:00:00Z");
    long["jobs"][0]["name"] = json!("x".repeat(500));
    assert_eq!(put(&server, &reporter, long).await.0, 200);
    let (_, list) = agents(&server, &server.owner).await;
    let stored = &list["agents"][0]["report"];
    assert_eq!(
        stored["jobs"][0]["name"].as_str().unwrap().chars().count(),
        80
    );
    assert_eq!(stored["host"]["cpu_percent"], 100.0);
    assert_eq!(
        stored["jobs"][0]["last_error"],
        "failed with key [hidden] at /x"
    );
}

#[tokio::test]
async fn an_older_report_does_not_replace_a_newer_one() {
    let server = Server::start().await;
    let reporter = server.token("box", "report");
    put(&server, &reporter, report("2026-11-18T10:00:00Z")).await;
    let mut older = report("2026-11-18T09:00:00Z");
    older["agent"]["version"] = json!("0.9");
    let (status, body) = put(&server, &reporter, older).await;
    assert_eq!(status, 200);
    assert_eq!(body["kept"], "newer");
    let (_, list) = agents(&server, &server.owner).await;
    assert_eq!(list["agents"][0]["report"]["agent"]["version"], "1.0");
}

#[tokio::test]
async fn only_the_owner_reads_the_agents() {
    let server = Server::start().await;
    let reporter = server.token("box", "report");
    let worker = server.token("worker", "read,write");
    put(&server, &reporter, report("2026-11-18T10:00:00Z")).await;

    assert_eq!(agents(&server, &worker).await.0, 403);
    assert_eq!(agents(&server, &reporter).await.0, 403);
    let write_only = server.token("owner", "write");
    assert_eq!(agents(&server, &write_only).await.0, 403);

    // The worker creates an item and completes it, which counts for today.
    let item = server
        .api(
            &worker,
            "POST",
            "/items",
            Some(json!({"title": "From the worker"})),
        )
        .await;
    server
        .api(
            &worker,
            "PATCH",
            &format!("/items/{}", item["id"]),
            Some(json!({"version": item["version"], "status": "done"})),
        )
        .await;
    let (status, list) = agents(&server, &server.owner).await;
    assert_eq!(status, 200);
    let list = list["agents"].as_array().unwrap();
    // The agent with a report comes first; the other has none.
    assert_eq!(list[0]["id"], "box");
    assert_eq!(list[0]["scopes"], json!(["report"]));
    assert_eq!(list[0]["report"]["agent"]["software"], "Test Agent");
    let worker_row = list.iter().find(|a| a["id"] == "worker").unwrap();
    assert_eq!(worker_row["report"], Value::Null);
    assert_eq!(worker_row["today"]["created"], 1);
    assert_eq!(
        worker_row["today"],
        json!({"created": 1, "updated": 0, "completed": 1, "commented": 0})
    );
}

#[tokio::test]
async fn the_command_sends_a_report_file() {
    let server = Server::start().await;
    let reporter = server.token("box", "report");
    let file = server.dir.join("report.json");
    std::fs::write(&file, report("2026-11-18T10:00:00Z").to_string()).unwrap();
    let run = server.cli(&reporter, &["report", "--file", file.to_str().unwrap()]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let (_, list) = agents(&server, &server.owner).await;
    assert_eq!(list["agents"][0]["report"]["host"]["name"], "box");
}

async fn post(server: &Server, token: Option<&str>, path: &str, body: Value) -> (u16, Value) {
    let mut request = reqwest::Client::new()
        .post(format!("{}/api{path}", server.url()))
        .json(&body);
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request.send().await.unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap_or(Value::Null))
}

#[tokio::test]
async fn an_agent_connects_once_with_a_code_from_the_owner() {
    let server = Server::start().await;
    // Only the owner's devices make codes.
    let worker = server.token("worker", "read,write");
    let request = json!({"name": "Mac mini", "access": "status"});
    assert_eq!(
        post(&server, Some(&worker), "/agent-codes", request.clone())
            .await
            .0,
        403
    );
    let read_only = server.token("owner", "read");
    assert_eq!(
        post(&server, Some(&read_only), "/agent-codes", request.clone())
            .await
            .0,
        403
    );
    assert_eq!(
        post(
            &server,
            Some(&server.owner),
            "/agent-codes",
            json!({"name": "x", "access": "admin"})
        )
        .await
        .0,
        400
    );

    let (status, made) = post(&server, Some(&server.owner), "/agent-codes", request).await;
    assert_eq!(status, 200, "{made}");
    assert_eq!(made["scopes"], json!(["report"]));
    let code = made["code"].as_str().unwrap().to_lowercase();

    let (status, connected) = post(&server, None, "/agents/connect", json!({"code": code})).await;
    assert_eq!(status, 200, "{connected}");
    assert_eq!(connected["agent"]["id"], "mac-mini");
    let token = connected["token"].as_str().unwrap().to_owned();
    // The code works once.
    assert_eq!(
        post(&server, None, "/agents/connect", json!({"code": code}))
            .await
            .0,
        400
    );

    // The new token sends reports and does nothing else.
    assert_eq!(
        put(&server, &token, report("2026-11-18T10:00:00Z")).await.0,
        200
    );
    let response = reqwest::Client::new()
        .get(format!("{}/api/items", server.url()))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 403);

    // A second agent of the same name gets its own ID, here with access to the items.
    let (_, made) = post(
        &server,
        Some(&server.owner),
        "/agent-codes",
        json!({"name": "Mac mini", "access": "work"}),
    )
    .await;
    let (_, second) = post(
        &server,
        None,
        "/agents/connect",
        json!({"code": made["code"]}),
    )
    .await;
    assert_eq!(second["agent"]["id"], "mac-mini-2");
    assert_eq!(second["scopes"], json!(["read", "write", "report"]));
}

#[tokio::test]
async fn revoking_an_agent_ends_its_tokens_and_report() {
    let server = Server::start().await;
    let reporter = server.token("box", "report");
    put(&server, &reporter, report("2026-11-18T10:00:00Z")).await;
    let worker = server.token("worker", "read,write");
    let delete = |token: String, id: &str| {
        let url = format!("{}/api/agents/{id}", server.url());
        async move {
            reqwest::Client::new()
                .delete(url)
                .bearer_auth(token)
                .send()
                .await
                .unwrap()
                .status()
                .as_u16()
        }
    };
    assert_eq!(delete(worker.clone(), "box").await, 403);
    assert_eq!(delete(server.owner.clone(), "owner").await, 404);
    assert_eq!(delete(server.owner.clone(), "box").await, 200);
    assert_eq!(
        put(&server, &reporter, report("2026-11-18T11:00:00Z"))
            .await
            .0,
        401
    );
    let (_, list) = agents(&server, &server.owner).await;
    let row = list["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == "box")
        .unwrap()
        .clone();
    assert_eq!(row["report"], Value::Null);
    assert_eq!(row["scopes"], json!([]));
}

#[tokio::test]
async fn the_command_line_connects_and_reports_with_the_saved_token() {
    let server = Server::start().await;
    let (_, made) = post(
        &server,
        Some(&server.owner),
        "/agent-codes",
        json!({"name": "Box", "access": "status"}),
    )
    .await;
    let config = server.dir.join("config");
    let command = |args: &[&str]| {
        std::process::Command::new(BIN)
            .args(args)
            .env_remove("PENDENZ_API_URL")
            .env_remove("PENDENZ_API_TOKEN")
            .env("XDG_CONFIG_HOME", &config)
            .output()
            .unwrap()
    };
    let out = command(&["connect", &server.url(), made["code"].as_str().unwrap()]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let saved = config.join("pendenz/agent.json");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(&saved).unwrap().permissions().mode() & 0o777,
        0o600
    );

    let file = server.dir.join("report.json");
    std::fs::write(&file, report("2026-11-18T10:00:00Z").to_string()).unwrap();
    let out = command(&["report", "--file", file.to_str().unwrap()]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let (_, list) = agents(&server, &server.owner).await;
    assert_eq!(list["agents"][0]["id"], "box");
    assert_eq!(list["agents"][0]["report"]["host"]["name"], "box");
}
