// The agents of this server as the owner's devices see them: who they are, when their tokens
// were last used, what they did today, and the latest status report each one sent.
use crate::{
    AppState,
    auth::Identity,
    error::{ApiError, Result},
    report::{Report, SCHEMA},
};
use axum::{
    Extension, Json,
    extract::{State, rejection::JsonRejection},
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};
use sqlx::Row;
use std::collections::HashMap;

// A report is bounded before it is stored, so this only keeps out bodies far beyond any report.
pub const BODY_LIMIT: usize = 256 * 1024;
// A clock ahead by more than this is not trusted for the report's time.
const CLOCK_SLACK_MINUTES: i64 = 5;

// An agent sends its own report; the actor is the token's. The owner's tokens cannot send one,
// because a report describes an agent.
pub async fn put_report(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    payload: std::result::Result<Json<Report>, JsonRejection>,
) -> Result<Json<Value>> {
    identity.require("report")?;
    if identity.is_human() {
        return Err(ApiError::forbidden());
    }
    let Json(report) = payload.map_err(|rejection| {
        ApiError::bad(format!(
            "Send a status report as pendenz report makes it: {}",
            rejection.body_text()
        ))
    })?;
    if report.schema != SCHEMA {
        return Err(ApiError::bad(format!(
            "This server takes reports with schema {SCHEMA}."
        )));
    }
    let report = report.bounded();
    // A clock far ahead would make every later report look older than this one.
    if report.sent_at > Utc::now() + Duration::minutes(CLOCK_SLACK_MINUTES) {
        return Err(ApiError::bad(
            "The report's time is ahead of the server's clock. Check the agent machine's clock.",
        ));
    }
    let body = serde_json::to_string(&report).map_err(|_| ApiError::bad("Unreadable report."))?;
    let sent_at = report
        .sent_at
        .to_rfc3339_opts(chrono::SecondsFormat::Nanos, true);

    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    // The agent may have been revoked while this request waited for the lock, and its report
    // removed: it must not come back.
    let allowed: bool = sqlx::query_scalar(concat!(
        "SELECT EXISTS(SELECT 1 FROM tokens WHERE actor_id = ? AND revoked = 0 \
         AND (',' || scopes || ',') LIKE '%,report,%' \
         AND (expires_at IS NULL OR expires_at > ",
        now!(),
        "))"
    ))
    .bind(&identity.actor.id)
    .fetch_one(&mut *tx)
    .await?;
    if !allowed {
        return Err(ApiError::unauthorized());
    }
    // A report that arrives after a newer one, such as a retry, does not replace it.
    let stored: Option<(String, String)> =
        sqlx::query_as("SELECT sent_at, received_at FROM agent_reports WHERE actor_id = ?")
            .bind(&identity.actor.id)
            .fetch_optional(&mut *tx)
            .await?;
    let older = |stored: &str| {
        DateTime::parse_from_rfc3339(stored).is_ok_and(|stored| stored >= report.sent_at)
    };
    if let Some((stored_sent, received_at)) = &stored
        && older(stored_sent)
    {
        return Ok(Json(json!({"received_at": received_at, "kept": "newer"})));
    }
    let received_at: String = sqlx::query_scalar(concat!(
        "INSERT INTO agent_reports(actor_id, body, sent_at) VALUES (?, ?, ?) \
         ON CONFLICT(actor_id) DO UPDATE SET body = excluded.body, sent_at = excluded.sent_at, \
         received_at = ",
        now!(),
        " RETURNING received_at"
    ))
    .bind(&identity.actor.id)
    .bind(&body)
    .bind(&sent_at)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(json!({"received_at": received_at})))
}

fn require_owner_read(identity: &Identity) -> Result<()> {
    if !identity.is_human() {
        return Err(ApiError::forbidden());
    }
    identity.require("read")
}

