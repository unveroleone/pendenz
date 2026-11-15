// The MCP tools. Their names, descriptions and input schemas are in tools.json, which is what an
// agent reads; the server instructions are in instructions.txt. This file checks the arguments
// against those schemas and carries each call out through the API.
//
// The icon enum of the project tools lists the symbols the app's project sheet offers
// (`Project.symbols` in the app). The server takes any symbol name, but the app has no way to
// choose another one, and a name that is not a symbol draws as nothing.
//
// A tool with readOnlyHint needs the read scope, every other one the write scope.
// add_item_image takes a path on the agent's machine, so only the stdio server offers it.
use super::{
    client::{Call, Client, Reply, image_body, image_id, item_id, project_id, query},
    schema::{self, js_space, js_trim, utf16_len},
};
use axum::http::Method;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Map, Value, json};
use std::sync::OnceLock;

pub const INSTRUCTIONS: &str = include_str!("instructions.txt");

// Only offered where a path means a file next to the agent.
const FILE_TOOLS: [&str; 1] = ["add_item_image"];

fn definitions() -> &'static [Value] {
    static TOOLS: OnceLock<Vec<Value>> = OnceLock::new();
    TOOLS.get_or_init(|| {
        let tools: Vec<Value> =
            serde_json::from_str(include_str!("tools.json")).expect("tools.json is valid JSON");
        for tool in &tools {
            for pattern in patterns(&tool["inputSchema"]) {
                assert!(
                    schema::known_pattern(&pattern),
                    "tools.json uses a pattern schema.rs does not know: {pattern}"
                );
            }
        }
        tools
    })
}

fn patterns(value: &Value) -> Vec<String> {
    match value {
        Value::Object(map) => map
            .iter()
            .flat_map(|(key, v)| match (key.as_str(), v) {
                ("pattern", Value::String(p)) => vec![p.clone()],
                _ => patterns(v),
            })
            .collect(),
        Value::Array(items) => items.iter().flat_map(patterns).collect(),
        _ => Vec::new(),
    }
}

fn needs(tool: &Value) -> &'static str {
    if tool["annotations"]["readOnlyHint"] == true {
        "read"
    } else {
        "write"
    }
}

// The tools a token may use. Without scopes (the API could not be asked) every tool is offered,
// and each call reports the error.
pub fn offered(scopes: Option<&[String]>, files: bool) -> Vec<&'static Value> {
    definitions()
        .iter()
        .filter(|tool| files || !FILE_TOOLS.contains(&tool["name"].as_str().unwrap_or("")))
        .filter(|tool| scopes.is_none_or(|scopes| scopes.iter().any(|s| s == needs(tool))))
        .collect()
}

// A call of one tool, answered as an MCP tool result.
pub async fn call(
    client: &Client,
    scopes: Option<&[String]>,
    files: bool,
    name: &str,
    arguments: Option<Value>,
) -> Value {
    let Some(tool) = offered(scopes, files)
        .into_iter()
        .find(|tool| tool["name"] == name)
    else {
        return failure(format!("MCP error -32602: Tool {name} not found"));
    };
    let mut args = arguments.unwrap_or_else(|| json!({}));
    trim(name, &mut args);
    let mut checked = schema::validate(&tool["inputSchema"], &mut args);
    if checked.is_ok()
        && matches!(name, "update_item" | "update_note")
        && args["changes"].as_object().is_some_and(Map::is_empty)
    {
        checked = Err("Include at least one field to change. at changes".into());
    }
    if let Err(issues) = checked {
        return failure(format!(
            "MCP error -32602: Input validation error: Invalid arguments for tool {name}: {issues}"
        ));
    }
    match run(client, name, args).await {
        Ok(Answer::Json(value)) => {
            json!({"content": [{"type": "text", "text": value.to_string()}]})
        }
        Ok(Answer::Image { mime, data }) => json!({"content": [{
            "type": "image",
            "data": STANDARD.encode(data),
            "mimeType": mime,
        }]}),
        Err(message) => failure(message),
    }
}

