// The MCP server over stdio, for an agent on the same machine: one JSON-RPC message per line in
// and out. It reads files the agent names, so it offers add_item_image.
use super::{
    client::Client,
    protocol::{self, Session},
};
use serde_json::Value;
use std::sync::Arc;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::Mutex,
};

pub async fn run() -> anyhow::Result<()> {
    let client = Client::from_env();
    // Offer only the tools this token may use. If the API cannot be reached at start, offer all
    // of them and let each call report the error.
    let scopes = client.get("/identity").await.ok().and_then(|identity| {
        identity["scopes"].as_array().map(|scopes| {
            scopes
                .iter()
                .filter_map(|s| s.as_str().map(str::to_owned))
                .collect()
        })
    });
    let session = Arc::new(Session {
        client,
        scopes,
        files: true,
    });
    let out = Arc::new(Mutex::new(tokio::io::stdout()));
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut running = tokio::task::JoinSet::new();
    while let Some(line) = lines.next_line().await? {
        // A line that is not a JSON-RPC message is dropped, as the protocol has no way to
        // answer it.
        let Some(message) = serde_json::from_str::<Value>(&line)
            .ok()
            .and_then(|m| protocol::parse(&m))
        else {
            continue;
        };
        while running.try_join_next().is_some() {}
        // Calls run side by side, so a slow one does not hold up a ping.
        let session = session.clone();
        let out = out.clone();
        running.spawn(async move {
            if let Some(answer) = session.handle(message).await {
                let mut line = answer.to_string();
                line.push('\n');
                let mut out = out.lock().await;
                let _ = out.write_all(line.as_bytes()).await;
                let _ = out.flush().await;
            }
        });
    }
    while running.join_next().await.is_some() {}
    Ok(())
}
