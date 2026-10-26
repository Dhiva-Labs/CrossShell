//! `crossshell-host` — the screen-share agent.
//!
//! Runs in the user's graphical session, listens on 127.0.0.1 only, and
//! publishes its port + a fresh token in `host.json` (readable only by this
//! user). Viewers reach it through an SSH local forward after reading
//! `host.json` over that same SSH connection — SSH is the authentication.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use std::net::{Ipv4Addr, TcpListener};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use crossshell_host::runtime::{self, HostInfo};
use crossshell_host::session::{self, SessionOptions, SessionSlot};
use crossshell_host::{logger, platform_init, BackendKind};
use crossshell_proto::{to_hex, DEFAULT_HOST_PORT};

const USAGE: &str = "\
crossshell-host — CrossShell screen-share agent

USAGE:
    crossshell-host [OPTIONS]
    crossshell-host [--runtime-dir DIR] --info    print host.json (port, token, pid)
    crossshell-host --version

OPTIONS:
    --port N               preferred port on 127.0.0.1 (default 47821; any
                           free port when it is taken, see host.json)
    --synthetic            serve an animated test pattern, not the desktop
    --no-clipboard         do not sync the clipboard with the viewer
    --no-notify            no desktop notification while a viewer is connected
    --runtime-dir DIR      keep host.json, the instance lock, status.json and
                           host.log in DIR (created 0700) instead of the
                           per-user default
    --exit-when-idle SECS  exit when no viewer has connected within SECS
                           seconds of start, or SECS seconds after the last
                           viewer left

The agent listens on 127.0.0.1 only. Viewers connect through an SSH tunnel.";

enum Action {
    Run,
    Info,
    Version,
    Help,
}

struct Args {
    action: Action,
    port: u16,
    synthetic: bool,
    clipboard: bool,
    notify: bool,
    runtime_dir: Option<PathBuf>,
    exit_when_idle: Option<Duration>,
}

fn parse_args(args: impl IntoIterator<Item = String>) -> anyhow::Result<Args> {
    let mut a = Args {
        action: Action::Run,
        port: DEFAULT_HOST_PORT,
        synthetic: false,
        clipboard: true,
        notify: true,
        runtime_dir: None,
        exit_when_idle: None,
    };
    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        let mut value = || it.next().with_context(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--port" => a.port = value()?.parse().context("bad --port")?,
            "--synthetic" => a.synthetic = true,
            "--no-clipboard" => a.clipboard = false,
            "--no-notify" => a.notify = false,
            "--runtime-dir" => {
                let dir = PathBuf::from(value()?);
                anyhow::ensure!(!dir.as_os_str().is_empty(), "--runtime-dir needs a path");
                a.runtime_dir = Some(std::path::absolute(&dir).context("bad --runtime-dir")?);
            }
            "--exit-when-idle" => {
                let secs: u64 = value()?.parse().context("bad --exit-when-idle (whole seconds)")?;
                anyhow::ensure!(secs > 0, "--exit-when-idle needs at least 1 second");
                a.exit_when_idle = Some(Duration::from_secs(secs));
            }
            "--info" => a.action = Action::Info,
            "--version" | "-V" => a.action = Action::Version,
            "--help" | "-h" => a.action = Action::Help,
            other => anyhow::bail!("unknown argument {other:?}\n\n{USAGE}"),
        }
    }
    Ok(a)
}

