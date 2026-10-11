//! JSON-lines events on stdout for the parent app.
//!
//! One object per line, flushed immediately. Write errors are ignored: a
//! GUI-subsystem Windows build started without a pipe has no stdout at all.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};

use crossshell_proto::DisplayInfo;
use serde_json::{json, Value};

pub fn emit(v: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

pub fn connecting() {
    emit(&json!({"ev": "connecting"}));
}

pub fn waiting(msg: &str) {
    emit(&json!({"ev": "waiting", "msg": msg}));
}

pub fn displays_json(displays: &[DisplayInfo]) -> Value {
    displays
        .iter()
        .map(|d| {
            json!({
                "index": d.index,
                "name": d.name,
                "x": d.x,
                "y": d.y,
                "width": d.width,
                "height": d.height,
                "primary": d.primary,
            })
        })
        .collect()
}

pub fn connected(displays: &[DisplayInfo]) {
    emit(&json!({"ev": "connected", "displays": displays_json(displays)}));
}

pub fn notice(level: u8, text: &str) {
    emit(&json!({"ev": "notice", "level": level, "text": text}));
}

/// Emit `closed` exactly once per process.
pub fn closed(reason: &str) {
    static DONE: AtomicBool = AtomicBool::new(false);
    if !DONE.swap(true, Ordering::SeqCst) {
        emit(&json!({"ev": "closed", "reason": reason}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_json_shape() {
        let d =
            DisplayInfo { index: 1, name: "DP-1".into(), x: -1920, y: 0, width: 1920, height: 1080, primary: false };
        let v = displays_json(&[d]);
        assert_eq!(v[0]["index"], 1);
        assert_eq!(v[0]["name"], "DP-1");
        assert_eq!(v[0]["x"], -1920);
        assert_eq!(v[0]["width"], 1920);
        assert_eq!(v[0]["primary"], false);
    }
}
