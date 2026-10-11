//! Capture/input backend traits for the CrossShell host agent.
//!
//! A [`Backend`] is created per viewer session (on Wayland that is one
//! portal session). It lists the displays and hands out a [`Capturer`] and
//! an [`Injector`] for the display the viewer picked. All coordinates the
//! core passes to an injector are in the selected display's frame pixels,
//! with (0, 0) at its top-left; the backend maps them to whatever its OS
//! API wants.

use std::time::Duration;

pub use crossshell_proto::DisplayInfo;

mod synthetic;
pub use synthetic::SyntheticBackend;

/// A captured frame, BGRX (`B, G, R, X` bytes per pixel — the X byte is
/// ignored). `stride` is in bytes and may exceed `width * 4`.
pub struct CapturedFrame<'a> {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub data: &'a [u8],
}

/// Result of one capture attempt.
pub enum Capture<'a> {
    /// The screen changed (or this is the first frame).
    Frame(CapturedFrame<'a>),
    /// Nothing changed within the timeout.
    Unchanged,
    /// Capture is temporarily impossible — e.g. the Windows secure desktop
    /// (UAC prompt, lock screen). The core shows `reason` to the viewer once
    /// and retries every 500 ms.
    Unavailable(String),
}

/// Cursor image, straight (non-premultiplied) RGBA.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorShape {
    pub width: u16,
    pub height: u16,
    pub hot_x: u16,
    pub hot_y: u16,
    pub rgba: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CursorUpdate {
    /// `Some(None)` = cursor hidden; `Some(Some(shape))` = new shape.
    pub shape: Option<Option<CursorShape>>,
    /// New position in display coordinates.
    pub position: Option<(i32, i32)>,
}

pub trait Backend: Send {
    fn displays(&mut self) -> anyhow::Result<Vec<DisplayInfo>>;
    fn capturer(&mut self, display: u8) -> anyhow::Result<Box<dyn Capturer>>;
    fn injector(&mut self, display: u8) -> anyhow::Result<Box<dyn Injector>>;
}

pub trait Capturer: Send {
    /// Wait up to `timeout` for a new frame. `Err` ends the session.
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Capture<'_>>;

    /// Cursor changes since the last call. Backends that embed the cursor
    /// in the frames return `None`.
    fn cursor(&mut self) -> Option<CursorUpdate> {
        None
    }
}

/// Input injection. Buttons use `crossshell_proto::msg::button` values,
/// keys are evdev keycodes, scroll is in 1/120 notch units (+y = up).
/// The core tracks pressed keys/buttons and releases them itself on focus
/// loss or disconnect, so backends need no release-all logic.
pub trait Injector: Send {
    fn pointer_move(&mut self, x: i32, y: i32) -> anyhow::Result<()>;
    fn pointer_button(&mut self, button: u8, down: bool) -> anyhow::Result<()>;
    fn scroll(&mut self, dx: i16, dy: i16) -> anyhow::Result<()>;
    fn key(&mut self, evdev: u16, down: bool) -> anyhow::Result<()>;
}
