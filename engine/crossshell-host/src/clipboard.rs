//! Text clipboard sync on the host side.
//!
//! The host polls its clipboard and forwards changes to the viewer; text
//! from the viewer is written to the host clipboard. Text we set ourselves
//! is remembered so it isn't echoed back.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use crossshell_proto::msg::MAX_CLIPBOARD;

pub struct ClipboardSync {
    inner: Arc<Mutex<Inner>>,
}

struct Inner {
    board: Option<arboard::Clipboard>,
    last: Option<String>,
}

impl ClipboardSync {
    pub fn new() -> Self {
        let board = match arboard::Clipboard::new() {
            Ok(b) => Some(b),
            Err(e) => {
                log::warn!("clipboard unavailable, sync disabled: {e}");
                None
            }
        };
        let mut inner = Inner { board, last: None };
        // Don't push whatever was on the clipboard before the session.
        inner.last = inner.read();
        ClipboardSync { inner: Arc::new(Mutex::new(inner)) }
    }

    /// Text from the viewer.
    pub fn set(&self, text: String) {
        let mut g = self.inner.lock().unwrap();
        if let Some(b) = g.board.as_mut() {
            if let Err(e) = b.set_text(text.clone()) {
                log::warn!("clipboard write failed: {e}");
                return;
            }
        }
        g.last = Some(text);
    }

    /// New host clipboard text since the last call, if any.
    pub fn poll(&self) -> Option<String> {
        let mut g = self.inner.lock().unwrap();
        let now = g.read()?;
        if g.last.as_deref() == Some(now.as_str()) || now.len() > MAX_CLIPBOARD {
            return None;
        }
        g.last = Some(now.clone());
        Some(now)
    }

    pub const POLL_INTERVAL: Duration = Duration::from_millis(750);
}

impl Default for ClipboardSync {
    fn default() -> Self {
        Self::new()
    }
}

impl Inner {
    fn read(&mut self) -> Option<String> {
        self.board.as_mut()?.get_text().ok().filter(|t| !t.is_empty())
    }
}
