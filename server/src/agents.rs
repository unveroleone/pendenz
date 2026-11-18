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
        today
            .entry(actor)
            .or_insert_with(|| json!({"created": 0, "updated": 0, "commented": 0}))[action] =
            json!(n);
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
