// Comments on items: progress, plans and results, mostly from agents. Every write here runs
// inside `items::write`, so it has the writer lock, the transaction and the idempotency key.
use crate::{
    auth::Identity,
    error::{ApiError, Result},
    items::{About, Written, next_seq, record},
    model::Comment,
};
use axum::http::StatusCode;
use serde_json::{Map, Value, json};
use sqlx::SqliteConnection;

const MAX_LENGTH: usize = 10_000;

fn body_text(value: Option<&Value>) -> Result<String> {
    let body = match value {
        Some(Value::String(body)) => body.replace("\r\n", "\n").trim().to_string(),
        _ => return Err(ApiError::bad("Send the comment body as text.")),
    };
    if body.is_empty() || body.chars().count() > MAX_LENGTH {
        return Err(ApiError::bad(
            "Write a comment between 1 and 10,000 characters.",
        ));
    }
    Ok(body)
}

// The item a comment is written on, through the hidden filter. Nothing is written on an item in
// the trash.
async fn open_item(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    refusal: &str,
) -> Result<()> {
    let trashed: Option<bool> = sqlx::query_scalar(
        "SELECT trashed FROM items WHERE id = ? AND (? OR hidden_from_agents = 0)",
    )
    .bind(id)
    .bind(identity.is_human())
    .fetch_optional(&mut *conn)
    .await?;
    if trashed.ok_or_else(ApiError::missing)? {
        return Err(ApiError::bad(refusal));
    }
    Ok(())
}

// A comment that the caller may change: one of this item's, not deleted, and for an agent one
// it wrote itself. The owner may change any. The comment is looked up by its ID and the item's
// together, so the item decides who sees it.
async fn own_comment(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    comment: i64,
) -> Result<Comment> {
    open_item(
        conn,
        identity,
        id,
        "This item is in the trash. Restore it before changing its comments.",
    )
    .await?;
    let found = sqlx::query_as::<_, Comment>(
        "SELECT * FROM comments WHERE id = ? AND item_id = ? AND deleted = 0",
    )
    .bind(comment)
    .bind(id)
    .fetch_optional(&mut *conn)
    .await?
    .ok_or_else(ApiError::missing)?;
    if !identity.is_human() && found.author_id != identity.actor.id {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "You can change only your own comments.".into(),
        ));
    }
    Ok(found)
}

fn written(comment: Comment) -> Written {
    Written {
        resource: "comment",
        id: comment.id.to_string(),
        body: json!(comment),
    }
}

pub(crate) async fn add(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    fields: Map<String, Value>,
) -> Result<Written> {
    open_item(
        conn,
        identity,
        id,
        "This item is in the trash. Restore it before commenting.",
    )
    .await?;
    if fields.len() != 1 || !matches!(fields.get("body"), Some(Value::String(_))) {
        return Err(ApiError::bad("Send only the comment body."));
    }
    let body = body_text(fields.get("body"))?;
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
    Ok(written(comment))
}

// A new text, the outdated mark, or both. The history names what changed but never holds the
// text, so a comment that is deleted later leaves nothing of it behind.
pub(crate) async fn update(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    comment: i64,
    mut fields: Map<String, Value>,
) -> Result<Written> {
    let before = own_comment(conn, identity, id, comment).await?;
    let version = fields
        .remove("version")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| ApiError::bad("Include the version you read."))?;
    let body = fields
        .remove("body")
        .map(|v| body_text(Some(&v)))
        .transpose()?;
    let outdated = match fields.remove("outdated") {
        None => None,
        Some(Value::Bool(flag)) => Some(flag),
        Some(_) => return Err(ApiError::bad("outdated is true or false.")),
    };
    if let Some(name) = fields.keys().next() {
        return Err(ApiError::bad(format!(
            "A comment has no field {name}. Send body, outdated or both."
        )));
    }
    if body.is_none() && outdated.is_none() {
        return Err(ApiError::bad("Send body, outdated or both."));
    }
    if version != before.version {
        return Err(ApiError(
            StatusCode::CONFLICT,
            "This comment changed. Read the item again before saving.".into(),
        ));
    }
    let body = body.filter(|text| *text != before.body);
    let outdated = outdated.filter(|flag| *flag != before.outdated);
    if body.is_none() && outdated.is_none() {
        return Ok(written(before));
    }
    let seq = next_seq(conn).await?;
    let edited = body.is_some();
    let after = sqlx::query_as::<_, Comment>(concat!(
        "UPDATE comments SET body = ?, outdated = ?, version = version + 1, seq = ?, \
         edited_at = CASE WHEN ? THEN ",
        now!(),
        " ELSE edited_at END WHERE id = ? AND version = ? RETURNING *"
    ))
    .bind(body.as_deref().unwrap_or(&before.body))
    .bind(outdated.unwrap_or(before.outdated))
    .bind(seq)
    .bind(edited)
    .bind(comment)
    .bind(before.version)
    .fetch_one(&mut *conn)
    .await?;
    let mut detail = json!({"comment_id": comment});
    if edited {
        detail["body_changed"] = json!(true);
    }
    if let Some(flag) = outdated {
        detail["outdated"] = json!(flag);
    }
    record(
        conn,
        About::Item(id),
        &identity.actor.id,
        "comment_updated",
        detail,
    )
    .await?;
    Ok(written(after))
}

// The row stays with an empty body and deleted set, because the changes feed has no tombstones.
pub(crate) async fn delete(
    conn: &mut SqliteConnection,
    identity: &Identity,
    id: i64,
    comment: i64,
    fields: Map<String, Value>,
) -> Result<Written> {
    if !fields.is_empty() {
        return Err(ApiError::bad("Deleting a comment takes no fields."));
    }
    own_comment(conn, identity, id, comment).await?;
    let seq = next_seq(conn).await?;
    let after = sqlx::query_as::<_, Comment>(
        "UPDATE comments SET body = '', deleted = 1, version = version + 1, seq = ? \
         WHERE id = ? RETURNING *",
    )
    .bind(seq)
    .bind(comment)
    .fetch_one(&mut *conn)
    .await?;
    record(
        conn,
        About::Item(id),
        &identity.actor.id,
        "comment_deleted",
        json!({"comment_id": comment}),
    )
    .await?;
    Ok(written(after))
}
