// The machine the agent runs on: CPU, memory, disk, the busiest programs, and samples of the
// last 24 hours kept in a small file between runs.
use super::{Host, Process, Sample};
use chrono::{Duration as Span, Utc};
use std::{collections::HashMap, path::PathBuf};
use sysinfo::{Disks, MINIMUM_CPU_UPDATE_INTERVAL, ProcessesToUpdate, System, ThreadKind};

// The largest programs in memory and the busiest on the CPU, this many of each.
const TOP: usize = 8;
// One sample is kept per this many minutes.
const SAMPLE_MINUTES: i64 = 10;

pub async fn collect(state_dir: Option<PathBuf>) -> anyhow::Result<Host> {
    let mut host = tokio::task::spawn_blocking(measure).await??;
    host.memory_free_percent = memory_free_percent().await;
    host.chip = chip().await;
    if let Some(dir) = state_dir {
        host.series = keep_sample(&dir, &host).unwrap_or_else(|error| {
            eprintln!("host samples: {error:#}");
            Vec::new()
        });
    }
    Ok(host)
}

fn measure() -> anyhow::Result<Host> {
    let mut system = System::new()?;
    system.refresh_cpu_usage();
    system.refresh_processes(ProcessesToUpdate::All, true);
    // CPU use is the difference between two readings, so wait a moment and read again.
    std::thread::sleep(MINIMUM_CPU_UPDATE_INTERVAL.max(std::time::Duration::from_millis(500)));
    system.refresh_cpu_usage();
    system.refresh_processes(ProcessesToUpdate::All, true);
    system.refresh_memory();

    let cores = system.cpus().len().max(1);
    // Per program, added up over its processes. A process's CPU is a share of one core, so it is
    // divided by the cores to match the machine's total.
    let mut programs: HashMap<String, Process> = HashMap::new();
    for process in system.processes().values() {
        // On Linux the threads of a process are listed too, each with the memory of the whole
        // process: a program with seven threads of one name counted seven times over. Kernel
        // workers such as kswapd are no part of another process and stay.
        if process.thread_kind() == Some(ThreadKind::Userland) {
            continue;
        }
        let name = process.name().to_string_lossy().into_owned();
        if name.is_empty() {
            continue;
        }
        let entry = programs.entry(name.clone()).or_insert(Process {
            name,
            count: 0,
            cpu_percent: 0.0,
            memory: 0,
        });
        entry.count += 1;
        entry.cpu_percent += f64::from(process.cpu_usage()) / cores as f64;
        entry.memory += process.memory();
    }
    let mut programs: Vec<Process> = programs.into_values().collect();
    // The largest in memory, then the busiest on the CPU that are not among them. Sent largest
    // first; the apps sort again by what they show.
    programs.sort_by_key(|p| std::cmp::Reverse(p.memory));
    let mut top: Vec<Process> = programs.iter().take(TOP).cloned().collect();
    programs.sort_by(|a, b| b.cpu_percent.total_cmp(&a.cpu_percent));
    for program in programs.into_iter().take(TOP) {
        if !top.iter().any(|p| p.name == program.name) {
            top.push(program);
        }
    }
    for process in &mut top {
        process.cpu_percent = (process.cpu_percent * 10.0).round() / 10.0;
    }

    // The disk the system boots from.
    let disks = Disks::new_with_refreshed_list()?;
    let root = disks
        .iter()
        .filter(|d| {
            let mount = d.mount_point();
            mount == std::path::Path::new("/")
                || mount == std::path::Path::new("/System/Volumes/Data")
        })
        .max_by_key(|d| d.total_space());
    let (disk_total, disk_used) = root
        .map(|d| (d.total_space(), d.total_space() - d.available_space()))
        .unwrap_or((0, 0));

    let load = System::load_average().ok();
    Ok(Host {
        name: System::host_name().unwrap_or_else(|_| "unknown".into()),
        os: System::long_os_version().ok(),
        chip: None,
        cores: cores as u32,
        uptime_s: System::uptime().unwrap_or(0),
        cpu_percent: (f64::from(system.global_cpu_usage()) * 10.0).round() / 10.0,
        load: load
            .map(|l| vec![l.one, l.five, l.fifteen])
            .unwrap_or_default(),
        memory_used: system.used_memory(),
        memory_total: system.total_memory(),
        swap_used: system.used_swap(),
        memory_free_percent: None,
        disk_used,
        disk_total,
        top,
        series: Vec::new(),
    })
}

async fn sysctl(name: &str) -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = tokio::process::Command::new("/usr/sbin/sysctl")
        .args(["-n", name])
        .kill_on_drop(true)
        .output()
        .await
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    (output.status.success() && !text.is_empty()).then_some(text)
}

// What Activity Monitor's memory pressure is drawn from: the share the kernel still counts free.
async fn memory_free_percent() -> Option<f64> {
    sysctl("kern.memorystatus_level").await?.parse().ok()
}

async fn chip() -> Option<String> {
    match sysctl("machdep.cpu.brand_string").await {
        Some(chip) => Some(chip),
        None => std::fs::read_to_string("/proc/cpuinfo")
            .ok()
            .and_then(|info| {
                info.lines()
                    .find(|l| l.starts_with("model name"))
                    .and_then(|l| l.split_once(':'))
                    .map(|(_, v)| v.trim().to_owned())
            }),
    }
}

// Adds this run's reading to the file when the last sample is old enough, drops what is older
// than a day, and returns the day's samples.
fn keep_sample(dir: &std::path::Path, host: &Host) -> anyhow::Result<Vec<Sample>> {
    let path = dir.join("host-samples.json");
    let mut samples: Vec<Sample> = std::fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    let now = Utc::now();
    samples.retain(|s| s.at > now - Span::hours(24) && s.at <= now);
    let due = samples
        .last()
        .is_none_or(|s| now - s.at >= Span::minutes(SAMPLE_MINUTES) - Span::seconds(30));
    if due {
        samples.push(Sample {
            at: now,
            cpu_percent: host.cpu_percent,
            memory_used: host.memory_used,
        });
        std::fs::create_dir_all(dir)?;
        let temporary = dir.join("host-samples.json.tmp");
        std::fs::write(&temporary, serde_json::to_vec(&samples)?)?;
        std::fs::rename(&temporary, &path)?;
    }
    Ok(samples)
}
