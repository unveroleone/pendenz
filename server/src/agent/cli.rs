// The command line for agents and scripts: the same calls as the MCP tools, against the API at
// PENDENZ_API_URL with PENDENZ_API_TOKEN. Each command prints the API's JSON answer.
use super::{
    client::{
        Call, Client, Reply, comment_id, file_body, file_id, item_id, note_id, project_id, query,
    },
    tools::LOCKED_FILE_NOTICE,
};
use axum::http::Method;
use clap::Subcommand;
use serde_json::{Map, Value, json};

// The text under `pendenz --help`.
pub const NOTES: &str = "\
Agent commands (workspace to reminders) need PENDENZ_API_URL and PENDENZ_API_TOKEN, and \
print JSON. PENDENZ_SOURCE names where new items come from, such as telegram.

Item IDs are written P-12 or 12, note IDs are plain numbers. A file can be of any kind, up to \
the size the owner set (workspace settings.file_limit_mb); its ID is in the files list of its \
item or note, and a picture there has a width and a height. An item's place in the manual order of its \
list is its position, highest first: update it to a number between two neighbours.
A note with \"locked\": true is private to the owner: use its text for the task at hand only, \
and do not save or copy it anywhere; the same holds for its files. You can lock a note with \"locked\": true; only the owner \
removes a lock. Write notes very short and in plain text: a title line, then only the facts \
the owner needs.
Every write takes --key KEY; reuse the key when you retry the same action after a network \
error, so it cannot apply twice.";

// Each command takes its arguments as they come, as `--option value` pairs after any IDs.
#[derive(Subcommand)]
pub enum Command {
    /// Who you are, your scopes, the time zone, the projects and the allowed values.
    Workspace(Rest),
    /// List items. [--status open|todo|doing|done] [--project ID|inbox] [--q TEXT] [--tag TAG]
    /// [--priority 0..4] [--stage new|none|...] [--due_after DATE] [--due_before DATE] [--sort newest|due|manual|...]
    /// [--archived true] [--trashed true] [--limit N] [--offset N]
    List(Rest),
    /// One item in full: ID [--activity N]
    Get(Rest),
    /// Add an item: --json '{"title":"...","due_at":"2026-11-13T09:00"}'
    Create(Rest),
    /// Change an item: ID --json '{"version":1,"status":"done"}'
    Update(Rest),
    /// Comment on an item: ID --body TEXT
    Comment(Rest),
    /// Change a comment: ID COMMENT_ID --json '{"version":1,"outdated":true}'
    CommentUpdate(Rest),
    /// Delete a comment: ID COMMENT_ID
    CommentDelete(Rest),
    /// Attach a file of any kind: ID FILE
    AddFile(Rest),
    /// Save a file of an item: ID FILE_ID --out PATH
    GetFile(Rest),
    /// Remove a file: ID FILE_ID
    RemoveFile(Rest),
    /// Create a project: --name NAME [--icon SYMBOL]
    Project(Rest),
    /// Rename or re-icon a project: ID [--name NAME] [--icon SYMBOL]
    ProjectUpdate(Rest),
    /// Delete a project: ID
    ProjectDelete(Rest),
    /// List notes: [--q TEXT] [--project ID|none] [--trashed true] [--limit N] [--offset N]
    Notes(Rest),
    /// One note in full: ID [--activity N]
    Note(Rest),
    /// Add a note: --json '{"body":"Title\n\nText"}'
    NoteCreate(Rest),
    /// Change a note: ID --json '{"version":1,"pinned":true}'
    NoteUpdate(Rest),
    /// Add text at the end of a note: ID --text TEXT
    NoteAppend(Rest),
    /// Attach a file of any kind to a note: ID FILE
    NoteAddFile(Rest),
    /// Save a file of a note: ID FILE_ID --out PATH
    NoteGetFile(Rest),
    /// Remove a file from a note: ID FILE_ID
    NoteRemoveFile(Rest),
    /// What changed since a cursor: [--cursor N] [--limit N]
    Changes(Rest),
    /// Reminders due in a window: --after TIME [--until TIME]
    Reminders(Rest),
}

#[derive(clap::Args)]
pub struct Rest {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    args: Vec<String>,
}

// `--option value` pairs. A later option of the same name replaces the earlier one.
fn options(values: &[String]) -> Result<Map<String, Value>, String> {
    let mut result = Map::new();
    for pair in values.chunks(2) {
        match pair {
            [name, value] if name.starts_with("--") => {
                result.insert(name[2..].to_owned(), Value::String(value.clone()));
            }
            _ => return Err("Expected --option value pairs.".into()),
        }
    }
    Ok(result)
}

fn json_object(text: Option<&Value>) -> Result<Value, String> {
    text.and_then(Value::as_str)
        .and_then(|t| serde_json::from_str::<Value>(t).ok())
        .filter(Value::is_object)
        .ok_or_else(|| "Pass --json with a JSON object.".to_owned())
}

fn text(opts: &Map<String, Value>, name: &str) -> Value {
    opts.get(name).cloned().unwrap_or_else(|| json!(""))
}

