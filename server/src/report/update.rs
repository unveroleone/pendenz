// The scheduled report job keeps this binary at the server's version. After a report, a server
// that names a newer release in `Pendenz-Version` makes the job fetch that release's build,
// check it against the release's SHA256SUMS as install.sh does, run it once, and put it in
// place of the running file. It never goes past the server and never takes a pre-release.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

const REPO: &str = "unveroleone/pendenz";
// After a failed try, whatever version it was for, the next waits this long.
const RETRY: chrono::TimeDelta = chrono::TimeDelta::hours(6);
const ASSET_LIMIT: usize = 100 * 1024 * 1024;
const SUMS_LIMIT: usize = 64 * 1024;

#[derive(Serialize, Deserialize)]
struct Tried {
    version: String,
    at: chrono::DateTime<chrono::Utc>,
}

// "1.2.3" as numbers. A pre-release ("1.3.0-rc.1"), build metadata or anything else is none.
fn release(version: &str) -> Option<(u64, u64, u64)> {
    let mut parts = version.trim().split('.');
    let mut number = || -> Option<u64> {
        let part = parts.next()?;
        (!part.is_empty() && part.bytes().all(|b| b.is_ascii_digit())).then(|| part.parse().ok())?
    };
    let version = (number()?, number()?, number()?);
    parts.next().is_none().then_some(version)
}

// The newer release the server runs, when there is one to take.
pub fn wanted(own: &str, server: &str) -> Option<String> {
    let (own, target) = (release(own)?, release(server)?);
    (target > own).then(|| server.trim().to_owned())
}

fn asset() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("pendenz-macos-arm64.tar.gz"),
        ("linux", "x86_64") => Some("pendenz-linux-x86_64.tar.gz"),
        ("linux", "aarch64") => Some("pendenz-linux-arm64.tar.gz"),
        _ => None,
    }
}

// A binary that another tool put there is that tool's to update: a build in a checkout, one
// from `cargo install`, and one reached through a link, as a package manager sets it up.
fn managed_elsewhere(exe: &Path, canonical: &Path) -> bool {
    let parts: Vec<_> = canonical
        .components()
        .map(|c| c.as_os_str().to_owned())
        .collect();
    exe != canonical
        || parts
            .windows(2)
            .any(|w| w[0] == "target" && (w[1] == "debug" || w[1] == "release"))
        || parts.windows(2).any(|w| w[0] == ".cargo" && w[1] == "bin")
}

// Brings the binary up to the server's version when it is behind. Prints one line when it
// tried, and never fails the report.
pub async fn follow(server_version: &str) {
    let own = env!("CARGO_PKG_VERSION");
    let Some(version) = wanted(own, server_version) else {
        return;
    };
    // Shorter than the two minutes between reports.
    match tokio::time::timeout(Duration::from_secs(100), replace(own, &version)).await {
        Ok(Ok(Some(done))) => println!("{done}"),
        Ok(Ok(None)) => {}
        Ok(Err(error)) => eprintln!("update to {version}: {error:#}"),
        Err(_) => eprintln!("update to {version}: took longer than 100 s"),
    }
}

