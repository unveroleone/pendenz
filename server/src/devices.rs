use crate::{
    AppState,
    auth::{self, Identity, hash},
    error::{ApiError, Result},
};
use axum::{
    Extension, Json,
    extract::{Path, State, rejection::JsonRejection},
    http::HeaderMap,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{FromRow, SqliteConnection};

// Letters and digits that are not mistaken for each other when read off a screen and typed.
const CODE_ALPHABET: &[u8; 30] = b"ABCDEFGHJKMNPQRSTVWXYZ23456789";
// 30^10 codes, about 49 bits. A code lives for ten minutes, so guessing one is out of reach
// without a limit on attempts.
pub(crate) const CODE_LENGTH: usize = 10;
pub(crate) const CODE_MINUTES: i64 = 10;

pub(crate) fn new_code() -> String {
    loop {
        // The hash of a fresh token is 32 evenly spread bytes. A byte of 240 or more is skipped,
        // so every character is equally likely.
        let digest = Sha256::digest(auth::new_token().as_bytes());
        let code: String = digest
            .iter()
            .filter(|byte| **byte < 240)
            .take(CODE_LENGTH)
            .map(|byte| CODE_ALPHABET[usize::from(*byte) % CODE_ALPHABET.len()] as char)
            .collect();
        if code.len() == CODE_LENGTH {
            return code;
        }
    }
}

// The code as it was typed, without the hyphen and spaces and in upper case.
pub(crate) fn normalize(code: &str) -> Option<String> {
    let code: String = code
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    (code.len() == CODE_LENGTH && code.bytes().all(|c| CODE_ALPHABET.contains(&c))).then_some(code)
}

async fn record(conn: &mut SqliteConnection, action: &str, detail: Value) -> sqlx::Result<()> {
    sqlx::query("INSERT INTO activity(actor_id, action, detail) VALUES (?, ?, ?)")
        .bind(auth::OWNER)
        .bind(action)
        .bind(detail.to_string())
        .execute(conn)
        .await?;
    Ok(())
}

// Stores a new code and returns it as shown to the owner, with the time it expires. Call it inside a
// write transaction. `created_by` is the device that asked, or None for the command line.
pub async fn new_pairing_code(
    conn: &mut SqliteConnection,
    created_by: Option<&str>,
) -> sqlx::Result<(String, String)> {
    sqlx::query(concat!(
        "DELETE FROM pairing_codes WHERE expires_at <= ",
        now!()
    ))
    .execute(&mut *conn)
    .await?;
    let code = new_code();
    let expires_at: String = sqlx::query_scalar(
        "INSERT INTO pairing_codes(code_hash, created_by, expires_at) \
         VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)) RETURNING expires_at",
    )
    .bind(hash(&code))
    .bind(created_by)
    .bind(format!("+{CODE_MINUTES} minutes"))
    .fetch_one(&mut *conn)
    .await?;
    record(conn, "pairing_code_created", json!({"device": created_by})).await?;
    let (head, tail) = code.split_at(CODE_LENGTH / 2);
    Ok((format!("{head}-{tail}"), expires_at))
}

// Revokes the token of a device and the codes it showed that nobody used yet. Returns None for
// an unknown device. Revoking twice changes nothing.
pub async fn revoke_device(
    conn: &mut SqliteConnection,
    id: &str,
    by_device: Option<&str>,
) -> sqlx::Result<Option<()>> {
    let known: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE id = ?)")
        .bind(id)
        .fetch_one(&mut *conn)
        .await?;
    if !known {
        return Ok(None);
    }
    let revoked = sqlx::query("UPDATE tokens SET revoked = 1 WHERE device_id = ? AND revoked = 0")
        .bind(id)
        .execute(&mut *conn)
        .await?
        .rows_affected();
    sqlx::query("DELETE FROM pairing_codes WHERE created_by = ?")
        .bind(id)
        .execute(&mut *conn)
        .await?;
    // No push goes to a device that is no longer paired.
    sqlx::query("DELETE FROM push_tokens WHERE device_id = ?")
        .bind(id)
        .execute(&mut *conn)
        .await?;
    if revoked > 0 {
        record(
            conn,
            "device_revoked",
            json!({"device": id, "by_device": by_device}),
        )
        .await?;
    }
    Ok(Some(()))
}

#[derive(Serialize, FromRow)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub created_at: String,
    pub last_used_at: Option<String>,
}