fn key(opts: &Map<String, Value>) -> Option<&str> {
    opts.get("key").and_then(Value::as_str)
}

// The next argument, as JavaScript's shift() gives it.
fn shift(args: &mut Vec<String>) -> Option<Value> {
    (!args.is_empty()).then(|| Value::String(args.remove(0)))
}

pub async fn run(command: Command) -> i32 {
    match execute(command).await {
        Ok(result) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&result).unwrap_or_default()
            );
            0
        }
        Err(message) => {
            eprintln!("{message}");
            1
        }
    }
}

async fn execute(command: Command) -> Result<Value, String> {
    let client = Client::from_env();
    let get = |path: String| {
        let client = &client;
        async move { client.get(&path).await }
    };
    let write = |path: String, method: Method, body: Value, key: Option<String>| {
        let client = &client;
        async move {
            Ok::<_, String>(
                client
                    .request(&path, Call::write(method, body, key.as_deref()))
                    .await?
                    .json(),
            )
        }
    };
    let owned = |opts: &Map<String, Value>| key(opts).map(str::to_owned);
    Ok(match command {
        Command::Workspace(_) => get("/bootstrap".into()).await?,
        Command::List(rest) => get(format!("/items{}", query(&options(&rest.args)?))).await?,
        Command::Get(mut rest) => {
            let id = item_id(shift(&mut rest.args).as_ref())?;
            get(format!("/items/{id}{}", query(&options(&rest.args)?))).await?
        }
        Command::Changes(rest) => get(format!("/changes{}", query(&options(&rest.args)?))).await?,
        Command::Reminders(rest) => {
            get(format!("/reminders{}", query(&options(&rest.args)?))).await?
        }
        Command::Create(rest) => {
            let opts = options(&rest.args)?;
            let body = json_object(opts.get("json"))?;
            write("/items".into(), Method::POST, body, owned(&opts)).await?
        }
        Command::Update(mut rest) => {
            let id = item_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            let body = json_object(opts.get("json"))?;
            write(format!("/items/{id}"), Method::PATCH, body, owned(&opts)).await?
        }
        Command::Comment(mut rest) => {
            let id = item_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            let body = json!({"body": text(&opts, "body")});
            write(
                format!("/items/{id}/comments"),
                Method::POST,
                body,
                owned(&opts),
            )
            .await?
        }
        Command::CommentUpdate(mut rest) => {
            let id = item_id(shift(&mut rest.args).as_ref())?;
            let comment = comment_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            let body = json_object(opts.get("json"))?;
            write(
                format!("/items/{id}/comments/{comment}"),
                Method::PATCH,
                body,
                owned(&opts),
            )
            .await?
        }
        Command::CommentDelete(mut rest) => {
            let id = item_id(shift(&mut rest.args).as_ref())?;
            let comment = comment_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            write(
                format!("/items/{id}/comments/{comment}"),
                Method::DELETE,
                json!({}),
                owned(&opts),
            )
            .await?
        }
        Command::AddFile(rest) => add_file(&client, false, rest).await?,
        Command::NoteAddFile(rest) => add_file(&client, true, rest).await?,
        Command::GetFile(rest) => get_file(&client, false, rest).await?,
        Command::NoteGetFile(rest) => get_file(&client, true, rest).await?,
        Command::RemoveFile(rest) => remove_file(&client, false, rest).await?,
        Command::NoteRemoveFile(rest) => remove_file(&client, true, rest).await?,
        Command::Project(rest) => {
            let opts = options(&rest.args)?;
            let mut body = json!({"name": text(&opts, "name")});
            if let Some(icon) = opts.get("icon") {
                body["icon"] = icon.clone();
            }
            write("/projects".into(), Method::POST, body, owned(&opts)).await?
        }
        Command::ProjectUpdate(mut rest) => {
            let id = project_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            let mut body = Map::new();
            for field in ["name", "icon"] {
                if let Some(value) = opts.get(field) {
                    body.insert(field.into(), value.clone());
                }
            }
            write(
                format!("/projects/{id}"),
                Method::PATCH,
                Value::Object(body),
                owned(&opts),
            )
            .await?
        }
        Command::ProjectDelete(mut rest) => {
            let id = project_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            write(
                format!("/projects/{id}"),
                Method::DELETE,
                json!({}),
                owned(&opts),
            )
            .await?
        }
        Command::Notes(rest) => get(format!("/notes{}", query(&options(&rest.args)?))).await?,
        Command::Note(mut rest) => {
            let id = note_id(shift(&mut rest.args).as_ref())?;
            get(format!("/notes/{id}{}", query(&options(&rest.args)?))).await?
        }
        Command::NoteCreate(rest) => {
            let opts = options(&rest.args)?;
            let body = json_object(opts.get("json"))?;
            write("/notes".into(), Method::POST, body, owned(&opts)).await?
        }
        Command::NoteUpdate(mut rest) => {
            let id = note_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            let body = json_object(opts.get("json"))?;
            write(format!("/notes/{id}"), Method::PATCH, body, owned(&opts)).await?
        }
        Command::NoteAppend(mut rest) => {
            let id = note_id(shift(&mut rest.args).as_ref())?;
            let opts = options(&rest.args)?;
            let body = json!({"append": text(&opts, "text")});
            write(format!("/notes/{id}"), Method::PATCH, body, owned(&opts)).await?
        }
    })
}

