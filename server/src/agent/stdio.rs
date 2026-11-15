// The MCP server over stdio, for an agent on the same machine. It reads files the agent names,
// so it offers add_item_image.
use super::{
    client::Client,
    server::{Caller, Pendenz},
};
use rmcp::ServiceExt;

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
    let server = Pendenz::for_caller(Caller {
        client,
        scopes,
        files: true,
    })
    .serve(rmcp::transport::stdio())
    .await?;
    server.waiting().await?;
    Ok(())
}
