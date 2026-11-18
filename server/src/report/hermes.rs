// Hermes Agent (https://github.com/NousResearch/hermes-agent), read from its folder: the
// gateway's state, the models in its config, usage and estimated cost from its session store,
// the cron jobs, and the plan limits that `hermes usage` fetches.
use super::{
    Account, AccountKind, Agent, Channel, Day, Health, Job, ModelUse, Spend, Tokens, Window, text,
};
use chrono::{DateTime, Duration as Span, FixedOffset, Local, NaiveDate, Utc};
use serde::Deserialize;
use serde_json::Value;
use sqlx::{
    ConnectOptions, Connection, Row,
    sqlite::{SqliteConnectOptions, SqliteConnection},
};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    path::{Path, PathBuf},
    time::Duration,
};

pub struct Found {
    pub agent: Agent,
    pub accounts: Vec<Account>,
    pub jobs: Vec<Job>,
}

pub async fn collect(home: PathBuf) -> anyhow::Result<Found> {
    let config = Config::read(&home.join("config.yaml"));
    let hermes = binary();
    let providers = config.providers();
    let store = home.join("state.db");
    let (version, windows, usage) = tokio::join!(
        version(&hermes),
        plan_windows(&hermes, &providers),
        usage(&store)
    );
    let mut accounts = usage.unwrap_or_else(|error| {
        eprintln!("hermes usage: {error:#}");
        Vec::new()
    });
    for (provider, plan, found) in windows {
        let id = format!("{provider}-plan");
        match accounts.iter_mut().find(|a| a.id == id) {
            Some(account) => {
                account.windows = found;
                account.plan = plan.or(account.plan.take());
            }
            None => accounts.push(Account {
                id,
                name: account_name(&provider, AccountKind::Subscription),
                kind: AccountKind::Subscription,
                plan,
                used_by: Vec::new(),
                windows: found,
                spend: None,
                daily: Vec::new(),
                models: Vec::new(),
            }),
        }
    }
    let mut agent = gateway(&home);
    agent.version = version;
    agent.model = config.model.clone();
    agent.fallbacks = config.fallbacks.iter().map(|(_, m)| m.clone()).collect();
    Ok(Found {
        agent,
        accounts,
        jobs: jobs(&home.join("cron")),
    })
}

// The `hermes` command: on the PATH, or where its installer puts it, since a LaunchAgent or a
// systemd timer starts with a short PATH.
fn binary() -> PathBuf {
    std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".local/bin/hermes"))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from("hermes"))
}

async fn output(command: &Path, args: &[&str]) -> Option<String> {
    let run = tokio::process::Command::new(command)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(Duration::from_secs(15), run)
        .await
        .ok()?
        .ok()?;
    String::from_utf8(output.stdout).ok()
}

async fn version(hermes: &Path) -> Option<String> {
    // "Hermes Agent v0.23.2 (2026.9.24) · stable · ..."
    let text = output(hermes, &["--version"]).await?;
    let word = text
        .lines()
        .next()?
        .split_whitespace()
        .find(|w| w.starts_with('v'))?;
    Some(word.trim_start_matches('v').to_owned())
}

#[derive(Deserialize)]
struct UsageAnswer {
    plan: Option<String>,
    #[serde(default)]
    windows: Vec<UsageWindow>,
    unavailable_reason: Option<String>,
}
#[derive(Deserialize)]
struct UsageWindow {
    label: String,
    used_percent: f64,
    resets_at: Option<DateTime<Utc>>,
}

// The limit windows of each provider's plan, as `hermes usage` fetches them. A provider used
// with a pay-per-token key answers with no windows and is left out.
async fn plan_windows(
    hermes: &Path,
    providers: &BTreeSet<String>,
) -> Vec<(String, Option<String>, Vec<Window>)> {
    let asks = providers.iter().map(|provider| async move {
        let text = output(hermes, &["usage", "--provider", provider, "--json"]).await?;
        let answer: UsageAnswer = serde_json::from_str(&text).ok()?;
        if answer.unavailable_reason.is_some() || answer.windows.is_empty() {
            return None;
        }
        let windows = answer
            .windows
            .into_iter()
            .map(|w| Window {
                label: w.label,
                used_percent: w.used_percent,
                resets_at: w.resets_at,
            })
            .collect();
        Some((provider.clone(), answer.plan, windows))
    });
    futures_util::future::join_all(asks)
        .await
        .into_iter()
        .flatten()
        .collect()
}