// The paired devices whose token still works, oldest first.
pub async fn paired_devices(conn: &mut SqliteConnection) -> sqlx::Result<Vec<Device>> {
    sqlx::query_as(concat!(
        "SELECT d.id, d.name, d.created_at, t.last_used_at FROM devices d \
         JOIN tokens t ON t.device_id = d.id \
         WHERE t.revoked = 0 AND (t.expires_at IS NULL OR t.expires_at > ",
        now!(),
        ") \
         ORDER BY d.created_at, d.id"
    ))
    .fetch_all(conn)
    .await
}

// Pairing a device hands out a token that can approve, so only a token that can approve itself
// may start it or look at the devices. Agent tokens never have that scope.
pub fn require_owner(identity: &Identity) -> Result<()> {
    if !identity.is_human() {
        return Err(ApiError::forbidden());
    }
    identity.require("approve")
}

pub async fn create_code(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Result<Json<Value>> {
    require_owner(&identity)?;
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    let (code, expires_at) = new_pairing_code(&mut tx, identity.device.as_deref()).await?;
    tx.commit().await?;
    Ok(Json(json!({"code": code, "expires_at": expires_at})))
}

pub async fn list(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Result<Json<Value>> {
    require_owner(&identity)?;
    let mut conn = state.db.acquire().await?;
    let devices = paired_devices(&mut conn).await?;
    Ok(Json(
        json!({"devices": devices, "current": identity.device}),
    ))
}

pub async fn revoke(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> Result<Json<Value>> {
    require_owner(&identity)?;
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    revoke_device(&mut tx, &id, identity.device.as_deref())
        .await?
        .ok_or_else(ApiError::missing)?;
    tx.commit().await?;
    Ok(Json(json!({"id": id, "revoked": true})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairRequest {
    code: String,
    name: String,
}

fn invalid_code() -> ApiError {
    ApiError::bad("This pairing code is not valid or has expired. Create a new one.")
}

// The one route without a token: a new device trades a pairing code for its own token. The code
// is used up in the same transaction that stores the device, so it works once.
pub async fn pair(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: std::result::Result<Json<PairRequest>, JsonRejection>,
) -> Result<Json<Value>> {
    if state.local && !auth::loopback_host(&headers) {
        return Err(ApiError::forbidden());
    }
    let Json(request) = payload
        .map_err(|_| ApiError::bad("Send a JSON object with the code and a device name."))?;
    let name = request
        .name
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if name.is_empty() || name.chars().count() > 60 || name.chars().any(char::is_control) {
        return Err(ApiError::bad(
            "Use a device name between 1 and 60 characters.",
        ));
    }
    let code_hash = hash(&normalize(&request.code).ok_or_else(invalid_code)?);
    // Looked up without the write lock first, so guesses cannot hold up the writers.
    let known: bool = sqlx::query_scalar(concat!(
        "SELECT EXISTS(SELECT 1 FROM pairing_codes WHERE code_hash = ? AND expires_at > ",
        now!(),
        ")"
    ))
    .bind(&code_hash)
    .fetch_one(&state.db)
    .await?;
    if !known {
        return Err(invalid_code());
    }
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    // The device that showed the code, or NULL for one from the command line.
    let used: Option<(Option<String>,)> = sqlx::query_as(concat!(
        "DELETE FROM pairing_codes WHERE code_hash = ? AND expires_at > ",
        now!(),
        " RETURNING created_by"
    ))
    .bind(&code_hash)
    .fetch_optional(&mut *tx)
    .await?;
    let (code_from,) = used.ok_or_else(invalid_code)?;
    let device_id = uuid::Uuid::new_v4().to_string();
    let token = auth::new_token();
    sqlx::query("INSERT INTO devices(id, name) VALUES (?, ?)")
        .bind(&device_id)
        .bind(&name)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO tokens(id, actor_id, label, token_hash, scopes, device_id) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(auth::OWNER)
    .bind(&name)
    .bind(hash(&token))
    .bind(auth::DEVICE_SCOPES.join(","))
    .bind(&device_id)
    .execute(&mut *tx)
    .await?;
    record(
        &mut tx,
        "device_paired",
        json!({"device": device_id, "name": name, "code_from": code_from}),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(json!({
        "token": token,
        "device": {"id": device_id, "name": name},
    })))
}
