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
// The highest price of a kWh the server takes, in Swiss francs.
const PRICE_CEILING_CHF: f64 = 100.0;

// The settings of the server that the owner changes in the app.
#[derive(Clone, Copy, PartialEq)]
pub(crate) struct Settings {
    pub file_limit_mb: i64,
    // Null until the owner sets one. Always named in the JSON, so an app can tell a server
    // that has the setting from one that does not.
    pub energy_price_chf: Option<f64>,
}

impl Settings {
    pub fn json(&self) -> Value {
        json!({
            "file_limit_mb": self.file_limit_mb,
            "file_limit_ceiling_mb": FILE_CEILING_MB,
            "energy_price_chf": self.energy_price_chf,
        })
    }
}

pub(crate) async fn read(conn: &mut SqliteConnection) -> Result<Settings> {
    let (file_limit_mb, energy_price_chf): (i64, Option<f64>) =
        sqlx::query_as("SELECT file_limit_mb, energy_price_chf FROM server_settings WHERE id = 1")
            .fetch_one(conn)
            .await?;
    Ok(Settings {
        file_limit_mb,
        energy_price_chf,
    })
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
            "Send {{\"file_limit_mb\": n}} with n from 1 to {FILE_CEILING_MB}, {{\"energy_price_chf\": x}} with x from 0 to {PRICE_CEILING_CHF} or null, or both."
        ))
    };
    let Ok(Json(Value::Object(mut fields))) = payload else {
        return Err(shape());
    };
    // Each field is left as it is when it is not sent; the price is cleared with null.
    let limit = match fields.remove("file_limit_mb") {
        None => None,
        Some(Value::Number(n)) => match n.as_i64() {
            Some(limit) if (1..=FILE_CEILING_MB).contains(&limit) => Some(limit),
            _ => return Err(shape()),
        },
        Some(_) => return Err(shape()),
    };
    let price = match fields.remove("energy_price_chf") {
        None => None,
        Some(Value::Null) => Some(None),
        Some(Value::Number(n)) => match n.as_f64() {
            Some(price) if price.is_finite() && (0.0..=PRICE_CEILING_CHF).contains(&price) => {
                Some(Some(price))
            }
            _ => return Err(shape()),
        },
        Some(_) => return Err(shape()),
    };
    if !fields.is_empty() || (limit.is_none() && price.is_none()) {
        return Err(shape());
    }
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let before = read(&mut tx).await?;
    let after = Settings {
        file_limit_mb: limit.unwrap_or(before.file_limit_mb),
        energy_price_chf: price.unwrap_or(before.energy_price_chf),
    };
    if before == after {
        return Ok(Json(before.json()));
    }
    sqlx::query("UPDATE server_settings SET file_limit_mb = ?, energy_price_chf = ? WHERE id = 1")
        .bind(after.file_limit_mb)
        .bind(after.energy_price_chf)
        .execute(&mut *tx)
        .await?;
    let mut changed = serde_json::Map::new();
    if after.file_limit_mb != before.file_limit_mb {
        changed.insert(
            "file_limit_mb".into(),
            json!({"from": before.file_limit_mb, "to": after.file_limit_mb}),
        );
    }
    if after.energy_price_chf != before.energy_price_chf {
        changed.insert(
            "energy_price_chf".into(),
            json!({"from": before.energy_price_chf, "to": after.energy_price_chf}),
        );
    }
    record(
        &mut tx,
        About::Nothing,
        &identity.actor.id,
        "settings_changed",
        Value::Object(changed),
    )
    .await?;
    tx.commit().await?;
    // The other devices learn the new settings from their next sync.
    state.push.changed(identity.device.as_deref());
    Ok(Json(after.json()))
}
