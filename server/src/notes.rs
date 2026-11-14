use crate::{
    AppState,
    auth::Identity,
    error::{ApiError, Result},
    items::{About, Written, guard_hidden, item_id, next_seq, record, settle_project},
    model::Activity,
};
use axum::{
    Extension, Json,
    extract::{Path, Query, State, rejection::QueryRejection},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sqlx::{FromRow, QueryBuilder, Sqlite, SqliteConnection, SqliteExecutor};

const BODY_LIMIT: usize = 100_000;

#[derive(Serialize, Clone, FromRow)]
pub struct Note {
    pub id: i64,
    pub body: String,
    pub project_id: Option<String>,
    pub pinned: bool,
    pub hidden_from_agents: bool,
    pub locked: bool,
    pub trashed: bool,
    pub version: i64,
    pub seq: i64,
    pub created_by: String,
    pub updated_by: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Default)]
#[serde(default, deny_unknown_fields)]
struct NoteInput {
    body: String,
    project_id: Option<String>,
    pinned: bool,
    hidden_from_agents: bool,
    locked: bool,
    trashed: bool,
}
impl From<&Note> for NoteInput {
    fn from(note: &Note) -> Self {
        Self {
            body: note.body.clone(),
            project_id: note.project_id.clone(),
            pinned: note.pinned,
            hidden_from_agents: note.hidden_from_agents,
            locked: note.locked,
            trashed: note.trashed,
        }
    }
}
impl NoteInput {
    // Rewrites the fields into the form that is stored. Running it again changes nothing. The
    // text keeps its spaces and blank lines: it is saved while it is being typed.
    fn validate(&mut self) -> Result<()> {
        self.body = self.body.replace("\r\n", "\n");
        if self.body.trim().is_empty() || self.body.chars().count() > BODY_LIMIT {
            return Err(ApiError::bad(
                "Write a note between 1 and 100,000 characters.",
            ));
        }
        if let Some(project) = &mut self.project_id {
            *project = project.trim().to_string();
            if project.is_empty() {
                self.project_id = None;
            }
        }
        Ok(())
    }
}

fn parse_input(fields: Map<String, Value>) -> Result<NoteInput> {
    serde_json::from_value(Value::Object(fields))
        .map_err(|e| ApiError::bad(format!("Invalid note fields: {e}")))
}

// An agent may lock a note, its own or one of the owner's: it is the one that knows what it wrote
// into it. Taking a lock off stays with the owner, so no agent can undo what the owner closed.
fn guard_unlock(before: &Note, input: &NoteInput, identity: &Identity) -> Result<()> {
    if !identity.is_human() && before.locked && !input.locked {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "Only the owner's own tokens can remove the lock of a note.".into(),
        ));
    }
    Ok(())
}

// The one place that decides whether a token may see a note, with the same rule as for items:
// a hidden note does not exist for an agent.
pub(crate) async fn visible_note<'e>(
    executor: impl SqliteExecutor<'e>,
    id: i64,
    identity: &Identity,
) -> Result<Note> {
    sqlx::query_as::<_, Note>("SELECT * FROM notes WHERE id = ? AND (? OR hidden_from_agents = 0)")
        .bind(id)
        .bind(identity.is_human())
        .fetch_optional(executor)
        .await?
        .ok_or_else(ApiError::missing)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Filters {
    q: Option<String>,
    project: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    #[serde(default)]
    trashed: bool,
}

// Pinned notes first, then by the last edit.
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
    // Written as literals so SQLite can match the partial index notes_listed.
    let mut query = QueryBuilder::<Sqlite>::new(if filters.trashed {
        "SELECT * FROM notes WHERE trashed = 1"
    } else {
        "SELECT * FROM notes WHERE trashed = 0"
    });
    if !identity.is_human() {
        query.push(" AND hidden_from_agents = 0");
    }
    match filters.project.as_deref() {
        None => {}
        Some("none") => {
            query.push(" AND project_id IS NULL");
        }
        Some(project) => {
            query
                .push(" AND project_id = ")
                .push_bind(project.to_string());
        }
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
            .push(" AND body LIKE ")
            .push_bind(pattern)
            .push(" ESCAPE '\\'");
    }
    query
        .push(" ORDER BY pinned DESC, updated_at DESC, id DESC LIMIT ")
        .push_bind(limit + 1)
        .push(" OFFSET ")
        .push_bind(offset);
    let mut notes = query.build_query_as::<Note>().fetch_all(&state.db).await?;
    let has_more = notes.len() as i64 > limit;
    notes.truncate(limit as usize);
    Ok(Json(json!({"notes": notes, "has_more": has_more})))
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
    // The history holds earlier texts of the note in full, so it is only sent when asked for.
    let entries = options.activity.unwrap_or(0);
    if !(0..=100).contains(&entries) {
        return Err(ApiError::bad("Ask for 0 to 100 activity entries."));
    }
    // One snapshot, so the note and its history belong to the same moment.
    let mut tx = state.db.begin().await?;
    let note = visible_note(&mut *tx, id, &identity).await?;
    let mut activity = sqlx::query_as::<_, Activity>(
        "SELECT id, actor_id, action, detail, created_at FROM activity \
         WHERE note_id = ? ORDER BY id DESC LIMIT ?",
    )
    .bind(id)
    .bind(entries + 1)
    .fetch_all(&mut *tx)
    .await?;
    let activity_has_more = activity.len() as i64 > entries;
    activity.truncate(entries as usize);
    Ok(Json(json!({
        "note": note,
        "activity": activity,
        "activity_has_more": activity_has_more,
    })))
}

