// Status reports: what an agent sends about itself, and the command that collects one on the
// agent's machine. The server stores the checked report and shows it to the owner's devices.
mod claude;
mod hermes;
mod host;
mod text;

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use std::{future::Future, path::PathBuf, time::Duration};

pub const SCHEMA: u32 = 1;

// Every section is optional: a missing one means "not available", an empty list "none".
#[derive(Serialize, Deserialize, Default, Clone)]
#[serde(deny_unknown_fields)]
pub struct Report {
    pub schema: u32,
    pub sent_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<Agent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accounts: Option<Vec<Account>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jobs: Option<Vec<Job>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runs: Option<Vec<Run>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<Host>,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Health {
    Online,
    Degraded,
    Offline,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Agent {
    // The agent software, such as "Hermes Agent".
    pub software: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fallbacks: Vec<String>,
    pub health: Health,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub health_detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<DateTime<Utc>>,
    // Where the agent can be reached, such as Telegram, and whether that works.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub channels: Vec<Channel>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Channel {
    pub name: String,
    pub connected: bool,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AccountKind {
    // Paid per token: shown in money.
    Api,
    // A plan with limits: shown as limit windows and tokens, never as money.
    Subscription,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Account {
    // Stable within one agent's reports, such as "anthropic-api".
    pub id: String,
    pub name: String,
    pub kind: AccountKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    // Which programs use it, such as "Hermes" or "Claude Code".
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub used_by: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub windows: Vec<Window>,
    // Money in US dollars. Estimated unless `estimated` is false.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spend: Option<Spend>,
    // The last 30 days, oldest first, in the agent machine's time zone.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub daily: Vec<Day>,
    // The last 30 days per model, largest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub models: Vec<ModelUse>,
}

impl Account {
    // Adds another program's use of the same account: tokens per day and per model add up.
    fn merge(&mut self, other: Account) {
        for name in other.used_by {
            if !self.used_by.contains(&name) {
                self.used_by.push(name);
            }
        }
        for day in other.daily {
            match self.daily.iter_mut().find(|d| d.date == day.date) {
                Some(mine) => {
                    mine.tokens.add(&day.tokens);
                    if let Some(cost) = day.cost {
                        mine.cost = Some(mine.cost.unwrap_or(0.0) + cost);
                    }
                }
                None => self.daily.push(day),
            }
        }
        self.daily.sort_by_key(|d| d.date);
        for model in other.models {
            match self.models.iter_mut().find(|m| m.model == model.model) {
                Some(mine) => {
                    mine.tokens.add(&model.tokens);
                    mine.sessions += model.sessions;
                    if let Some(cost) = model.cost {
                        mine.cost = Some(mine.cost.unwrap_or(0.0) + cost);
                    }
                }
                None => self.models.push(model),
            }
        }
        self.models.sort_by_key(|m| {
            std::cmp::Reverse(m.tokens.input + m.tokens.output + m.tokens.cache_read)
        });
    }
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Window {
    pub label: String,
    pub used_percent: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<DateTime<Utc>>,
}

#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(deny_unknown_fields)]
pub struct Spend {
    pub estimated: bool,
    pub today: f64,
    pub week: f64,
    pub month: f64,
}

#[derive(Serialize, Deserialize, Clone, Default, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
pub struct Tokens {
    #[serde(default)]
    pub input: u64,
    #[serde(default)]
    pub output: u64,
    #[serde(default)]
    pub cache_read: u64,
    #[serde(default)]
    pub cache_write: u64,
}
impl Tokens {
    fn add(&mut self, other: &Tokens) {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
    }
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Day {
    pub date: NaiveDate,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    #[serde(flatten)]
    pub tokens: Tokens,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct ModelUse {
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    #[serde(default)]
    pub sessions: u64,
    #[serde(flatten)]
    pub tokens: Tokens,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Job {
    pub name: String,
    // In words, such as "Every 5 min" or "Sun 04:00".
    pub schedule: String,
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run_at: Option<DateTime<Utc>>,
    // "ok" or "error"; missing before the first run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub failure_streak: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    // Model runs in the last 7 days, and their tokens. A job that only runs a script has none.
    #[serde(default)]
    pub runs_week: u32,
    #[serde(default)]
    pub tokens_week: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_duration_s: Option<f64>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Run {
    pub title: String,
    // The program, such as "Claude Code".
    pub kind: String,
    // "busy" or "idle".
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<DateTime<Utc>>,
}

#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(deny_unknown_fields)]
pub struct Host {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chip: Option<String>,
    #[serde(default)]
    pub cores: u32,
    #[serde(default)]
    pub uptime_s: u64,
    pub cpu_percent: f64,
    #[serde(default)]
    pub load: Vec<f64>,
    pub memory_used: u64,
    pub memory_total: u64,
    #[serde(default)]
    pub swap_used: u64,
    // Share of memory the system still has free, 0 to 100, where it tells (macOS).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_free_percent: Option<f64>,
    #[serde(default)]
    pub disk_used: u64,
    #[serde(default)]
    pub disk_total: u64,
    // The busiest programs, with the processes of one name added up.
    #[serde(default)]
    pub top: Vec<Process>,
    // The last 24 hours, oldest first.
    #[serde(default)]
    pub series: Vec<Sample>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Process {
    pub name: String,
    #[serde(default = "one")]
    pub count: u32,
    pub cpu_percent: f64,
    pub memory: u64,
}
fn one() -> u32 {
    1
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Sample {
    pub at: DateTime<Utc>,
    pub cpu_percent: f64,
    pub memory_used: u64,
}

// Bounds on what a report may hold. The server cuts to them, so a report it stores is small and
// the apps can draw every list without paging.
const NAME: usize = 80;
const DETAIL: usize = 160;
const MAX_ACCOUNTS: usize = 12;
const MAX_WINDOWS: usize = 6;
const MAX_DAYS: usize = 31;
const MAX_MODELS: usize = 12;
const MAX_JOBS: usize = 50;
const MAX_RUNS: usize = 20;
const MAX_PROCESSES: usize = 16;
const MAX_SAMPLES: usize = 300;
const MAX_CHANNELS: usize = 8;

// The largest count a report keeps: far above any real use, and small enough that the apps can
// add up a month of them without running over.
const MAX_COUNT: u64 = 1_000_000_000_000_000;

fn count(value: &mut u64) {
    *value = (*value).min(MAX_COUNT);
}

impl Tokens {
    fn capped(&mut self) {
        count(&mut self.input);
        count(&mut self.output);
        count(&mut self.cache_read);
        count(&mut self.cache_write);
    }
}

fn finite(value: f64) -> f64 {
    if value.is_finite() { value } else { 0.0 }
}
fn percent(value: f64) -> f64 {
    finite(value).clamp(0.0, 100.0)
}
fn money(value: f64) -> f64 {
    finite(value).max(0.0)
}

impl Report {
    // Cuts every text and list to its bound and clears values that make no sense. Used by the
    // server on every report it takes, and by the collector before it sends one.
    pub fn bounded(mut self) -> Self {
        if let Some(agent) = &mut self.agent {
            agent.software = text::cut(&agent.software, NAME);
            agent.version = agent.version.as_deref().map(|v| text::cut(v, NAME));
            agent.model = agent.model.as_deref().map(|v| text::cut(v, NAME));
            agent.fallbacks.truncate(MAX_MODELS);
            for model in &mut agent.fallbacks {
                *model = text::cut(model, NAME);
            }
            agent.health_detail = agent
                .health_detail
                .as_deref()
                .map(|v| text::cut(&text::clean(v), DETAIL));
            agent.channels.truncate(MAX_CHANNELS);
            for channel in &mut agent.channels {
                channel.name = text::cut(&channel.name, NAME);
            }
        }
        if let Some(accounts) = &mut self.accounts {
            accounts.truncate(MAX_ACCOUNTS);
            for account in accounts {
                account.id = text::cut(&account.id, NAME);
                account.name = text::cut(&account.name, NAME);
                account.plan = account.plan.as_deref().map(|v| text::cut(v, NAME));
                account.used_by.truncate(MAX_MODELS);
                for name in &mut account.used_by {
                    *name = text::cut(name, NAME);
                }
                account.windows.truncate(MAX_WINDOWS);
                for window in &mut account.windows {
                    window.label = text::cut(&window.label, NAME);
                    window.used_percent = percent(window.used_percent);
                }
                if let Some(spend) = &mut account.spend {
                    spend.today = money(spend.today);
                    spend.week = money(spend.week);
                    spend.month = money(spend.month);
                }
                let skip = account.daily.len().saturating_sub(MAX_DAYS);
                account.daily.drain(..skip);
                for day in &mut account.daily {
                    day.cost = day.cost.map(money);
                    day.tokens.capped();
                }
                account.models.truncate(MAX_MODELS);
                for model in &mut account.models {
                    model.model = text::cut(&model.model, NAME);
                    model.cost = model.cost.map(money);
                    model.tokens.capped();
                    count(&mut model.sessions);
                }
            }
        }
        if let Some(jobs) = &mut self.jobs {
            jobs.truncate(MAX_JOBS);
            for job in jobs {
                job.name = text::cut(&job.name, NAME);
                job.schedule = text::cut(&job.schedule, NAME);
                job.last_status = job.last_status.as_deref().map(|v| text::cut(v, 20));
                job.last_error = job
                    .last_error
                    .as_deref()
                    .map(|v| text::cut(&text::clean(v), DETAIL));
                job.last_duration_s = job.last_duration_s.map(|v| finite(v).max(0.0));
                count(&mut job.tokens_week);
            }
        }
        if let Some(runs) = &mut self.runs {
            runs.truncate(MAX_RUNS);
            for run in runs {
                run.title = text::cut(&run.title, NAME);
                run.kind = text::cut(&run.kind, NAME);
                run.state = text::cut(&run.state, 20);
            }
        }
        if let Some(host) = &mut self.host {
            host.name = text::cut(&host.name, NAME);
            host.os = host.os.as_deref().map(|v| text::cut(v, NAME));
            host.chip = host.chip.as_deref().map(|v| text::cut(v, NAME));
            host.cpu_percent = percent(host.cpu_percent);
            host.load.truncate(3);
            host.load.iter_mut().for_each(|v| *v = finite(*v).max(0.0));
            host.memory_free_percent = host.memory_free_percent.map(percent);
            for value in [
                &mut host.memory_used,
                &mut host.memory_total,
                &mut host.swap_used,
                &mut host.disk_used,
                &mut host.disk_total,
                &mut host.uptime_s,
            ] {
                count(value);
            }
            host.disk_used = host.disk_used.min(host.disk_total);
            host.top.truncate(MAX_PROCESSES);
            for process in &mut host.top {
                process.name = text::cut(&process.name, NAME);
                process.cpu_percent = finite(process.cpu_percent).max(0.0);
                count(&mut process.memory);
            }
            let skip = host.series.len().saturating_sub(MAX_SAMPLES);
            host.series.drain(..skip);
            for sample in &mut host.series {
                sample.cpu_percent = percent(sample.cpu_percent);
                count(&mut sample.memory_used);
            }
        }
        self
    }
}

#[derive(clap::Args)]
pub struct Args {
    /// Print the report instead of sending it.
    #[arg(long)]
    dry_run: bool,
    /// Send this report (a JSON file, or - for stdin) instead of collecting one.
    #[arg(long)]
    file: Option<PathBuf>,
    /// Leave out the machine's CPU, memory, disk and busiest programs.
    #[arg(long)]
    no_host: bool,
    /// Hermes Agent's folder. Read when it exists.
    #[arg(long, env = "HERMES_HOME")]
    hermes_home: Option<PathBuf>,
    /// Claude Code's folder. Read when it exists.
    #[arg(long, env = "CLAUDE_CONFIG_DIR")]
    claude_home: Option<PathBuf>,
    /// Where the report command keeps the machine's samples of the last 24 hours.
    #[arg(long, env = "PENDENZ_STATE_DIR")]
    state_dir: Option<PathBuf>,
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
}

// Each source gets this long. A source that takes longer is left out of the report.
const SOURCE_TIME: Duration = Duration::from_secs(25);

async fn bounded_source<T>(
    name: &str,
    source: impl Future<Output = anyhow::Result<T>>,
) -> Option<T> {
    match tokio::time::timeout(SOURCE_TIME, source).await {
        Ok(Ok(value)) => Some(value),
        Ok(Err(error)) => {
            eprintln!("{name}: {error:#}");
            None
        }
        Err(_) => {
            eprintln!("{name}: took longer than {} s", SOURCE_TIME.as_secs());
            None
        }
    }
}

pub async fn collect(args: &Args) -> Report {
    let home = home();
    let hermes_home = args
        .hermes_home
        .clone()
        .or_else(|| home.as_ref().map(|h| h.join(".hermes")));
    let claude_home = args
        .claude_home
        .clone()
        .or_else(|| home.as_ref().map(|h| h.join(".claude")));
    let state_dir = args.state_dir.clone().or_else(|| {
        std::env::var_os("XDG_STATE_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|h| h.join(".local/state")))
            .map(|d| d.join("pendenz"))
    });

    let host = async {
        if args.no_host {
            None
        } else {
            bounded_source("host", host::collect(state_dir.clone())).await
        }
    };
    let hermes = async {
        match hermes_home
            .as_ref()
            .filter(|p| p.join("config.yaml").is_file() || p.join("state.db").is_file())
        {
            Some(path) => {
                bounded_source("hermes", hermes::collect(path.clone(), state_dir.clone())).await
            }
            None => None,
        }
    };
    let claude = async {
        match claude_home
            .as_ref()
            .filter(|p| p.join("projects").is_dir() || p.join("sessions").is_dir())
        {
            Some(path) => bounded_source("claude-code", claude::collect(path.clone())).await,
            None => None,
        }
    };
    let (host, hermes, claude) = tokio::join!(host, hermes, claude);

    let mut report = Report {
        schema: SCHEMA,
        sent_at: Utc::now(),
        host,
        ..Report::default()
    };
    let mut accounts: Vec<Account> = Vec::new();
    let mut runs: Vec<Run> = Vec::new();
    if let Some(hermes) = hermes {
        report.agent = Some(hermes.agent);
        report.jobs = Some(hermes.jobs);
        accounts.extend(hermes.accounts);
    }
    if let Some(claude) = claude {
        runs.extend(claude.runs);
        // Claude Code runs on the Claude plan. When Hermes already found that plan's limits,
        // the tokens join that account.
        match accounts.iter_mut().find(|a| a.id == claude.account.id) {
            Some(account) => account.merge(claude.account),
            None => accounts.push(claude.account),
        }
    }
    if !accounts.is_empty() {
        report.accounts = Some(accounts);
    }
    if report.agent.is_some() || !runs.is_empty() {
        report.runs = Some(runs);
    }
    report.bounded()
}

pub async fn run(args: Args) -> i32 {
    let report = match &args.file {
        Some(path) => match read_file(path) {
            Ok(report) => report,
            Err(error) => {
                eprintln!("{error:#}");
                return 1;
            }
        },
        None => collect(&args).await,
    };
    if args.dry_run {
        match serde_json::to_string_pretty(&report) {
            Ok(text) => {
                println!("{text}");
                return 0;
            }
            Err(error) => {
                eprintln!("{error}");
                return 1;
            }
        }
    }
    crate::agent::cli::send_report(&report).await
}

fn read_file(path: &std::path::Path) -> anyhow::Result<Report> {
    let text = if path.as_os_str() == "-" {
        std::io::read_to_string(std::io::stdin())?
    } else {
        std::fs::read_to_string(path)?
    };
    let report: Report = serde_json::from_str(&text)?;
    anyhow::ensure!(
        report.schema == SCHEMA,
        "This command sends reports with schema {SCHEMA}"
    );
    Ok(report.bounded())
}