pub fn account_name(provider: &str, kind: AccountKind) -> String {
    match (provider, kind) {
        ("anthropic", AccountKind::Subscription) => "Claude plan".into(),
        ("anthropic", AccountKind::Api) => "Anthropic API".into(),
        ("openai-codex", _) => "ChatGPT plan".into(),
        ("openai", AccountKind::Api) => "OpenAI API".into(),
        ("deepseek", AccountKind::Api) => "DeepSeek API".into(),
        ("openrouter", _) => "OpenRouter".into(),
        ("nous", _) => "Nous Portal".into(),
        (other, AccountKind::Api) => format!("{other} API"),
        (other, AccountKind::Subscription) => format!("{other} plan"),
    }
}

// Usage per account, model and day over the last 30 days, from the session store. Hermes
// estimates the cost of a session from a price list; a session that a plan includes has none.
async fn usage(path: &Path) -> anyhow::Result<Vec<Account>> {
    let mut db: SqliteConnection = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .busy_timeout(Duration::from_secs(3))
        .connect()
        .await?;
    let today = Local::now().date_naive();
    let first = today - Span::days(29);
    let since = first
        .and_hms_opt(0, 0, 0)
        .and_then(|t| t.and_local_timezone(Local).earliest())
        .map(|t| t.timestamp() as f64)
        .unwrap_or(0.0);
    let rows = sqlx::query(
        "SELECT u.model, u.billing_provider AS provider, \
           COALESCE(NULLIF(u.billing_mode, ''), s.billing_mode, '') AS mode, \
           date(s.started_at, 'unixepoch', 'localtime') AS day, \
           COUNT(DISTINCT u.session_id) AS sessions, \
           SUM(u.input_tokens) AS input, SUM(u.output_tokens) AS output, \
           SUM(u.cache_read_tokens) AS cache_read, SUM(u.cache_write_tokens) AS cache_write, \
           SUM(u.estimated_cost_usd) AS estimated, SUM(u.actual_cost_usd) AS actual \
         FROM session_model_usage u JOIN sessions s ON s.id = u.session_id \
         WHERE s.started_at >= ? AND u.billing_provider <> '' \
         GROUP BY 1, 2, 3, 4",
    )
    .bind(since)
    .fetch_all(&mut db)
    .await?;
    db.close().await.ok();

    struct Building {
        kind: AccountKind,
        provider: String,
        days: BTreeMap<NaiveDate, (f64, Tokens)>,
        models: HashMap<String, ModelUse>,
        actual: bool,
    }
    let mut accounts: BTreeMap<String, Building> = BTreeMap::new();
    for row in rows {
        let provider: String = row.try_get("provider")?;
        let mode: String = row.try_get("mode")?;
        let kind = if mode.contains("subscription") {
            AccountKind::Subscription
        } else {
            AccountKind::Api
        };
        let id = format!(
            "{provider}-{}",
            if kind == AccountKind::Api {
                "api"
            } else {
                "plan"
            }
        );
        let day: String = row.try_get("day")?;
        let Ok(day) = NaiveDate::parse_from_str(&day, "%Y-%m-%d") else {
            continue;
        };
        let tokens = Tokens {
            input: row.try_get::<i64, _>("input")?.max(0) as u64,
            output: row.try_get::<i64, _>("output")?.max(0) as u64,
            cache_read: row.try_get::<i64, _>("cache_read")?.max(0) as u64,
            cache_write: row.try_get::<i64, _>("cache_write")?.max(0) as u64,
        };
        let actual: f64 = row.try_get::<Option<f64>, _>("actual")?.unwrap_or(0.0);
        let estimated: f64 = row.try_get::<Option<f64>, _>("estimated")?.unwrap_or(0.0);
        let cost = if actual > 0.0 { actual } else { estimated };
        let model: String = row.try_get("model")?;
        let sessions = row.try_get::<i64, _>("sessions")?.max(0) as u64;

        let account = accounts.entry(id).or_insert_with(|| Building {
            kind,
            provider: provider.clone(),
            days: BTreeMap::new(),
            models: HashMap::new(),
            actual: false,
        });
        account.actual |= actual > 0.0;
        let entry = account.days.entry(day).or_default();
        entry.0 += cost;
        entry.1.add(&tokens);
        let use_ = account.models.entry(model.clone()).or_insert(ModelUse {
            model,
            cost: (kind == AccountKind::Api).then_some(0.0),
            sessions: 0,
            tokens: Tokens::default(),
        });
        use_.sessions += sessions;
        use_.tokens.add(&tokens);
        if let Some(total) = &mut use_.cost {
            *total += cost;
        }
    }

    Ok(accounts
        .into_iter()
        .map(|(id, building)| {
            let api = building.kind == AccountKind::Api;
            let daily: Vec<Day> = (0..30)
                .map(|n| {
                    let date = first + Span::days(n);
                    let (cost, tokens) = building.days.get(&date).cloned().unwrap_or_default();
                    Day {
                        date,
                        cost: api.then_some(round_money(cost)),
                        tokens,
                    }
                })
                .collect();
            let sum = |days: i64| -> f64 {
                daily
                    .iter()
                    .filter(|d| d.date > today - Span::days(days))
                    .filter_map(|d| d.cost)
                    .sum()
            };
            let spend = api.then(|| Spend {
                estimated: !building.actual,
                today: round_money(sum(1)),
                week: round_money(sum(7)),
                month: round_money(sum(30)),
            });
            let mut models: Vec<ModelUse> = building.models.into_values().collect();
            for model in &mut models {
                model.cost = model.cost.map(round_money);
            }
            models.sort_by(|a, b| {
                let size = |m: &ModelUse| m.tokens.input + m.tokens.output + m.tokens.cache_read;
                b.cost
                    .unwrap_or(0.0)
                    .total_cmp(&a.cost.unwrap_or(0.0))
                    .then(size(b).cmp(&size(a)))
            });
            Account {
                id,
                name: account_name(&building.provider, building.kind),
                kind: building.kind,
                plan: None,
                used_by: vec!["Hermes".into()],
                windows: Vec::new(),
                spend,
                daily,
                models,
            }
        })
        .collect())
}