fn failure(message: String) -> Value {
    json!({"isError": true, "content": [{"type": "text", "text": message}]})
}

// The fields whose white space at either end is dropped before they are checked.
fn trim(name: &str, args: &mut Value) {
    fn trim_at(value: Option<&mut Value>) {
        if let Some(Value::String(text)) = value {
            *text = js_trim(text).to_owned();
        }
    }
    fn trim_item(fields: Option<&mut Value>) {
        let Some(fields) = fields else { return };
        trim_at(fields.get_mut("title"));
        if let Some(Value::Array(lines)) = fields.get_mut("checklist") {
            for line in lines {
                trim_at(line.get_mut("text"));
            }
        }
    }
    match name {
        "create_item" => trim_item(args.get_mut("item")),
        "update_item" => trim_item(args.get_mut("changes")),
        "add_comment" => trim_at(args.get_mut("body")),
        "create_project" | "update_project" => trim_at(args.get_mut("name")),
        _ => {}
    }
}

enum Answer {
    Json(Value),
    Image { mime: String, data: Vec<u8> },
}

fn key(args: &Value) -> Option<&str> {
    args.get("key").and_then(Value::as_str)
}

fn object(value: &Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

async fn run(client: &Client, name: &str, args: Value) -> Result<Answer, String> {
    let write = |method: Method, body: Value| Call::write(method, body, key(&args));
    let value = match name {
        "workspace" => client.get("/bootstrap").await?,
        "list_items" => {
            let mut filters = object(&args);
            let manual = filters.get("sort") == Some(&json!("manual"));
            if filters.get("status") == Some(&json!("all")) {
                filters.remove("status");
            }
            let result = client.get(&format!("/items{}", query(&filters))).await?;
            json!({
                "items": rows(&result["items"], |item| compact(item, manual)),
                "has_more": result["has_more"],
            })
        }
        "get_item" => {
            let mut params = Map::new();
            params.insert("activity".into(), args["activity"].clone());
            client
                .get(&format!(
                    "/items/{}{}",
                    item_id(args.get("id"))?,
                    query(&params)
                ))
                .await?
        }
        "create_item" => {
            let item = &args["item"];
            let created = client
                .request("/items", write(Method::POST, item.clone()))
                .await?
                .json();
            compact(&created, item.get("position").is_some())
        }
        "update_item" => {
            let changes = &args["changes"];
            let mut body = object(changes);
            body.insert("version".into(), args["version"].clone());
            let path = format!("/items/{}", item_id(args.get("id"))?);
            let updated = client
                .request(&path, write(Method::PATCH, Value::Object(body)))
                .await?
                .json();
            compact(&updated, changes.get("position").is_some())
        }
        "add_comment" => {
            let path = format!("/items/{}/comments", item_id(args.get("id"))?);
            client
                .request(&path, write(Method::POST, json!({"body": args["body"]})))
                .await?
                .json()
        }
        "get_item_image" => {
            let path = format!(
                "/items/{}/images/{}",
                item_id(args.get("id"))?,
                image_id(args.get("image"))?
            );
            let call = Call {
                binary: true,
                ..Call::default()
            };
            return match client.request(&path, call).await? {
                Reply::Binary { mime, data } => Ok(Answer::Image { mime, data }),
                Reply::Json(value) => Ok(Answer::Json(value)),
            };
        }
        "add_item_image" => {
            let path = format!("/items/{}/images", item_id(args.get("id"))?);
            let body = image_body(args["path"].as_str().unwrap_or(""))?;
            let updated = client
                .request(&path, write(Method::POST, body))
                .await?
                .json();
            compact(&updated, false)
        }
        "remove_item_image" => {
            let path = format!(
                "/items/{}/images/{}",
                item_id(args.get("id"))?,
                image_id(args.get("image"))?
            );
            let updated = client
                .request(&path, write(Method::DELETE, json!({})))
                .await?
                .json();
            compact(&updated, false)
        }
        "create_project" => {
            let mut body = json!({"name": args["name"]});
            if let Some(icon) = args.get("icon") {
                body["icon"] = icon.clone();
            }
            client
                .request("/projects", write(Method::POST, body))
                .await?
                .json()
        }
        "update_project" => {
            let mut body = Map::new();
            for field in ["name", "icon"] {
                if let Some(value) = args.get(field) {
                    body.insert(field.into(), value.clone());
                }
            }
            if body.is_empty() {
                return Err("Send a name, an icon or both.".into());
            }
            let path = format!("/projects/{}", project_id(args.get("id"))?);
            client
                .request(&path, write(Method::PATCH, Value::Object(body)))
                .await?
                .json()
        }
        "delete_project" => {
            let path = format!("/projects/{}", project_id(args.get("id"))?);
            client
                .request(&path, write(Method::DELETE, json!({})))
                .await?
                .json()
        }
        "search_notes" => {
            let result = client
                .get(&format!("/notes{}", query(&object(&args))))
                .await?;
            json!({
                "notes": rows(&result["notes"], compact_note),
                "has_more": result["has_more"],
            })
        }
        "get_note" => {
            let path = format!("/notes/{}", note_number(&args["id"]));
            let mut note = client.get(&path).await?["note"].clone();
            if note["locked"] == true
                && let Value::Object(fields) = &mut note
            {
                fields.insert("notice".into(), LOCKED_NOTICE.into());
            }
            note
        }
        "create_note" => {
            let created = client
                .request("/notes", write(Method::POST, args["note"].clone()))
                .await?
                .json();
            compact_note(&created)
        }
        "update_note" => {
            let mut body = object(&args["changes"]);
            body.insert("version".into(), args["version"].clone());
            let path = format!("/notes/{}", note_number(&args["id"]));
            let updated = client
                .request(&path, write(Method::PATCH, Value::Object(body)))
                .await?
                .json();
            compact_note(&updated)
        }
        "append_note" => {
            let path = format!("/notes/{}", note_number(&args["id"]));
            let updated = client
                .request(&path, write(Method::PATCH, json!({"append": args["text"]})))
                .await?
                .json();
            compact_note(&updated)
        }
        "changes" => {
            let mut page = client
                .get(&format!("/changes{}", query(&object(&args))))
                .await?;
            // Notes are context to search, not work to pick up, and a note can be long.
            if let Some(Value::Array(changes)) = page.get_mut("changes") {
                changes.retain(|change| change["type"] != "note");
            }
            page
        }
        _ => return Err(format!("MCP error -32602: Tool {name} not found")),
    };
    Ok(Answer::Json(value))
}

// A note ID that the schema already checked, as a number or a string of digits.
fn note_number(id: &Value) -> String {
    super::client::js_string(Some(id))
}

fn rows(list: &Value, row: impl Fn(&Value) -> Value) -> Value {
    match list {
        Value::Array(items) => Value::Array(items.iter().map(row).collect()),
        other => other.clone(),
    }
}

// The first `units` UTF-16 units of a text, as JavaScript's slice() takes them. A cut through a
// character that needs two units drops that character.
fn slice16(text: &str, units: usize) -> &str {
    let mut count = 0;
    for (i, c) in text.char_indices() {
        count += c.len_utf16();
        if count > units {
            return &text[..i];
        }
    }
    text
}

fn cut(text: &str, units: usize, rest: &str) -> String {
    if utf16_len(text) > units {
        format!("{}… ({rest} for the rest)", slice16(text, units))
    } else {
        text.to_owned()
    }
}

fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|n| n != 0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(_) => true,
    }
}

