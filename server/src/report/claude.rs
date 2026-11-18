// Claude Code, read from its folder: the sessions open right now, and tokens per day and model
// over the last 30 days from its session logs. Claude Code runs on the Claude plan, so it is
// shown as limits and tokens, never as money.
use super::{Account, AccountKind, Day, ModelUse, Run, Tokens};
use chrono::{DateTime, Duration as Span, Local, NaiveDate, Utc};
use serde::Deserialize;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::{Path, PathBuf},
    time::SystemTime,
};

pub struct Found {
    pub account: Account,
    pub runs: Vec<Run>,
}

pub async fn collect(home: PathBuf) -> anyhow::Result<Found> {
    tokio::task::spawn_blocking(move || {
        Ok(Found {
            account: usage(&home.join("projects")),
            runs: sessions(&home.join("sessions")),
        })
    })
    .await?
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Session {
    pid: u32,
    name: Option<String>,
    status: Option<String>,
    started_at: Option<i64>,
    entrypoint: Option<String>,
}

// Sessions a person or a script started from the command line, while their process lives.
fn sessions(dir: &Path) -> Vec<Run> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let found: Vec<Session> = entries
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
        .filter(|s: &Session| s.entrypoint.as_deref() == Some("cli"))
        .collect();
    let pids: Vec<sysinfo::Pid> = found
        .iter()
        .map(|s| sysinfo::Pid::from_u32(s.pid))
        .collect();
    let Ok(mut system) = sysinfo::System::new() else {
        return Vec::new();
    };
    system.refresh_processes(sysinfo::ProcessesToUpdate::Some(&pids), true);
    let mut runs: Vec<Run> = found
        .into_iter()
        .filter(|s| system.process(sysinfo::Pid::from_u32(s.pid)).is_some())
        .map(|s| Run {
            title: s.name.unwrap_or_else(|| "Claude Code".into()),
            kind: "Claude Code".into(),
            state: s.status.unwrap_or_else(|| "idle".into()),
            started_at: s.started_at.and_then(DateTime::from_timestamp_millis),
        })
        .collect();
    runs.sort_by_key(|r| std::cmp::Reverse(r.started_at));
    runs
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<DateTime<Utc>>,
    session_id: Option<String>,
    request_id: Option<String>,
    message: Option<Message>,
}
#[derive(Deserialize)]
struct Message {
    id: Option<String>,
    model: Option<String>,
    usage: Option<Usage>,
}
#[derive(Deserialize, Default)]
struct Usage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
}

fn logs(dir: &Path, since: SystemTime, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        if meta.is_dir() {
            logs(&path, since, out);
        } else if path.extension().is_some_and(|x| x == "jsonl")
            && meta.modified().is_ok_and(|m| m >= since)
        {
            out.push(path);
        }
    }
}

fn usage(projects: &Path) -> Account {
    let today = Local::now().date_naive();
    let first = today - Span::days(29);
    let since = SystemTime::now() - std::time::Duration::from_secs(31 * 86_400);
    let mut files = Vec::new();
    logs(projects, since, &mut files);

    // One answer is written as several lines while it streams. They share the message and request
    // IDs, and the last one has the final output count, so the largest of each is kept.
    let mut answers: HashMap<String, (NaiveDate, String, Option<String>, Tokens)> = HashMap::new();
    let mut unnamed = 0u64;
    for file in files {
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        for line in text.lines() {
            // Cheap test first: most lines carry no usage.
            if !line.contains("\"usage\"") {
                continue;
            }
            let Ok(line) = serde_json::from_str::<Line>(line) else {
                continue;
            };
            if line.kind.as_deref() != Some("assistant") {
                continue;
            }
            let (Some(message), Some(at)) = (line.message, line.timestamp) else {
                continue;
            };
            let (Some(usage), Some(model)) = (message.usage, message.model) else {
                continue;
            };
            if model.starts_with('<') {
                continue;
            }
            let date = at.with_timezone(&Local).date_naive();
            if date < first || date > today {
                continue;
            }
            let tokens = Tokens {
                input: usage.input_tokens,
                output: usage.output_tokens,
                cache_read: usage.cache_read_input_tokens,
                cache_write: usage.cache_creation_input_tokens,
            };
            let key = match (message.id, line.request_id) {
                (None, None) => {
                    unnamed += 1;
                    format!("#{unnamed}")
                }
                (id, request) => {
                    format!("{}:{}", id.unwrap_or_default(), request.unwrap_or_default())
                }
            };
            let size = |t: &Tokens| t.output + t.input + t.cache_read + t.cache_write;
            match answers.get(&key) {
                Some(kept) if size(&kept.3) >= size(&tokens) => {}
                _ => {
                    answers.insert(key, (date, model, line.session_id, tokens));
                }
            }
        }
    }
    let mut days: BTreeMap<NaiveDate, Tokens> = BTreeMap::new();
    let mut models: HashMap<String, (Tokens, HashSet<String>)> = HashMap::new();
    for (date, model, session, tokens) in answers.into_values() {
        days.entry(date).or_default().add(&tokens);
        let entry = models.entry(model).or_default();
        entry.0.add(&tokens);
        if let Some(session) = session {
            entry.1.insert(session);
        }
    }
    let daily = (0..30)
        .map(|n| {
            let date = first + Span::days(n);
            Day {
                date,
                cost: None,
                tokens: days.get(&date).cloned().unwrap_or_default(),
            }
        })
        .collect();
    let mut models: Vec<ModelUse> = models
        .into_iter()
        .map(|(model, (tokens, sessions))| ModelUse {
            model,
            cost: None,
            sessions: sessions.len() as u64,
            tokens,
        })
        .collect();
    models
        .sort_by_key(|m| std::cmp::Reverse(m.tokens.input + m.tokens.output + m.tokens.cache_read));
    Account {
        id: "anthropic-plan".into(),
        name: "Claude plan".into(),
        kind: AccountKind::Subscription,
        plan: None,
        used_by: vec!["Claude Code".into()],
        windows: Vec::new(),
        spend: None,
        daily,
        models,
    }
}