// Every agent, with its report when it sent one. Agents never see this: a report holds what an
// agent spends and what runs on its machine.
pub async fn list(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Result<Json<Value>> {
    require_owner_read(&identity)?;
    let mut conn = state.db.acquire().await?;
    let rows = sqlx::query(
        "SELECT a.id, a.name, r.body, r.received_at, \
           (SELECT MAX(t.last_used_at) FROM tokens t WHERE t.actor_id = a.id AND t.revoked = 0) \
             AS last_used_at, \
           (SELECT GROUP_CONCAT(t.scopes) FROM tokens t WHERE t.actor_id = a.id AND t.revoked = 0 \
             AND (t.expires_at IS NULL OR t.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))) \
             AS scopes \
         FROM actors a LEFT JOIN agent_reports r ON r.actor_id = a.id \
         WHERE a.kind = 'agent' \
         ORDER BY r.received_at IS NULL, r.received_at DESC, a.name",
    )
    .fetch_all(&mut *conn)
    .await?;

    // What each agent did today, in the server's time zone: items it created and changed, and
    // its comments. The activity log has every write with its actor.
    // The first hour of the day that exists: a change of clock can skip midnight.
    let date = Utc::now().with_timezone(&state.tz).date_naive();
    let midnight = (0..3)
        .find_map(|hour| {
            date.and_hms_opt(hour, 0, 0)?
                .and_local_timezone(state.tz)
                .earliest()
        })
        .map(|t| t.with_timezone(&Utc))
        .unwrap_or_else(Utc::now);
    let counts = sqlx::query(
        "SELECT actor_id, action, COUNT(*) AS n FROM activity \
         WHERE created_at >= ? AND item_id IS NOT NULL \
           AND action IN ('created', 'updated', 'completed', 'completed_occurrence', 'commented') \
           AND actor_id IN (SELECT id FROM actors WHERE kind = 'agent') \
         GROUP BY actor_id, action",
    )
    .bind(midnight.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
    .fetch_all(&mut *conn)
    .await?;
    let mut today: HashMap<String, Value> = HashMap::new();
    for row in counts {
        let actor: String = row.try_get("actor_id")?;
        let action: String = row.try_get("action")?;
        let n: i64 = row.try_get("n")?;
        let field = match action.as_str() {
            "completed_occurrence" => "completed",
            other => other,
        };
        let counts = today.entry(actor).or_insert_with(no_activity);
        counts[field] = json!(counts[field].as_i64().unwrap_or(0) + n);
    }

    // The lines the owner wrote about the agents' jobs. A list, not an object keyed by the job:
    // a client that turns snake case keys into its own would change a job's name.
    let mut descriptions: HashMap<String, Vec<Value>> = HashMap::new();
    for (actor, job, text) in sqlx::query_as::<_, (String, String, String)>(
        "SELECT actor_id, job, text FROM job_descriptions ORDER BY actor_id, job",
    )
    .fetch_all(&mut *conn)
    .await?
    {
        descriptions
            .entry(actor)
            .or_default()
            .push(json!({"job": job, "text": text}));
    }

    let mut agents = Vec::new();
    for row in rows {
        let id: String = row.try_get("id")?;
        let body: Option<String> = row.try_get("body")?;
        let scopes: Option<String> = row.try_get("scopes")?;
        let mut scopes: Vec<&str> = scopes
            .as_deref()
            .unwrap_or("")
            .split(',')
            .filter(|s| !s.is_empty())
            .collect();
        scopes.sort_unstable();
        scopes.dedup();
        let report = body.and_then(|b| serde_json::from_str::<Value>(&b).ok());
        agents.push(json!({
            "id": id,
            "name": row.try_get::<String, _>("name")?,
            "scopes": scopes,
            "last_used_at": row.try_get::<Option<String>, _>("last_used_at")?,
            "received_at": row.try_get::<Option<String>, _>("received_at")?,
            "today": today.remove(&id).unwrap_or_else(no_activity),
            "job_descriptions": descriptions.remove(&id).unwrap_or_default(),
            "report": report,
        }));
    }
    Ok(Json(json!({
        "agents": agents,
        "now": Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
    })))
}

fn no_activity() -> Value {
    json!({"created": 0, "updated": 0, "completed": 0, "commented": 0})
}

// MARK: Connecting an agent

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CodeRequest {
    name: String,
    // "status": it sends reports and nothing else. "work": it also reads and writes items.
    access: String,
}

fn scopes_for(access: &str) -> Option<Vec<&'static str>> {
    match access {
        "status" => Some(vec!["report"]),
        "work" => Some(vec!["read", "write", "report"]),
        _ => None,
    }
}

fn clean_name(name: &str) -> Option<String> {
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    (!name.is_empty() && name.chars().count() <= 60 && !name.chars().any(char::is_control))
        .then_some(name)
}

// The owner makes a one-time code for a new agent, in the app. The code carries the name and
// the scopes; the agent cannot choose them. Like a pairing code it needs a token that approves.
pub async fn create_code(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    payload: std::result::Result<Json<CodeRequest>, JsonRejection>,
) -> Result<Json<Value>> {
    crate::devices::require_owner(&identity)?;
    let shape = || {
        ApiError::bad(
            "Send {\"name\": \"...\", \"access\": \"status\" or \"work\"} with a name of 1 to 60 characters.",
        )
    };
    let Json(request) = payload.map_err(|_| shape())?;
    let name = clean_name(&request.name).ok_or_else(shape)?;
    let scopes = scopes_for(&request.access).ok_or_else(shape)?;
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    sqlx::query(concat!(
        "DELETE FROM agent_codes WHERE expires_at <= ",
        now!()
    ))
    .execute(&mut *tx)
    .await?;
    let code = crate::devices::new_code();
    let expires_at: String = sqlx::query_scalar(
        "INSERT INTO agent_codes(code_hash, name, scopes, created_by, expires_at) \
         VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)) RETURNING expires_at",
    )
    .bind(crate::auth::hash(&code))
    .bind(&name)
    .bind(scopes.join(","))
    .bind(identity.device.as_deref())
    .bind(format!("+{} minutes", crate::devices::CODE_MINUTES))
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO activity(actor_id, action, detail) VALUES (?, 'agent_code_created', ?)",
    )
    .bind(&identity.actor.id)
    .bind(json!({"name": name, "scopes": scopes}).to_string())
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    let (head, tail) = code.split_at(crate::devices::CODE_LENGTH / 2);
    Ok(Json(json!({
        "code": format!("{head}-{tail}"),
        "expires_at": expires_at,
        "name": name,
        "scopes": scopes,
    })))
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectRequest {
    code: String,
}

fn invalid_agent_code() -> ApiError {
    ApiError::bad("This agent code is not valid or has expired. Make a new one in the app.")
}

// An ID from the name, lowercase letters, digits and hyphens, that no actor has yet.
async fn free_agent_id(conn: &mut sqlx::SqliteConnection, name: &str) -> Result<String> {
    let mut base: String = name
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    while base.contains("--") {
        base = base.replace("--", "-");
    }
    let mut base = base.trim_matches('-').chars().take(32).collect::<String>();
    // Reserved for the bridge, which gets the telegram scope alone; and never the owner.
    if base.is_empty() || base == crate::auth::OWNER || base == "telegram-bridge" {
        base = format!("agent-{}", if base.is_empty() { "new" } else { &base });
    }
    for n in 1..1000 {
        let id = if n == 1 {
            base.clone()
        } else {
            format!("{base}-{n}")
        };
        let taken: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM actors WHERE id = ?)")
            .bind(&id)
            .fetch_one(&mut *conn)
            .await?;
        if !taken {
            return Ok(id);
        }
    }
    Err(ApiError::bad("Choose another name for the agent."))
}

