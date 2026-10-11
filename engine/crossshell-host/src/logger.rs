//! Minimal `log` backend: stderr plus a log file (the agent usually runs
//! without a console — launched by a scheduled task or systemd-run).

use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

struct Logger {
    file: Option<Mutex<File>>,
    level: log::LevelFilter,
}

impl log::Log for Logger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= self.level
    }

    fn log(&self, r: &log::Record) {
        if !self.enabled(r.metadata()) {
            return;
        }
        let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
        let line = format!("{secs:.3} {:<5} {}: {}\n", r.level(), r.target(), r.args());
        let _ = std::io::stderr().write_all(line.as_bytes());
        if let Some(f) = &self.file {
            if let Ok(mut f) = f.lock() {
                let _ = f.write_all(line.as_bytes());
            }
        }
    }

    fn flush(&self) {}
}

/// Install the logger. `CROSSSHELL_LOG=debug|trace` raises verbosity.
pub fn init(file: Option<&Path>) {
    let level = match std::env::var("CROSSSHELL_LOG").as_deref() {
        Ok("trace") => log::LevelFilter::Trace,
        Ok("debug") => log::LevelFilter::Debug,
        Ok("warn") => log::LevelFilter::Warn,
        _ => log::LevelFilter::Info,
    };
    let file = file.and_then(|p| {
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        File::create(p).ok().map(Mutex::new)
    });
    let logger = Box::leak(Box::new(Logger { file, level }));
    if log::set_logger(logger).is_ok() {
        log::set_max_level(level);
    }
}
