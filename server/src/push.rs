use crate::{
    AppState,
    auth::Identity,
    devices,
    error::{ApiError, Result},
};
use axum::{
    Extension, Json,
    extract::{State, rejection::JsonRejection},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::FromRow;
use std::{sync::Mutex, time::Duration};
use tokio::sync::Notify;

// Changes that follow each other within this time go out as one push.
const COLLECT: Duration = Duration::from_secs(2);
// The shortest time between two pushes. iOS allows an app only a few background pushes an
// hour and keeps the newest one, so more would be thrown away on the device.
const PAUSE: Duration = Duration::from_secs(20);
const TIMEOUT: Duration = Duration::from_secs(10);
// The relay takes this many devices in one request.
const BATCH: usize = 16;
const MAX_ANSWER: u64 = 64 * 1024;

// Where the pushes go. The relay holds the APNs key of the app, the server only names devices.
pub struct Relay {
    url: reqwest::Url,
    // Sent as a bearer token while the relay is not open to every server.
    key: Option<String>,
    client: reqwest::Client,
}

impl Relay {
    // Reads PENDENZ_PUSH_RELAY and PENDENZ_PUSH_RELAY_KEY. Without the first, push is off.
    pub fn from_env() -> anyhow::Result<Option<Self>> {
        let Some(address) = std::env::var("PENDENZ_PUSH_RELAY")
            .ok()
            .filter(|s| !s.trim().is_empty())
        else {
            return Ok(None);
        };
        let url = reqwest::Url::parse(address.trim())
            .map_err(|_| anyhow::anyhow!("PENDENZ_PUSH_RELAY must be a URL"))?;
        let is_local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
        anyhow::ensure!(
            url.scheme() == "https" || (url.scheme() == "http" && is_local),
            "PENDENZ_PUSH_RELAY must start with https://"
        );
        let key = std::env::var("PENDENZ_PUSH_RELAY_KEY")
            .ok()
            .filter(|s| !s.is_empty());
        let client = reqwest::Client::builder().timeout(TIMEOUT).build()?;
        Ok(Some(Self {
            url: url.join("/v1/push")?,
            key,
            client,
        }))
    }
}

// What has changed since the last push, and who changed it. It stays this small however many
// writes arrive.
#[derive(Default)]
struct Pending {
    changed: bool,
    // The device behind the first change, None for an agent or the command line.
    first: Option<String>,
    // Whether a change came from anyone else since.
    mixed: bool,
}

pub struct Push {
    relay: Option<Relay>,
    pending: Mutex<Pending>,
    wake: Notify,
}

impl Push {
    pub fn new(relay: Option<Relay>) -> Self {
        Self {
            relay,
            pending: Mutex::new(Pending::default()),
            wake: Notify::new(),
        }
    }

    pub fn is_on(&self) -> bool {
        self.relay.is_some()
    }

    // Called after a write is committed. `origin` is the device that wrote: it has the change
    // already and needs no push for it.
    pub fn changed(&self, origin: Option<&str>) {
        if self.relay.is_none() {
            return;
        }
        {
            let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
            if !pending.changed {
                pending.changed = true;
                pending.first = origin.map(str::to_owned);
                pending.mixed = false;
            } else if pending.first.as_deref() != origin {
                pending.mixed = true;
            }
        }
        // Keeps one wake-up when the sender is busy, so a change during a send is not lost.
        self.wake.notify_one();
    }

    // Takes what is pending. The answer is None when nothing changed, and otherwise the one
    // device to leave out, if every change came from it.
    fn take(&self) -> Option<Option<String>> {
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        if !pending.changed {
            return None;
        }
        let taken = std::mem::take(&mut *pending);
        Some(if taken.mixed { None } else { taken.first })
    }
}

#[derive(FromRow)]
struct Registration {
    device_id: String,
    token: String,
    environment: String,
    registration: String,
}

#[derive(Deserialize)]
struct Answer {
    results: Vec<Outcome>,
}

#[derive(Deserialize)]
struct Outcome {
    status: String,
}

// The one sender. It runs for as long as the server does.
pub async fn run(state: AppState) {
    let Some(relay) = &state.push.relay else {
        return;
    };
    loop {
        state.push.wake.notified().await;
        tokio::time::sleep(COLLECT).await;
        let Some(skip) = state.push.take() else {
            continue;
        };
        if let Err(error) = send(&state, relay, skip.as_deref()).await {
            // Not tried again: the next change sends a push, and the app syncs when it comes
            // to the front.
            tracing::warn!(%error, "Push not sent");
        }
        tokio::time::sleep(PAUSE).await;
    }
}

async fn send(state: &AppState, relay: &Relay, skip: Option<&str>) -> anyhow::Result<()> {
    let registered: Vec<Registration> = sqlx::query_as(
        "SELECT p.device_id, p.token, p.environment, p.registration FROM push_tokens p \
         JOIN tokens t ON t.device_id = p.device_id \
         WHERE t.revoked = 0 \
         AND (t.expires_at IS NULL OR t.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')) \
         ORDER BY p.device_id",
    )
    .fetch_all(&state.db)
    .await?;
    let wanted: Vec<&Registration> = registered
        .iter()
        .filter(|r| Some(r.device_id.as_str()) != skip)
        .collect();
    let (mut sent, mut dropped) = (0, 0);
    for batch in wanted.chunks(BATCH) {
        let devices: Vec<Value> = batch
            .iter()
            .map(|r| json!({"token": r.token, "environment": r.environment}))
            .collect();
        let mut request = relay
            .client
            .post(relay.url.clone())
            .json(&json!({"kind": "sync", "devices": devices}));
        if let Some(key) = &relay.key {
            request = request.bearer_auth(key);
        }
        let response = request.send().await?.error_for_status()?;
        anyhow::ensure!(
            response.content_length().is_none_or(|n| n <= MAX_ANSWER),
            "The relay's answer is too long"
        );
        let answer: Answer = response.json().await?;
        anyhow::ensure!(
            answer.results.len() == batch.len(),
            "The relay answered for another number of devices"
        );
        for (registration, outcome) in batch.iter().zip(&answer.results) {
            match outcome.status.as_str() {
                "sent" => sent += 1,
                // APNs no longer knows the token. The app registers again when it has a new one.
                "gone" | "invalid" => {
                    forget(state, registration).await?;
                    dropped += 1;
                }
                other => tracing::warn!(status = other, "Push not delivered to a device"),
            }
        }
    }
    tracing::info!(sent, dropped, "Push sent");
    Ok(())
}

// Removes exactly the registration that was sent. One made in the meantime has another name
// and stays.
async fn forget(state: &AppState, registration: &Registration) -> sqlx::Result<()> {
    let _guard = state.writer.lock().await;
    sqlx::query("DELETE FROM push_tokens WHERE device_id = ? AND registration = ?")
        .bind(&registration.device_id)
        .bind(&registration.registration)
        .execute(&state.db)
        .await?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Register {
    token: String,
    environment: String,
}

// The device a request comes from. Only a paired device has a push token to register.
fn device(identity: &Identity) -> Result<&str> {
    devices::require_owner(identity)?;
    identity
        .device
        .as_deref()
        .ok_or_else(|| ApiError::bad("Only a paired device can register for push."))
}

// A paired device tells the server its APNs token, at every launch that has a new one.
pub async fn register(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
    payload: std::result::Result<Json<Register>, JsonRejection>,
) -> Result<Json<Value>> {
    let device = device(&identity)?;
    let Json(request) = payload
        .map_err(|_| ApiError::bad("Send a JSON object with the token and the environment."))?;
    let token = request.token.to_ascii_lowercase();
    // Apple does not promise a length, so anything from today's 32 bytes up is taken.
    if !(64..=200).contains(&token.len()) || !token.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(ApiError::bad(
            "The token is the APNs device token as hexadecimal digits.",
        ));
    }
    if !["sandbox", "production"].contains(&request.environment.as_str()) {
        return Err(ApiError::bad("The environment is sandbox or production."));
    }
    let _guard = state.writer.lock().await;
    let mut tx = state.db.begin_with("BEGIN IMMEDIATE").await?;
    // Checked again now that the lock is held: the device may have been revoked while this
    // request waited, and a revoked device must not come back into the table.
    let paired: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM tokens WHERE device_id = ? AND revoked = 0 \
         AND (expires_at IS NULL OR expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')))",
    )
    .bind(device)
    .fetch_one(&mut *tx)
    .await?;
    if !paired {
        return Err(ApiError::unauthorized());
    }
    // The same phone, paired again: its token moves to the new pairing.
    sqlx::query("DELETE FROM push_tokens WHERE environment = ? AND token = ? AND device_id <> ?")
        .bind(&request.environment)
        .bind(&token)
        .bind(device)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO push_tokens(device_id, token, environment, registration) VALUES (?, ?, ?, ?) \
         ON CONFLICT(device_id) DO UPDATE SET token = excluded.token, \
         environment = excluded.environment, registration = excluded.registration, \
         updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
    )
    .bind(device)
    .bind(&token)
    .bind(&request.environment)
    .bind(uuid::Uuid::new_v4().to_string())
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    // `push` says whether this server sends pushes at all, for the app's settings.
    Ok(Json(
        json!({"registered": true, "push": state.push.is_on()}),
    ))
}

pub async fn unregister(
    State(state): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Result<Json<Value>> {
    let device = device(&identity)?;
    let _guard = state.writer.lock().await;
    sqlx::query("DELETE FROM push_tokens WHERE device_id = ?")
        .bind(device)
        .execute(&state.db)
        .await?;
    Ok(Json(json!({"registered": false})))
}