const COMPACT_DESCRIPTION: usize = 200;
const NOTE_PREVIEW: usize = 200;

// Sent with the text of a locked note, so the rule is next to the text it is about.
const LOCKED_NOTICE: &str = "The owner locked this note. Use its text only for the task you are on: do not save it or a summary of it to a memory, a journal or a log, and do not copy it into another note, an item, a comment or a message.";

// A list row for an agent: enough to pick the right item, without full descriptions.
fn compact(item: &Value, with_position: bool) -> Value {
    // A token without the read scope only gets a receipt with the id and version.
    if item.get("title").is_none() {
        return item.clone();
    }
    let mut row = Map::new();
    row.insert("id".into(), item["id"].clone());
    row.insert(
        "ref".into(),
        format!("P-{}", super::client::js_string(item.get("id"))).into(),
    );
    for field in ["title", "status", "version"] {
        if let Some(value) = item.get(field) {
            row.insert(field.into(), value.clone());
        }
    }
    for field in [
        "project_id",
        "due_at",
        "due_tz",
        "remind_at",
        "repeat_rule",
        "source_url",
    ] {
        match item.get(field) {
            None | Some(Value::Null) => {}
            Some(value) => {
                row.insert(field.into(), value.clone());
            }
        }
    }
    if truthy(item.get("priority")) {
        row.insert("priority".into(), item["priority"].clone());
    }
    if with_position && let Some(position) = item.get("position") {
        row.insert("position".into(), position.clone());
    }
    if let Some(Value::Array(tags)) = item.get("tags")
        && !tags.is_empty()
    {
        row.insert("tags".into(), Value::Array(tags.clone()));
    }
    if let Some(stage) = item.get("agent_stage")
        && stage != "none"
    {
        row.insert("agent_stage".into(), stage.clone());
    }
    if let Some(Value::Array(images)) = item.get("images")
        && !images.is_empty()
    {
        row.insert("images".into(), images.len().into());
    }
    if let Some(Value::Array(lines)) = item.get("checklist")
        && !lines.is_empty()
    {
        let done = lines.iter().filter(|line| truthy(line.get("done"))).count();
        row.insert(
            "checklist".into(),
            format!("{done}/{} done", lines.len()).into(),
        );
    }
    if let Some(Value::String(description)) = item.get("description")
        && !description.is_empty()
    {
        row.insert(
            "description".into(),
            cut(description, COMPACT_DESCRIPTION, "get_item").into(),
        );
    }
    Value::Object(row)
}