// Without a token, like pairing: the agent's machine trades the code for a new agent and its
// token. The code is used up in the same transaction, so it works once. A lost answer leaves a
// connected agent without its token; the owner revokes it and makes a new code.
pub async fn connect(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    payload: std::result::Result<Json<ConnectRequest>, JsonRejection>,
) -> Result<Json<Value>> {
    if state.local && !crate::auth::loopback_host(&headers) {
        return Err(ApiError::forbidden());
    }
    let Json(request) = payload.map_err(|_| ApiError::bad("Send {\"code\": \"...\"}."))?;
    let code = crate::devices::normalize(&request.code).ok_or_else(invalid_agent_code)?;
    let code_hash = crate::auth::hash(&code);
    // Looked up without the write lock first, so guesses cannot hold up the writers.
    let known: bool = sqlx::query_scalar(concat!(
        "SELECT EXISTS(SELECT 1 FROM agent_codes WHERE code_hash = ? AND expires_at > ",
        now!(),
        ")"
    ))
    .bind(&code_hash)
    .fetch_one(&state.db)
    .await?;
    if !known {
        return Err(invalid_agent_code());
    }
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let used: Option<(String, String)> = sqlx::query_as(concat!(
        "DELETE FROM agent_codes WHERE code_hash = ? AND expires_at > ",
        now!(),
        " RETURNING name, scopes"
    ))
    .bind(&code_hash)
    .fetch_optional(&mut *tx)
    .await?;
    let (name, scopes) = used.ok_or_else(invalid_agent_code)?;
    // Only scopes an agent may hold, whatever the row says.
    let scopes: Vec<&str> = scopes
        .split(',')
        .filter(|s| ["read", "write", "report"].contains(s))
        .collect();
    let id = free_agent_id(&mut tx, &name).await?;
    sqlx::query("INSERT INTO actors(id, name, kind) VALUES (?, ?, 'agent')")
        .bind(&id)
        .bind(&name)
        .execute(&mut *tx)
        .await?;
    let token = crate::auth::new_token();
    sqlx::query(
        "INSERT INTO tokens(id, actor_id, label, token_hash, scopes) VALUES (?, ?, 'connected', ?, ?)",
    )
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(&id)
    .bind(crate::auth::hash(&token))
    .bind(scopes.join(","))
    .execute(&mut *tx)
    .await?;
    sqlx::query("INSERT INTO activity(actor_id, action, detail) VALUES (?, 'agent_connected', ?)")
        .bind(&id)
        .bind(json!({"name": name, "scopes": scopes}).to_string())
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(json!({
        "token": token,
        "agent": {"id": id, "name": name},
        "scopes": scopes,
    })))
}

