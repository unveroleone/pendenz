use crate::{
    AppState,
    auth::Identity,
    devices::require_owner,
    error::{ApiError, Result},
    items::{About, record},
};
use axum::{
    Extension, Json,
    extract::{State, rejection::JsonRejection},
};
use serde_json::{Value, json};
use sqlx::SqliteConnection;

// A megabyte of a file, as the apps count it.
pub const MB: u64 = 1_000_000;
// The largest file the server takes, whatever the setting says. The route's body limit is fixed
// when the router is built, and a Cloudflare tunnel refuses larger bodies anyway.
pub const FILE_CEILING_MB: i64 = 100;

// The settings of the server that the owner changes in the app.
pub(crate) struct Settings {
    pub file_limit_mb: i64,
}

impl Settings {
    pub fn json(&self) -> Value {
        json!({
            "file_limit_mb": self.file_limit_mb,
            "file_limit_ceiling_mb": FILE_CEILING_MB,
        })
    }
}

pub(crate) async fn read(conn: &mut SqliteConnection) -> Result<Settings> {
    let file_limit_mb: i64 =
        sqlx::query_scalar("SELECT file_limit_mb FROM server_settings WHERE id = 1")
            .fetch_one(conn)
            .await?;
    Ok(Settings { file_limit_mb })
}

pub async fn get(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Result<Json<Value>> {
    identity.require("read")?;
    let mut conn = state.db.acquire().await?;
    Ok(Json(read(&mut conn).await?.json()))
}

// Only the owner's devices change a setting, never an agent. Like the device routes it takes the
// writer lock itself and needs no idempotency key: it sets a value, so a repeat does no harm.
pub async fn update(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    payload: std::result::Result<Json<Value>, JsonRejection>,
) -> Result<Json<Value>> {
    require_owner(&identity)?;
    let shape = || {
        ApiError::bad(format!(
            "Send {{\"file_limit_mb\": n}} with n from 1 to {FILE_CEILING_MB}."
        ))
    };
    let Ok(Json(Value::Object(mut fields))) = payload else {
        return Err(shape());
    };
    let limit = match (fields.remove("file_limit_mb"), fields.is_empty()) {
        (Some(Value::Number(n)), true) => n.as_i64().ok_or_else(shape)?,
        _ => return Err(shape()),
    };
    if !(1..=FILE_CEILING_MB).contains(&limit) {
        return Err(shape());
    }
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let before = read(&mut tx).await?;
    if before.file_limit_mb == limit {
        return Ok(Json(before.json()));
    }
    sqlx::query("UPDATE server_settings SET file_limit_mb = ? WHERE id = 1")
        .bind(limit)
        .execute(&mut *tx)
        .await?;
    record(
        &mut tx,
        About::Nothing,
        &identity.actor.id,
        "settings_changed",
        json!({"file_limit_mb": {"from": before.file_limit_mb, "to": limit}}),
    )
    .await?;
    tx.commit().await?;
    // The other devices learn the new limit from their next sync.
    state.push.changed(identity.device.as_deref());
    Ok(Json(
        Settings {
            file_limit_mb: limit,
        }
        .json(),
    ))
}