// A list row for a note: its first line as the title and the start of the rest. A locked note
// keeps the rest to itself, as its row in the app does.
fn compact_note(note: &Value) -> Value {
    // A token without the read scope only gets a receipt with the id and version.
    let Some(body) = note.get("body") else {
        return note.clone();
    };
    let body = body.as_str().unwrap_or("");
    let mut lines = js_trim(body).split('\n');
    let title = lines.next().unwrap_or("");
    let text = lines.collect::<Vec<_>>().join("\n");
    let text = js_trim(&text);
    // A heading mark at the start goes, with the space after it.
    let title = if title.starts_with('#') {
        title.trim_start_matches('#').trim_start_matches(js_space)
    } else {
        title
    };
    let mut row = Map::new();
    row.insert("id".into(), note["id"].clone());
    row.insert("title".into(), slice16(title, 240).into());
    for field in ["version", "updated_at"] {
        if let Some(value) = note.get(field) {
            row.insert(field.into(), value.clone());
        }
    }
    row.insert("length".into(), utf16_len(body).into());
    match note.get("project_id") {
        Some(Value::Null) => {}
        Some(value) => {
            row.insert("project_id".into(), value.clone());
        }
        None => {}
    }
    if truthy(note.get("pinned")) {
        row.insert("pinned".into(), true.into());
    }
    if truthy(note.get("trashed")) {
        row.insert("trashed".into(), true.into());
    }
    if truthy(note.get("locked")) {
        row.insert("locked".into(), true.into());
    } else if !text.is_empty() {
        row.insert("preview".into(), cut(text, NOTE_PREVIEW, "get_note").into());
    }
    Value::Object(row)
}
