// The machine's energy and temperature. `pendenz report energy` runs all the time (a LaunchAgent
// from `report install --energy`), reads the SMC every few seconds and keeps a day's totals in
// `energy.json` in the machine's state folder. The report command reads that file and sends this
// month and the last.
use super::smc::Smc;
use super::{Energy, EnergyMonth};
use chrono::{DateTime, Datelike, Duration as Span, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

const FILE: &str = "energy.json";
const FORMAT: u32 = 1;
// How often the SMC is read, and how often the totals go to disk.
const EVERY: Duration = Duration::from_secs(5);
const WRITE_EVERY: Duration = Duration::from_secs(60);
// A longer pause between two readings (sleep, a stopped process, a failed read) is not counted.
const LONGEST_GAP: Duration = Duration::from_secs(30);
// Days kept in the file: enough for this month and the last.
const KEEP_DAYS: i64 = 62;

#[derive(Serialize, Deserialize, Default)]
struct State {
    format: u32,
    // The last minute's average power and the last temperature, each with when it was measured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    power_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    watts: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    temp_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    temp_c: Option<f64>,
    #[serde(default)]
    days: Vec<Day>,
}

// One day in the machine's time zone.
#[derive(Serialize, Deserialize, Clone)]
struct Day {
    date: NaiveDate,
    #[serde(default)]
    wh: f64,
    // Seconds with a power reading at both ends.
    #[serde(default)]
    power_s: f64,
    // Seconds spent at each whole degree of CPU temperature, and the day's highest reading.
    #[serde(default)]
    temps: BTreeMap<i32, f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    temp_max: Option<f64>,
}

impl State {
    fn day(&mut self, date: NaiveDate) -> &mut Day {
        let index = match self.days.iter().position(|d| d.date == date) {
            Some(index) => index,
            None => {
                self.days.push(Day {
                    date,
                    wh: 0.0,
                    power_s: 0.0,
                    temps: BTreeMap::new(),
                    temp_max: None,
                });
                self.days.sort_by_key(|d| d.date);
                self.days
                    .iter()
                    .position(|d| d.date == date)
                    .expect("added")
            }
        };
        &mut self.days[index]
    }

    // Adds power between two readings over `seconds` that end at `end`, split at midnight.
    fn add_power(&mut self, end: DateTime<Local>, seconds: f64, from: f64, to: f64) {
        let watts = (from + to) / 2.0;
        let start = end - Span::milliseconds((seconds * 1000.0) as i64);
        let parts = if start.date_naive() == end.date_naive() {
            vec![(end.date_naive(), seconds)]
        } else {
            let midnight = end
                .date_naive()
                .and_hms_opt(0, 0, 0)
                .and_then(|t| t.and_local_timezone(Local).earliest())
                .unwrap_or(end);
            let after = ((end - midnight).num_milliseconds() as f64 / 1000.0).clamp(0.0, seconds);
            vec![
                (start.date_naive(), seconds - after),
                (end.date_naive(), after),
            ]
        };
        for (date, part) in parts {
            if part <= 0.0 {
                continue;
            }
            let day = self.day(date);
            day.wh += watts * part / 3600.0;
            day.power_s += part;
        }
    }

    fn add_temperature(&mut self, date: NaiveDate, seconds: f64, celsius: f64) {
        let day = self.day(date);
        *day.temps.entry(celsius.round() as i32).or_default() += seconds;
        day.temp_max = Some(day.temp_max.map_or(celsius, |m| m.max(celsius)));
    }

    fn trim(&mut self, today: NaiveDate) {
        let oldest = today - Span::days(KEEP_DAYS);
        self.days.retain(|d| d.date > oldest && d.date <= today);
    }
}

fn read(dir: &Path) -> Option<State> {
    let bytes = std::fs::read(dir.join(FILE)).ok()?;
    let state: State = serde_json::from_slice(&bytes).ok()?;
    (state.format == FORMAT).then_some(state)
}

fn write(dir: &Path, state: &State) -> anyhow::Result<()> {
    std::fs::create_dir_all(dir)?;
    let temporary = dir.join(format!("{FILE}.tmp"));
    std::fs::write(&temporary, serde_json::to_vec(state)?)?;
    std::fs::rename(&temporary, dir.join(FILE))?;
    Ok(())
}

// The binary this process runs, as a file: an update renames a new one over it.
fn binary_id() -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(std::env::current_exe().ok()?)
        .ok()
        .map(|m| m.ino())
}