fn main() {
    if let Err(e) = run() {
        log::error!("{e:#}");
        eprintln!("crossshell-host: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let args = parse_args(std::env::args().skip(1))?;
    let dir = args.runtime_dir.clone().unwrap_or_else(runtime::runtime_dir);
    match args.action {
        Action::Run => {}
        Action::Info => {
            match runtime::read_host_info(&dir) {
                Some(i) => println!("{}", serde_json::to_string_pretty(&i)?),
                None => anyhow::bail!("no agent info at {}", runtime::host_json_path(&dir).display()),
            }
            return Ok(());
        }
        Action::Version => {
            println!("crossshell-host {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Action::Help => {
            println!("{USAGE}");
            return Ok(());
        }
    }
    runtime::ensure_dir(&dir).with_context(|| format!("creating {}", dir.display()))?;
    // A private runtime dir keeps the log too, so a remote-launched agent
    // leaves nothing behind outside it.
    let log = if args.runtime_dir.is_some() { runtime::host_log_path(&dir) } else { runtime::log_path() };
    logger::init(Some(&log));
    platform_init();

    let Some(_lock) = runtime::lock_instance(&dir)? else {
        log::info!("another crossshell-host is already running in {}; exiting", dir.display());
        return Ok(());
    };
    // A previous agent killed mid-session leaves its status behind.
    let _ = std::fs::remove_file(runtime::status_json_path(&dir));

    // Preferred port, else any free one (recorded in host.json).
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, args.port))
        .or_else(|_| TcpListener::bind((Ipv4Addr::LOCALHOST, 0)))
        .context("binding 127.0.0.1")?;
    let port = listener.local_addr()?.port();

    let token = runtime::new_token()?;
    let info = HostInfo {
        v: 1,
        port,
        token: to_hex(&token),
        pid: std::process::id(),
        ver: env!("CARGO_PKG_VERSION").into(),
    };
    runtime::write_host_info(&dir, &info)?;
    log::info!(
        "listening on 127.0.0.1:{port} (backend: {}, runtime dir: {})",
        if args.synthetic { "synthetic" } else { "native" },
        dir.display()
    );

    let opts = Arc::new(SessionOptions {
        token,
        backend: if args.synthetic { BackendKind::Synthetic } else { BackendKind::Native },
        runtime_dir: Some(dir.clone()),
        clipboard: args.clipboard,
        notify: args.notify,
    });
    let slot = Arc::new(SessionSlot::default());
    if let Some(limit) = args.exit_when_idle {
        let (slot, dir) = (slot.clone(), dir.clone());
        std::thread::Builder::new().name("cs-idle".into()).spawn(move || loop {
            std::thread::sleep(Duration::from_millis(250));
            if slot.idle_for().is_some_and(|idle| idle >= limit) {
                log::info!("no viewer for {}s; exiting (--exit-when-idle)", limit.as_secs());
                runtime::remove_agent_files(&dir);
                std::process::exit(0);
            }
        })?;
    }
    for conn in listener.incoming() {
        let stream = match conn {
            Ok(s) => s,
            Err(e) => {
                log::warn!("accept failed: {e}");
                continue;
            }
        };
        let opts = opts.clone();
        let slot = slot.clone();
        std::thread::spawn(move || {
            if let Err(e) = session::serve_connection(stream, &opts, &slot) {
                log::warn!("session ended with error: {e:#}");
            }
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(a: &[&str]) -> anyhow::Result<Args> {
        parse_args(a.iter().map(|s| s.to_string()))
    }

    #[test]
    fn defaults_are_unchanged() {
        let a = parse(&[]).unwrap();
        assert!(matches!(a.action, Action::Run));
        assert_eq!(a.port, DEFAULT_HOST_PORT);
        assert!(!a.synthetic && a.clipboard && a.notify);
        assert!(a.runtime_dir.is_none() && a.exit_when_idle.is_none());
    }

    #[test]
    fn remote_launch_flags() {
        let a = parse(&["--runtime-dir", "rt", "--exit-when-idle", "30", "--no-notify", "--synthetic"]).unwrap();
        let dir = a.runtime_dir.unwrap();
        assert!(dir.is_absolute() && dir.ends_with("rt"));
        assert_eq!(a.exit_when_idle, Some(Duration::from_secs(30)));
        assert!(!a.notify && a.synthetic);
        // --info honours --runtime-dir whatever the order.
        let a = parse(&["--info", "--runtime-dir", "/tmp/x"]).unwrap();
        assert!(matches!(a.action, Action::Info));
        assert_eq!(a.runtime_dir.as_deref(), Some(std::path::Path::new("/tmp/x")));
    }

    #[test]
    fn bad_values_are_errors() {
        for bad in [
            &["--exit-when-idle", "0"][..],
            &["--exit-when-idle", "-1"],
            &["--exit-when-idle", "1.5"],
            &["--exit-when-idle"],
            &["--runtime-dir"],
            &["--runtime-dir", ""],
            &["--port", "x"],
            &["--bogus"],
        ] {
            assert!(parse(bad).is_err(), "{bad:?}");
        }
    }
}
