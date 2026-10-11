//! Input helpers that don't need a window: pointer-move coalescing, scroll
//! conversion, button and shortcut mapping.

use std::time::{Duration, Instant};

use winit::event::{MouseButton, MouseScrollDelta};
use winit::keyboard::KeyCode;

use crossshell_proto::msg::button;

/// At most one `PointerMove` per this long.
pub const MOVE_INTERVAL: Duration = Duration::from_millis(8);
/// Touchpad pixels that count as one wheel notch.
const PIXELS_PER_NOTCH: f64 = 40.0;

pub fn button_code(b: MouseButton) -> Option<u8> {
    match b {
        MouseButton::Left => Some(button::LEFT),
        MouseButton::Middle => Some(button::MIDDLE),
        MouseButton::Right => Some(button::RIGHT),
        MouseButton::Back => Some(button::BACK),
        MouseButton::Forward => Some(button::FORWARD),
        MouseButton::Other(_) => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shortcut {
    Fullscreen,
    Menu,
}

/// The only keys the viewer keeps for itself.
pub fn shortcut(code: KeyCode, ctrl: bool, alt: bool) -> Option<Shortcut> {
    match code {
        KeyCode::F11 => Some(Shortcut::Fullscreen),
        KeyCode::Enter | KeyCode::NumpadEnter if ctrl && alt => Some(Shortcut::Fullscreen),
        KeyCode::KeyM if ctrl && alt => Some(Shortcut::Menu),
        _ => None,
    }
}

/// Rate-limits pointer moves while never losing the final position: a move
/// that arrives too soon is held and released by [`flush_due`](Self::flush_due)
/// (or superseded by [`force`](Self::force) before a click).
#[derive(Default)]
pub struct MoveLimiter {
    last_sent_at: Option<Instant>,
    last_sent: Option<(i32, i32)>,
    pending: Option<(i32, i32)>,
}

impl MoveLimiter {
    /// New pointer position; `Some` = send it now.
    pub fn push(&mut self, now: Instant, p: (i32, i32)) -> Option<(i32, i32)> {
        if self.last_sent == Some(p) {
            self.pending = None;
            return None;
        }
        match self.last_sent_at {
            Some(t) if now.saturating_duration_since(t) < MOVE_INTERVAL => {
                self.pending = Some(p);
                None
            }
            _ => Some(self.sent(now, p)),
        }
    }

    /// A held move that is now due.
    pub fn flush_due(&mut self, now: Instant) -> Option<(i32, i32)> {
        match (self.pending, self.last_sent_at) {
            (Some(p), Some(t)) if now.saturating_duration_since(t) >= MOVE_INTERVAL => Some(self.sent(now, p)),
            (Some(p), None) => Some(self.sent(now, p)),
            _ => None,
        }
    }

    /// Send `p` now unless the remote pointer is already there.
    pub fn force(&mut self, now: Instant, p: (i32, i32)) -> Option<(i32, i32)> {
        if self.last_sent == Some(p) {
            self.pending = None;
            return None;
        }
        Some(self.sent(now, p))
    }

    /// When the held move becomes due.
    pub fn deadline(&self) -> Option<Instant> {
        self.pending.and(self.last_sent_at).map(|t| t + MOVE_INTERVAL)
    }

    /// Forget everything (e.g. after a display switch).
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    fn sent(&mut self, now: Instant, p: (i32, i32)) -> (i32, i32) {
        self.last_sent_at = Some(now);
        self.last_sent = Some(p);
        self.pending = None;
        p
    }
}

/// Turns winit scroll deltas into wire units (1/120 notch, +y up, +x right),
/// carrying fractions over so slow touchpad scrolling isn't lost.
#[derive(Default)]
pub struct ScrollAccum {
    x: f64,
    y: f64,
}

impl ScrollAccum {
    pub fn add(&mut self, d: MouseScrollDelta) -> Option<(i16, i16)> {
        // winit: positive = content moves right/down, i.e. the wheel turned
        // left/up. The wire wants +x = right, +y = up.
        match d {
            MouseScrollDelta::LineDelta(x, y) => {
                self.x += -(x as f64) * 120.0;
                self.y += y as f64 * 120.0;
            }
            MouseScrollDelta::PixelDelta(p) => {
                self.x += -p.x * 120.0 / PIXELS_PER_NOTCH;
                self.y += p.y * 120.0 / PIXELS_PER_NOTCH;
            }
        }
        let (dx, dy) = (self.x.trunc(), self.y.trunc());
        self.x -= dx;
        self.y -= dy;
        let clamp = |v: f64| v.clamp(i16::MIN as f64, i16::MAX as f64) as i16;
        (dx != 0.0 || dy != 0.0).then(|| (clamp(dx), clamp(dy)))
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use winit::dpi::PhysicalPosition;

    #[test]
    fn buttons() {
        assert_eq!(button_code(MouseButton::Left), Some(1));
        assert_eq!(button_code(MouseButton::Middle), Some(2));
        assert_eq!(button_code(MouseButton::Right), Some(3));
        assert_eq!(button_code(MouseButton::Back), Some(4));
        assert_eq!(button_code(MouseButton::Forward), Some(5));
        assert_eq!(button_code(MouseButton::Other(9)), None);
    }

    #[test]
    fn shortcuts_are_exactly_these() {
        assert_eq!(shortcut(KeyCode::F11, false, false), Some(Shortcut::Fullscreen));
        assert_eq!(shortcut(KeyCode::Enter, true, true), Some(Shortcut::Fullscreen));
        assert_eq!(shortcut(KeyCode::KeyM, true, true), Some(Shortcut::Menu));
        // Without both modifiers everything goes to the remote.
        assert_eq!(shortcut(KeyCode::Enter, true, false), None);
        assert_eq!(shortcut(KeyCode::Enter, false, true), None);
        assert_eq!(shortcut(KeyCode::KeyM, false, false), None);
        assert_eq!(shortcut(KeyCode::KeyM, true, false), None);
        assert_eq!(shortcut(KeyCode::KeyA, true, true), None);
        assert_eq!(shortcut(KeyCode::F12, true, true), None);
        assert_eq!(shortcut(KeyCode::Tab, false, true), None);
        assert_eq!(shortcut(KeyCode::SuperLeft, false, false), None);
    }

    #[test]
    fn limiter_sends_first_then_holds_then_flushes() {
        let t0 = Instant::now();
        let ms = |n| t0 + Duration::from_millis(n);
        let mut l = MoveLimiter::default();
        assert_eq!(l.push(ms(0), (1, 1)), Some((1, 1)));
        // Too soon: held, latest wins.
        assert_eq!(l.push(ms(2), (2, 2)), None);
        assert_eq!(l.push(ms(4), (3, 3)), None);
        assert_eq!(l.deadline(), Some(ms(8)));
        assert_eq!(l.flush_due(ms(5)), None);
        assert_eq!(l.flush_due(ms(8)), Some((3, 3)));
        assert_eq!(l.flush_due(ms(30)), None);
        assert_eq!(l.deadline(), None);
        // After the interval a new move goes out immediately.
        assert_eq!(l.push(ms(30), (9, 9)), Some((9, 9)));
    }

    #[test]
    fn limiter_dedupes_and_flushes_before_clicks() {
        let t0 = Instant::now();
        let ms = |n| t0 + Duration::from_millis(n);
        let mut l = MoveLimiter::default();
        assert_eq!(l.push(ms(0), (5, 5)), Some((5, 5)));
        assert_eq!(l.push(ms(20), (5, 5)), None); // same place
        assert_eq!(l.push(ms(21), (6, 6)), Some((6, 6)));
        assert_eq!(l.push(ms(22), (7, 7)), None);
        assert_eq!(l.force(ms(23), (7, 7)), Some((7, 7)));
        // Moving back to the last sent position cancels a held move.
        assert_eq!(l.push(ms(25), (8, 8)), None);
        assert_eq!(l.push(ms(26), (7, 7)), None);
        assert_eq!(l.flush_due(ms(40)), None);
        assert_eq!(l.force(ms(30), (7, 7)), None);
        assert_eq!(l.force(ms(31), (1, 2)), Some((1, 2)));
        assert_eq!(l.force(ms(32), (1, 2)), None);
        l.reset();
        assert_eq!(l.push(ms(41), (7, 7)), Some((7, 7)));
    }

    #[test]
    fn limiter_rate_is_bounded() {
        // A 1 kHz mouse for one second yields ~125 sends, never more.
        let t0 = Instant::now();
        let mut l = MoveLimiter::default();
        let mut sent = 0;
        for i in 0..1000u64 {
            let now = t0 + Duration::from_millis(i);
            if l.push(now, (i as i32, 0)).is_some() {
                sent += 1;
            }
            if l.flush_due(now).is_some() {
                sent += 1;
            }
        }
        assert!((100..=130).contains(&sent), "{sent}");
    }

    #[test]
    fn line_scroll_is_120_per_notch_with_wire_directions() {
        let mut s = ScrollAccum::default();
        // Wheel up one notch: winit +1 → wire +120 (up).
        assert_eq!(s.add(MouseScrollDelta::LineDelta(0.0, 1.0)), Some((0, 120)));
        assert_eq!(s.add(MouseScrollDelta::LineDelta(0.0, -2.0)), Some((0, -240)));
        // Tilt right: winit -1 (content moves left) → wire +120 (right).
        assert_eq!(s.add(MouseScrollDelta::LineDelta(-1.0, 0.0)), Some((120, 0)));
        assert_eq!(s.add(MouseScrollDelta::LineDelta(1.0, 0.0)), Some((-120, 0)));
    }

    #[test]
    fn pixel_scroll_accumulates_fractions() {
        let mut s = ScrollAccum::default();
        assert_eq!(s.add(MouseScrollDelta::PixelDelta(PhysicalPosition::new(0.0, 40.0))), Some((0, 120)));
        // 0.4 px/notch-units: three 0.4 steps = 1.2 → one unit emitted, 0.2 kept.
        let step = MouseScrollDelta::PixelDelta(PhysicalPosition::new(0.0, 0.4 * 40.0 / 120.0));
        assert_eq!(s.add(step), None);
        assert_eq!(s.add(step), None);
        assert_eq!(s.add(step), Some((0, 1)));
        assert_eq!(s.add(MouseScrollDelta::PixelDelta(PhysicalPosition::new(0.0, 0.0))), None);
        s.reset();
        assert_eq!(s.add(MouseScrollDelta::PixelDelta(PhysicalPosition::new(0.0, -20.0))), Some((0, -60)));
    }

    #[test]
    fn scroll_clamps_to_i16() {
        let mut s = ScrollAccum::default();
        assert_eq!(s.add(MouseScrollDelta::LineDelta(0.0, 1000.0)), Some((0, i16::MAX)));
    }
}
