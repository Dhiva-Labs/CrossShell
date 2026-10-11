//! `crossshell-host` — the screen-share agent.
//!
//! Runs in the user's graphical session, listens on 127.0.0.1 only, and
//! publishes its port + a fresh token in `host.json` (readable only by this
//! user). Viewers reach it through an SSH local forward after reading
//! `host.json` over that same SSH connection — SSH is the authentication.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use std::net::{Ipv4Addr, TcpListener};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use anyhow::Context;
use crossshell_host::runtime::{self, HostInfo};
use crossshell_host::session::{self, SessionOptions};
use crossshell_host::{logger, platform_init, BackendKind};
use crossshell_proto::{to_hex, DEFAULT_HOST_PORT};

const USAGE: &str = "\
crossshell-host — CrossShell screen-share agent

USAGE:
    crossshell-host [--port N] [--synthetic] [--no-clipboard]
    crossshell-host --info      print host.json (port, token, pid)
    crossshell-host --version

The agent listens on 127.0.0.1 only. Viewers connect through an SSH tunnel.";

struct Args {
    port: u16,
    synthetic: bool,
    clipboard: bool,
}

fn parse_args() -> anyhow::Result<Option<Args>> {
    let mut a = Args { port: DEFAULT_HOST_PORT, synthetic: false, clipboard: true };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--port" => a.port = it.next().context("--port needs a value")?.parse().context("bad --port")?,
            "--synthetic" => a.synthetic = true,
            "--no-clipboard" => a.clipboard = false,
            "--info" => {
                let dir = runtime::runtime_dir();
                match runtime::read_host_info(&dir) {
                    Some(i) => println!("{}", serde_json::to_string_pretty(&i)?),
                    None => anyhow::bail!("no agent info at {}", runtime::host_json_path(&dir).display()),
                }
                return Ok(None);
            }
            "--version" | "-V" => {
                println!("crossshell-host {}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            "--help" | "-h" => {
                println!("{USAGE}");
                return Ok(None);
            }
            other => anyhow::bail!("unknown argument {other:?}\n\n{USAGE}"),
        }
    }
    Ok(Some(a))
}

fn main() {
    if let Err(e) = run() {
        log::error!("{e:#}");
        eprintln!("crossshell-host: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let Some(args) = parse_args()? else { return Ok(()) };
    let dir = runtime::runtime_dir();
    runtime::ensure_dir(&dir).with_context(|| format!("creating {}", dir.display()))?;
    logger::init(Some(&runtime::log_path()));
    platform_init();

    let Some(_lock) = runtime::lock_instance(&dir)? else {
        log::info!("another crossshell-host is already running; exiting");
        return Ok(());
    };

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
        "listening on 127.0.0.1:{port} (backend: {})",
        if args.synthetic { "synthetic" } else { "native" }
    );

    let opts = Arc::new(SessionOptions {
        token,
        backend: if args.synthetic { BackendKind::Synthetic } else { BackendKind::Native },
        runtime_dir: Some(dir.clone()),
        clipboard: args.clipboard,
    });
    let busy = Arc::new(AtomicBool::new(false));
    for conn in listener.incoming() {
        let stream = match conn {
            Ok(s) => s,
            Err(e) => {
                log::warn!("accept failed: {e}");
                continue;
            }
        };
        let opts = opts.clone();
        let busy = busy.clone();
        std::thread::spawn(move || {
            if let Err(e) = session::serve_connection(stream, &opts, &busy) {
                log::warn!("session ended with error: {e:#}");
            }
        });
    }
    Ok(())
}
