use crate::{
    AppState,
    auth::Identity,
    error::{ApiError, Result},
    model::{Comment, Item, Project, parse_instant, utc_key},
    notes::Note,
};
use axum::{
    Extension, Json,
    extract::{Query, State, rejection::QueryRejection},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::FromRow;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Cursor {
    cursor: Option<i64>,
    limit: Option<i64>,
}

// Rows changed after the cursor, oldest change first. A row appears once, in its current state,
// at the sequence number of its latest write. Trashed and archived rows are included.
pub async fn changes(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    query: std::result::Result<Query<Cursor>, QueryRejection>,
) -> Result<Json<Value>> {
    identity.require("read")?;
    let Query(query) = query.map_err(|e| ApiError::bad(e.body_text()))?;
    let cursor = query.cursor.unwrap_or(0);
    let limit = query.limit.unwrap_or(200);
    if cursor < 0 || !(1..=500).contains(&limit) {
        return Err(ApiError::bad(
            "Use a cursor of 0 or more and a limit from 1 to 500.",
        ));
    }
    // One snapshot for all five reads, so the head matches the rows.
    let mut tx = state.db.begin().await?;
    let head: i64 = sqlx::query_scalar("SELECT value FROM meta WHERE key = 'seq'")
        .fetch_one(&mut *tx)
        .await?;
    if cursor > head {
        // The server was restored from a backup that is older than this client's cursor.
        return Ok(Json(
            json!({"cursor": 0, "has_more": true, "reset": true, "changes": []}),
        ));
    }
    let human = identity.is_human();
    let items = sqlx::query_as::<_, Item>(
        "SELECT * FROM items WHERE seq > ? AND (? OR hidden_from_agents = 0) ORDER BY seq LIMIT ?",
    )
    .bind(cursor)
    .bind(human)
    .bind(limit + 1)
    .fetch_all(&mut *tx)
    .await?;
    let comments = sqlx::query_as::<_, Comment>(
        "SELECT c.* FROM comments c JOIN items i ON i.id = c.item_id \
         WHERE c.seq > ? AND (? OR i.hidden_from_agents = 0) ORDER BY c.seq LIMIT ?",
    )
    .bind(cursor)
    .bind(human)
    .bind(limit + 1)
    .fetch_all(&mut *tx)
    .await?;
    let projects =
        sqlx::query_as::<_, Project>("SELECT * FROM projects WHERE seq > ? ORDER BY seq LIMIT ?")
            .bind(cursor)
            .bind(limit + 1)
            .fetch_all(&mut *tx)
            .await?;
    let notes = sqlx::query_as::<_, Note>(
        "SELECT * FROM notes WHERE seq > ? AND (? OR hidden_from_agents = 0) ORDER BY seq LIMIT ?",
    )
    .bind(cursor)
    .bind(human)
    .bind(limit + 1)
    .fetch_all(&mut *tx)
    .await?;
    let mut changes: Vec<(i64, Value)> = Vec::new();
    changes.extend(items.iter().map(|row| {
        (
            row.seq,
            json!({"seq": row.seq, "type": "item", "data": row}),
        )
    }));
    changes.extend(comments.iter().map(|row| {
        (
            row.seq,
            json!({"seq": row.seq, "type": "comment", "data": row}),
        )
    }));
    changes.extend(projects.iter().map(|row| {
        (
            row.seq,
            json!({"seq": row.seq, "type": "project", "data": row}),
        )
    }));
    changes.extend(notes.iter().map(|row| {
        (
            row.seq,
            json!({"seq": row.seq, "type": "note", "data": row}),
        )
    }));
    changes.sort_by_key(|(seq, _)| *seq);
    let has_more = changes.len() as i64 > limit;
    changes.truncate(limit as usize);
    // A full page ends at its last row. The last page ends at the head, which also moves the
    // cursor past rows this token may not see.
    let next = match (has_more, changes.last()) {
        (true, Some((seq, _))) => *seq,
        _ => head,
    };
    Ok(Json(json!({
        "cursor": next,
        "has_more": has_more,
        "reset": false,
        "changes": changes.into_iter().map(|(_, change)| change).collect::<Vec<_>>(),
    })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Window {
    after: Option<String>,
    until: Option<String>,
}

#[derive(FromRow)]
struct Reminder {
    id: i64,
    title: String,
    due_at: Option<String>,
    due_tz: Option<String>,
    remind_utc: String,
    repeat_rule: Option<String>,
}

// Open items whose reminder time lies in (after, until]. The caller keeps the returned `until`
// as its next `after`, so the server stores no "sent" state and each reminder is reported once.
pub async fn reminders(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    query: std::result::Result<Query<Window>, QueryRejection>,
) -> Result<Json<Value>> {
    identity.require("read")?;
    let Query(query) = query.map_err(|e| ApiError::bad(e.body_text()))?;
    let instant = |text: &str| {
        parse_instant(text.trim(), state.tz).ok_or_else(|| {
            ApiError::bad("Write after and until as a time such as 2026-11-13T09:00:00+01:00.")
        })
    };
    let now = chrono::Utc::now();
    let after = match &query.after {
        Some(text) => utc_key(&instant(text)?),
        None => return Err(ApiError::bad("Send after, the time of your last check.")),
    };
    let until = match &query.until {
        Some(text) => utc_key(&instant(text)?),
        None => utc_key(&now),
    };
    if until < after {
        return Err(ApiError::bad("until must not be earlier than after."));
    }
    const PAGE: usize = 200;
    macro_rules! select {
        () => {
            "SELECT id, title, due_at, due_tz, remind_utc, repeat_rule FROM items"
        };
    }
    // Written as literals so SQLite matches the partial index items_remind.
    macro_rules! open {
        () => {
            "status <> 'done' AND trashed = 0 AND archived = 0 AND (? OR hidden_from_agents = 0)"
        };
    }
    let human = identity.is_human();
    // One snapshot for all reads of this request.
    let mut tx = state.db.begin().await?;
    let mut rows = sqlx::query_as::<_, Reminder>(concat!(
        select!(),
        " WHERE remind_utc > ? AND remind_utc <= ? AND ",
        open!(),
        " ORDER BY remind_utc, id LIMIT ?"
    ))
    .bind(&after)
    .bind(&until)
    .bind(human)
    .bind(PAGE as i64 + 1)
    .fetch_all(&mut *tx)
    .await?;
    // A long gap can hold more than one page. Then the window ends at the reminder time of the
    // last row on this page, and the rest of that second is loaded too, so the caller can go on
    // from that time without losing or repeating a reminder.
    let (until, has_more) = if rows.len() > PAGE {
        rows.truncate(PAGE);
        let (cut, last_id) = (rows[PAGE - 1].remind_utc.clone(), rows[PAGE - 1].id);
        let rest = sqlx::query_as::<_, Reminder>(concat!(
            select!(),
            " WHERE remind_utc = ? AND id > ? AND ",
            open!(),
            " ORDER BY id"
        ))
        .bind(&cut)
        .bind(last_id)
        .bind(human)
        .fetch_all(&mut *tx)
        .await?;
        rows.extend(rest);
        let has_more: bool = sqlx::query_scalar(concat!(
            "SELECT EXISTS(SELECT 1 FROM items WHERE remind_utc > ? AND remind_utc <= ? AND ",
            open!(),
            ")"
        ))
        .bind(&cut)
        .bind(&until)
        .bind(human)
        .fetch_one(&mut *tx)
        .await?;
        (cut, has_more)
    } else {
        (until, false)
    };
    let reminders: Vec<Value> = rows
        .iter()
        .map(|row| {
            let zone = row
                .due_tz
                .as_deref()
                .and_then(|name| name.parse().ok())
                .unwrap_or(state.tz);
            let remind_at = parse_instant(&row.remind_utc, zone)
                .map(|at| crate::model::local_text(&at))
                .unwrap_or_else(|| row.remind_utc.clone());
            json!({"id": row.id, "title": row.title, "remind_at": remind_at, "due_at": row.due_at,
                "due_tz": row.due_tz, "repeat_rule": row.repeat_rule})
        })
        .collect();
    Ok(Json(
        json!({"after": after, "until": until, "has_more": has_more, "reminders": reminders}),
    ))
}
