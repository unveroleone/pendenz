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
    assert_eq!(worker_row["today"]["completed"], 1);
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
