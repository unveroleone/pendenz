use crate::{
    AppState,
    error::{ApiError, Result},
};
use axum::{
    Extension, Json,
    extract::{Request, State},
    http::{HeaderMap, header},
    middleware::Next,
    response::Response,
};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::FromRow;

pub const SCOPES: [&str; 5] = ["read", "write", "propose", "approve", "telegram"];
// What a paired device may do: everything a person can, approving included.
pub const DEVICE_SCOPES: [&str; 4] = ["read", "write", "propose", "approve"];
pub const TOKEN_PREFIX: &str = "pdz_";
// The one person a server belongs to. Paired devices and the command line act as this actor;
// every other actor is an agent. Migration 0006 renamed the ID from "leo".
pub const OWNER: &str = "owner";
// A token whose last use is older than five minutes, so the usage time is written at most that often.
macro_rules! stale {
    () => {
        "(last_used_at IS NULL OR last_used_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-5 minutes'))"
    };
}

#[derive(Clone, Serialize, FromRow)]
pub struct Actor {
    pub id: String,
    pub name: String,
    pub kind: String,
}

#[derive(Clone)]
pub struct Identity {
    pub actor: Actor,
    pub scopes: Vec<String>,
    // Set for the token of a paired device.
    pub device: Option<String>,
}
impl Identity {
    pub fn require(&self, scope: &str) -> Result<()> {
        if self.scopes.iter().any(|s| s == scope) {
            Ok(())
        } else {
            Err(ApiError::forbidden())
        }
    }
    // Agents never see rows with hidden_from_agents set. Every read and write checks this.
    pub fn is_human(&self) -> bool {
        self.actor.kind == "human"
    }
}

// The SHA-256 of some bytes in lowercase hex, the form of every hash the database stores.
pub fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn hash(value: &str) -> String {
    sha256_hex(value.as_bytes())
}

pub fn new_token() -> String {
    format!(
        "{TOKEN_PREFIX}{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

fn well_formed(token: &str) -> bool {
    token.strip_prefix(TOKEN_PREFIX).is_some_and(|rest| {
        rest.len() == 64
            && rest
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    })
}

#[derive(FromRow)]
struct TokenRow {
    token_id: String,
    scopes: String,
    device_id: Option<String>,
    stale: bool,
    #[sqlx(flatten)]
    actor: Actor,
}

pub async fn lookup(state: &AppState, token: &str) -> Result<Identity> {
    if !well_formed(token) {
        return Err(ApiError::unauthorized());
    }
    let row = sqlx::query_as::<_, TokenRow>(concat!(
        "SELECT t.id AS token_id, t.scopes, t.device_id, a.id, a.name, a.kind, ",
        stale!(),
        " AS stale \
         FROM tokens t JOIN actors a ON a.id = t.actor_id \
         WHERE t.token_hash = ? AND t.revoked = 0 \
         AND (t.expires_at IS NULL OR t.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
    ))
    .bind(hash(token))
    .fetch_optional(&state.db)
    .await?
    .ok_or_else(ApiError::unauthorized)?;
    if row.stale {
        // Best effort: a busy database must not fail the request over a usage timestamp. The
        // condition is repeated so two requests at once write it only once.
        let _ = sqlx::query(concat!("UPDATE tokens SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND ", stale!()))
        .bind(&row.token_id)
        .execute(&state.db)
        .await;
    }
    Ok(Identity {
        actor: row.actor,
        scopes: row.scopes.split(',').map(str::to_owned).collect(),
        device: row.device_id,
    })
}

pub fn loopback_host(headers: &HeaderMap) -> bool {
    let host = headers
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    // Drop a numeric port. "[::1]" has colons of its own, which the digit check leaves alone.
    let name = match host.rsplit_once(':') {
        Some((name, port)) if !port.is_empty() && port.bytes().all(|c| c.is_ascii_digit()) => name,
        _ => host,
    };
    matches!(name, "localhost" | "127.0.0.1" | "[::1]")
}

pub async fn identity(Extension(identity): Extension<Identity>) -> Json<Value> {
    Json(json!({"actor": identity.actor, "scopes": identity.scopes, "device_id": identity.device}))
}

pub async fn authenticate(
    State(state): State<AppState>,
    mut request: Request,
    next: Next,
) -> Result<Response> {
    if state.local && !loopback_host(request.headers()) {
        return Err(ApiError::forbidden());
    }
    let mut sent = request.headers().get_all(header::AUTHORIZATION).iter();
    let identity = match (sent.next(), sent.next()) {
        (Some(value), None) => {
            let token = value
                .to_str()
                .ok()
                .and_then(|s| s.split_once(' '))
                .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("bearer"))
                .map(|(_, token)| token.trim_start_matches(' '))
                .ok_or_else(ApiError::unauthorized)?;
            lookup(&state, token).await?
        }
        // Development only: without a token the request acts as the owner on a paired device.
        (None, _) if state.local => Identity {
            actor: sqlx::query_as("SELECT id, name, kind FROM actors WHERE id = ?")
                .bind(OWNER)
                .fetch_one(&state.db)
                .await?,
            scopes: DEVICE_SCOPES.map(String::from).to_vec(),
            device: None,
        },
        // No header, or more than one.
        _ => return Err(ApiError::unauthorized()),
    };
    request.extensions_mut().insert(identity);
    Ok(next.run(request).await)
}