// Runs until stopped. One sampler per state folder: a second one finds the lock held and stops.
pub async fn sample(dir: PathBuf) -> anyhow::Result<()> {
    std::fs::create_dir_all(&dir)?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join("energy.lock"))?;
    if lock.try_lock().is_err() {
        anyhow::bail!(
            "Another sampler already writes {}",
            dir.join(FILE).display()
        );
    }
    let smc = Smc::open()?;
    anyhow::ensure!(
        smc.power().is_some() || smc.cpu_temperature().is_some(),
        "The SMC of this Mac gives neither its power nor its CPU temperature."
    );
    let binary = binary_id();
    let mut state = read(&dir).unwrap_or(State {
        format: FORMAT,
        ..State::default()
    });
    eprintln!(
        "energy: sampling every {} s into {}",
        EVERY.as_secs(),
        dir.join(FILE).display()
    );

    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut ticks = tokio::time::interval(EVERY);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // The previous readings, each with the moment it was taken.
    let mut last_power: Option<(Instant, f64)> = None;
    let mut last_temp: Option<Instant> = None;
    // This minute's energy and its seconds, for the average power.
    let mut minute = (0.0, 0.0);
    let mut written = Instant::now();
    loop {
        tokio::select! {
            _ = ticks.tick() => {}
            _ = terminate.recv() => break,
        }
        let now = Instant::now();
        let wall = Local::now();
        match smc.power() {
            Some(watts) => {
                if let Some((then, before)) = last_power {
                    let gap = now - then;
                    if gap <= LONGEST_GAP {
                        let seconds = gap.as_secs_f64();
                        state.add_power(wall, seconds, before, watts);
                        minute.0 += (before + watts) / 2.0 * seconds;
                        minute.1 += seconds;
                    }
                }
                last_power = Some((now, watts));
            }
            None => last_power = None,
        }
        match smc.cpu_temperature() {
            Some(celsius) => {
                if let Some(then) = last_temp {
                    let gap = now - then;
                    if gap <= LONGEST_GAP {
                        state.add_temperature(wall.date_naive(), gap.as_secs_f64(), celsius);
                    }
                }
                last_temp = Some(now);
                state.temp_at = Some(wall.to_utc());
                state.temp_c = Some((celsius * 10.0).round() / 10.0);
            }
            None => last_temp = None,
        }
        if now - written >= WRITE_EVERY {
            if minute.1 > 0.0 {
                state.watts = Some((minute.0 / minute.1 * 100.0).round() / 100.0);
                state.power_at = Some(wall.to_utc());
            }
            minute = (0.0, 0.0);
            state.trim(wall.date_naive());
            if let Err(error) = write(&dir, &state) {
                eprintln!("energy: {error:#}");
            }
            written = now;
            if binary_id() != binary {
                eprintln!("energy: the binary was updated, stopping for launchd to start it again");
                return Ok(());
            }
        }
    }
    state.trim(Local::now().date_naive());
    write(&dir, &state)
}

// The weighted median of a histogram of whole degrees.
fn median(temps: &BTreeMap<i32, f64>) -> Option<f64> {
    let total: f64 = temps.values().sum();
    if total <= 0.0 {
        return None;
    }
    let mut seen = 0.0;
    for (&degree, &seconds) in temps {
        seen += seconds;
        if seen >= total / 2.0 {
            return Some(f64::from(degree));
        }
    }
    None
}

fn month_of(state: &State, year: i32, month: u32) -> Option<EnergyMonth> {
    let days: Vec<&Day> = state
        .days
        .iter()
        .filter(|d| d.date.year() == year && d.date.month() == month)
        .collect();
    if days.is_empty() {
        return None;
    }
    let mut temps: BTreeMap<i32, f64> = BTreeMap::new();
    for day in &days {
        for (&degree, &seconds) in &day.temps {
            *temps.entry(degree).or_default() += seconds;
        }
    }
    let wh: f64 = days.iter().map(|d| d.wh).sum();
    let seconds: f64 = days.iter().map(|d| d.power_s).sum();
    Some(EnergyMonth {
        month: format!("{year:04}-{month:02}"),
        kwh: wh.round() / 1000.0,
        hours: (seconds / 3600.0 * 10.0).round() / 10.0,
        temp_max: days
            .iter()
            .filter_map(|d| d.temp_max)
            .reduce(f64::max)
            .map(|c| (c * 10.0).round() / 10.0),
        temp_median: median(&temps),
    })
}

// This month and the last, from the sampler's file, or nothing when no sampler runs here.
pub fn collect(dir: &Path) -> Option<Energy> {
    let state = read(dir)?;
    let today = Local::now().date_naive();
    let last = today.with_day(1)? - Span::days(1);
    let months: Vec<EnergyMonth> = [
        month_of(&state, today.year(), today.month()),
        month_of(&state, last.year(), last.month()),
    ]
    .into_iter()
    .flatten()
    .collect();
    Some(Energy {
        power_at: state.power_at,
        watts: state.watts,
        temp_at: state.temp_at,
        temp_c: state.temp_c,
        months,
    })
}