// The item or note a file command is about, as its API path.
fn holder(note: bool, rest: &mut Rest) -> Result<String, String> {
    let id = shift(&mut rest.args);
    Ok(if note {
        format!("/notes/{}", note_id(id.as_ref())?)
    } else {
        format!("/items/{}", item_id(id.as_ref())?)
    })
}

async fn add_file(client: &Client, note: bool, mut rest: Rest) -> Result<Value, String> {
    let holder = holder(note, &mut rest)?;
    let path = shift(&mut rest.args)
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default();
    let file = file_body(&path)?;
    let opts = options(&rest.args)?;
    Ok(client
        .request(&format!("{holder}/files"), Call::upload(file, key(&opts)))
        .await?
        .json())
}

fn file(note: bool, rest: &mut Rest) -> Result<String, String> {
    file_id(shift(&mut rest.args).as_ref()).map_err(|error| {
        if note {
            "Use a file ID from the note's files list.".into()
        } else {
            error
        }
    })
}

// The copy a file of a locked note becomes on disk carries the lock's rule, as the MCP tool's
// answer does. The note is read before and after the download, so a lock set in between counts.
async fn get_file(client: &Client, note: bool, mut rest: Rest) -> Result<Value, String> {
    let holder = holder(note, &mut rest)?;
    let file = file(note, &mut rest)?;
    let opts = options(&rest.args)?;
    let Some(out) = opts.get("out").and_then(Value::as_str) else {
        return Err("Pass --out with the path to write.".into());
    };
    let locked = note && client.get(&holder).await?["note"]["locked"] == true;
    let call = Call {
        binary: true,
        ..Call::default()
    };
    let (mime, data) = match client
        .request(&format!("{holder}/files/{file}"), call)
        .await?
    {
        Reply::Binary { mime, data } => (mime, data),
        Reply::Json(_) => return Err("The API answered without the file.".into()),
    };
    let locked = locked || note && client.get(&holder).await?["note"]["locked"] == true;
    std::fs::write(out, &data).map_err(|error| format!("Could not write {out}: {error}"))?;
    let mut answer = json!({"file": out, "mime": mime, "bytes": data.len()});
    if locked {
        answer["notice"] = LOCKED_FILE_NOTICE.into();
    }
    Ok(answer)
}

async fn remove_file(client: &Client, note: bool, mut rest: Rest) -> Result<Value, String> {
    let holder = holder(note, &mut rest)?;
    let file = file(note, &mut rest)?;
    let opts = options(&rest.args)?;
    Ok(client
        .request(
            &format!("{holder}/files/{file}"),
            Call::write(Method::DELETE, json!({}), key(&opts)),
        )
        .await?
        .json())
}

// Sends a status report for the agent this token belongs to (`pendenz report`).
// A profile sends with its own saved connection and nothing else, so its report can never go
// out under the token of the machine's other agent. Returns the exit code and the version the
// server named, also when it refused the report.
pub async fn send_report(
    report: &crate::report::Report,
    profile: Option<&str>,
) -> (i32, Option<String>) {
    let body = match serde_json::to_value(report) {
        Ok(body) => body,
        Err(error) => {
            eprintln!("{error}");
            return (1, None);
        }
    };
    let client = match profile {
        Some(name) => match crate::report::setup::saved(Some(name)) {
            Some(saved) => Client::saved(saved),
            None => {
                eprintln!(
                    "The profile {name} is not connected: pendenz connect --profile {name} <server> <code>"
                );
                return (1, None);
            }
        },
        None => Client::from_env(),
    };
    let mut answer = client
        .request("/agents/me/report", Call::write(Method::PUT, body, None))
        .await;
    // A server older than the skills' sentences or the machine's energy refuses a report that
    // has them, and names the field. Sent once more without them, so a collector run ahead of its
    // server still reports.
    let summaries = report
        .jobs
        .iter()
        .flatten()
        .any(|job| job.skill_summary.is_some());
    let energy = report.host.as_ref().is_some_and(|h| h.energy.is_some());
    let refused_field = matches!(&answer, Err(message)
        if message.contains("skill_summary") || message.contains("energy"));
    if (summaries || energy)
        && client.last_status() == Some(400)
        && (refused_field
            || answer.is_err()
                && client
                    .server_version()
                    .is_some_and(|v| crate::report::update::older_than_this(&v)))
    {
        let mut plain = report.clone();
        for job in plain.jobs.iter_mut().flatten() {
            job.skill_summary = None;
        }
        if let Some(host) = &mut plain.host {
            host.energy = None;
        }
        if let Ok(body) = serde_json::to_value(&plain) {
            answer = client
                .request("/agents/me/report", Call::write(Method::PUT, body, None))
                .await;
        }
    }
    let code = match answer {
        Ok(reply) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&reply.json()).unwrap_or_default()
            );
            0
        }
        Err(message) => {
            eprintln!("{message}");
            1
        }
    };
    (code, client.server_version())
}
