use crate::{
    AppState,
    auth::{Actor, Identity, hash},
    error::{ApiError, Result},
    images,
    model::{
        AGENT_SOURCES, Activity, Comment, HUMAN_SOURCES, Item, ItemInput, Project, STAGES,
        STATUSES, bound_key,
    },
    notes,
};
use axum::{
    Extension, Json,
    extract::{
        OriginalUri, Path, Query, State,
        rejection::{JsonRejection, QueryRejection},
    },
    http::{HeaderMap, Method, StatusCode},
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqliteExecutor};

pub(crate) const NOW: &str = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')";

pub async fn bootstrap(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Result<Json<Value>> {
    identity.require("read")?;
    let actors =
        sqlx::query_as::<_, Actor>("SELECT id, name, kind FROM actors ORDER BY kind DESC, name")
            .fetch_all(&state.db)
            .await?;
    let mut projects: Vec<(String, String, Option<String>)> =
        sqlx::query_as("SELECT id, name, icon FROM projects WHERE deleted = 0")
            .fetch_all(&state.db)
            .await?;
    // Sorted here because SQLite only folds ASCII letters.
    projects.sort_by_cached_key(|(_, name, _)| fold(name));
    let sources: &[&str] = if identity.is_human() {
        &HUMAN_SOURCES
    } else {
        &AGENT_SOURCES
    };
    Ok(Json(json!({
        "actor": identity.actor,
        "scopes": identity.scopes,
        "timezone": state.tz.name(),
        "actors": actors,
        "projects": projects.into_iter().map(|(id, name, icon)| json!({"id": id, "name": name, "icon": icon})).collect::<Vec<_>>(),
        "options": {
            "statuses": STATUSES,
            "priorities": [
                {"value": 0, "label": "None"},
                {"value": 1, "label": "Low"},
                {"value": 2, "label": "Medium"},
                {"value": 3, "label": "High"},
                {"value": 4, "label": "Urgent"}
            ],
            "agent_stages": STAGES,
            "created_via": sources,
            "repeat_rule": {
                "syntax": "FREQ=DAILY, WEEKLY, MONTHLY or YEARLY, then optional parts separated by semicolons: INTERVAL=1 to 999, BYDAY=MO,TU,WE,TH,FR,SA,SU (weekly only), BYMONTHDAY=1 to 31 (monthly only). The item needs a due_at.",
                "examples": ["FREQ=DAILY", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH", "FREQ=MONTHLY;BYMONTHDAY=31"]
            }
        }
    })))
}

// The one place that decides whether a token may see an item. A hidden item does not exist for
// an agent: reads and writes both answer 404.
pub(crate) async fn visible_item<'e>(
    executor: impl SqliteExecutor<'e>,
    id: i64,
    identity: &Identity,
) -> Result<Item> {
    sqlx::query_as::<_, Item>("SELECT * FROM items WHERE id = ? AND (? OR hidden_from_agents = 0)")
        .bind(id)
        .bind(identity.is_human())
        .fetch_optional(executor)
        .await?
        .ok_or_else(ApiError::missing)
}

// Digits only, no sign and no leading zero, so each item has exactly one address.
pub(crate) fn item_id(text: &str) -> Result<i64> {
    if text.starts_with('0') || !text.bytes().all(|c| c.is_ascii_digit()) {
        return Err(ApiError::missing());
    }
    text.parse().map_err(|_| ApiError::missing())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Filters {
    project: Option<String>,
    status: Option<String>,
    stage: Option<String>,
    tag: Option<String>,
    priority: Option<i64>,
    q: Option<String>,
    due_before: Option<String>,
    due_after: Option<String>,
    sort: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    #[serde(default)]
    archived: bool,
    #[serde(default)]
    trashed: bool,
}

pub async fn list(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    filters: std::result::Result<Query<Filters>, QueryRejection>,
) -> Result<Json<Value>> {
    identity.require("read")?;
    let Query(filters) = filters.map_err(|e| ApiError::bad(e.body_text()))?;
    let limit = filters.limit.unwrap_or(50);
    let offset = filters.offset.unwrap_or(0);
    if !(1..=200).contains(&limit) || !(0..=1_000_000).contains(&offset) {
        return Err(ApiError::bad(
            "Use a limit from 1 to 200 and an offset from 0 to 1000000.",
        ));
    }
    let windowed = filters.due_after.is_some() || filters.due_before.is_some();
    let order = match filters.sort.as_deref().unwrap_or("newest") {
        "newest" => "id DESC",
        "oldest" => "id ASC",
        "edited" => "updated_at DESC, id DESC",
        // Inside a due window every row has a date, and this order is the one items_due has.
        "due" if windowed => "due_utc ASC, id ASC",
        "due" => "due_utc IS NULL, due_utc ASC, id ASC",
        "priority" => "priority DESC, due_utc IS NULL, due_utc ASC, id ASC",
        "manual" => "position DESC, id DESC",
        "title" => "title COLLATE NOCASE ASC, id ASC",
        _ => {
            return Err(ApiError::bad(
                "Sort by newest, oldest, edited, due, priority, manual or title.",
            ));
        }
    };
    // Trash is one place across archive states. Everything else is either active or archived.
    // These conditions are written as literals so SQLite can match them to the partial indexes.
    let mut query = QueryBuilder::<Sqlite>::new(if filters.trashed {
        "SELECT * FROM items WHERE trashed = 1"
    } else if filters.archived {
        "SELECT * FROM items WHERE trashed = 0 AND archived = 1"
    } else {
        "SELECT * FROM items WHERE trashed = 0 AND archived = 0"
    });
    if !identity.is_human() {
        query.push(" AND hidden_from_agents = 0");
    }
    match filters.status.as_deref() {
        None => {}
        Some("open") => {
            query.push(" AND status <> 'done'");
        }
        Some("done") => {
            query.push(" AND status = 'done'");
        }
        Some(status @ ("todo" | "doing")) => {
            query
                .push(" AND status <> 'done' AND status = ")
                .push_bind(status.to_string());
        }
        Some(_) => return Err(ApiError::bad("Status is open, todo, doing or done.")),
    }
    match filters.project.as_deref() {
        None => {}
        Some("inbox") => {
            query.push(" AND project_id IS NULL");
        }
        Some(project) => {
            query
                .push(" AND project_id = ")
                .push_bind(project.to_string());
        }
    }
    if let Some(stage) = &filters.stage {
        if !STAGES.contains(&stage.as_str()) {
            return Err(ApiError::bad("Unknown agent stage."));
        }
        query.push(" AND agent_stage = ").push_bind(stage.clone());
    }
    if let Some(priority) = filters.priority {
        if !(0..=4).contains(&priority) {
            return Err(ApiError::bad("Priority is a number from 0 to 4."));
        }
        query.push(" AND priority = ").push_bind(priority);
    }
    if let Some(tag) = &filters.tag {
        query
            .push(" AND EXISTS (SELECT 1 FROM json_each(items.tags) WHERE value = ")
            .push_bind(tag.trim().trim_start_matches('#').to_lowercase())
            .push(")");
    }
    if let Some(text) = filters
        .q
        .as_deref()
        .map(str::trim)
        .filter(|q| !q.is_empty())
    {
        let pattern = format!(
            "%{}%",
            text.replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_")
        );
        query
            .push(" AND (title LIKE ")
            .push_bind(pattern.clone())
            .push(" ESCAPE '\\' OR description LIKE ")
            .push_bind(pattern)
            .push(" ESCAPE '\\')");
    }
    for (bound, comparison) in [
        (&filters.due_after, " AND due_utc >= "),
        (&filters.due_before, " AND due_utc < "),
    ] {
        if let Some(text) = bound {
            let key = bound_key(text.trim(), state.tz).ok_or_else(|| {
                ApiError::bad("Write due_after and due_before as a date or a time.")
            })?;
            query.push(comparison).push_bind(key);
        }
    }
    query
        .push(format!(" ORDER BY {order} LIMIT "))
        .push_bind(limit + 1)
        .push(" OFFSET ")
        .push_bind(offset);
    let mut items = query.build_query_as::<Item>().fetch_all(&state.db).await?;
    let has_more = items.len() as i64 > limit;
    items.truncate(limit as usize);
    Ok(Json(json!({"items": items, "has_more": has_more})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DetailOptions {
    activity: Option<i64>,
}

pub async fn detail(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    options: std::result::Result<Query<DetailOptions>, QueryRejection>,
) -> Result<Json<Value>> {
    identity.require("read")?;
    let id = item_id(&id)?;
    let Query(options) = options.map_err(|e| ApiError::bad(e.body_text()))?;
    // The history is the bulky part, so a reader asks for as much of it as it needs.
    let entries = options.activity.unwrap_or(20);
    if !(0..=100).contains(&entries) {
        return Err(ApiError::bad("Ask for 0 to 100 activity entries."));
    }
    // One snapshot, so the item and its history belong to the same moment.
    let mut tx = state.db.begin().await?;
    let item = visible_item(&mut *tx, id, &identity).await?;
    let comments =
        sqlx::query_as::<_, Comment>("SELECT * FROM comments WHERE item_id = ? ORDER BY id")
            .bind(id)
            .fetch_all(&mut *tx)
            .await?;
    let mut activity = sqlx::query_as::<_, Activity>(
        "SELECT id, actor_id, action, detail, created_at FROM activity \
         WHERE item_id = ? ORDER BY id DESC LIMIT ?",
    )
    .bind(id)
    .bind(entries + 1)
    .fetch_all(&mut *tx)
    .await?;
    let activity_has_more = activity.len() as i64 > entries;
    activity.truncate(entries as usize);
    Ok(Json(json!({
        "item": item,
        "comments": comments,
        "activity": activity,
        "activity_has_more": activity_has_more,
    })))
}

pub(crate) async fn next_seq(conn: &mut SqliteConnection) -> Result<i64> {
    Ok(
        sqlx::query_scalar("UPDATE meta SET value = value + 1 WHERE key = 'seq' RETURNING value")
            .fetch_one(conn)
            .await?,
    )
}

// The row an activity entry is about.
pub(crate) enum About {
    Item(i64),
    Note(i64),
    Nothing,
}

pub(crate) async fn record(
    conn: &mut SqliteConnection,
    about: About,
    actor: &str,
    action: &str,
    detail: Value,
) -> Result<()> {
    let (item, note) = match about {
        About::Item(id) => (Some(id), None),
        About::Note(id) => (None, Some(id)),
        About::Nothing => (None, None),
    };
    sqlx::query(
        "INSERT INTO activity(item_id, note_id, actor_id, action, detail) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(item)
    .bind(note)
    .bind(actor)
    .bind(action)
    .bind(detail.to_string())
    .execute(conn)
    .await?;
    Ok(())
}

// An agent may not send the switch at all, so it can neither hide nor reveal an item.
pub(crate) fn guard_hidden(fields: &Map<String, Value>, identity: &Identity) -> Result<()> {
    if !identity.is_human() && fields.contains_key("hidden_from_agents") {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "Only the owner's own tokens can set hidden_from_agents.".into(),
        ));
    }
    Ok(())
}

fn parse_input(fields: Map<String, Value>) -> Result<ItemInput> {
    serde_json::from_value(Value::Object(fields))
        .map_err(|e| ApiError::bad(format!("Invalid item fields: {e}")))
}

// Checks the project a write names. A project that was deleted sends the row to the inbox, as it
// did with the rows it held: a client that was offline may still file into it, and what it
// captured must not be refused for that.
pub(crate) async fn settle_project(
    conn: &mut SqliteConnection,
    project: &mut Option<String>,
) -> Result<()> {
    let Some(id) = project.as_deref() else {
        return Ok(());
    };
    let deleted: Option<bool> = sqlx::query_scalar("SELECT deleted FROM projects WHERE id = ?")
        .bind(id)
        .fetch_optional(conn)
        .await?;
    match deleted {
        Some(false) => {}
        Some(true) => *project = None,
        None => {
            return Err(ApiError::bad(
                "Choose an existing project ID, or leave project_id empty for the inbox.",
            ));
        }
    }
    Ok(())
}

// What a write produced. The idempotency table keeps the kind and ID, never a copy of the row.
pub(crate) struct Written {
    pub resource: &'static str,
    pub id: String,
    pub body: Value,
}

async fn create_item(
    conn: &mut SqliteConnection,
    state: &AppState,
    identity: &Identity,
    mut fields: Map<String, Value>,
) -> Result<Written> {
    guard_hidden(&fields, identity)?;
    // Items the owner captures wait for triage. Items an agent adds are not triaged.
    let (allowed, default, stage): (&[&str], &str, &str) = if identity.is_human() {
        (&HUMAN_SOURCES, "app", "new")
    } else {
        (&AGENT_SOURCES, "mcp", "none")
    };
    let via = match fields.remove("created_via") {
        None | Some(Value::Null) => default.to_string(),
        Some(Value::String(via)) if allowed.contains(&via.as_str()) => via,
        Some(_) => {
            return Err(ApiError::bad(format!(
                "created_via is one of {} for this token.",
                allowed.join(", ")
            )));
        }
    };
    let mut input = parse_input(fields)?;
    let derived = input.validate(state.tz)?;
    if input.status == "done" && input.repeat_rule.is_some() {
        return Err(ApiError::bad("A repeating item cannot be created as done."));
    }
    settle_project(conn, &mut input.project_id).await?;
    let seq = next_seq(conn).await?;
    let item = sqlx::query_as::<_, Item>(&format!(
        "INSERT INTO items(title, description, status, project_id, priority, position, tags, \
         checklist, due_at, due_tz, due_utc, remind_at, remind_utc, repeat_rule, agent_stage, \
         hidden_from_agents, created_via, source_url, archived, trashed, completed_at, seq, \
         created_by, updated_by) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \
         CASE WHEN ? = 'done' THEN {NOW} END, ?, ?, ?) RETURNING *"
    ))
    .bind(&input.title)
    .bind(&input.description)
    .bind(&input.status)
    .bind(&input.project_id)
    .bind(input.priority)
    // Sequence numbers only grow, so an item without a position lands on top of its list.
    .bind(input.position.unwrap_or(seq as f64))
    .bind(json!(input.tags).to_string())
    .bind(json!(input.checklist).to_string())
    .bind(&input.due_at)
    .bind(&input.due_tz)
    .bind(&derived.due_utc)
    .bind(&input.remind_at)
    .bind(&derived.remind_utc)
    .bind(&input.repeat_rule)
    .bind(stage)
    .bind(input.hidden_from_agents)
    .bind(&via)
    .bind(&input.source_url)
    .bind(input.archived)
    .bind(input.trashed)
    .bind(&input.status)
    .bind(seq)
    .bind(&identity.actor.id)
    .bind(&identity.actor.id)
    .fetch_one(&mut *conn)
    .await?;
    record(
        conn,
        About::Item(item.id),
        &identity.actor.id,
        "created",
        json!({"created_via": via}),
    )
    .await?;
    Ok(Written {
        resource: "item",
        id: item.id.to_string(),
        body: json!(item),
    })
}

async fn update_item(
    conn: &mut SqliteConnection,
    state: &AppState,
    identity: &Identity,
    id: i64,
    mut fields: Map<String, Value>,
) -> Result<Written> {
    let before = visible_item(&mut *conn, id, identity).await?;
    guard_hidden(&fields, identity)?;
    let version = fields
        .remove("version")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| ApiError::bad("Include the version you read."))?;
    if fields.is_empty() {
        return Err(ApiError::bad("Include at least one field to change."));
    }
    if version != before.version {
        return Err(ApiError::conflict());
    }
    // Lay the sent fields over the stored ones, then validate the whole item.
    let current = ItemInput::from(&before);
    let mut merged = match json!(current) {
        Value::Object(map) => map,
        _ => Map::new(),
    };
    merged.extend(fields);
    let mut input = parse_input(merged)?;
    // A null position keeps the stored one: every item has a place in its list.
    input.position = input.position.or(current.position);
    let mut derived = input.validate(state.tz)?;
    let written = |item: &Item| Written {
        resource: "item",
        id: id.to_string(),
        body: json!(item),
    };
    settle_project(conn, &mut input.project_id).await?;
    if input == current {
        return Ok(written(&before));
    }
    // A repeating item is never done: marking it done moves it to its next occurrence.
    let completes = input.status == "done" && before.status != "done";
    let repeats = input.status == "done" && input.repeat_rule.is_some();
    if repeats {
        input.advance(chrono::Utc::now())?;
        derived = input.validate(state.tz)?;
    }
    let action = if before.trashed != input.trashed {
        if input.trashed {
            "trashed"
        } else {
            "restored_from_trash"
        }
    } else if before.archived != input.archived {
        if input.archived {
            "archived"
        } else {
            "restored"
        }
    } else if repeats {
        "completed_occurrence"
    } else if completes {
        "completed"
    } else if before.status == "done" && input.status != "done" {
        "reopened"
    } else {
        "updated"
    };
    let seq = next_seq(conn).await?;
    let item = sqlx::query_as::<_, Item>(&format!(
        "UPDATE items SET title = ?, description = ?, status = ?, project_id = ?, priority = ?, \
         position = ?, tags = ?, checklist = ?, due_at = ?, due_tz = ?, due_utc = ?, remind_at = ?, \
         remind_utc = ?, repeat_rule = ?, hidden_from_agents = ?, source_url = ?, archived = ?, \
         trashed = ?, \
         completed_at = CASE WHEN ? <> 'done' THEN NULL WHEN status = 'done' THEN completed_at ELSE {NOW} END, \
         version = version + 1, seq = ?, updated_by = ?, updated_at = {NOW} \
         WHERE id = ? AND version = ? RETURNING *"
    ))
    .bind(&input.title)
    .bind(&input.description)
    .bind(&input.status)
    .bind(&input.project_id)
    .bind(input.priority)
    .bind(input.position)
    .bind(json!(input.tags).to_string())
    .bind(json!(input.checklist).to_string())
    .bind(&input.due_at)
    .bind(&input.due_tz)
    .bind(&derived.due_utc)
    .bind(&input.remind_at)
    .bind(&derived.remind_utc)
    .bind(&input.repeat_rule)
    .bind(input.hidden_from_agents)
    .bind(&input.source_url)
    .bind(input.archived)
    .bind(input.trashed)
    .bind(&input.status)
    .bind(seq)
    .bind(&identity.actor.id)
    .bind(id)
    .bind(before.version)
    .fetch_optional(&mut *conn)
    .await?
    .ok_or_else(ApiError::conflict)?;
    // Only the changed fields, each with its old and new value.
    let mut changes = Map::new();
    if let (Value::Object(old), Value::Object(new)) = (json!(current), json!(input)) {
        for (key, to) in new {
            let from = old.get(&key).cloned().unwrap_or(Value::Null);
            if from != to {
                changes.insert(key, json!({"from": from, "to": to}));
            }
        }
    }
    record(
        conn,
        About::Item(id),
        &identity.actor.id,
        action,
        json!({"changes": changes}),
    )
    .await?;
    Ok(written(&item))
}

async fn add_comment(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    fields: Map<String, Value>,
) -> Result<Written> {
    let trashed: Option<bool> = sqlx::query_scalar(
        "SELECT trashed FROM items WHERE id = ? AND (? OR hidden_from_agents = 0)",
    )
    .bind(id)
    .bind(identity.is_human())
    .fetch_optional(&mut *conn)
    .await?;
    if trashed.ok_or_else(ApiError::missing)? {
        return Err(ApiError::bad(
            "This item is in the trash. Restore it before commenting.",
        ));
    }
    let body = match (fields.len(), fields.get("body")) {
        (1, Some(Value::String(body))) => body.replace("\r\n", "\n").trim().to_string(),
        _ => return Err(ApiError::bad("Send only the comment body.")),
    };
    if body.is_empty() || body.chars().count() > 10_000 {
        return Err(ApiError::bad(
            "Write a comment between 1 and 10,000 characters.",
        ));
    }
    let seq = next_seq(conn).await?;
    let comment = sqlx::query_as::<_, Comment>(
        "INSERT INTO comments(item_id, author_id, body, seq) VALUES (?, ?, ?, ?) RETURNING *",
    )
    .bind(id)
    .bind(&identity.actor.id)
    .bind(body)
    .bind(seq)
    .fetch_one(&mut *conn)
    .await?;
    record(
        conn,
        About::Item(id),
        &identity.actor.id,
        "commented",
        json!({"comment_id": comment.id}),
    )
    .await?;
    Ok(Written {
        resource: "comment",
        id: comment.id.to_string(),
        body: json!(comment),
    })
}

const SLUG_LENGTH: usize = 40;

// A readable ID such as "home-lab", made from the name. "inbox" stays free for the list filter.
fn slug(name: &str) -> String {
    let mut text = String::new();
    for c in name.to_lowercase().chars() {
        match c {
            'a'..='z' | '0'..='9' => text.push(c),
            'ä' => text.push_str("ae"),
            'ö' => text.push_str("oe"),
            'ü' => text.push_str("ue"),
            'ß' => text.push_str("ss"),
            'à' | 'á' | 'â' => text.push('a'),
            'è' | 'é' | 'ê' | 'ë' => text.push('e'),
            'ì' | 'í' | 'î' | 'ï' => text.push('i'),
            'ò' | 'ó' | 'ô' => text.push('o'),
            'ù' | 'ú' | 'û' => text.push('u'),
            'ç' => text.push('c'),
            _ if !text.ends_with('-') => text.push('-'),
            _ => {}
        }
    }
    let text: String = text.trim_matches('-').chars().take(SLUG_LENGTH).collect();
    let text = text.trim_end_matches('-');
    if text.is_empty() || text == "inbox" {
        "project".into()
    } else {
        text.into()
    }
}

// Names are compared without case. Going through upper case also pairs ß and ẞ with SS.
fn fold(name: &str) -> String {
    name.to_lowercase().to_uppercase().to_lowercase()
}

fn project_name(value: &Value) -> Result<String> {
    let name = match value {
        Value::String(name) => name.split_whitespace().collect::<Vec<_>>().join(" "),
        _ => String::new(),
    };
    if name.is_empty() || name.chars().count() > 80 || name.chars().any(char::is_control) {
        return Err(ApiError::bad(
            "Use a project name between 1 and 80 characters.",
        ));
    }
    Ok(name)
}

// The name of a symbol, such as "house" or "server.rack". The app decides what it can draw;
// the server only keeps the text in shape. Null takes the icon away.
fn project_icon(value: &Value) -> Result<Option<String>> {
    match value {
        Value::Null => Ok(None),
        Value::String(icon)
            if (1..=64).contains(&icon.len())
                && icon
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.') =>
        {
            Ok(Some(icon.clone()))
        }
        _ => Err(ApiError::bad(
            "Use a symbol name of up to 64 lowercase letters, digits and dots as the icon, or null.",
        )),
    }
}

// The app sends the ID it already files items under, so a project made without a connection
// keeps its ID. It has the shape of a slug.
fn project_id(value: &Value) -> Result<String> {
    match value {
        Value::String(id)
            if (1..=SLUG_LENGTH).contains(&id.len())
                && id != "inbox"
                && !id.starts_with('-')
                && !id.ends_with('-')
                && id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') =>
        {
            Ok(id.clone())
        }
        _ => Err(ApiError::bad(
            "Use a project ID of up to 40 lowercase letters, digits and hyphens, other than \"inbox\".",
        )),
    }
}

async fn create_project(
    conn: &mut SqliteConnection,
    identity: &Identity,
    fields: Map<String, Value>,
) -> Result<Written> {
    if fields
        .keys()
        .any(|key| !matches!(key.as_str(), "name" | "icon" | "id"))
    {
        return Err(ApiError::bad(
            "A project takes a name, and optionally an icon and an ID.",
        ));
    }
    let name = project_name(fields.get("name").unwrap_or(&Value::Null))?;
    let icon = fields.get("icon").map(project_icon).transpose()?.flatten();
    let wanted = fields.get("id").map(project_id).transpose()?;
    // A deleted project gives its name back, but never its ID: a change that another device
    // still has queued for the old project must not reach a new one.
    let existing: Vec<(String, String, bool)> =
        sqlx::query_as("SELECT id, name, deleted FROM projects")
            .fetch_all(&mut *conn)
            .await?;
    let folded = fold(&name);
    if existing
        .iter()
        .any(|(_, saved, deleted)| !deleted && fold(saved) == folded)
    {
        return Err(ApiError::bad("A project with this name already exists."));
    }
    let id = match wanted {
        Some(id) if existing.iter().any(|(taken, _, _)| *taken == id) => {
            return Err(ApiError::bad("A project with this ID already exists."));
        }
        Some(id) => id,
        None => {
            // A taken slug gets -2, -3 and so on, shortened so the ID keeps its length limit.
            let base = slug(&name);
            (1..)
                .map(|n| {
                    if n == 1 {
                        return base.clone();
                    }
                    let suffix = format!("-{n}");
                    let stem: String = base.chars().take(SLUG_LENGTH - suffix.len()).collect();
                    format!("{}{suffix}", stem.trim_end_matches('-'))
                })
                .find(|candidate| existing.iter().all(|(id, _, _)| id != candidate))
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string())
        }
    };
    let seq = next_seq(conn).await?;
    let project = sqlx::query_as::<_, Project>(
        "INSERT INTO projects(id, name, icon, seq) VALUES (?, ?, ?, ?) RETURNING *",
    )
    .bind(&id)
    .bind(&name)
    .bind(&icon)
    .bind(seq)
    .fetch_one(&mut *conn)
    .await?;
    record(
        conn,
        About::Nothing,
        &identity.actor.id,
        "project_created",
        json!({"id": id, "name": name, "icon": icon}),
    )
    .await?;
    Ok(Written {
        resource: "project",
        id,
        body: json!(project),
    })
}

// A new name or icon. The ID stays, so items and notes keep their project. There is no
// version to check: the later edit wins.
async fn update_project(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: &str,
    fields: Map<String, Value>,
) -> Result<Written> {
    if fields.is_empty()
        || fields
            .keys()
            .any(|key| !matches!(key.as_str(), "name" | "icon"))
    {
        return Err(ApiError::bad("Send a name, an icon or both."));
    }
    let current =
        sqlx::query_as::<_, Project>("SELECT * FROM projects WHERE id = ? AND deleted = 0")
            .bind(id)
            .fetch_optional(&mut *conn)
            .await?
            .ok_or_else(ApiError::missing)?;
    let name = match fields.get("name") {
        Some(value) => project_name(value)?,
        None => current.name.clone(),
    };
    let icon = match fields.get("icon") {
        Some(value) => project_icon(value)?,
        None => current.icon.clone(),
    };
    if name == current.name && icon == current.icon {
        return Ok(Written {
            resource: "project",
            id: current.id.clone(),
            body: json!(current),
        });
    }
    let folded = fold(&name);
    let taken: Vec<(String, String)> =
        sqlx::query_as("SELECT id, name FROM projects WHERE id <> ? AND deleted = 0")
            .bind(id)
            .fetch_all(&mut *conn)
            .await?;
    if taken.iter().any(|(_, saved)| fold(saved) == folded) {
        return Err(ApiError::bad("A project with this name already exists."));
    }
    let seq = next_seq(conn).await?;
    let project = sqlx::query_as::<_, Project>(
        "UPDATE projects SET name = ?, icon = ?, seq = ? WHERE id = ? RETURNING *",
    )
    .bind(&name)
    .bind(&icon)
    .bind(seq)
    .bind(id)
    .fetch_one(&mut *conn)
    .await?;
    record(
        conn,
        About::Nothing,
        &identity.actor.id,
        "project_updated",
        json!({"id": id, "name": name, "icon": icon}),
    )
    .await?;
    Ok(Written {
        resource: "project",
        id: id.to_string(),
        body: json!(project),
    })
}

// Deleting a project files what it held into the inbox: every item and note of it loses the
// project in a write of its own, so the changes feed tells each client. The project's row stays
// with deleted = 1 for the same reason. Hidden rows move too, also when an agent deletes: it gets
// the project's row back and nothing about them.
async fn delete_project(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: &str,
    fields: Map<String, Value>,
) -> Result<Written> {
    if !fields.is_empty() {
        return Err(ApiError::bad("A delete takes no fields."));
    }
    let name: String = sqlx::query_scalar("SELECT name FROM projects WHERE id = ? AND deleted = 0")
        .bind(id)
        .fetch_optional(&mut *conn)
        .await?
        .ok_or_else(ApiError::missing)?;
    let actor = &identity.actor.id;
    let moved = json!({"changes": {"project_id": {"from": id, "to": null}}});
    let items: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM items WHERE project_id = ? ORDER BY id")
            .bind(id)
            .fetch_all(&mut *conn)
            .await?;
    for item in &items {
        let seq = next_seq(conn).await?;
        sqlx::query(&format!(
            "UPDATE items SET project_id = NULL, version = version + 1, seq = ?, updated_by = ?, \
             updated_at = {NOW} WHERE id = ?"
        ))
        .bind(seq)
        .bind(actor)
        .bind(item)
        .execute(&mut *conn)
        .await?;
        record(conn, About::Item(*item), actor, "updated", moved.clone()).await?;
    }
    let notes: Vec<i64> =
        sqlx::query_scalar("SELECT id FROM notes WHERE project_id = ? ORDER BY id")
            .bind(id)
            .fetch_all(&mut *conn)
            .await?;
    for note in &notes {
        let seq = next_seq(conn).await?;
        // The time of the last edit stays: Notes is sorted by it, and the text did not change.
        sqlx::query(
            "UPDATE notes SET project_id = NULL, version = version + 1, seq = ?, updated_by = ? \
             WHERE id = ?",
        )
        .bind(seq)
        .bind(actor)
        .bind(note)
        .execute(&mut *conn)
        .await?;
        record(conn, About::Note(*note), actor, "updated", moved.clone()).await?;
    }
    let seq = next_seq(conn).await?;
    let project = sqlx::query_as::<_, Project>(
        "UPDATE projects SET deleted = 1, seq = ? WHERE id = ? RETURNING *",
    )
    .bind(seq)
    .bind(id)
    .fetch_one(&mut *conn)
    .await?;
    record(
        conn,
        About::Nothing,
        actor,
        "project_deleted",
        json!({"id": id, "name": name, "items": items.len(), "notes": notes.len()}),
    )
    .await?;
    Ok(Written {
        resource: "project",
        id: id.to_string(),
        body: json!(project),
    })
}

// A retry gets the row as it is now, through the same visibility check as any other read.
// So an item the owner hid in the meantime answers 404 to an agent, and no response copy is stored.
async fn replay(
    conn: &mut SqliteConnection,
    identity: &Identity,
    resource: &str,
    id: &str,
) -> Result<Value> {
    match resource {
        "item" => Ok(json!(
            visible_item(&mut *conn, item_id(id)?, identity).await?
        )),
        "comment" => sqlx::query_as::<_, Comment>(
            "SELECT c.* FROM comments c JOIN items i ON i.id = c.item_id \
             WHERE c.id = ? AND (? OR i.hidden_from_agents = 0)",
        )
        .bind(item_id(id)?)
        .bind(identity.is_human())
        .fetch_optional(&mut *conn)
        .await?
        .map(|comment| json!(comment))
        .ok_or_else(ApiError::missing),
        "note" => Ok(json!(
            notes::visible_note(&mut *conn, item_id(id)?, identity).await?
        )),
        _ => sqlx::query_as::<_, Project>("SELECT * FROM projects WHERE id = ?")
            .bind(id)
            .fetch_optional(&mut *conn)
            .await?
            .map(|project| json!(project))
            .ok_or_else(ApiError::missing),
    }
}

// What a write answers. A token without the read scope, such as the capture Shortcut, only gets
// a receipt. Otherwise an edit or a retry would hand it the stored row.
fn answer(identity: &Identity, resource: &str, body: Value) -> Value {
    if identity.scopes.iter().any(|scope| scope == "read") {
        return body;
    }
    let keep: &[&str] = match resource {
        "item" | "note" => &["id", "version"],
        "comment" => &["id", "item_id"],
        _ => &["id"],
    };
    Value::Object(
        keep.iter()
            .filter_map(|key| Some((key.to_string(), body.get(*key)?.clone())))
            .collect(),
    )
}

// Every write goes through here: one writer at a time, one transaction, and an idempotency key
// so a retry does not write twice.
pub async fn write(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    method: Method,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
    payload: std::result::Result<Json<Value>, JsonRejection>,
) -> Result<Json<Value>> {
    identity.require("write")?;
    let path = uri.path();
    let segments: Vec<&str> = path.trim_start_matches("/api/").split('/').collect();
    let is_upload = matches!(segments.as_slice(), ["items", _, "images"]);
    let fields = match payload {
        Ok(Json(Value::Object(fields))) => fields,
        // A delete has nothing to send, so it may come without a body.
        Err(JsonRejection::MissingJsonContentType(_)) if method == Method::DELETE => Map::new(),
        Err(rejection) if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE => {
            return Err(ApiError(
                StatusCode::PAYLOAD_TOO_LARGE,
                if is_upload {
                    "An image can be at most 5 MB.".into()
                } else {
                    "The request body is larger than 1 MB.".into()
                },
            ));
        }
        _ => {
            return Err(ApiError::bad(
                "Send a JSON object with Content-Type: application/json.",
            ));
        }
    };
    let key = headers
        .get("idempotency-key")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty() && s.len() <= 128)
        .ok_or_else(|| ApiError::bad("Send an Idempotency-Key header of 1 to 128 characters."))?;
    // An image is decoded and checked here, before the writer lock: megabytes of base64 must
    // not keep other writes waiting. Its hash stands for the body in the fingerprint.
    let (upload, fields) = if is_upload {
        (Some(images::prepare(fields)?), Map::new())
    } else {
        (None, fields)
    };
    let fingerprint = match &upload {
        Some(upload) => hash(&format!("{method} {path} {}", upload.sha256)),
        None => hash(&format!(
            "{method} {path} {}",
            Value::Object(fields.clone())
        )),
    };
    let actor = &identity.actor.id;
    let _guard = state.writer.lock().await;
    // IMMEDIATE takes the write lock at the start. A deferred transaction that reads first can
    // fail with "database is locked" when another connection writes before it does.
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let saved: Option<(String, String, String)> = sqlx::query_as(
        "SELECT fingerprint, resource, resource_id FROM idempotency WHERE actor_id = ? AND key = ?",
    )
    .bind(actor)
    .bind(key)
    .fetch_optional(&mut *tx)
    .await?;
    if let Some((previous, resource, id)) = saved {
        if previous != fingerprint {
            return Err(ApiError::bad(
                "This idempotency key was already used for another request.",
            ));
        }
        let body = replay(&mut tx, &identity, &resource, &id).await?;
        return Ok(Json(answer(&identity, &resource, body)));
    }
    let written = match segments.as_slice() {
        ["items"] => create_item(&mut tx, &state, &identity, fields).await?,
        ["items", id] => update_item(&mut tx, &state, &identity, item_id(id)?, fields).await?,
        ["items", id, "comments"] => add_comment(&mut tx, &identity, item_id(id)?, fields).await?,
        ["items", id, "images"] => {
            let upload = upload.ok_or_else(ApiError::missing)?;
            images::add(&mut tx, &identity, item_id(id)?, upload).await?
        }
        ["items", id, "images", image] => {
            images::remove(&mut tx, &identity, item_id(id)?, item_id(image)?, fields).await?
        }
        ["projects"] => create_project(&mut tx, &identity, fields).await?,
        ["projects", id] if method == Method::DELETE => {
            delete_project(&mut tx, &identity, id, fields).await?
        }
        ["projects", id] => update_project(&mut tx, &identity, id, fields).await?,
        ["notes"] => notes::create(&mut tx, &identity, fields).await?,
        ["notes", id] => notes::update(&mut tx, &identity, item_id(id)?, fields).await?,
        _ => return Err(ApiError::missing()),
    };
    sqlx::query(
        "INSERT INTO idempotency(actor_id, key, fingerprint, resource, resource_id) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(actor)
    .bind(key)
    .bind(fingerprint)
    .bind(written.resource)
    .bind(&written.id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    // After the commit and not for a retry that wrote nothing: the other devices are asked to
    // sync what is now stored.
    state.push.changed(identity.device.as_deref());
    Ok(Json(answer(&identity, written.resource, written.body)))
}
