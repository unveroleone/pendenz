// Regression tests for the agent tools: the hosted MCP endpoint, the stdio MCP server and the
// command line. Each test compares its transcript with a fixture recorded from the Node adapters
// these replaced, so a change in what an agent sees shows up as a failing step.
// `support/mod.rs` describes how to run them against the Node adapters and how to record.
mod support;

use serde_json::{Value, json};
use support::*;

fn init_params(version: &str) -> Value {
    json!({
        "protocolVersion": version,
        "capabilities": {},
        "clientInfo": {"name": "test", "version": "1"}
    })
}

// The request metadata a client of protocol version 2026-07-28 sends with every request, in
// place of the initialize handshake.
fn meta_2026() -> Value {
    json!({
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": {"name": "test", "version": "1"}
    })
}

// A request as a 2026-07-28 client sends it: no session, the method and name in headers.
async fn post_2026(hosted: &Hosted, method: &str, name: Option<&str>, params: Value) -> Value {
    let mut params = params;
    params["_meta"] = meta_2026();
    let mut request = hosted
        .http
        .post(&hosted.url)
        .bearer_auth(&hosted.token)
        .header("Accept", ACCEPT)
        .header("MCP-Protocol-Version", "2026-07-28")
        .header("Mcp-Method", method);
    if let Some(name) = name {
        request = request.header("Mcp-Name", name);
    }
    let response = request
        .json(&json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
        .send()
        .await
        .unwrap();
    answer(response).await
}

#[tokio::test]
async fn hosted_http_rules() {
    let server = Server::start().await;
    let token = server.token("bot", "read,write");
    let http = reqwest::Client::new();
    let url = server.mcp_url();
    let origin = server.mcp_origin();
    let list = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
    let mut t = Transcript::new("hosted_http");

    let post = |headers: Vec<(&'static str, String)>, body: String| {
        let mut request = http.post(&url).body(body);
        for (name, value) in headers {
            request = request.header(name, value);
        }
        request.send()
    };
    let auth = || ("Authorization", format!("Bearer {token}"));
    let json_type = || ("Content-Type", "application/json".to_owned());
    let accept = || ("Accept", ACCEPT.to_owned());

    t.add(
        "health",
        answer(http.get(format!("{origin}/healthz")).send().await.unwrap()).await,
    );
    t.add(
        "get",
        answer(http.get(&url).bearer_auth(&token).send().await.unwrap()).await,
    );
    t.add(
        "delete",
        answer(http.delete(&url).bearer_auth(&token).send().await.unwrap()).await,
    );
    t.add(
        "wrong host",
        answer(
            post(
                vec![
                    auth(),
                    json_type(),
                    accept(),
                    ("Host", "pendenz.example".into()),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "wrong origin",
        answer(
            post(
                vec![
                    auth(),
                    json_type(),
                    accept(),
                    ("Origin", "https://evil.example".into()),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    let same_origin = t.add(
        "same origin",
        answer(
            post(
                vec![auth(), json_type(), accept(), ("Origin", origin.clone())],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    assert_eq!(same_origin["status"], 200);
    t.add(
        "no token",
        answer(
            post(vec![json_type(), accept()], list.to_string())
                .await
                .unwrap(),
        )
        .await,
    );
    t.add(
        "not a pendenz token",
        answer(
            post(
                vec![
                    ("Authorization", "Bearer abc".into()),
                    json_type(),
                    accept(),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "lowercase scheme",
        answer(
            post(
                vec![
                    ("Authorization", format!("bearer {token}")),
                    json_type(),
                    accept(),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "unknown token",
        answer(
            post(
                vec![
                    ("Authorization", format!("Bearer pdz_{}", "0".repeat(64))),
                    json_type(),
                    accept(),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    let revoked = server.token("bot", "read");
    let tokens = server.admin(&["list-tokens"]);
    let id = tokens.as_array().unwrap().last().unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    server.admin(&["revoke-token", &id]);
    t.add(
        "revoked token",
        answer(
            post(
                vec![
                    ("Authorization", format!("Bearer {revoked}")),
                    json_type(),
                    accept(),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "text body",
        answer(
            post(
                vec![auth(), ("Content-Type", "text/plain".into()), accept()],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "no content type",
        answer(
            post(vec![auth(), accept()], list.to_string())
                .await
                .unwrap(),
        )
        .await,
    );
    t.add(
        "too large",
        answer(
            post(
                vec![auth(), json_type(), accept()],
                format!("\"{}\"", "a".repeat(1024 * 1024 + 10)),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "invalid json",
        answer(
            post(vec![auth(), json_type(), accept()], "{".into())
                .await
                .unwrap(),
        )
        .await,
    );
    t.add(
        "batch",
        answer(
            post(
                vec![auth(), json_type(), accept()],
                json!([list.clone()]).to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "not json-rpc",
        answer(
            post(
                vec![auth(), json_type(), accept()],
                json!({"hello": 1}).to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "no accept",
        answer(
            post(vec![auth(), json_type()], list.to_string())
                .await
                .unwrap(),
        )
        .await,
    );
    t.add(
        "accept json only",
        answer(
            post(
                vec![auth(), json_type(), ("Accept", "application/json".into())],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "notification",
        answer(
            post(
                vec![auth(), json_type(), accept()],
                json!({"jsonrpc": "2.0", "method": "notifications/initialized"}).to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "unsupported protocol header",
        answer(
            post(
                vec![
                    auth(),
                    json_type(),
                    accept(),
                    ("MCP-Protocol-Version", "1999-01-01".into()),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "supported protocol header",
        answer(
            post(
                vec![
                    auth(),
                    json_type(),
                    accept(),
                    ("MCP-Protocol-Version", "2025-06-18".into()),
                ],
                json!({"jsonrpc": "2.0", "id": 2, "method": "ping"}).to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "initialize",
        answer(
            post(
                vec![auth(), json_type(), accept()],
                json!({"jsonrpc": "2.0", "id": "a", "method": "initialize", "params": init_params("2025-06-18")})
                    .to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    // Edges found in review: each answer here was recorded from the Node endpoint.
    t.add(
        "query string",
        answer(
            http.post(format!("{url}?x=1"))
                .bearer_auth(&token)
                .header("Content-Type", "application/json")
                .header("Accept", ACCEPT)
                .body(list.to_string())
                .send()
                .await
                .unwrap(),
        )
        .await,
    );
    t.add(
        "empty origin",
        answer(
            post(
                vec![auth(), json_type(), accept(), ("Origin", String::new())],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "origin twice",
        answer(
            post(
                vec![
                    auth(),
                    json_type(),
                    accept(),
                    ("Origin", origin.clone()),
                    ("Origin", "https://evil.example".into()),
                ],
                list.to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    t.add(
        "accept split over two headers",
        answer(
            post(
                vec![
                    auth(),
                    json_type(),
                    ("Accept", "application/json".into()),
                    ("Accept", "text/event-stream".into()),
                ],
                json!({"jsonrpc": "2.0", "id": 3, "method": "ping"}).to_string(),
            )
            .await
            .unwrap(),
        )
        .await,
    );
    for (label, id) in [
        ("id true", json!(true)),
        ("id null", Value::Null),
        ("id fraction", json!(1.5)),
        ("id object", json!({})),
    ] {
        t.add(
            label,
            answer(
                post(
                    vec![auth(), json_type(), accept()],
                    json!({"jsonrpc": "2.0", "id": id, "method": "ping"}).to_string(),
                )
                .await
                .unwrap(),
            )
            .await,
        );
    }
    t.finish();
}

#[tokio::test]
async fn hosted_rate_limit() {
    let server = Server::start().await;
    let http = reqwest::Client::new();
    let url = server.mcp_url();
    let token = server.token("bot", "read");
    let send = |token: Option<&str>| {
        let mut request = http
            .post(&url)
            .header("Content-Type", "application/json")
            .header("Accept", ACCEPT)
            .body(json!({"jsonrpc": "2.0", "id": 1, "method": "ping"}).to_string());
        if let Some(token) = token {
            request = request.header("Authorization", format!("Bearer {token}"));
        }
        request.send()
    };
    let mut t = Transcript::new("hosted_rate_limit");
    // Requests without a token are refused before they are counted, so they cannot use up the
    // budget of a token.
    let mut statuses = Vec::new();
    for _ in 0..181 {
        statuses.push(send(None).await.unwrap().status().as_u16());
    }
    t.add(
        "181 without a token",
        json!(statuses.iter().all(|s| *s == 401)),
    );
    let mut statuses = Vec::new();
    for _ in 0..180 {
        statuses.push(send(Some(&token)).await.unwrap().status().as_u16());
    }
    t.add(
        "first 180 with a token",
        json!(statuses.iter().all(|s| *s == 200)),
    );
    t.add("181st", answer(send(Some(&token)).await.unwrap()).await);
    t.finish();
}

// A skill entry with the digest and size of its files left out, since they change with every
// edit of the text. check_file compares them with the bytes the server serves.
fn skill_shape(result: &Value) -> Value {
    let mut result = result.clone();
    let strip = |skill: &mut Value| {
        let files = skill.get_mut("resources").and_then(Value::as_array_mut);
        for file in files.into_iter().flatten().filter_map(Value::as_object_mut) {
            file.remove("digest");
            file.remove("size");
        }
    };
    if let Some(skills) = result.get_mut("skills").and_then(Value::as_array_mut) {
        skills.iter_mut().for_each(strip);
    }
    if let Some(skill) = result.get_mut("skill") {
        strip(skill);
    }
    result
}

// The check a client makes: the bytes read match the size and digest of the manifest.
fn check_file(file: &Value, contents: &Value) {
    use sha2::{Digest, Sha256};
    let text = contents["text"].as_str().expect("the file as text");
    assert_eq!(file["uri"], contents["uri"]);
    assert_eq!(file["size"], json!(text.len()), "size");
    let digest = Sha256::digest(text.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    assert_eq!(file["digest"], json!(format!("sha256:{digest}")), "digest");
}

#[tokio::test]
async fn hosted_tools() {
    let server = Server::start().await;
    let bot = server.hosted(&server.token("bot", "read,write"));
    let reader = server.hosted(&server.token("reader", "read"));
    let writer = server.hosted(&server.token("writer", "write"));
    let owner = server.hosted(&server.owner);
    let mut t = Transcript::new("hosted_tools");

    // The protocol.
    t.add(
        "initialize",
        bot.rpc("initialize", Some(init_params("2025-06-18"))).await,
    );
    t.add(
        "initialize unknown version",
        bot.rpc("initialize", Some(init_params("1999-01-01"))).await,
    );
    t.add(
        "initialize 2025-03-26",
        bot.rpc("initialize", Some(init_params("2025-03-26"))).await["result"]["protocolVersion"]
            .clone(),
    );
    t.add("ping", bot.rpc("ping", None).await);
    t.add("unknown method", bot.rpc("foo/bar", None).await);
    t.add("resources/list", bot.rpc("resources/list", None).await);
    t.add("prompts/list", bot.rpc("prompts/list", None).await);
    t.add("tools for bot", bot.tools().await);
    t.add("tools for reader", json!(names(&reader.tools().await)));
    t.add("tools for writer", json!(names(&writer.tools().await)));
    t.add("tools for owner", json!(names(&owner.tools().await)));
    t.add("unknown tool", bot.call("nope", json!({})).await);
    t.add(
        "tool the scopes leave out",
        reader
            .call("create_item", json!({"item": {"title": "x"}}))
            .await,
    );
    // The wording of this error came from the SDK's own schema check; the code is what counts.
    let no_name = bot.rpc("tools/call", Some(json!({"arguments": {}}))).await;
    t.add("call without a name", no_name["error"]["code"].clone());
    let no_args = bot
        .rpc("tools/call", Some(json!({"name": "workspace"})))
        .await;
    t.add("call without arguments", tool_result(&no_args));

    // Validation: only that it is a validation error is compared, not its wording.
    for (tool, args) in [
        ("list_items", json!({"limit": 0})),
        ("list_items", json!({"bogus": 1})),
        ("list_items", json!({"status": "later"})),
        ("get_item", json!({"id": "x"})),
        ("get_item", json!({"id": 0})),
        ("get_item", json!({"id": 1.5})),
        ("get_item", json!({})),
        ("get_item", json!({"id": 1, "activity": 101})),
        (
            "update_comment",
            json!({"id": 1, "comment": "x", "version": 1, "outdated": true}),
        ),
        (
            "update_comment",
            json!({"id": 1, "comment": 1, "outdated": true}),
        ),
        (
            "update_comment",
            json!({"id": 1, "comment": 1, "version": 1, "body": " "}),
        ),
        ("delete_comment", json!({"id": 1})),
        ("create_item", json!({"item": {"title": "   "}})),
        (
            "create_item",
            json!({"item": {"title": "x", "tags": ["two words"]}}),
        ),
        (
            "create_item",
            json!({"item": {"title": "x", "source_url": "not a url"}}),
        ),
        (
            "create_item",
            json!({"item": {"title": "x", "priority": 9}}),
        ),
        (
            "create_item",
            json!({"item": {"title": "x", "extra": true}}),
        ),
        ("create_item", json!({"item": {"title": "x"}, "key": ""})),
        (
            "create_item",
            json!({"item": {"title": "x", "checklist": [{"text": " "}]}}),
        ),
        (
            "update_item",
            json!({"id": "P-1", "version": 1, "changes": {}}),
        ),
        (
            "update_item",
            json!({"id": "P-1", "version": 0, "changes": {"status": "done"}}),
        ),
        (
            "update_item",
            json!({"id": "P-1", "changes": {"status": "done"}}),
        ),
        ("add_comment", json!({"id": 1, "body": "  "})),
        ("get_item_file", json!({"id": 1, "file": "abc"})),
        ("create_project", json!({"name": "x", "icon": "rocket"})),
        ("create_note", json!({"note": {"body": ""}})),
        (
            "update_note",
            json!({"id": 1, "version": 1, "changes": {"locked": false}}),
        ),
        ("append_note", json!({"id": "a", "text": "x"})),
        ("changes", json!({"limit": 501})),
    ] {
        let result = bot.call(tool, args.clone()).await;
        assert!(
            validation_error(&result, tool),
            "{tool} {args}: expected a validation error, got {result}"
        );
    }

    // Projects.
    t.add("workspace", bot.call("workspace", json!({})).await);
    t.add(
        "create project",
        bot.call(
            "create_project",
            json!({"name": "Home Lab", "icon": "server.rack", "key": "p1"}),
        )
        .await,
    );
    t.add(
        "create project again with the key",
        bot.call(
            "create_project",
            json!({"name": "Home Lab", "icon": "server.rack", "key": "p1"}),
        )
        .await,
    );
    t.add(
        "create project without icon",
        bot.call("create_project", json!({"name": "  Errands  "}))
            .await,
    );
    t.add(
        "rename project",
        bot.call(
            "update_project",
            json!({"id": "home-lab", "name": "Homelab"}),
        )
        .await,
    );
    t.add(
        "re-icon project",
        bot.call(
            "update_project",
            json!({"id": "home-lab", "icon": "wrench.and.screwdriver"}),
        )
        .await,
    );
    t.add(
        "update project with nothing",
        bot.call("update_project", json!({"id": "home-lab"})).await,
    );
    t.add(
        "update project with a bad id",
        bot.call("update_project", json!({"id": "Bad ID!", "name": "x"}))
            .await,
    );
    t.add(
        "update missing project",
        bot.call("update_project", json!({"id": "nothing-here", "name": "x"}))
            .await,
    );

    // Items.
    t.add(
        "create minimal item",
        bot.call(
            "create_item",
            json!({"item": {"title": "  Call the dentist  "}}),
        )
        .await,
    );
    let long = "Ä".repeat(150) + &"x".repeat(60) + "🔑 end";
    let full = json!({
        "item": {
            "title": "Renew the passport",
            "description": long,
            "status": "doing",
            "project_id": "home-lab",
            "priority": 3,
            "tags": ["admin", "travel"],
            "checklist": [{"text": "  Photo  ", "done": true}, {"text": "Form"}],
            "due_at": "2030-01-15T09:00",
            "due_tz": "Europe/Zurich",
            "remind_at": "2030-01-15T08:00",
            "repeat_rule": "FREQ=WEEKLY",
            "source_url": "https://example.com/passport",
            "position": 5
        },
        "key": "c2"
    });
    t.add(
        "create full item",
        bot.call("create_item", full.clone()).await,
    );
    t.add(
        "create full item again with the key",
        bot.call("create_item", full).await,
    );
    t.add(
        "create item with the key and other arguments",
        bot.call(
            "create_item",
            json!({"item": {"title": "Other"}, "key": "c2"}),
        )
        .await,
    );
    t.add(
        "create item in a missing project",
        bot.call(
            "create_item",
            json!({"item": {"title": "Lost", "project_id": "nowhere"}}),
        )
        .await,
    );
    t.add(
        "create item with a bad date",
        bot.call(
            "create_item",
            json!({"item": {"title": "Date", "due_at": "tomorrow"}}),
        )
        .await,
    );
    t.add(
        "create inbox items",
        json!([
            bot.call("create_item", json!({"item": {"title": "Buy milk", "due_at": "2030-01-10", "tags": ["errand"], "priority": 1}})).await,
            bot.call("create_item", json!({"item": {"title": "Fix the shelf", "position": 100, "description": "Short."}})).await,
        ]),
    );
    t.add("list open", bot.call("list_items", json!({})).await);
    t.add(
        "list project manual",
        bot.call(
            "list_items",
            json!({"project": "home-lab", "sort": "manual"}),
        )
        .await,
    );
    t.add(
        "list inbox manual",
        bot.call("list_items", json!({"project": "inbox", "sort": "manual"}))
            .await,
    );
    t.add(
        "list all with q",
        bot.call("list_items", json!({"status": "all", "q": "dentist"}))
            .await,
    );
    t.add(
        "list with limit",
        bot.call("list_items", json!({"limit": 1, "sort": "oldest"}))
            .await,
    );
    t.add(
        "list with offset",
        bot.call(
            "list_items",
            json!({"limit": 1, "offset": 1, "sort": "oldest"}),
        )
        .await,
    );
    t.add(
        "list by tag",
        bot.call("list_items", json!({"tag": "errand"})).await,
    );
    t.add(
        "list by priority",
        bot.call("list_items", json!({"priority": 3})).await,
    );
    t.add(
        "list due range",
        bot.call(
            "list_items",
            json!({"due_after": "2030-01-01", "due_before": "2030-01-12", "sort": "due"}),
        )
        .await,
    );
    t.add(
        "list by title",
        bot.call("list_items", json!({"sort": "title"})).await,
    );
    t.add("get item", bot.call("get_item", json!({"id": "P-2"})).await);
    t.add(
        "get item lowercase ref without activity",
        bot.call("get_item", json!({"id": "p-2", "activity": 0}))
            .await,
    );
    t.add(
        "get item by number",
        bot.call("get_item", json!({"id": 1})).await,
    );
    t.add(
        "get item by string number",
        bot.call("get_item", json!({"id": "3"})).await,
    );
    t.add(
        "get missing item",
        bot.call("get_item", json!({"id": "P-999"})).await,
    );
    t.add(
        "finish item",
        bot.call(
            "update_item",
            json!({"id": "P-1", "version": 1, "changes": {"status": "done"}, "key": "u1"}),
        )
        .await,
    );
    t.add(
        "update with an old version",
        bot.call(
            "update_item",
            json!({"id": "P-1", "version": 1, "changes": {"title": "Again"}}),
        )
        .await,
    );
    t.add(
        "finish repeating item",
        bot.call(
            "update_item",
            json!({"id": 2, "version": 1, "changes": {"status": "done"}}),
        )
        .await,
    );
    t.add(
        "move item",
        bot.call(
            "update_item",
            json!({"id": 3, "version": 1, "changes": {"position": 250.5}}),
        )
        .await,
    );
    t.add(
        "change many fields",
        bot.call(
            "update_item",
            json!({"id": 4, "version": 1, "changes": {
                "title": "  Fix the kitchen shelf ",
                "description": "",
                "priority": 0,
                "tags": [],
                "checklist": [{"text": "Screws"}],
                "due_at": null,
                "project_id": "home-lab",
                "source_url": null
            }}),
        )
        .await,
    );
    t.add(
        "archive item",
        bot.call(
            "update_item",
            json!({"id": 3, "version": 2, "changes": {"archived": true}}),
        )
        .await,
    );
    t.add(
        "list archived",
        bot.call("list_items", json!({"archived": true})).await,
    );
    t.add(
        "trash item",
        bot.call(
            "update_item",
            json!({"id": 3, "version": 3, "changes": {"archived": false, "trashed": true}}),
        )
        .await,
    );
    t.add(
        "list trashed",
        bot.call("list_items", json!({"trashed": true})).await,
    );
    t.add(
        "list done",
        bot.call("list_items", json!({"status": "done"})).await,
    );
    t.add(
        "comment",
        bot.call(
            "add_comment",
            json!({"id": "P-2", "body": "  Booked the photo.  ", "key": "k1"}),
        )
        .await,
    );
    t.add(
        "comment on a missing item",
        bot.call("add_comment", json!({"id": 999, "body": "x"}))
            .await,
    );

    // Comments are changed by their author; the owner may change any.
    server
        .api(
            &server.owner,
            "POST",
            "/items/2/comments",
            Some(json!({"body": "Ask at the counter."})),
        )
        .await;
    t.add(
        "mark comment outdated",
        bot.call(
            "update_comment",
            json!({"id": "P-2", "comment": 1, "version": 1, "outdated": true, "key": "uc1"}),
        )
        .await,
    );
    t.add(
        "mark comment outdated again with the key",
        bot.call(
            "update_comment",
            json!({"id": "P-2", "comment": 1, "version": 1, "outdated": true, "key": "uc1"}),
        )
        .await,
    );
    t.add(
        "get item with an outdated comment",
        bot.call("get_item", json!({"id": 2, "activity": 2})).await,
    );
    t.add(
        "edit comment with an old version",
        bot.call(
            "update_comment",
            json!({"id": 2, "comment": 1, "version": 1, "body": "x"}),
        )
        .await,
    );
    t.add(
        "edit comment without a change",
        bot.call(
            "update_comment",
            json!({"id": 2, "comment": 1, "version": 2}),
        )
        .await,
    );
    t.add(
        "edit the owner's comment",
        bot.call(
            "update_comment",
            json!({"id": 2, "comment": 2, "version": 1, "outdated": true}),
        )
        .await,
    );
    t.add(
        "delete the owner's comment",
        bot.call("delete_comment", json!({"id": 2, "comment": 2}))
            .await,
    );
    t.add(
        "edit comment under another item",
        bot.call(
            "update_comment",
            json!({"id": 1, "comment": 1, "version": 2, "body": "x"}),
        )
        .await,
    );
    t.add(
        "owner edits the agent's comment",
        owner
            .call(
                "update_comment",
                json!({"id": 2, "comment": 1, "version": 2, "body": " Booked the photo for Friday. "}),
            )
            .await,
    );
    t.add(
        "delete comment",
        bot.call(
            "delete_comment",
            json!({"id": 2, "comment": 1, "key": "dc1"}),
        )
        .await,
    );
    t.add(
        "delete comment again with the key",
        bot.call(
            "delete_comment",
            json!({"id": 2, "comment": 1, "key": "dc1"}),
        )
        .await,
    );
    t.add(
        "delete comment again",
        bot.call("delete_comment", json!({"id": 2, "comment": 1}))
            .await,
    );
    t.add(
        "edit a deleted comment",
        owner
            .call(
                "update_comment",
                json!({"id": 2, "comment": 1, "version": 4, "outdated": false}),
            )
            .await,
    );
    t.add(
        "get item after deleting a comment",
        bot.call("get_item", json!({"id": 2, "activity": 3})).await,
    );

    // A picture sent by an app of 0.2.0 to the old image route is a file with a size.
    server
        .api(
            &server.owner,
            "POST",
            "/items/2/images",
            Some(json!({"mime": "image/png", "data": png_base64()})),
        )
        .await;
    t.add(
        "get item with an old image",
        bot.call("get_item", json!({"id": 2, "activity": 1})).await,
    );
    let image = bot.call("get_item_file", json!({"id": 2, "file": 1})).await;
    assert_eq!(image["content"][0]["data"], png_base64());
    t.add("get an old image", image);
    t.add(
        "remove an old image",
        bot.call("remove_item_file", json!({"id": 2, "file": 1, "key": "r1"}))
            .await,
    );

    // Files, uploaded by the owner through the API.
    for (name, mime, data) in [
        (
            "Packing list.txt",
            "text/plain",
            b"Passport\nCharger\n".to_vec(),
        ),
        (
            "Offer.pdf",
            "application/pdf",
            b"%PDF-1.7 not really".to_vec(),
        ),
        ("photo.png", "image/png", PNG.to_vec()),
    ] {
        let response = server
            .upload(&server.owner, 2, (name, mime, data), name, None)
            .await;
        assert!(response.status().is_success());
    }
    t.add(
        "list shows the file count",
        bot.call("list_items", json!({"project": "home-lab"})).await,
    );
    t.add(
        "get item with files",
        bot.call("get_item", json!({"id": 2, "activity": 1})).await,
    );
    t.add(
        "get a text file",
        bot.call("get_item_file", json!({"id": 2, "file": 2})).await,
    );
    t.add(
        "get a file that cannot be shown",
        bot.call("get_item_file", json!({"id": "P-2", "file": "3"}))
            .await,
    );
    let picture = bot.call("get_item_file", json!({"id": 2, "file": 4})).await;
    assert_eq!(picture["content"][0]["data"], png_base64());
    t.add("get an image file", picture);
    t.add(
        "get a missing file",
        bot.call("get_item_file", json!({"id": 2, "file": 99}))
            .await,
    );
    t.add(
        "remove file",
        bot.call(
            "remove_item_file",
            json!({"id": 2, "file": 3, "key": "rf1"}),
        )
        .await,
    );
    t.add(
        "remove file again",
        bot.call("remove_item_file", json!({"id": 2, "file": 3}))
            .await,
    );

    // Hidden rows do not exist for an agent.
    let hidden = server
        .api(
            &server.owner,
            "POST",
            "/items",
            Some(json!({"title": "Secret", "hidden_from_agents": true})),
        )
        .await;
    let hidden_id = hidden["id"].clone();
    t.add(
        "get hidden item",
        bot.call("get_item", json!({"id": hidden_id})).await,
    );
    t.add(
        "list without hidden",
        bot.call("list_items", json!({"q": "Secret"})).await,
    );
    t.add(
        "owner sees hidden",
        owner.call("list_items", json!({"q": "Secret"})).await,
    );

    // Notes.
    t.add(
        "create note",
        bot.call(
            "create_note",
            json!({"note": {"body": "## Wifi\n\nThe password is on the router 🔑. ".to_owned() + &"y".repeat(250)}, "key": "n1"}),
        )
        .await,
    );
    t.add(
        "create locked note",
        bot.call(
            "create_note",
            json!({"note": {"body": "Bank\n\nPIN 1234", "locked": true, "project_id": "home-lab", "pinned": true}}),
        )
        .await,
    );
    t.add(
        "create title-only note",
        bot.call("create_note", json!({"note": {"body": "  Just a title  "}}))
            .await,
    );
    let secret_note = server
        .api(
            &server.owner,
            "POST",
            "/notes",
            Some(json!({"body": "Hidden note", "hidden_from_agents": true})),
        )
        .await;
    t.add("search notes", bot.call("search_notes", json!({})).await);
    t.add(
        "search notes with q",
        bot.call("search_notes", json!({"q": "password"})).await,
    );
    t.add(
        "search locked note by text",
        bot.call("search_notes", json!({"q": "PIN"})).await,
    );
    t.add(
        "search notes without project",
        bot.call("search_notes", json!({"project": "none", "limit": 1}))
            .await,
    );
    t.add(
        "search notes in project",
        bot.call("search_notes", json!({"project": "home-lab"}))
            .await,
    );
    t.add("get note", bot.call("get_note", json!({"id": 1})).await);
    t.add(
        "get locked note",
        bot.call("get_note", json!({"id": "2"})).await,
    );
    t.add(
        "get hidden note",
        bot.call("get_note", json!({"id": secret_note["id"].clone()}))
            .await,
    );
    t.add(
        "pin note",
        bot.call(
            "update_note",
            json!({"id": 1, "version": 1, "changes": {"pinned": true}}),
        )
        .await,
    );
    t.add(
        "rewrite note with an old version",
        bot.call(
            "update_note",
            json!({"id": 1, "version": 1, "changes": {"body": "New"}}),
        )
        .await,
    );
    t.add(
        "append to note",
        bot.call(
            "append_note",
            json!({"id": 1, "text": "\nGuest network: guest", "key": "a1"}),
        )
        .await,
    );
    t.add(
        "append to locked note",
        bot.call("append_note", json!({"id": 2, "text": "PUK 5678"}))
            .await,
    );
    t.add(
        "lock note",
        bot.call(
            "update_note",
            json!({"id": 3, "version": 1, "changes": {"locked": true, "project_id": "home-lab"}}),
        )
        .await,
    );
    t.add(
        "trash note",
        bot.call(
            "update_note",
            json!({"id": 3, "version": 2, "changes": {"trashed": true}}),
        )
        .await,
    );
    t.add(
        "search trashed notes",
        bot.call("search_notes", json!({"trashed": true})).await,
    );
    t.add(
        "get missing note",
        bot.call("get_note", json!({"id": 99})).await,
    );

    // The changes feed leaves notes out.
    let all = t.add(
        "changes",
        bot.call("changes", json!({"cursor": 0, "limit": 500}))
            .await,
    );
    assert!(
        !all.to_string().contains("\"type\":\"note\""),
        "changes must leave notes out"
    );
    t.add(
        "changes page",
        bot.call("changes", json!({"cursor": 3, "limit": 2})).await,
    );
    t.add("changes default", bot.call("changes", json!({})).await);

    // Deleting a project moves its items to the inbox.
    t.add(
        "delete project",
        bot.call("delete_project", json!({"id": "home-lab", "key": "d1"}))
            .await,
    );
    t.add(
        "delete project again",
        bot.call("delete_project", json!({"id": "home-lab"})).await,
    );
    t.add(
        "inbox after delete",
        bot.call("list_items", json!({"project": "inbox"})).await,
    );
    t.add(
        "workspace after delete",
        bot.call("workspace", json!({})).await,
    );

    // A token without read gets receipts.
    t.add(
        "writer creates",
        writer
            .call("create_item", json!({"item": {"title": "Blind"}}))
            .await,
    );
    t.add(
        "writer updates",
        writer
            .call(
                "update_item",
                json!({"id": 1, "version": 2, "changes": {"status": "todo"}}),
            )
            .await,
    );
    t.add(
        "writer creates note",
        writer
            .call("create_note", json!({"note": {"body": "Blind note"}}))
            .await,
    );
    t.add(
        "writer appends",
        writer
            .call("append_note", json!({"id": 1, "text": "more"}))
            .await,
    );
    t.add(
        "writer comments",
        writer
            .call("add_comment", json!({"id": 1, "body": "seen"}))
            .await,
    );
    t.add(
        "writer creates project",
        writer
            .call("create_project", json!({"name": "Blind"}))
            .await,
    );
    t.add(
        "reader reads",
        reader
            .call("get_item", json!({"id": 1, "activity": 3}))
            .await,
    );

    // Keys and numbers as the Node adapter sent them: white space around a key does not make
    // it another key, and 1.0 is the number 1.
    t.add(
        "padded key",
        bot.call(
            "create_item",
            json!({"item": {"title": "Padded"}, "key": " pk "}),
        )
        .await,
    );
    t.add(
        "the same key without padding",
        bot.call(
            "create_item",
            json!({"item": {"title": "Padded"}, "key": "pk"}),
        )
        .await,
    );
    t.add(
        "whole numbers written with a fraction",
        bot.call(
            "create_item",
            json!({"item": {"title": "Floats", "priority": 1.0, "position": 2.0}, "key": "f1"}),
        )
        .await,
    );
    t.add(
        "the same call with plain numbers",
        bot.call(
            "create_item",
            json!({"item": {"title": "Floats", "priority": 1, "position": 2}, "key": "f1"}),
        )
        .await,
    );
    t.add(
        "version written with a fraction",
        bot.call(
            "update_item",
            json!({"id": 8, "version": 1.0, "changes": {"status": "doing"}}),
        )
        .await,
    );
    // Protocol version 2026-07-28, which the Node adapter did not speak: no handshake, and
    // each request names its method in a header.
    t.add(
        "2026 discover",
        post_2026(&bot, "server/discover", None, json!({})).await,
    );
    t.add(
        "2026 tools for reader",
        post_2026(&reader, "tools/list", None, json!({})).await["body"]["result"]["tools"]
            .as_array()
            .map(|tools| json!(tools.iter().map(|t| t["name"].clone()).collect::<Vec<_>>()))
            .unwrap_or(Value::Null),
    );
    // The skills extension: the skill, its file as a resource, and nothing for a token that may
    // use no tool.
    let skill_uri = "skill://pendenz/agent-loop/SKILL.md";
    let listed = post_2026(&bot, "skills/list", None, json!({})).await;
    t.add("2026 skills", skill_shape(&listed["body"]["result"]));
    t.add(
        "2026 skill",
        skill_shape(
            &post_2026(&bot, "skills/get", None, json!({"uri": skill_uri})).await["body"]["result"],
        ),
    );
    t.add(
        "2026 unknown skill",
        post_2026(
            &bot,
            "skills/get",
            None,
            json!({"uri": "skill://pendenz/other/SKILL.md"}),
        )
        .await,
    );
    t.add(
        "2026 resources",
        post_2026(&reader, "resources/list", None, json!({})).await["body"]["result"]["resources"]
            .as_array()
            .map(|list| {
                json!(
                    list.iter()
                        .map(|r| json!({"uri": r["uri"], "name": r["name"], "mimeType": r["mimeType"]}))
                        .collect::<Vec<_>>()
                )
            })
            .unwrap_or(Value::Null),
    );
    let read = post_2026(
        &writer,
        "resources/read",
        Some(skill_uri),
        json!({"uri": skill_uri}),
    )
    .await;
    let file = &listed["body"]["result"]["skills"][0]["resources"][0];
    check_file(file, &read["body"]["result"]["contents"][0]);
    t.add(
        "2026 read the skill",
        json!({
            "uri": read["body"]["result"]["contents"][0]["uri"],
            "mimeType": read["body"]["result"]["contents"][0]["mimeType"],
            "starts": read["body"]["result"]["contents"][0]["text"].as_str().map(|text| text.lines().take(3).collect::<Vec<_>>()),
        }),
    );
    t.add(
        "2026 read an unknown file",
        post_2026(
            &bot,
            "resources/read",
            Some("skill://pendenz/agent-loop/other.md"),
            json!({"uri": "skill://pendenz/agent-loop/other.md"}),
        )
        .await,
    );
    let bridge = server.hosted(&server.token("telegram-bridge", "telegram"));
    for method in ["skills/list", "resources/list"] {
        t.add(
            &format!("2026 {method} without tools"),
            post_2026(&bridge, method, None, json!({})).await,
        );
    }
    t.add(
        "2026 read without tools",
        post_2026(
            &bridge,
            "resources/read",
            Some(skill_uri),
            json!({"uri": skill_uri}),
        )
        .await,
    );
    t.add(
        "2026 tool call",
        post_2026(
            &bot,
            "tools/call",
            Some("get_item"),
            json!({"name": "get_item", "arguments": {"id": "P-1", "activity": 0}}),
        )
        .await,
    );
    t.add(
        "2026 tool error",
        post_2026(
            &bot,
            "tools/call",
            Some("get_item"),
            json!({"name": "get_item", "arguments": {"id": "P-999"}}),
        )
        .await,
    );
    t.add(
        "2026 hidden item",
        post_2026(
            &bot,
            "tools/call",
            Some("get_item"),
            json!({"name": "get_item", "arguments": {"id": hidden_id}}),
        )
        .await,
    );
    t.add(
        "2026 writer receipt",
        post_2026(
            &writer,
            "tools/call",
            Some("create_item"),
            json!({"name": "create_item", "arguments": {"item": {"title": "New protocol"}}}),
        )
        .await,
    );
    t.add(
        "2026 without the method header",
        bot.http
            .post(&bot.url)
            .bearer_auth(&bot.token)
            .header("Accept", ACCEPT)
            .header("MCP-Protocol-Version", "2026-07-28")
            .json(&json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {"_meta": meta_2026()}}))
            .send()
            .await
            .unwrap()
            .status()
            .as_u16()
            .into(),
    );

    t.finish();
}

#[tokio::test]
async fn stdio_server() {
    let server = Server::start().await;
    let token = server.token("bot", "read,write");
    let mut t = Transcript::new("stdio").scratch(&server.dir);

    let mut mcp = StdioMcp::start(&server.url(), Some(&token), &[]);
    t.add("initialize", mcp.initialize().await);
    t.add(
        "tools",
        mcp.rpc("tools/list", None).await["result"]["tools"].clone(),
    );
    t.add("ping", mcp.rpc("ping", None).await);
    t.add("unknown method", mcp.rpc("foo/bar", None).await);
    t.add(
        "discover",
        mcp.rpc("server/discover", Some(json!({"_meta": meta_2026()})))
            .await,
    );
    let listed = mcp
        .rpc("skills/list", Some(json!({"_meta": meta_2026()})))
        .await;
    t.add("skills", skill_shape(&listed["result"]));
    let read = mcp
        .rpc(
            "resources/read",
            Some(json!({"_meta": meta_2026(), "uri": "skill://pendenz/agent-loop/SKILL.md"})),
        )
        .await;
    check_file(
        &listed["result"]["skills"][0]["resources"][0],
        &read["result"]["contents"][0],
    );
    t.add(
        "create item",
        mcp.call("create_item", json!({"item": {"title": "Scan the letter"}}))
            .await,
    );
    let png = server.dir.join("photo.png");
    std::fs::write(&png, PNG).unwrap();
    t.add(
        "add a picture",
        mcp.call(
            "add_item_file",
            json!({"id": "P-1", "path": png.display().to_string(), "key": "img1"}),
        )
        .await,
    );
    t.add(
        "add a picture again with the key",
        mcp.call(
            "add_item_file",
            json!({"id": "P-1", "path": png.display().to_string(), "key": "img1"}),
        )
        .await,
    );
    let image = mcp.call("get_item_file", json!({"id": 1, "file": 1})).await;
    assert_eq!(image["content"][0]["data"], png_base64());
    t.add("get the picture", image);
    assert!(
        validation_error(
            &mcp.call("add_item_file", json!({"id": 1, "path": ""}))
                .await,
            "add_item_file"
        ),
        "an empty path is a validation error"
    );
    let letter = server.dir.join("Brief an die Bank.txt");
    std::fs::write(&letter, "Sehr geehrte Damen und Herren").unwrap();
    t.add(
        "add file",
        mcp.call(
            "add_item_file",
            json!({"id": "P-1", "path": letter.display().to_string(), "key": "file1"}),
        )
        .await,
    );
    t.add(
        "add file again with the key",
        mcp.call(
            "add_item_file",
            json!({"id": "P-1", "path": letter.display().to_string(), "key": "file1"}),
        )
        .await,
    );
    t.add(
        "get file",
        mcp.call("get_item_file", json!({"id": 1, "file": 2})).await,
    );
    let gone = mcp
        .call(
            "add_item_file",
            json!({"id": 1, "path": server.dir.join("missing.pdf").display().to_string()}),
        )
        .await;
    assert_eq!(gone["isError"], true, "{gone}");
    t.add(
        "add a file to a missing item",
        mcp.call(
            "add_item_file",
            json!({"id": 99, "path": png.display().to_string()}),
        )
        .await,
    );
    t.add(
        "workspace",
        mcp.call("workspace", json!({})).await["content"][0]["json"]["actor"].clone(),
    );
    drop(mcp);

    // The source of new items.
    let mut telegram = StdioMcp::start(
        &server.url(),
        Some(&server.token("telegram-bridge", "telegram")),
        &[("PENDENZ_SOURCE", "telegram")],
    );
    t.add("telegram initialize", telegram.initialize().await);
    t.add("telegram tools", telegram.tool_names().await);
    drop(telegram);
    let mut sourced = StdioMcp::start(
        &server.url(),
        Some(&token),
        &[("PENDENZ_SOURCE", "telegram")],
    );
    sourced.initialize().await;
    t.add(
        "create with a source the token may not use",
        sourced
            .call("create_item", json!({"item": {"title": "From chat"}}))
            .await,
    );
    drop(sourced);

    let mut reader = StdioMcp::start(&server.url(), Some(&server.token("reader", "read")), &[]);
    reader.initialize().await;
    t.add("reader tools", reader.tool_names().await);
    drop(reader);

    // Without the API at start every tool is offered, and each call reports the error.
    let mut offline = StdioMcp::start(
        &format!("http://127.0.0.1:{}", free_port()),
        Some(&token),
        &[],
    );
    offline.initialize().await;
    t.add("offline tools", offline.tool_names().await);
    let failed = offline.call("workspace", json!({})).await;
    assert_eq!(failed["isError"], true, "{failed}");
    drop(offline);

    let mut remote = StdioMcp::start("http://pendenz.example", Some(&token), &[]);
    remote.initialize().await;
    t.add(
        "plain http remote tools",
        json!(remote.tool_names().await.as_array().map(Vec::len)),
    );
    t.add(
        "plain http remote",
        remote.call("workspace", json!({})).await,
    );
    drop(remote);

    let mut untokened = StdioMcp::start(&server.url(), None, &[]);
    untokened.initialize().await;
    t.add("no token", untokened.call("list_items", json!({})).await);
    drop(untokened);
    t.finish();
}

// A server that answers every request with the same raw HTTP response.
async fn fake_http(
    response: &'static str,
) -> (u16, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let hits = std::sync::Arc::new(AtomicUsize::new(0));
    let counter = hits.clone();
    tokio::spawn(async move {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            counter.fetch_add(1, Ordering::SeqCst);
            let mut buffer = [0; 4096];
            let _ = socket.read(&mut buffer).await;
            let _ = socket.write_all(response.as_bytes()).await;
            let _ = socket.shutdown().await;
        }
    });
    (port, hits)
}

// Several threads, because the command line blocks one while the fake servers answer it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cli() {
    let server = Server::start().await;
    let token = server.token("bot", "read,write");
    let dir = server.dir.clone();
    let mut t = Transcript::new("cli").scratch(&dir);
    let png = dir.join("photo.png");
    std::fs::write(&png, PNG).unwrap();
    let png = png.display().to_string();
    let out = dir.join("out.png").display().to_string();
    let txt = dir.join("list.txt");
    std::fs::write(&txt, "Milk\nBread\n").unwrap();
    let txt = txt.display().to_string();
    let saved = dir.join("saved.txt").display().to_string();

    let steps: Vec<(&str, Vec<&str>)> = vec![
        ("workspace", vec!["workspace"]),
        (
            "project",
            vec![
                "project",
                "--name",
                "Home Lab",
                "--icon",
                "server.rack",
                "--key",
                "p1",
            ],
        ),
        (
            "project again",
            vec![
                "project",
                "--name",
                "Home Lab",
                "--icon",
                "server.rack",
                "--key",
                "p1",
            ],
        ),
        ("project without name", vec!["project"]),
        (
            "project-update",
            vec!["project-update", "home-lab", "--name", "Homelab"],
        ),
        ("project-update nothing", vec!["project-update", "home-lab"]),
        (
            "project-update bad id",
            vec!["project-update", "Bad!", "--name", "x"],
        ),
        (
            "create",
            vec![
                "create",
                "--json",
                r#"{"title":"Call the dentist","due_at":"2030-01-15T09:00","project_id":"home-lab"}"#,
                "--key",
                "c1",
            ],
        ),
        (
            "create again",
            vec![
                "create",
                "--json",
                r#"{"title":"Call the dentist","due_at":"2030-01-15T09:00","project_id":"home-lab"}"#,
                "--key",
                "c1",
            ],
        ),
        (
            "create second",
            vec![
                "create",
                "--json",
                r#"{"title":"Buy milk","tags":["errand"],"due_at":"2030-01-10T18:00"}"#,
            ],
        ),
        ("create bad json", vec!["create", "--json", "{"]),
        ("create json array", vec!["create", "--json", "[1]"]),
        ("create without json", vec!["create"]),
        (
            "create invalid item",
            vec!["create", "--json", r#"{"title":""}"#],
        ),
        ("list", vec!["list"]),
        (
            "list filtered",
            vec![
                "list",
                "--status",
                "open",
                "--project",
                "home-lab",
                "--sort",
                "manual",
                "--limit",
                "5",
            ],
        ),
        (
            "list by tag",
            vec!["list", "--tag", "errand", "--q", "milk"],
        ),
        ("list unknown option", vec!["list", "--colour", "red"]),
        ("list odd options", vec!["list", "--status"]),
        ("list not an option", vec!["list", "status", "open"]),
        ("get", vec!["get", "P-1"]),
        ("get with activity", vec!["get", "1", "--activity", "0"]),
        ("get bad id", vec!["get", "P-x"]),
        ("get no id", vec!["get"]),
        ("get missing", vec!["get", "P-99"]),
        (
            "update",
            vec![
                "update",
                "P-1",
                "--json",
                r#"{"version":1,"status":"doing"}"#,
                "--key",
                "u1",
            ],
        ),
        (
            "update old version",
            vec!["update", "1", "--json", r#"{"version":1,"status":"done"}"#],
        ),
        (
            "comment",
            vec!["comment", "P-1", "--body", "Called, no answer."],
        ),
        ("comment empty", vec!["comment", "P-1"]),
        (
            "comment-update",
            vec![
                "comment-update",
                "P-1",
                "1",
                "--json",
                r#"{"version":1,"outdated":true}"#,
                "--key",
                "cu1",
            ],
        ),
        (
            "comment-update bad comment id",
            vec!["comment-update", "P-1", "x", "--json", r#"{"version":1}"#],
        ),
        ("comment-delete", vec!["comment-delete", "P-1", "1"]),
        ("comment-delete missing", vec!["comment-delete", "P-1", "1"]),
        (
            "add-file picture",
            vec!["add-file", "P-1", &png, "--key", "i1"],
        ),
        ("add-file missing item", vec!["add-file", "P-99", &png]),
        (
            "get-file picture",
            vec!["get-file", "P-1", "1", "--out", &out],
        ),
        (
            "get-file bad file id",
            vec!["get-file", "P-1", "x", "--out", &out],
        ),
        (
            "get-file missing",
            vec!["get-file", "P-1", "9", "--out", &out],
        ),
        (
            "remove-file picture",
            vec!["remove-file", "P-1", "1", "--key", "ri1"],
        ),
        ("add-file", vec!["add-file", "P-1", &txt, "--key", "f1"]),
        (
            "add-file again with the key",
            vec!["add-file", "P-1", &txt, "--key", "f1"],
        ),
        ("get-file", vec!["get-file", "P-1", "2", "--out", &saved]),
        ("get-file without out", vec!["get-file", "P-1", "2"]),
        (
            "remove-file",
            vec!["remove-file", "P-1", "2", "--key", "rf1"],
        ),
        ("remove-file again", vec!["remove-file", "1", "2"]),
        (
            "note-create",
            vec![
                "note-create",
                "--json",
                r#"{"body":"Wifi\n\nPassword on the router"}"#,
            ],
        ),
        (
            "note-create locked",
            vec![
                "note-create",
                "--json",
                r#"{"body":"Bank\n\nPIN 1234","locked":true}"#,
            ],
        ),
        ("notes", vec!["notes"]),
        (
            "notes filtered",
            vec!["notes", "--q", "Wifi", "--project", "none", "--limit", "1"],
        ),
        ("note", vec!["note", "1"]),
        ("note locked", vec!["note", "2"]),
        ("note bad id", vec!["note", "P-1"]),
        (
            "note-update",
            vec![
                "note-update",
                "1",
                "--json",
                r#"{"version":1,"pinned":true}"#,
            ],
        ),
        (
            "note-append",
            vec!["note-append", "1", "--text", "Guest: guest", "--key", "a1"],
        ),
        ("note-append empty", vec!["note-append", "1"]),
        (
            "changes",
            vec!["changes", "--cursor", "0", "--limit", "500"],
        ),
        (
            "changes page",
            vec!["changes", "--cursor", "2", "--limit", "2"],
        ),
        (
            "reminders",
            vec!["reminders", "--after", "2020-01-01T00:00:00Z"],
        ),
        (
            "reminders until",
            vec![
                "reminders",
                "--after",
                "2030-01-01T00:00:00Z",
                "--until",
                "2030-01-12T00:00:00Z",
            ],
        ),
        ("reminders without after", vec!["reminders"]),
        (
            "project-delete",
            vec!["project-delete", "home-lab", "--key", "pd1"],
        ),
        ("project-delete bad id", vec!["project-delete", "-x"]),
        ("unknown command", vec!["frobnicate"]),
    ];
    for (label, args) in steps {
        t.add(label, server.cli(&token, &args).record());
    }
    assert_eq!(std::fs::read(&out).unwrap(), PNG);

    // The connection rules of the client.
    t.add(
        "plain http remote",
        run_cli("http://pendenz.example", &token, &["workspace"], &[]).record(),
    );
    t.add(
        "no token",
        run_cli(&server.url(), "", &["workspace"], &[]).record(),
    );
    t.add(
        "empty key",
        server
            .cli(
                &token,
                &["create", "--json", r#"{"title":"Empty key"}"#, "--key", ""],
            )
            .record(),
    );
    t.add(
        "created_via from the environment",
        run_cli(
            &server.url(),
            &token,
            &["create", "--json", r#"{"title":"From chat"}"#],
            &[("PENDENZ_SOURCE", "telegram")],
        )
        .record(),
    );
    let (port, _) = fake_http(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
    )
    .await;
    t.add(
        "not json",
        run_cli(
            &format!("http://127.0.0.1:{port}"),
            &token,
            &["workspace"],
            &[],
        )
        .record(),
    );
    let (target, target_hits) = fake_http(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
    )
    .await;
    let redirect: &'static str = Box::leak(
        format!(
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{target}/api/bootstrap\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        .into_boxed_str(),
    );
    let (port, _) = fake_http(redirect).await;
    let redirected = run_cli(
        &format!("http://127.0.0.1:{port}"),
        &token,
        &["workspace"],
        &[],
    );
    assert_eq!(redirected.code, 1, "a redirect must fail");
    assert_eq!(
        target_hits.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "the client must not follow a redirect with the token"
    );
    let help = run_cli(&server.url(), &token, &["--help"], &[]);
    assert_eq!(help.code, 0);
    for command in ["workspace", "note-append", "get-file", "reminders"] {
        assert!(help.stdout.contains(command), "help lists {command}");
    }
    t.finish();
}