fn round_money(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

// Whether the gateway runs, from the state file it keeps, and whether its process is alive.
fn gateway(home: &Path) -> Agent {
    let mut agent = Agent {
        software: "Hermes Agent".into(),
        version: None,
        model: None,
        fallbacks: Vec::new(),
        health: Health::Offline,
        health_detail: None,
        since: None,
        channels: Vec::new(),
    };
    let state: Option<Value> = std::fs::read(home.join("gateway_state.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    let Some(state) = state else {
        agent.health_detail = Some("The gateway has not run yet".into());
        return agent;
    };
    let pid = state["pid"]
        .as_u64()
        .map(|p| sysinfo::Pid::from_u32(p as u32));
    let process = pid.and_then(|pid| {
        let mut system = sysinfo::System::new().ok()?;
        system.refresh_processes(sysinfo::ProcessesToUpdate::Some(&[pid]), true);
        system.process(pid).map(|p| p.start_time())
    });
    if let Some(platforms) = state["platforms"].as_object() {
        agent.channels = platforms
            .iter()
            .map(|(name, platform)| Channel {
                name: capitalized(name),
                connected: platform["state"].as_str() == Some("connected"),
            })
            .collect();
    }
    let running = state["gateway_state"].as_str() == Some("running");
    match (running, process) {
        (true, Some(started)) => {
            agent.since = DateTime::from_timestamp(started as i64, 0);
            let down: Vec<&str> = agent
                .channels
                .iter()
                .filter(|c| !c.connected)
                .map(|c| c.name.as_str())
                .collect();
            if down.is_empty() {
                agent.health = Health::Online;
            } else {
                agent.health = Health::Degraded;
                agent.health_detail = Some(format!("Not connected: {}", down.join(", ")));
            }
        }
        _ => {
            agent.health_detail = Some(
                state["exit_reason"]
                    .as_str()
                    .map(text::clean)
                    .filter(|r| !r.is_empty())
                    .unwrap_or_else(|| "The gateway is not running".into()),
            );
        }
    }
    agent
}

fn capitalized(name: &str) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

// The few config values the report needs, read line by line so the report command does not
// need a YAML parser: the main model and provider, and the fallbacks.
#[derive(Default)]
struct Config {
    model: Option<String>,
    provider: Option<String>,
    fallbacks: Vec<(String, String)>,
}
impl Config {
    fn read(path: &Path) -> Self {
        let mut config = Config::default();
        let Ok(text) = std::fs::read_to_string(path) else {
            return config;
        };
        let mut section = "";
        let mut fallback: Option<(Option<String>, Option<String>)> = None;
        let value = |line: &str| -> Option<String> {
            let (_, v) = line.split_once(':')?;
            let v = v.split(" #").next()?.trim().trim_matches(['"', '\'']);
            (!v.is_empty()).then(|| v.to_owned())
        };
        for line in text.lines() {
            if line.trim_start().starts_with('#') || line.trim().is_empty() {
                continue;
            }
            let indent = line.len() - line.trim_start().len();
            if indent == 0 {
                section = line.split(':').next().unwrap_or("");
                continue;
            }
            let trimmed = line.trim_start();
            match section {
                "model" if indent == 2 => {
                    if trimmed.starts_with("default:") {
                        config.model = value(trimmed);
                    } else if trimmed.starts_with("provider:") {
                        config.provider = value(trimmed);
                    }
                }
                "fallback_providers" => {
                    let item = trimmed.strip_prefix("- ");
                    if item.is_some()
                        && let Some((Some(p), Some(m))) = fallback.take()
                    {
                        config.fallbacks.push((p, m));
                    }
                    let field = item.unwrap_or(trimmed);
                    let entry = fallback.get_or_insert((None, None));
                    if field.starts_with("provider:") {
                        entry.0 = value(field);
                    } else if field.starts_with("model:") {
                        entry.1 = value(field);
                    }
                }
                _ => {}
            }
        }
        if let Some((Some(p), Some(m))) = fallback {
            config.fallbacks.push((p, m));
        }
        config
    }

    fn providers(&self) -> BTreeSet<String> {
        self.provider
            .iter()
            .chain(self.fallbacks.iter().map(|(p, _)| p))
            .filter(|p| p.as_str() != "auto" && p.as_str() != "custom")
            .cloned()
            .collect()
    }
}

#[derive(Deserialize)]
struct CronJob {
    id: String,
    name: Option<String>,
    #[serde(default)]
    schedule: Value,
    schedule_display: Option<String>,
    #[serde(default = "yes")]
    enabled: bool,
    last_run_at: Option<String>,
    last_status: Option<String>,
    next_run_at: Option<String>,
    #[serde(default)]
    failure_streak: u32,
    last_error: Option<String>,
    last_delivery_error: Option<String>,
}
fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct Audit {
    ts: DateTime<Utc>,
    job_id: String,
    #[serde(default)]
    total_tokens: u64,
    duration_ms: Option<f64>,
}

fn time(value: Option<&str>) -> Option<DateTime<Utc>> {
    DateTime::<FixedOffset>::parse_from_rfc3339(value?)
        .ok()
        .map(|t| t.with_timezone(&Utc))
}

fn jobs(cron: &Path) -> Vec<Job> {
    let list: Vec<CronJob> = std::fs::read(cron.join("jobs.json"))
        .ok()
        .and_then(|bytes| {
            let value: Value = serde_json::from_slice(&bytes).ok()?;
            let list = if value.is_array() {
                value
            } else {
                value.get("jobs")?.clone()
            };
            serde_json::from_value(list).ok()
        })
        .unwrap_or_default();
    let week_ago = Utc::now() - Span::days(7);
    let mut runs: HashMap<String, (u32, u64, Option<f64>)> = HashMap::new();
    if let Ok(text) = std::fs::read_to_string(cron.join("usage_audit.jsonl")) {
        for audit in text
            .lines()
            .filter_map(|l| serde_json::from_str::<Audit>(l).ok())
        {
            let entry = runs.entry(audit.job_id).or_default();
            if audit.ts > week_ago {
                entry.0 += 1;
                entry.1 += audit.total_tokens;
            }
            entry.2 = audit.duration_ms.map(|ms| (ms / 100.0).round() / 10.0);
        }
    }
    let mut jobs: Vec<Job> = list
        .into_iter()
        .map(|job| {
            let (runs_week, tokens_week, last_duration_s) =
                runs.get(&job.id).cloned().unwrap_or_default();
            let status = job.last_status.as_deref().map(|s| {
                if s == "ok" || s == "success" {
                    "ok".to_owned()
                } else {
                    "error".to_owned()
                }
            });
            let failing = status.as_deref() == Some("error") || job.failure_streak > 0;
            Job {
                name: job.name.unwrap_or(job.id),
                schedule: schedule(&job.schedule, job.schedule_display.as_deref()),
                enabled: job.enabled,
                last_run_at: time(job.last_run_at.as_deref()),
                last_status: status,
                next_run_at: time(job.next_run_at.as_deref()).filter(|_| job.enabled),
                failure_streak: job.failure_streak,
                last_error: if failing {
                    job.last_error
                        .or(job.last_delivery_error)
                        .map(|e| text::clean(&e))
                } else {
                    None
                },
                runs_week,
                tokens_week,
                last_duration_s,
            }
        })
        .collect();
    jobs.sort_by(|a, b| a.next_run_at.cmp(&b.next_run_at).then(a.name.cmp(&b.name)));
    jobs
}

const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// A job's schedule in words: "Every 5 min", "Hourly", "Daily 09:00, 13:00", "Sun 04:00".
// Anything else is shown as written.
pub fn schedule(schedule: &Value, display: Option<&str>) -> String {
    let fallback = display
        .map(str::to_owned)
        .or_else(|| schedule["display"].as_str().map(str::to_owned))
        .unwrap_or_default();
    if schedule["kind"] == "interval"
        && let Some(minutes) = schedule["minutes"].as_u64()
    {
        return match minutes {
            60 => "Hourly".into(),
            m if m % 1440 == 0 => format!("Every {} days", m / 1440),
            m if m % 60 == 0 => format!("Every {} h", m / 60),
            m => format!("Every {m} min"),
        };
    }
    let Some(expr) = schedule["expr"].as_str() else {
        return fallback;
    };
    cron_words(expr).unwrap_or(fallback)
}

fn cron_words(expr: &str) -> Option<String> {
    let fields: Vec<&str> = expr.split_whitespace().collect();
    let [minute, hour, day, month, weekday] = fields[..] else {
        return None;
    };
    if day != "*" || month != "*" {
        return None;
    }
    let numbers = |field: &str, max: u32| -> Option<Vec<u32>> {
        field
            .split(',')
            .map(|n| n.parse().ok().filter(|n| *n <= max))
            .collect()
    };
    let minutes = numbers(minute, 59)?;
    if hour == "*" && weekday == "*" && minutes.len() == 1 {
        return Some(if minutes[0] == 0 {
            "Hourly".into()
        } else {
            format!("Hourly at :{:02}", minutes[0])
        });
    }
    let hours = numbers(hour, 23)?;
    let mut times: Vec<String> = Vec::new();
    for h in &hours {
        for m in &minutes {
            times.push(format!("{h:02}:{m:02}"));
        }
    }
    let when = if weekday == "*" {
        "Daily".to_owned()
    } else {
        let days = numbers(weekday, 7)?;
        days.iter()
            .map(|d| DAYS[(*d % 7) as usize])
            .collect::<Vec<_>>()
            .join(", ")
    };
    Some(format!("{when} {}", times.join(", ")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn schedules_in_words() {
        let cron = |expr: &str| schedule(&json!({"kind": "cron", "expr": expr}), None);
        assert_eq!(cron("0 4 * * 0"), "Sun 04:00");
        assert_eq!(cron("0 9,13,18 * * *"), "Daily 09:00, 13:00, 18:00");
        assert_eq!(cron("0 13 * * 0,2,4"), "Sun, Tue, Thu 13:00");
        assert_eq!(cron("0 * * * *"), "Hourly");
        assert_eq!(cron("*/5 * 1 * *"), "");
        assert_eq!(
            schedule(&json!({"kind": "interval", "minutes": 5}), None),
            "Every 5 min"
        );
        assert_eq!(
            schedule(&json!({"kind": "interval", "minutes": 120}), None),
            "Every 2 h"
        );
    }

    #[test]
    fn reads_models_from_config() {
        let dir = std::env::temp_dir().join(format!("pendenz-hermes-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.yaml");
        std::fs::write(
            &path,
            "model:\n  # comment\n  default: \"claude-sonnet-5-5\"\n  provider: \"anthropic\"\n  aliases:\n    opus:\n      model: x\n      provider: y\nfallback_providers:\n  - provider: openai-codex\n    model: gpt-6.1-sol\n  - provider: deepseek\n    model: deepseek-flash\nother: 1\n",
        )
        .unwrap();
        let config = Config::read(&path);
        assert_eq!(config.model.as_deref(), Some("claude-sonnet-5-5"));
        assert_eq!(config.provider.as_deref(), Some("anthropic"));
        assert_eq!(
            config.fallbacks,
            vec![
                ("openai-codex".to_owned(), "gpt-6.1-sol".to_owned()),
                ("deepseek".to_owned(), "deepseek-flash".to_owned())
            ]
        );
        std::fs::remove_dir_all(dir).ok();
    }
}
