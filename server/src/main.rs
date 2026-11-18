// The current time as SQLite writes it. A macro rather than a constant, so a query can take it
// in concat! and stay a string known at compile time, which is what sqlx accepts.
macro_rules! now {
    () => {
        "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
    };
}

mod agent;
mod agents;
mod auth;
mod changes;
mod comments;
mod devices;
mod error;
mod files;
mod images;
mod items;
mod model;
mod notes;
mod push;
mod repeat;
mod report;
mod settings;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Request, State},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::Response,
    routing::{any, delete, get, patch, post, put},
};
use clap::{Parser, Subcommand};
use serde_json::json;
use sqlx::{
    SqlitePool,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions},
};
use std::{net::SocketAddr, str::FromStr, sync::Arc, time::Duration};
use tokio::sync::Mutex;
use tracing_subscriber::EnvFilter;

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub local: bool,
    pub tz: chrono_tz::Tz,
    // SQLite has one writer. Every write route takes this lock for its whole transaction.
    pub writer: Arc<Mutex<()>>,
    // Asks the paired devices to sync after a change. Does nothing without a relay.
    pub push: Arc<push::Push>,
    // Room for the file uploads that are read into memory at the same time.
    pub uploads: Arc<tokio::sync::Semaphore>,
    // The same for the file downloads, each held until it is sent.
    pub downloads: Arc<tokio::sync::Semaphore>,
}

#[derive(Parser)]
#[command(version, about = "Pendenz server, its admin commands, and the MCP server and command line for agents", after_help = agent::cli::NOTES)]
struct Args {
    #[arg(long, env = "DATABASE_URL", default_value = "sqlite://data/pendenz.db")]
    database_url: String,
    #[command(subcommand)]
    command: Option<Command>,
}
#[derive(Subcommand)]
enum Command {
    /// Run the API (default).
    Serve,
    /// Set the name agents and the activity log use for the owner, the one person of this server.
    SetOwnerName {
        #[arg(long)]
        name: String,
    },
    /// Add an agent identity, one per connection, so the activity log shows who did what.
    /// The telegram scope is only given to the agent with the ID telegram-bridge.
    AddAgent {
        #[arg(long)]
        id: String,
        #[arg(long)]
        name: String,
    },
    /// Issue a bearer token. The token is printed once and stored only as a hash.
    IssueToken {
        #[arg(long)]
        actor: String,
        #[arg(long)]
        label: String,
        #[arg(long, default_value = "read")]
        scopes: String,
        /// Days until the token expires. Without it the token does not expire.
        #[arg(long)]
        days: Option<i64>,
    },
    ListTokens,
    RevokeToken {
        id: String,
    },
    /// Print a one-time code that pairs a new iPhone, iPad or Mac. It works for ten minutes.
    PairingCode,
    ListDevices,
    /// Revoke the token of a paired device.
    RevokeDevice {
        id: String,
    },
    /// Run the MCP server over stdio for an agent on this machine, with PENDENZ_API_URL and
    /// PENDENZ_API_TOKEN.
    Mcp,
    /// Collect a status report on this machine (the agent software found here, its usage and
    /// jobs, and the machine's load) and send it with PENDENZ_API_URL and PENDENZ_API_TOKEN.
    Report(report::Args),
    /// Connect this machine as an agent with a code from the app's settings (Agents, Connect an
    /// Agent). Saves the server and the new token for the agent commands of this user.
    Connect {
        server: String,
        code: String,
    },
    #[command(flatten)]
    Agent(agent::cli::Command),
    // Anything else, answered as the agent command line always did.
    #[command(external_subcommand)]
    #[allow(dead_code)]
    Unknown(Vec<String>),
}

fn valid_name(name: &str) -> anyhow::Result<&str> {
    let name = name.trim();
    anyhow::ensure!(
        !name.is_empty() && name.chars().count() <= 80 && !name.chars().any(char::is_control),
        "Use a name between 1 and 80 characters"
    );
    Ok(name)
}

async fn set_owner_name(db: &SqlitePool, name: &str) -> anyhow::Result<()> {
    let name = valid_name(name)?;
    sqlx::query("UPDATE actors SET name = ? WHERE id = ?")
        .bind(name)
        .bind(auth::OWNER)
        .execute(db)
        .await?;
    println!(
        "{}",
        json!({"id": auth::OWNER, "name": name, "kind": "human"})
    );
    Ok(())
}

