//! Tells the person at the machine that a viewer is connected: a desktop
//! notification on Linux, a notification-area balloon (shown as a toast) on
//! Windows. Shown when a session starts, removed when it ends; `--no-notify`
//! turns it off. A missing notification service is silently ignored.

use std::sync::mpsc;
use std::thread::JoinHandle;

/// Longest viewer name shown, in characters.
pub const MAX_NAME_CHARS: usize = 64;

/// `viewer_name` as it is safe to show and log: control and bidi-override
/// characters removed, at most [`MAX_NAME_CHARS`] characters.
pub fn clean_viewer_name(name: &str) -> String {
    let s: String = name
        .chars()
        .filter(|&c| !c.is_control() && !is_bidi_control(c))
        .take(MAX_NAME_CHARS)
        .collect();
    let s = s.trim();
    if s.is_empty() { "viewer".into() } else { s.into() }
}

/// Characters that reorder the text around them (could make the name read
/// as something else).
fn is_bidi_control(c: char) -> bool {
    matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
}

/// The notification text.
pub fn message(viewer_name: &str, view_only: bool) -> String {
    let what = if view_only { "viewed" } else { "viewed and controlled" };
    format!("Your screen is being {what} from {}", clean_viewer_name(viewer_name))
}

/// The notice for one session; removed when dropped. Shown from a thread of
/// its own so a slow or missing notification service never delays the
/// session.
pub struct ViewerNotice {
    stop: Option<mpsc::Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl ViewerNotice {
    pub fn show(viewer_name: &str, view_only: bool) -> ViewerNotice {
        let text = message(viewer_name, view_only);
        let (tx, rx) = mpsc::channel::<()>();
        let thread = std::thread::Builder::new()
            .name("cs-notify".into())
            .spawn(move || show_until(&text, view_only, &rx))
            .map_err(|e| log::debug!("notification thread: {e}"))
            .ok();
        ViewerNotice { stop: Some(tx), thread }
    }
}

impl Drop for ViewerNotice {
    fn drop(&mut self) {
        // Dropping the sender wakes the thread, which removes the notice.
        drop(self.stop.take());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

#[cfg(target_os = "linux")]
fn show_until(text: &str, view_only: bool, stop: &mpsc::Receiver<()>) {
    use crossshell_platform_linux::notify::{self, Urgency};
    // Being controlled is worth a notice that stays up until dismissed.
    let urgency = if view_only { Urgency::Normal } else { Urgency::Critical };
    notify::show_until(text, urgency, stop);
}

#[cfg(windows)]
fn show_until(text: &str, _view_only: bool, stop: &mpsc::Receiver<()>) {
    crossshell_platform_windows::notify::show_until("CrossShell", text, stop);
}

#[cfg(not(any(windows, target_os = "linux")))]
fn show_until(_text: &str, _view_only: bool, stop: &mpsc::Receiver<()>) {
    let _ = stop.recv();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_text() {
        assert_eq!(message("laptop", true), "Your screen is being viewed from laptop");
        assert_eq!(message("laptop", false), "Your screen is being viewed and controlled from laptop");
    }

    #[test]
    fn viewer_names_are_cleaned() {
        assert_eq!(clean_viewer_name("pc\n\u{1b}[31mred\u{7}"), "pc[31mred");
        assert_eq!(clean_viewer_name("evil\u{202e}gpj.exe"), "evilgpj.exe");
        assert_eq!(clean_viewer_name("  \t "), "viewer");
        assert_eq!(clean_viewer_name(""), "viewer");
        let long = "é".repeat(100);
        assert_eq!(clean_viewer_name(&long).chars().count(), MAX_NAME_CHARS);
        assert_eq!(clean_viewer_name("ünïcode — ok"), "ünïcode — ok");
    }
}
