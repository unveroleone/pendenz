// Status reports: what an agent sends about itself, and the command that collects one on the
// agent's machine. The server stores the checked report and shows it to the owner's devices.
mod claude;
mod energy;
mod hermes;
mod host;
pub mod setup;
mod skills;
mod smc;
mod text;
pub mod update;

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
    // The first sentence of the description of the skill the job runs, never its prompt.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skill_summary: Option<String>,
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
    // What the machine used and how warm it ran, where a sampler measures it (a Mac).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub energy: Option<Energy>,
}

#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(deny_unknown_fields)]
pub struct Energy {
    // The last minute's average power in watts, and when it was measured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub power_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watts: Option<f64>,
    // The last CPU temperature in degrees Celsius, and when it was measured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temp_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temp_c: Option<f64>,
    // The machine's current month, such as "2026-11", so the apps tell this month from the last
    // in the machine's calendar, not their own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub this_month: Option<String>,
    // This month, then the last, in the machine's time zone. A month without readings is missing.
    #[serde(default)]
    pub months: Vec<EnergyMonth>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct EnergyMonth {
    // "2026-11".
    pub month: String,
    // Missing when the month has no power readings, only temperatures.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kwh: Option<f64>,
    // The hours that were measured; time asleep or without a sampler is missing.
    pub hours: f64,
    // The highest and the median CPU temperature, each the mean of the CPU's sensors.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temp_max: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temp_median: Option<f64>,
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
pub const NAME: usize = 80;
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
const MAX_MONTHS: usize = 2;

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
fn within(value: f64, low: f64, high: f64) -> Option<f64> {
    (value.is_finite() && (low..=high).contains(&value)).then_some(value)
}
const CELSIUS: (f64, f64) = (-40.0, 150.0);

fn is_month(text: &str) -> bool {
    NaiveDate::parse_from_str(&format!("{text}-01"), "%Y-%m-%d").is_ok() && text.len() == 7
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
                job.skill_summary = job
                    .skill_summary
                    .as_deref()
                    .map(|v| text::cut(&text::clean(v), DETAIL))
                    .filter(|v| !v.is_empty());
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
            if let Some(energy) = &mut host.energy {
                energy.watts = energy.watts.and_then(|w| within(w, 0.0, 2000.0));
                energy.temp_c = energy.temp_c.and_then(|c| within(c, CELSIUS.0, CELSIUS.1));
                energy.this_month = energy.this_month.take().filter(|m| is_month(m));
                energy.months.retain(|m| is_month(&m.month));
                energy.months.truncate(MAX_MONTHS);
                for month in &mut energy.months {
                    month.kwh = month.kwh.map(|k| finite(k).clamp(0.0, 10_000.0));
                    // 31 days and the hour a change from summer time adds.
                    month.hours = finite(month.hours).clamp(0.0, 745.0);
                    month.temp_max = month.temp_max.and_then(|c| within(c, CELSIUS.0, CELSIUS.1));
                    month.temp_median = month
                        .temp_median
                        .and_then(|c| within(c, CELSIUS.0, CELSIUS.1));
                }
            }
        }
        self
    }
}

#[derive(clap::Subcommand)]
enum Action {
    /// Send a report every two minutes from now on: a LaunchAgent on macOS, a systemd user
    /// timer on Linux. The options given here go into the job.
    Install {
        /// On a Mac: also measure the machine's power and CPU temperature all the time, so the
        /// reports carry its energy this month. Not for a profile.
        #[arg(long)]
        energy: bool,
    },
    /// Stop sending reports, and stop the energy sampler.
    Uninstall,
    /// Measure the Mac's power and CPU temperature every few seconds until stopped, for the
    /// reports. `report install --energy` runs it as a LaunchAgent.
    #[command(hide = true)]
    Energy,
}

#[derive(clap::Args)]
pub struct Args {
    #[command(subcommand)]
    action: Option<Action>,
    /// A second agent on this machine, such as a second Hermes profile: its own connection from
    /// `pendenz connect --profile`, its own job and its own samples. Only ever given on the
    /// command line, so an inherited variable cannot move a job to another agent's token.
    #[arg(long, global = true)]
    profile: Option<String>,
    /// Print the report instead of sending it.
    #[arg(long)]
    dry_run: bool,
    /// Send this report (a JSON file, or - for stdin) instead of collecting one.
    #[arg(long)]
    file: Option<PathBuf>,
    /// After the report, bring this binary up to the server's version when the server runs a
    /// newer release. `report install` gives the job this option.
    #[arg(long)]
    update: bool,
    /// With `report install`: a job that leaves the binary as it is.
    #[arg(long, global = true)]
    no_update: bool,
    /// Leave out the machine's CPU, memory, disk and busiest programs.
    #[arg(long, global = true)]
    no_host: bool,
    /// Leave out Claude Code, for a second agent whose machine already reports it.
    #[arg(long, global = true)]
    no_claude: bool,
    /// Hermes Agent's folder, or one of its profiles (~/.hermes/profiles/<name>). Read when it
    /// exists.
    #[arg(long, global = true, env = "HERMES_HOME")]
    hermes_home: Option<PathBuf>,
    /// Claude Code's folder. Read when it exists.
    #[arg(long, global = true, env = "CLAUDE_CONFIG_DIR")]
    claude_home: Option<PathBuf>,
    /// Where the report command keeps the machine's samples of the last 24 hours. A profile
    /// keeps its own in a folder of its name inside.
    #[arg(long, global = true, env = "PENDENZ_STATE_DIR")]
    state_dir: Option<PathBuf>,
}

