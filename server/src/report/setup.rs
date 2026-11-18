// Setting up an agent's machine: `pendenz connect` trades a code from the app for a token and
// saves it, and `pendenz report install` makes the system run `pendenz report` every two
// minutes (a LaunchAgent on macOS, a systemd user timer on Linux).
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize)]
pub struct Saved {
    pub server: String,
    pub token: String,
    #[serde(default)]
    pub agent: Option<String>,
}

fn config_dir() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| super::home().map(|h| h.join(".config")))
        .map(|d| d.join("pendenz"))
}

fn saved_path() -> Option<PathBuf> {
    config_dir().map(|d| d.join("agent.json"))
}

pub fn saved() -> Option<Saved> {
    let bytes = std::fs::read(saved_path()?).ok()?;
    serde_json::from_slice(&bytes).ok()
}

// Writes the file readable by this user alone, before the token goes into it.
fn save(saved: &Saved) -> anyhow::Result<PathBuf> {
    let path = saved_path().ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    let dir = path.parent().expect("a folder");
    std::fs::create_dir_all(dir)?;
    let temporary = dir.join("agent.json.tmp");
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec_pretty(saved)?)?;
    }
    std::fs::rename(&temporary, &path)?;
    Ok(path)
}

// The server's address as typed: "pendenz.example.com" means https, and a token only goes over
// TLS unless the server is on this machine.
fn server_url(text: &str) -> anyhow::Result<String> {
    let text = text.trim().trim_end_matches('/');
    let text = if text.contains("://") {
        text.to_owned()
    } else {
        format!("https://{text}")
    };
    let url = url::Url::parse(&text)?;
    let host = url.host_str().unwrap_or("");
    let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(&host);
    anyhow::ensure!(
        url.scheme() == "https" || (url.scheme() == "http" && local),
        "Use an https address. Only a server on this machine may use http."
    );
    Ok(format!("{}://{}", url.scheme(), url.authority()))
}

pub async fn connect(server: &str, code: &str) -> anyhow::Result<Value> {
    let server = server_url(server)?;
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let response = http
        .post(format!("{server}/api/agents/connect"))
        .json(&json!({"code": code}))
        .send()
        .await?;
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        anyhow::bail!(
            "{}",
            body["error"]
                .as_str()
                .unwrap_or("The server refused the code.")
        );
    }
    let token = body["token"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("The server sent no token."))?;
    let path = save(&Saved {
        server: server.clone(),
        token: token.to_owned(),
        agent: body["agent"]["id"].as_str().map(str::to_owned),
    })?;
    Ok(json!({
        "agent": body["agent"],
        "scopes": body["scopes"],
        "saved": path.display().to_string(),
        "next": "Run `pendenz report install` to send a status report every two minutes.",
    }))
}

const LABEL: &str = "pendenz.report";

fn launch_agent_path() -> Option<PathBuf> {
    super::home().map(|h| h.join(format!("Library/LaunchAgents/{LABEL}.plist")))
}

fn systemd_dir() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| super::home().map(|h| h.join(".config")))
        .map(|d| d.join("systemd/user"))
}

fn xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn run(program: &str, args: &[&str]) -> anyhow::Result<()> {
    let status = std::process::Command::new(program).args(args).status()?;
    anyhow::ensure!(status.success(), "{program} {} failed", args.join(" "));
    Ok(())
}

// The PATH the job runs with: the usual places, so the agent software's own commands, such as
// `hermes usage`, are found.
fn job_path(home: &Path) -> String {
    let mut parts = vec![
        home.join(".local/bin").display().to_string(),
        "/opt/homebrew/bin".into(),
        "/usr/local/bin".into(),
        "/usr/bin".into(),
        "/bin".into(),
    ];
    parts.dedup();
    parts.join(":")
}

pub fn install() -> anyhow::Result<Value> {
    anyhow::ensure!(
        saved().is_some()
            || (std::env::var("PENDENZ_API_URL").is_ok()
                && std::env::var("PENDENZ_API_TOKEN").is_ok()),
        "Connect this machine first: pendenz connect <server> <code>"
    );
    let exe = std::env::current_exe()?;
    let exe = exe.display().to_string();
    let home = super::home().ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    if cfg!(target_os = "macos") {
        let path = launch_agent_path().expect("a home");
        let log = home.join("Library/Logs/pendenz-report.log");
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{LABEL}</string>
    <key>ProgramArguments</key><array><string>{}</string><string>report</string></array>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>{}</string></dict>
    <key>StartInterval</key><integer>120</integer>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <key>StandardOutPath</key><string>{}</string>
    <key>StandardErrorPath</key><string>{}</string>
</dict>
</plist>
"#,
            xml(&exe),
            xml(&job_path(&home)),
            xml(&log.display().to_string()),
            xml(&log.display().to_string()),
        );
        std::fs::create_dir_all(path.parent().expect("a folder"))?;
        let uid = String::from_utf8(std::process::Command::new("id").arg("-u").output()?.stdout)?;
        let domain = format!("gui/{}", uid.trim());
        // Replaces a job installed before.
        let _ = std::process::Command::new("launchctl")
            .args(["bootout", &format!("{domain}/{LABEL}")])
            .stderr(std::process::Stdio::null())
            .status();
        std::fs::write(&path, plist)?;
        run(
            "launchctl",
            &["bootstrap", &domain, &path.display().to_string()],
        )?;
        Ok(
            json!({"installed": path.display().to_string(), "log": log.display().to_string(), "every_seconds": 120}),
        )
    } else {
        let dir = systemd_dir().expect("a home");
        std::fs::create_dir_all(&dir)?;
        std::fs::write(
            dir.join("pendenz-report.service"),
            format!(
                "[Unit]\nDescription=Send a Pendenz status report\n\n[Service]\nType=oneshot\nEnvironment=PATH={}\nExecStart=\"{}\" report\n",
                job_path(&home),
                exe
            ),
        )?;
        std::fs::write(
            dir.join("pendenz-report.timer"),
            "[Unit]\nDescription=Send a Pendenz status report every two minutes\n\n[Timer]\nOnBootSec=30s\nOnUnitActiveSec=2min\n\n[Install]\nWantedBy=timers.target\n",
        )?;
        run("systemctl", &["--user", "daemon-reload"])?;
        run(
            "systemctl",
            &["--user", "enable", "--now", "pendenz-report.timer"],
        )?;
        Ok(
            json!({"installed": dir.join("pendenz-report.timer").display().to_string(), "every_seconds": 120}),
        )
    }
}

pub fn uninstall() -> anyhow::Result<Value> {
    if cfg!(target_os = "macos") {
        let path = launch_agent_path().expect("a home");
        let uid = String::from_utf8(std::process::Command::new("id").arg("-u").output()?.stdout)?;
        let _ = std::process::Command::new("launchctl")
            .args(["bootout", &format!("gui/{}/{LABEL}", uid.trim())])
            .stderr(std::process::Stdio::null())
            .status();
        let _ = std::fs::remove_file(&path);
    } else {
        let _ = std::process::Command::new("systemctl")
            .args(["--user", "disable", "--now", "pendenz-report.timer"])
            .status();
        if let Some(dir) = systemd_dir() {
            let _ = std::fs::remove_file(dir.join("pendenz-report.timer"));
            let _ = std::fs::remove_file(dir.join("pendenz-report.service"));
        }
    }
    Ok(json!({"uninstalled": true}))
}