pub(crate) async fn create(
    conn: &mut SqliteConnection,
    identity: &Identity,
    fields: Map<String, Value>,
) -> Result<Written> {
    guard_hidden(&fields, identity)?;
    let mut input = parse_input(fields)?;
    input.validate()?;
    settle_project(conn, &mut input.project_id).await?;
    let seq = next_seq(conn).await?;
    let note = sqlx::query_as::<_, Note>(
        "INSERT INTO notes(body, project_id, pinned, hidden_from_agents, locked, trashed, seq, \
         created_by, updated_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING *",
    )
    .bind(&input.body)
    .bind(&input.project_id)
    .bind(input.pinned)
    .bind(input.hidden_from_agents)
    .bind(input.locked)
    .bind(input.trashed)
    .bind(seq)
    .bind(&identity.actor.id)
    .bind(&identity.actor.id)
    .fetch_one(&mut *conn)
    .await?;
    record(
        conn,
        About::Note(note.id),
        &identity.actor.id,
        "created",
        json!({}),
    )
    .await?;
    Ok(Written {
        resource: "note",
        id: note.id.to_string(),
        body: json!(note),
    })
}

pub(crate) async fn update(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    mut fields: Map<String, Value>,
) -> Result<Written> {
    let before = visible_note(&mut *conn, id, identity).await?;
    guard_hidden(&fields, identity)?;
    // An append names no version: the text goes after whatever the note holds now, so two writers
    // cannot lose each other's lines, and a retry with the same key sends the same request.
    let version = if let Some(text) = fields.remove("append") {
        let text = text
            .as_str()
            .map(|text| text.replace("\r\n", "\n"))
            .filter(|text| !text.trim().is_empty())
            .ok_or_else(|| ApiError::bad("Send the text to append."))?;
        if !fields.is_empty() {
            return Err(ApiError::bad("An append takes no other fields."));
        }
        let mut body = before.body.clone();
        if !body.ends_with('\n') {
            body.push('\n');
        }
        body.push_str(&text);
        fields.insert("body".into(), Value::String(body));
        before.version
    } else {
        fields
            .remove("version")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| ApiError::bad("Include the version you read."))?
    };
    if fields.is_empty() {
        return Err(ApiError::bad("Include at least one field to change."));
    }
    if version != before.version {
        return Err(ApiError(
            StatusCode::CONFLICT,
            "This note changed. Read it again before saving.".into(),
        ));
    }
    // Lay the sent fields over the stored ones, then validate the whole note.
    let current = NoteInput::from(&before);
    let mut merged = match json!(current) {
        Value::Object(map) => map,
        _ => Map::new(),
    };
    merged.extend(fields);
    let mut input = parse_input(merged)?;
    input.validate()?;
    guard_unlock(&before, &input, identity)?;
    let written = |note: &Note| Written {
        resource: "note",
        id: id.to_string(),
        body: json!(note),
    };
    settle_project(conn, &mut input.project_id).await?;
    if input == current {
        return Ok(written(&before));
    }
    let action = match (before.trashed, input.trashed) {
        (false, true) => "trashed",
        (true, false) => "restored_from_trash",
        _ => "updated",
    };
    let seq = next_seq(conn).await?;
    let note = sqlx::query_as::<_, Note>(concat!("UPDATE notes SET body = ?, project_id = ?, pinned = ?, hidden_from_agents = ?, locked = ?, \
         trashed = ?, version = version + 1, seq = ?, updated_by = ?, updated_at = ", now!(), " \
         WHERE id = ? AND version = ? RETURNING *"))
    .bind(&input.body)
    .bind(&input.project_id)
    .bind(input.pinned)
    .bind(input.hidden_from_agents)
    .bind(input.locked)
    .bind(input.trashed)
    .bind(seq)
    .bind(&identity.actor.id)
    .bind(id)
    .bind(before.version)
    .fetch_one(&mut *conn)
    .await?;
    // The changed fields with their old and new value. For the text only the old one: the new
    // one is the note itself, or the "from" of the next change.
    let mut changes = Map::new();
    if let (Value::Object(old), Value::Object(new)) = (json!(current), json!(input)) {
        for (key, to) in new {
            let from = old.get(&key).cloned().unwrap_or(Value::Null);
            if from == to {
                continue;
            }
            let change = if key == "body" {
                json!({"from": from})
            } else {
                json!({"from": from, "to": to})
            };
            changes.insert(key, change);
        }
    }
    record(
        conn,
        About::Note(id),
        &identity.actor.id,
        action,
        json!({"changes": changes}),
    )
    .await?;
    Ok(written(&note))
}
