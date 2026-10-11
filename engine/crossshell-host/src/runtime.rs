//! Runtime files: `host.json` (port + token, read by viewers over SSH),
//! `status.json` (who is watching, read by the local app), the
//! single-instance lock and the log path.
//!
//! Linux:   `${XDG_RUNTIME_DIR:-$HOME/.cache}/crossshell/` (dir 0700, files 0600)
//! Windows: `%LOCALAPPDATA%\CrossShell\` (per-user ACL by default)

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostInfo {
    pub v: u32,
    pub port: u16,
    pub token: String,
    pub pid: u32,
    pub ver: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionStatus {
    /// The agent's pid, so readers can tell a live status from a stale one.
    pub pid: u32,
    pub viewer: String,
    pub since: u64,
    pub view_only: bool,
}

/// Directory holding the runtime files.
pub fn runtime_dir() -> PathBuf {
    #[cfg(windows)]
    {
        let base = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir());
        base.join("CrossShell")
    }
    #[cfg(not(windows))]
    {
        let base = std::env::var_os("XDG_RUNTIME_DIR")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
            .unwrap_or_else(std::env::temp_dir);
        base.join("crossshell")
    }
}

/// Where the agent writes its log.
pub fn log_path() -> PathBuf {
    #[cfg(windows)]
    {
        runtime_dir().join("host.log")
    }
    #[cfg(not(windows))]
    {
        let base = std::env::var_os("XDG_STATE_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
            .unwrap_or_else(std::env::temp_dir);
        base.join("crossshell").join("host.log")
    }
}

/// Create the runtime dir, private to this user.
pub fn ensure_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        // Tighten a pre-existing dir too.
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        fs::create_dir_all(dir)
    }
}

/// Write `contents` to `path` atomically, readable only by this user.
pub fn write_private(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    let _ = fs::remove_file(&tmp);
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(&tmp)?;
    f.write_all(contents)?;
    f.sync_all()?;
    drop(f);
    fs::rename(&tmp, path)
}

/// Holds the single-instance lock for the life of the agent.
pub struct InstanceLock {
    _file: File,
}

/// Take the single-instance lock, or `Ok(None)` if another agent holds it.
pub fn lock_instance(dir: &Path) -> std::io::Result<Option<InstanceLock>> {
    let f = OpenOptions::new().create(true).truncate(false).write(true).open(dir.join("host.lock"))?;
    match f.try_lock() {
        Ok(()) => Ok(Some(InstanceLock { _file: f })),
        Err(fs::TryLockError::WouldBlock) => Ok(None),
        Err(fs::TryLockError::Error(e)) => Err(e),
    }
}

pub fn host_json_path(dir: &Path) -> PathBuf {
    dir.join("host.json")
}

pub fn status_json_path(dir: &Path) -> PathBuf {
    dir.join("status.json")
}

pub fn write_host_info(dir: &Path, info: &HostInfo) -> std::io::Result<()> {
    write_private(&host_json_path(dir), serde_json::to_string(info)?.as_bytes())
}

pub fn read_host_info(dir: &Path) -> Option<HostInfo> {
    serde_json::from_slice(&fs::read(host_json_path(dir)).ok()?).ok()
}

/// Fresh 32-byte session token.
pub fn new_token() -> anyhow::Result<[u8; crossshell_proto::TOKEN_LEN]> {
    let mut t = [0u8; crossshell_proto::TOKEN_LEN];
    getrandom::fill(&mut t).map_err(|e| anyhow::anyhow!("no OS randomness: {e}"))?;
    Ok(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_info_round_trips_and_is_private() {
        let dir = std::env::temp_dir().join(format!("cs-rt-{}", std::process::id()));
        ensure_dir(&dir).unwrap();
        let info = HostInfo { v: 1, port: 47821, token: "ab".repeat(32), pid: 42, ver: "0.1.0".into() };
        write_host_info(&dir, &info).unwrap();
        assert_eq!(read_host_info(&dir), Some(info));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(host_json_path(&dir)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
            let dmode = fs::metadata(&dir).unwrap().permissions().mode();
            assert_eq!(dmode & 0o777, 0o700);
        }
        let lock = lock_instance(&dir).unwrap();
        assert!(lock.is_some());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn tokens_are_random() {
        assert_ne!(new_token().unwrap(), new_token().unwrap());
    }
}