async fn add_agent(db: &SqlitePool, id: &str, name: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !id.is_empty()
            && id.len() <= 40
            && id
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-'),
        "Use a lowercase agent ID with letters, digits or hyphens, up to 40 characters"
    );
    let name = valid_name(name)?;
    let known: Option<String> = sqlx::query_scalar("SELECT id FROM actors WHERE id = ?")
        .bind(id)
        .fetch_optional(db)
        .await?;
    anyhow::ensure!(known.is_none(), "An actor with this ID already exists");
    sqlx::query("INSERT INTO actors(id, name, kind) VALUES (?, ?, 'agent')")
        .bind(id)
        .bind(name)
        .execute(db)
        .await?;
    println!("{}", json!({"id": id, "name": name, "kind": "agent"}));
    Ok(())
}

async fn issue_token(
    db: &SqlitePool,
    actor: &str,
    label: &str,
    scopes: &str,
    days: Option<i64>,
) -> anyhow::Result<()> {
    let label = label.trim();
    anyhow::ensure!(
        !label.is_empty() && label.chars().count() <= 60 && !label.chars().any(char::is_control),
        "Use a label between 1 and 60 characters"
    );
    let kind: Option<String> = sqlx::query_scalar("SELECT kind FROM actors WHERE id = ?")
        .bind(actor)
        .fetch_optional(db)
        .await?;
    let kind = kind.ok_or_else(|| anyhow::anyhow!("Unknown actor. Add the agent first."))?;
    let requested: Vec<&str> = scopes.split(',').map(str::trim).collect();
    anyhow::ensure!(
        requested.iter().all(|s| auth::SCOPES.contains(s)),
        "Scopes are read, write, propose, approve, telegram and report"
    );
    // Stored in one fixed order without duplicates.
    let granted: Vec<&str> = auth::SCOPES
        .into_iter()
        .filter(|s| requested.contains(s))
        .collect();
    anyhow::ensure!(
        kind == "human" || !granted.contains(&"approve"),
        "Agents cannot approve"
    );
    anyhow::ensure!(
        if actor == "telegram-bridge" {
            granted == ["telegram"]
        } else {
            !granted.contains(&"telegram")
        },
        "The telegram scope belongs to telegram-bridge, which gets no other scope"
    );
    anyhow::ensure!(
        days.is_none_or(|d| (1..=3650).contains(&d)),
        "Use between 1 and 3650 days"
    );
    let id = uuid::Uuid::new_v4().to_string();
    let token = auth::new_token();
    let scopes = granted.join(",");
    let mut tx = db.begin().await?;
    let expires_at: Option<String> = sqlx::query_scalar(
        "INSERT INTO tokens(id, actor_id, label, token_hash, scopes, expires_at) \
         VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', ?)) RETURNING expires_at",
    )
    .bind(&id)
    .bind(actor)
    .bind(label)
    .bind(auth::hash(&token))
    .bind(&scopes)
    .bind(days.map(|d| format!("+{d} days")))
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query("INSERT INTO activity(actor_id, action, detail) VALUES (?, 'token_issued', ?)")
        .bind(auth::OWNER)
        .bind(json!({"id": id, "actor": actor, "label": label, "scopes": granted}).to_string())
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    println!(
        "{}",
        json!({"id": id, "actor": actor, "label": label, "scopes": granted, "expires_at": expires_at, "token": token})
    );
    Ok(())
}

async fn list_tokens(db: &SqlitePool) -> anyhow::Result<()> {
    type Row = (
        String,
        String,
        String,
        String,
        bool,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
    );
    let rows: Vec<Row> = sqlx::query_as(
        "SELECT id, actor_id, label, scopes, revoked, expires_at, last_used_at, created_at, \
         device_id FROM tokens ORDER BY created_at",
    )
    .fetch_all(db)
    .await?;
    let tokens: Vec<_> = rows
        .into_iter()
        .map(
            |(id, actor, label, scopes, revoked, expires_at, last_used_at, created_at, device)| {
                json!({"id": id, "actor": actor, "label": label,
                "scopes": scopes.split(',').collect::<Vec<_>>(), "revoked": revoked,
                "expires_at": expires_at, "last_used_at": last_used_at, "created_at": created_at,
                "device_id": device})
            },
        )
        .collect();
    println!("{}", serde_json::to_string_pretty(&tokens)?);
    Ok(())
}