// MARK: Job descriptions

// The longest line the owner may write about a job.
pub const DESCRIPTION: usize = 200;

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DescriptionRequest {
    job: String,
    text: String,
}

// Sets or, with an empty text, removes the owner's line about one of an agent's jobs, inside the
// caller's transaction. The agent has to exist and hold a token that still works, so a line
// cannot come back after the agent was taken off. The job is named exactly as the stored report
// names it: trimmed and at most as long as a report keeps a name, whatever else it holds.
pub async fn set_description(
    conn: &mut sqlx::SqliteConnection,
    agent: &str,
    job: &str,
    text: &str,
) -> Result<Value> {
    let job = job.trim();
    if job.is_empty() || job.chars().count() > crate::report::NAME {
        return Err(ApiError::bad(format!(
            "Name the job as the agent's report does, in 1 to {} characters.",
            crate::report::NAME
        )));
    }
    // One line: line breaks and runs of white space become one space.
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() > DESCRIPTION || text.chars().any(char::is_control) {
        return Err(ApiError::bad(format!(
            "Write the description as one line of at most {DESCRIPTION} characters."
        )));
    }
    let connected: bool = sqlx::query_scalar(concat!(
        "SELECT EXISTS(SELECT 1 FROM actors a WHERE a.id = ? AND a.kind = 'agent' \
         AND EXISTS(SELECT 1 FROM tokens t WHERE t.actor_id = a.id AND t.revoked = 0 \
         AND (t.expires_at IS NULL OR t.expires_at > ",
        now!(),
        ")))"
    ))
    .bind(agent)
    .fetch_one(&mut *conn)
    .await?;
    if !connected {
        return Err(ApiError::missing());
    }
    if text.is_empty() {
        sqlx::query("DELETE FROM job_descriptions WHERE actor_id = ? AND job = ?")
            .bind(agent)
            .bind(job)
            .execute(&mut *conn)
            .await?;
        return Ok(json!({"agent": agent, "job": job, "text": null}));
    }
    sqlx::query(concat!(
        "INSERT INTO job_descriptions(actor_id, job, text) VALUES (?, ?, ?) \
         ON CONFLICT(actor_id, job) DO UPDATE SET text = excluded.text, updated_at = ",
        now!()
    ))
    .bind(agent)
    .bind(job)
    .bind(&text)
    .execute(&mut *conn)
    .await?;
    Ok(json!({"agent": agent, "job": job, "text": text}))
}

// The owner's devices write what a job does, like a setting: the route takes the writer lock
// itself and needs no idempotency key, since a repeat writes the same line. Not item data, so it
// is not in the activity log, the changes feed or a push.
pub async fn put_description(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Path(id): axum::extract::Path<String>,
    payload: std::result::Result<Json<DescriptionRequest>, JsonRejection>,
) -> Result<Json<Value>> {
    crate::devices::require_owner(&identity)?;
    let Json(request) =
        payload.map_err(|_| ApiError::bad("Send {\"job\": \"...\", \"text\": \"...\"}."))?;
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let written = set_description(&mut tx, &id, &request.job, &request.text).await?;
    tx.commit().await?;
    Ok(Json(written))
}

// The owner takes an agent off: its tokens stop working, and its report and the lines about its
// jobs go. The agent stays as an actor, so the activity log and the items it wrote still name it.
pub async fn revoke(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Result<Json<Value>> {
    crate::devices::require_owner(&identity)?;
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let is_agent: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM actors WHERE id = ? AND kind = 'agent')")
            .bind(&id)
            .fetch_one(&mut *tx)
            .await?;
    if !is_agent {
        return Err(ApiError::missing());
    }
    let revoked = sqlx::query("UPDATE tokens SET revoked = 1 WHERE actor_id = ? AND revoked = 0")
        .bind(&id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    sqlx::query("DELETE FROM agent_reports WHERE actor_id = ?")
        .bind(&id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM job_descriptions WHERE actor_id = ?")
        .bind(&id)
        .execute(&mut *tx)
        .await?;
    if revoked > 0 {
        sqlx::query(
            "INSERT INTO activity(actor_id, action, detail) VALUES (?, 'agent_revoked', ?)",
        )
        .bind(&identity.actor.id)
        .bind(json!({"agent": id}).to_string())
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(Json(json!({"id": id, "revoked": true})))
}
