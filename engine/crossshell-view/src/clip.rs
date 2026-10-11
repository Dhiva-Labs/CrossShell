//! Clipboard sync (text only) on its own thread, so a slow or unresponsive
//! clipboard owner can never stall the window.

use std::sync::mpsc::{self, Sender};

use crossshell_proto::msg::MAX_CLIPBOARD;
use crossshell_proto::Message;

use crate::net::Out;

pub enum ClipCmd {
    /// The window gained focus: send the local clipboard if it changed.
    FocusGained,
    /// The remote side copied something: put it on the local clipboard.
    Set(String),
}

/// Decides what to send, given what was last synced either way. Kept apart
/// from the OS clipboard so it can be tested.
#[derive(Default)]
pub struct SyncState {
    last: Option<String>,
}

impl SyncState {
    /// Local clipboard text after a focus gain: `Some` = send to the remote.
    pub fn local_changed(&mut self, text: &str) -> Option<String> {
        if text.is_empty() || text.len() > MAX_CLIPBOARD || self.last.as_deref() == Some(text) {
            return None;
        }
        self.last = Some(text.to_owned());
        Some(text.to_owned())
    }

    /// Text that came from the remote and is being set locally. Recorded so
    /// it isn't echoed back on the next focus gain.
    pub fn remote_set(&mut self, text: &str) {
        self.last = Some(text.to_owned());
    }
}

/// Start the clipboard thread. Opening the clipboard happens on that thread
/// (it can be slow, e.g. an unreachable X server), so commands sent before
/// it is ready simply queue; if it fails they are dropped.
pub fn spawn(out: Sender<Out>) -> Option<Sender<ClipCmd>> {
    let (tx, rx) = mpsc::channel::<ClipCmd>();
    std::thread::Builder::new()
        .name("cs-clipboard".into())
        .spawn(move || {
            let mut cb = match arboard::Clipboard::new() {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("crossshell-view: clipboard sync disabled: {e}");
                    return;
                }
            };
            let mut state = SyncState::default();
            for cmd in rx {
                match cmd {
                    ClipCmd::FocusGained => {
                        if let Ok(text) = cb.get_text() {
                            if let Some(t) = state.local_changed(&text) {
                                let _ = out.send(Out::Msg(Message::ClipboardText(t)));
                            }
                        }
                    }
                    ClipCmd::Set(text) => {
                        state.remote_set(&text);
                        if let Err(e) = cb.set_text(text) {
                            eprintln!("crossshell-view: cannot set the clipboard: {e}");
                        }
                    }
                }
            }
        })
        .ok()?;
    Some(tx)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sends_only_changes() {
        let mut s = SyncState::default();
        assert_eq!(s.local_changed("hello"), Some("hello".into()));
        assert_eq!(s.local_changed("hello"), None);
        assert_eq!(s.local_changed("world"), Some("world".into()));
    }

    #[test]
    fn ignores_empty_and_oversized() {
        let mut s = SyncState::default();
        assert_eq!(s.local_changed(""), None);
        assert_eq!(s.local_changed(&"x".repeat(MAX_CLIPBOARD + 1)), None);
        assert_eq!(s.local_changed(&"x".repeat(MAX_CLIPBOARD)).map(|t| t.len()), Some(MAX_CLIPBOARD));
    }

    #[test]
    fn remote_text_is_not_echoed_back() {
        let mut s = SyncState::default();
        s.remote_set("from remote");
        assert_eq!(s.local_changed("from remote"), None);
        assert_eq!(s.local_changed("local edit"), Some("local edit".into()));
        // Local text copied again later, after the remote overwrote it, goes out.
        s.remote_set("remote again");
        assert_eq!(s.local_changed("local edit"), Some("local edit".into()));
    }
}