async fn revoke_token(db: &SqlitePool, id: &str) -> anyhow::Result<()> {
    let mut tx = db.begin_with("BEGIN IMMEDIATE").await?;
    let found: Option<(bool, Option<String>)> =
        sqlx::query_as("SELECT revoked, device_id FROM tokens WHERE id = ?")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await?;
    let (revoked, device) = found.ok_or_else(|| anyhow::anyhow!("Token not found"))?;
    if let Some(device) = device {
        // The token of a paired device: revoked as the device, so the pairing codes it showed
        // and nobody used go with it.
        devices::revoke_device(&mut tx, &device, None).await?;
    } else if !revoked {
        sqlx::query("UPDATE tokens SET revoked = 1 WHERE id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "INSERT INTO activity(actor_id, action, detail) VALUES (?, 'token_revoked', ?)",
        )
        .bind(auth::OWNER)
        .bind(json!({"id": id}).to_string())
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    println!("{}", json!({"id": id, "revoked": true}));
    Ok(())
}

// The first device is paired with a code from here. Later ones get theirs from a paired device.
async fn pairing_code(db: &SqlitePool) -> anyhow::Result<()> {
    let mut tx = db.begin_with("BEGIN IMMEDIATE").await?;
    let (code, expires_at) = devices::new_pairing_code(&mut tx, None).await?;
    tx.commit().await?;
    println!("{}", json!({"code": code, "expires_at": expires_at}));
    Ok(())
}

async fn list_devices(db: &SqlitePool) -> anyhow::Result<()> {
    let mut conn = db.acquire().await?;
    let devices = devices::paired_devices(&mut conn).await?;
    println!("{}", serde_json::to_string_pretty(&devices)?);
    Ok(())
}

async fn revoke_device(db: &SqlitePool, id: &str) -> anyhow::Result<()> {
    let mut tx = db.begin_with("BEGIN IMMEDIATE").await?;
    devices::revoke_device(&mut tx, id, None)
        .await?
        .ok_or_else(|| anyhow::anyhow!("Device not found"))?;
    tx.commit().await?;
    println!("{}", json!({"id": id, "revoked": true}));
    Ok(())
}

// Private data: no proxy or client may keep a copy of an answer, or guess its type. Every
// answer also names the server's version, so an app that is newer than its server can tell
// a change this server does not know yet from one it refuses for good.
async fn response_headers(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        "pendenz-version",
        HeaderValue::from_static(env!("CARGO_PKG_VERSION")),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

async fn shutdown() {
    let mut terminate =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = async {
            match terminate.as_mut() {
                Some(signal) => { signal.recv().await; }
                None => std::future::pending().await,
            }
        } => {}
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    // The agent commands run on the agent's machine. They talk to an API and need no database
    // and no log on stdout, which is theirs.
    match args.command {
        Some(Command::Mcp) => return agent::stdio::run().await,
        Some(Command::Report(args)) => std::process::exit(report::run(args).await),
        Some(Command::Connect { server, code }) => {
            std::process::exit(report::connect(&server, &code).await)
        }
        Some(Command::Agent(command)) => std::process::exit(agent::cli::run(command).await),
        Some(Command::Unknown(_)) => {
            eprintln!("Unknown command. Run with --help.");
            std::process::exit(1);
        }
        _ => {}
    }
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "pendenz=info,tower_http=info".into()),
        )
        .init();
    let options = SqliteConnectOptions::from_str(&args.database_url)?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(10));
    if let Some(parent) = options.get_filename().parent()
        && !parent.as_os_str().is_empty()
    {
        std::fs::create_dir_all(parent)?;
    }
    let db = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?;
    sqlx::migrate!("./migrations").run(&db).await?;
    match args.command.unwrap_or(Command::Serve) {
        Command::SetOwnerName { name } => return set_owner_name(&db, &name).await,
        Command::AddAgent { id, name } => return add_agent(&db, &id, &name).await,
        Command::IssueToken {
            actor,
            label,
            scopes,
            days,
        } => return issue_token(&db, &actor, &label, &scopes, days).await,
        Command::ListTokens => return list_tokens(&db).await,
        Command::RevokeToken { id } => return revoke_token(&db, &id).await,
        Command::PairingCode => return pairing_code(&db).await,
        Command::ListDevices => return list_devices(&db).await,
        Command::RevokeDevice { id } => return revoke_device(&db, &id).await,
        Command::Serve => {}
        Command::Mcp
        | Command::Report(_)
        | Command::Connect { .. }
        | Command::Agent(_)
        | Command::Unknown(_) => {
            unreachable!()
        }
    }
    let mode = std::env::var("PENDENZ_AUTH_MODE").unwrap_or_else(|_| "token".into());
    anyhow::ensure!(
        ["local", "token"].contains(&mode.as_str()),
        "PENDENZ_AUTH_MODE must be token or local"
    );
    let local = mode == "local";
    let bind: SocketAddr = std::env::var("PENDENZ_BIND")
        .unwrap_or_else(|_| "127.0.0.1:8080".into())
        .parse()?;
    anyhow::ensure!(
        !local || bind.ip().is_loopback(),
        "Local mode must bind to a loopback address"
    );
    let tz: chrono_tz::Tz = std::env::var("PENDENZ_TIMEZONE")
        .unwrap_or_else(|_| "Europe/Zurich".into())
        .parse()
        .map_err(|_| anyhow::anyhow!("PENDENZ_TIMEZONE must be an IANA zone like Europe/Zurich"))?;
    if local {
        tracing::warn!(
            "Local development mode: requests without a token act as the owner. Do not expose this listener."
        );
    }
    // Replay protection only has to cover client retries, so old keys can go.
    sqlx::query(
        "DELETE FROM idempotency WHERE created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 days')",
    )
    .execute(&db)
    .await?;
    let relay = push::Relay::from_env()?;
    let state = AppState {
        db,
        local,
        tz,
        writer: Arc::new(Mutex::new(())),
        push: Arc::new(push::Push::new(relay)),
        uploads: Arc::new(tokio::sync::Semaphore::new(files::UPLOADS_AT_ONCE)),
        downloads: Arc::new(tokio::sync::Semaphore::new(files::DOWNLOADS_AT_ONCE)),
    };
    if state.push.is_on() {
        tokio::spawn(push::run(state.clone()));
    }
    let state_push = state.push.is_on();
    let api = Router::new()
        .route("/identity", get(auth::identity))
        .route("/bootstrap", get(items::bootstrap))
        .route("/items", get(items::list).post(items::write))
        .route("/items/{id}", get(items::detail).patch(items::write))
        .route("/items/{id}/comments", post(items::write))
        .route(
            "/items/{id}/comments/{comment}",
            patch(items::write).delete(items::write),
        )
        // An image is larger than anything else the API takes, so this route alone gets room.
        .route(
            "/items/{id}/images",
            post(items::write)
                .layer(DefaultBodyLimit::max(images::BODY_LIMIT))
                .layer(middleware::from_fn_with_state(
                    state.clone(),
                    files::one_of_the_uploads,
                )),
        )
        .route(
            "/items/{id}/images/{image}",
            get(images::download).delete(items::write),
        )
        // A file is read by its own handler, which sets its own limit (the ceiling).
        .route(
            "/items/{id}/files",
            post(files::upload).layer(DefaultBodyLimit::disable()),
        )
        .route(
            "/items/{id}/files/{file}",
            get(files::download).delete(items::write),
        )
        .route("/settings", get(settings::get).patch(settings::update))
        .route("/projects", post(items::write))
        .route("/projects/{id}", patch(items::write).delete(items::write))
        .route("/notes", get(notes::list).post(items::write))
        .route("/notes/{id}", get(notes::detail).patch(items::write))
        .route("/devices", get(devices::list))
        .route("/devices/{id}", delete(devices::revoke))
        .route("/pairing-codes", post(devices::create_code))
        .route("/push-token", put(push::register).delete(push::unregister))
        .route("/agents", get(agents::list))
        .route("/agents/{id}", delete(agents::revoke))
        .route("/agent-codes", post(agents::create_code))
        .route(
            "/agents/me/report",
            put(agents::put_report).layer(DefaultBodyLimit::max(agents::BODY_LIMIT)),
        )
        .route("/changes", get(changes::changes))
        .route("/reminders", get(changes::reminders))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth::authenticate,
        ))
        // Added after the layer above: a device that pairs has no token yet.
        .route("/pair", post(devices::pair))
        // The same for an agent that connects with a code from the app.
        .route("/agents/connect", post(agents::connect));
    // What clients call this server, for the hosted MCP endpoint's host check.
    let origin = std::env::var("PENDENZ_ORIGIN")
        .ok()
        .filter(|origin| !origin.is_empty())
        .unwrap_or_else(|| format!("http://{bind}"));
    let hosted = Arc::new(agent::hosted::Hosted::new(
        state.clone(),
        Router::new()
            .nest("/api", api.clone())
            .with_state(state.clone()),
        &origin,
    )?);
    let app = Router::new()
        .nest("/api", api)
        .route("/mcp", any(agent::hosted::handle).with_state(hosted))
        .route("/healthz", get(|| async { Json(json!({"status": "ok"})) }))
        .route(
            "/readyz",
            get(|State(state): State<AppState>| async move {
                sqlx::query("SELECT 1")
                    .execute(&state.db)
                    .await
                    .map_err(error::ApiError::from)?;
                Ok::<_, error::ApiError>(Json(json!({"status": "ready"})))
            }),
        )
        .fallback(|| async { error::ApiError::missing() })
        .method_not_allowed_fallback(|| async {
            error::ApiError(
                StatusCode::METHOD_NOT_ALLOWED,
                "This route does not support that method.".into(),
            )
        })
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(middleware::from_fn(response_headers))
        .layer(tower_http::trace::TraceLayer::new_for_http())
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!(%bind, mode, %tz, push = state_push, "Pendenz API listening");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown())
    .await?;
    Ok(())
}