async fn replace(own: &str, version: &str) -> anyhow::Result<Option<String>> {
    let Some(asset) = asset() else {
        return Ok(None);
    };
    let path = std::path::absolute(std::env::current_exe()?)?;
    let exe = std::fs::canonicalize(&path)?;
    if managed_elsewhere(&path, &exe) {
        return Ok(None);
    }
    let dir = exe
        .parent()
        .ok_or_else(|| anyhow::anyhow!("the binary has no folder"))?
        .to_owned();
    // The lock and the record of the last try belong to the binary, so two report jobs of
    // one machine never replace it at the same time.
    let lock = match std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(".pendenz-update.lock"))
    {
        Ok(file) => file,
        // A folder this user cannot write to is updated by whoever installed it.
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if lock.try_lock().is_err() {
        return Ok(None);
    }
    // Another job may have replaced the file since this process started. A file whose version
    // cannot be read is left alone.
    let Some(installed) = installed_version(&exe).await else {
        return Ok(None);
    };
    if wanted(&installed, version).is_none() {
        return Ok(None);
    }
    // The record of a try is removed when it succeeds, so one that is there failed.
    let record = dir.join(".pendenz-update.json");
    let now = chrono::Utc::now();
    if let Some(tried) = std::fs::read(&record)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Tried>(&bytes).ok())
        && now - tried.at < RETRY
    {
        return Ok(None);
    }
    // Written beside and renamed, so a link in its place is replaced, not followed.
    let temporary = dir.join(format!(".pendenz-update.json.{}", std::process::id()));
    std::fs::write(
        &temporary,
        serde_json::to_vec(&Tried {
            version: version.to_owned(),
            at: now,
        })?,
    )?;
    std::fs::rename(&temporary, &record)?;

    let base = std::env::var("PENDENZ_DOWNLOAD_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| format!("https://github.com/{REPO}/releases/download/v{version}"));
    let base = base.trim_end_matches('/');
    // GitHub sends a release file on through a redirect; a mirror on this machine needs none,
    // and must not hand the download on to a remote host over plain HTTP.
    let local = loopback(base);
    let http = reqwest::Client::builder()
        .redirect(if local {
            reqwest::redirect::Policy::none()
        } else {
            reqwest::redirect::Policy::limited(5)
        })
        .https_only(!local)
        .timeout(Duration::from_secs(90))
        .build()?;
    let sums = download(&http, &format!("{base}/SHA256SUMS"), SUMS_LIMIT).await?;
    let sums = String::from_utf8(sums)?;
    let expected = sums
        .lines()
        .filter_map(|line| line.split_once(char::is_whitespace))
        .find(|(_, name)| name.trim().trim_start_matches('*') == asset)
        .map(|(hash, _)| hash.to_ascii_lowercase())
        .ok_or_else(|| anyhow::anyhow!("SHA256SUMS does not list {asset}"))?;
    let archive = download(&http, &format!("{base}/{asset}"), ASSET_LIMIT).await?;
    let actual = hex(&Sha256::digest(&archive));
    anyhow::ensure!(actual == expected, "{asset} does not match SHA256SUMS");

    // Unpacked next to the binary, so the last step is a rename on one file system.
    let work = Work::new(dir.join(format!(".pendenz-update-{}", std::process::id())))?;
    let tarball = work.path().join(asset);
    std::fs::write(&tarball, &archive)?;
    let status = tokio::process::Command::new("tar")
        .arg("-xzf")
        .arg(&tarball)
        .arg("-C")
        .arg(work.path())
        .arg("pendenz")
        .stdin(std::process::Stdio::null())
        .status()
        .await?;
    anyhow::ensure!(status.success(), "tar could not unpack {asset}");
    let fresh = work.path().join("pendenz");
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fresh, std::fs::Permissions::from_mode(0o755))?;
    }
    let says = installed_version(&fresh).await;
    anyhow::ensure!(
        says.as_deref() == Some(version),
        "the downloaded build says it is {}",
        says.as_deref().unwrap_or("nothing")
    );
    std::fs::rename(&fresh, &exe)?;
    let _ = std::fs::remove_file(&record);
    Ok(Some(format!(
        "Updated pendenz from {own} to {version}, the server's version."
    )))
}

// A folder that is removed when it goes out of scope, whatever happened.
struct Work(PathBuf);

impl Work {
    fn new(path: PathBuf) -> std::io::Result<Self> {
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir(&path)?;
        Ok(Work(path))
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Work {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn loopback(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|u| {
        u.host_str()
            .is_some_and(|h| ["localhost", "127.0.0.1", "[::1]"].contains(&h))
    })
}

async fn download(http: &reqwest::Client, url: &str, limit: usize) -> anyhow::Result<Vec<u8>> {
    let mut response = http.get(url).send().await?.error_for_status()?;
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        anyhow::ensure!(body.len() + chunk.len() <= limit, "{url} is too large");
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// What `<binary> --version` prints after "pendenz ".
async fn installed_version(binary: &PathBuf) -> Option<String> {
    let run = tokio::process::Command::new(binary)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(Duration::from_secs(10), run)
        .await
        .ok()?
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    Some(text.trim().strip_prefix("pendenz ")?.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_only_a_newer_release() {
        assert_eq!(wanted("0.5.3", "0.5.4").as_deref(), Some("0.5.4"));
        assert_eq!(wanted("0.5.3", "0.10.0").as_deref(), Some("0.10.0"));
        assert_eq!(wanted("0.5.3", "0.5.3"), None);
        assert_eq!(wanted("0.5.4", "0.5.3"), None);
        assert_eq!(wanted("0.5.3", "0.6.0-rc.1"), None);
        assert_eq!(wanted("0.5.3", "0.6"), None);
        assert_eq!(wanted("0.5.3", "0.6.0.1"), None);
        assert_eq!(wanted("0.5.3", "+1.0.0"), None);
    }

    #[test]
    fn leaves_other_tools_binaries_alone() {
        let alone = |p: &str| managed_elsewhere(Path::new(p), Path::new(p));
        assert!(alone("/src/pendenz/target/debug/pendenz"));
        assert!(alone("/home/a/.cargo/bin/pendenz"));
        assert!(!alone("/home/a/.local/bin/pendenz"));
        assert!(managed_elsewhere(
            Path::new("/opt/homebrew/bin/pendenz"),
            Path::new("/opt/homebrew/Cellar/pendenz/0.5.3/bin/pendenz")
        ));
    }
}