impl Args {
    // The options a scheduled job repeats, with paths made absolute, since the job starts
    // elsewhere and without this shell's environment.
    fn job_options(&self) -> anyhow::Result<Vec<String>> {
        let absolute = |path: &PathBuf| -> anyhow::Result<String> {
            Ok(std::path::absolute(path)?.display().to_string())
        };
        let mut options = Vec::new();
        if !self.no_update {
            options.push("--update".into());
        }
        if let Some(name) = &self.profile {
            options.extend(["--profile".to_owned(), name.clone()]);
        }
        if self.no_host {
            options.push("--no-host".into());
        }
        if self.no_claude {
            options.push("--no-claude".into());
        }
        for (flag, path) in [
            ("--hermes-home", &self.hermes_home),
            ("--claude-home", &self.claude_home),
            ("--state-dir", &self.state_dir),
        ] {
            if let Some(path) = path {
                options.extend([flag.to_owned(), absolute(path)?]);
            }
        }
        Ok(options)
    }
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

// The machine's state folder: the report command's samples, and the energy sampler's file.
fn machine_state_dir(args: &Args) -> Option<PathBuf> {
    args.state_dir.clone().or_else(|| {
        std::env::var_os("XDG_STATE_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| home().map(|h| h.join(".local/state")))
            .map(|d| d.join("pendenz"))
    })
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
    let machine_dir = machine_state_dir(args);
    // A profile keeps its own samples and usage totals beside the machine's.
    let state_dir = machine_dir.clone().map(|dir| match &args.profile {
        Some(name) => dir.join(name),
        None => dir,
    });

    let host = async {
        if args.no_host {
            None
        } else {
            // The machine's energy goes with the machine's own report only, so it shows once.
            let energy_dir = machine_dir.clone().filter(|_| args.profile.is_none());
            bounded_source("host", host::collect(state_dir.clone(), energy_dir)).await
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
            .filter(|_| !args.no_claude)
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

fn print(result: anyhow::Result<serde_json::Value>) -> i32 {
    match result {
        Ok(value) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&value).unwrap_or_default()
            );
            0
        }
        Err(error) => {
            eprintln!("{error:#}");
            1
        }
    }
}

pub async fn connect(server: &str, code: &str, profile: Option<&str>) -> i32 {
    print(setup::connect(server, code, profile).await)
}

pub async fn run(args: Args) -> i32 {
    if let Some(name) = &args.profile
        && let Err(error) = setup::check_profile(name)
    {
        eprintln!("{error}");
        return 1;
    }
    let profile = args.profile.as_deref();
    match args.action {
        Some(Action::Install { energy }) => {
            return print(install(&args, energy));
        }
        Some(Action::Uninstall) => return print(setup::uninstall(profile)),
        Some(Action::Energy) => {
            let Some(dir) = machine_state_dir(&args) else {
                eprintln!("HOME is not set");
                return 1;
            };
            return match energy::sample(dir).await {
                Ok(()) => 0,
                Err(error) => {
                    eprintln!("energy: {error:#}");
                    1
                }
            };
        }
        None => {}
    }
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
    let (code, server_version) = crate::agent::cli::send_report(&report, profile).await;
    // A report from a file is someone else's; only the collecting job updates.
    if args.update
        && !args.no_update
        && args.file.is_none()
        && let Some(version) = server_version
    {
        update::follow(&version).await;
    }
    code
}

// The report job, and on a Mac the energy sampler with it. A sampler installed before follows the
// machine's report: it is installed again with the same state folder, or removed with --no-host.
fn install(args: &Args, energy: bool) -> anyhow::Result<serde_json::Value> {
    let profile = args.profile.as_deref();
    if energy {
        anyhow::ensure!(
            profile.is_none() && !args.no_host,
            "--energy measures the whole machine: install it with the machine's own report, without --profile and --no-host."
        );
        anyhow::ensure!(cfg!(target_os = "macos"), "--energy works on macOS only.");
        let smc = smc::Smc::open()?;
        anyhow::ensure!(
            smc.power().is_some() || smc.cpu_temperature().is_some(),
            "The SMC of this Mac gives neither its power nor its CPU temperature."
        );
    }
    anyhow::ensure!(
        setup::saved(profile).is_some(),
        "{}",
        match profile {
            Some(name) => format!(
                "Connect this profile first: pendenz connect --profile {name} <server> <code>"
            ),
            None => "Connect this machine first: pendenz connect <server> <code>".into(),
        }
    );
    let options = args.job_options()?;
    let state_dir = args
        .state_dir
        .as_ref()
        .map(std::path::absolute)
        .transpose()?;
    let mut result = setup::install(profile, &options)?;
    if profile.is_none() && cfg!(target_os = "macos") {
        let sampler = if energy || (setup::energy_installed() && !args.no_host) {
            setup::install_energy(state_dir.as_deref())
        } else if setup::energy_installed() {
            setup::uninstall_energy().map(|()| serde_json::json!({"uninstalled": true}))
        } else {
            return Ok(result);
        };
        result["energy"] = sampler.map_err(|error| {
            error.context("The report job is installed, the energy sampler is not")
        })?;
    }
    Ok(result)
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
