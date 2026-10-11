//! `crossshell-view` — the remote-desktop viewer window.
//!
//! The Flutter app spawns this with `--port <p>` (an SSH local forward to the
//! host agent), writes the 64-hex-char session token to stdin, and reads
//! JSON-line events from stdout:
//!
//! ```text
//! {"ev":"connecting"}
//! {"ev":"waiting","msg":"…"}          no Welcome after 3 s (consent dialog?)
//! {"ev":"connected","displays":[…]}
//! {"ev":"notice","level":1,"text":"…"}  empty text clears the banner
//! {"ev":"closed","reason":"…"}
//! ```
//!
//! Exit code 0 when the user closed the viewer, 1 on any failure or when the
//! remote side went away, 2 on bad usage.
//!
//! On Windows release builds this is a GUI-subsystem executable: no console
//! window opens, and the standard handles a parent passes at spawn (the
//! pipe the app reads) still work.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod args;
mod clip;
mod events;
mod font;
mod font_data;
mod geom;
mod input;
mod keymap;
mod menu;
mod net;
mod render;
mod snapshot;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;

use anyhow::Context;
use winit::event_loop::EventLoop;

use app::{App, UserEvent};
use args::{Args, Parsed};
use net::{ConnectOpts, NetEvent, Notify, Shared, Timing};

/// Name shown in the host's log for this viewer.
pub fn viewer_name() -> String {
    let from_env = std::env::var("HOSTNAME").or_else(|_| std::env::var("COMPUTERNAME")).ok();
    let name = from_env
        .or_else(|| std::fs::read_to_string("/etc/hostname").ok())
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty());
    name.unwrap_or_else(|| "viewer".into())
}

fn main() {
    std::process::exit(match real_main() {
        Ok(code) => code,
        Err(e) => {
            let msg = format!("{e:#}");
            eprintln!("crossshell-view: {msg}");
            events::closed(&msg);
            1
        }
    });
}

fn real_main() -> anyhow::Result<i32> {
    let args = match args::parse(std::env::args().skip(1)) {
        Ok(Parsed::Run(a)) => a,
        Ok(Parsed::Help) => {
            println!("{}", args::USAGE);
            return Ok(0);
        }
        Ok(Parsed::Version) => {
            println!("crossshell-view {}", env!("CARGO_PKG_VERSION"));
            return Ok(0);
        }
        Err(e) => {
            eprintln!("crossshell-view: {e:#}\n\n{}", args::USAGE);
            return Ok(2);
        }
    };
    let token = match args::read_token() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("crossshell-view: {e:#}");
            if args.snapshot.is_none() {
                events::closed(&format!("{e:#}"));
            }
            return Ok(2);
        }
    };

    if let Some(path) = &args.snapshot {
        // Headless: report on stderr, no JSON events.
        return match snapshot::run(&args, token) {
            Ok(s) => {
                println!(
                    "snapshot: {} frames, {:.1} KiB, {:.1} fps, {}x{} -> {}",
                    s.frames,
                    s.kib,
                    s.fps,
                    s.width,
                    s.height,
                    path.display()
                );
                Ok(0)
            }
            Err(e) => {
                eprintln!("crossshell-view: {e:#}");
                Ok(1)
            }
        };
    }
    run_window(args, token)
}

fn run_window(args: Args, token: [u8; 32]) -> anyhow::Result<i32> {
    events::connecting();
    let event_loop =
        EventLoop::<UserEvent>::with_user_event().build().context("cannot open a window (no display server?)")?;
    let proxy = event_loop.create_proxy();

    // Frames arrive far faster than redraws are useful: wake the UI once per
    // pending batch, not once per frame.
    let frame_pending = Arc::new(AtomicBool::new(false));
    let notify: Notify = {
        let pending = frame_pending.clone();
        Arc::new(move |ev| {
            if matches!(ev, NetEvent::Frame { .. }) && pending.swap(true, Ordering::SeqCst) {
                return;
            }
            let _ = proxy.send_event(UserEvent::Net(ev));
        })
    };

    let shared = Arc::new(Shared::default());
    let (tx, rx) = mpsc::channel();
    let clip = if args.clipboard { clip::spawn(tx.clone()) } else { None };
    let opts = ConnectOpts {
        port: args.port,
        token,
        viewer_name: viewer_name(),
        display: args.display,
        quality: args.quality,
        fps: args.fps,
        view_only: args.view_only,
        timing: Timing::default(),
    };
    let session = net::spawn(opts, shared, notify, tx, rx).context("starting the network thread")?;

    let mut app = App::new(args, session, frame_pending, clip);
    event_loop.run_app(&mut app).context("window event loop failed")?;
    Ok(app.exit_code)
}
