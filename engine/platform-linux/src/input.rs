//! Input helpers shared by the backends: button and scroll mapping, frame
//! pixel → compositor coordinate mapping, and the injector used by both
//! D-Bus remote-desktop APIs (Mutter and the portal).

use std::sync::{Arc, Mutex};

use crossshell_platform::Injector;
use crossshell_proto::keymap::evdev;
use crossshell_proto::msg::button;

/// Wire button → evdev `BTN_*` code.
pub fn evdev_button(b: u8) -> Option<u16> {
    match b {
        button::LEFT => Some(evdev::BTN_LEFT),
        button::MIDDLE => Some(evdev::BTN_MIDDLE),
        button::RIGHT => Some(evdev::BTN_RIGHT),
        button::BACK => Some(evdev::BTN_SIDE),
        button::FORWARD => Some(evdev::BTN_EXTRA),
        _ => None,
    }
}

/// Wire button → X11 core button number.
pub fn x11_button(b: u8) -> Option<u8> {
    match b {
        button::LEFT => Some(1),
        button::MIDDLE => Some(2),
        button::RIGHT => Some(3),
        button::BACK => Some(8),
        button::FORWARD => Some(9),
        _ => None,
    }
}

/// Wheel notch in wire units.
pub const NOTCH: i32 = 120;

/// Turns 1/120-notch scroll deltas into whole notches, carrying the rest
/// over to the next event (high-resolution wheels and touchpads send less
/// than a notch at a time).
#[derive(Debug, Default)]
pub struct ScrollAccum {
    x: i32,
    y: i32,
}

impl ScrollAccum {
    /// Add a delta (+x right, +y up); returns whole notches to emit.
    pub fn add(&mut self, dx: i16, dy: i16) -> (i32, i32) {
        // A direction change drops what was left over the other way.
        if (dx as i32).signum() * self.x.signum() < 0 {
            self.x = 0;
        }
        if (dy as i32).signum() * self.y.signum() < 0 {
            self.y = 0;
        }
        self.x += dx as i32;
        self.y += dy as i32;
        let (nx, ny) = (self.x / NOTCH, self.y / NOTCH);
        self.x -= nx * NOTCH;
        self.y -= ny * NOTCH;
        (nx, ny)
    }
}

/// X11 buttons for whole notches: 4/5 = up/down, 6/7 = left/right.
/// Each entry is pressed and released once.
pub fn x11_scroll_buttons(nx: i32, ny: i32) -> Vec<u8> {
    let mut v = Vec::new();
    let (bx, by) = (if nx > 0 { 7 } else { 6 }, if ny > 0 { 4 } else { 5 });
    v.extend(std::iter::repeat_n(by, ny.unsigned_abs() as usize));
    v.extend(std::iter::repeat_n(bx, nx.unsigned_abs() as usize));
    v
}

/// What a remote-desktop API needs to know to place the pointer on one
/// stream, kept up to date by the capturer of that stream.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Geometry {
    /// Size of the buffers PipeWire delivers (0 until negotiated).
    pub buffer: (u32, u32),
    /// Top-left of the crop region inside those buffers.
    pub crop: (i32, i32),
    /// When set, the API wants coordinates in this space (the stream's
    /// logical size) rather than buffer pixels.
    pub logical: Option<(f64, f64)>,
}

impl Geometry {
    /// Frame pixel → API coordinate.
    pub fn map(&self, x: i32, y: i32) -> (f64, f64) {
        let (px, py) = ((x + self.crop.0) as f64, (y + self.crop.1) as f64);
        match self.logical {
            Some((lw, lh)) if self.buffer.0 > 0 && self.buffer.1 > 0 => {
                (px * lw / self.buffer.0 as f64, py * lh / self.buffer.1 as f64)
            }
            _ => (px, py),
        }
    }
}

pub type SharedGeometry = Arc<Mutex<Geometry>>;

/// The `Notify*` calls both remote-desktop D-Bus APIs offer.
pub trait RemoteInput: Send {
    /// `wait` = block until the compositor has taken the event; otherwise
    /// fire and forget (motion is frequent and ordered by the bus anyway).
    fn motion_absolute(&mut self, x: f64, y: f64, wait: bool) -> anyhow::Result<()>;
    fn button(&mut self, evdev: u16, down: bool) -> anyhow::Result<()>;
    /// `axis` 0 = vertical, 1 = horizontal; positive steps = down / right.
    fn axis_discrete(&mut self, axis: u32, steps: i32) -> anyhow::Result<()>;
    fn key(&mut self, evdev: u16, down: bool) -> anyhow::Result<()>;
}

/// [`Injector`] over a [`RemoteInput`] for one stream.
pub struct StreamInjector<R> {
    input: R,
    geometry: SharedGeometry,
    scroll: ScrollAccum,
    moved: bool,
}

/// evdev `KEY_UNKNOWN`: `<I248>`, `NoSymbol` in every XKB layout.
const KEY_UNKNOWN: u16 = 240;
/// Pause between the two first motions (about one compositor frame).
const SETTLE: std::time::Duration = std::time::Duration::from_millis(20);

impl<R: RemoteInput> StreamInjector<R> {
    /// Wrap `input` and wake its virtual keyboard: on a seat without a
    /// keyboard (headless, or a mini PC with none attached) the compositor
    /// only announces one when the first key arrives, and clients lose that
    /// key. Spend it now on a key with no keysym in any layout.
    pub fn new(mut input: R, geometry: SharedGeometry) -> Self {
        let primed = input.key(KEY_UNKNOWN, true).and_then(|_| input.key(KEY_UNKNOWN, false));
        if let Err(e) = primed {
            log::debug!("keyboard priming failed: {e:#}");
        }
        StreamInjector { input, geometry, scroll: ScrollAccum::default(), moved: false }
    }
}

impl<R: RemoteInput> Injector for StreamInjector<R> {
    fn pointer_move(&mut self, x: i32, y: i32) -> anyhow::Result<()> {
        let (sx, sy) = self.geometry.lock().unwrap().map(x, y);
        if !self.moved {
            // The first motion of a fresh virtual pointer only makes it enter
            // the surface below, and clients (GTK at least) drop clicks until
            // a real motion follows. Send it twice, far enough apart that
            // Mutter does not merge the two.
            self.moved = true;
            self.input.motion_absolute(sx, sy, true)?;
            std::thread::sleep(SETTLE);
        }
        self.input.motion_absolute(sx, sy, false)
    }

    fn pointer_button(&mut self, b: u8, down: bool) -> anyhow::Result<()> {
        match evdev_button(b) {
            Some(code) => self.input.button(code, down),
            None => Ok(()),
        }
    }

    fn scroll(&mut self, dx: i16, dy: i16) -> anyhow::Result<()> {
        let (nx, ny) = self.scroll.add(dx, dy);
        if ny != 0 {
            self.input.axis_discrete(0, -ny)?;
        }
        if nx != 0 {
            self.input.axis_discrete(1, nx)?;
        }
        Ok(())
    }

    fn key(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
        self.input.key(code, down)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buttons_map_to_evdev_and_x11() {
        assert_eq!(evdev_button(button::LEFT), Some(0x110));
        assert_eq!(evdev_button(button::RIGHT), Some(0x111));
        assert_eq!(evdev_button(button::MIDDLE), Some(0x112));
        assert_eq!(evdev_button(button::BACK), Some(0x113));
        assert_eq!(evdev_button(button::FORWARD), Some(0x114));
        assert_eq!(evdev_button(9), None);
        assert_eq!([1, 2, 3, 4, 5].map(x11_button), [Some(1), Some(2), Some(3), Some(8), Some(9)]);
        assert_eq!(x11_button(0), None);
    }

    #[test]
    fn whole_notches_pass_straight_through() {
        let mut a = ScrollAccum::default();
        assert_eq!(a.add(0, 120), (0, 1));
        assert_eq!(a.add(0, -360), (0, -3));
        assert_eq!(a.add(240, 0), (2, 0));
    }

    #[test]
    fn partial_notches_accumulate() {
        let mut a = ScrollAccum::default();
        assert_eq!(a.add(0, 50), (0, 0));
        assert_eq!(a.add(0, 50), (0, 0));
        assert_eq!(a.add(0, 50), (0, 1)); // 150 → 1 notch, 30 left
        assert_eq!(a.add(0, 90), (0, 1));
        assert_eq!(a.add(0, -40), (0, 0)); // direction change drops the rest
        assert_eq!(a.add(0, -80), (0, -1));
        assert_eq!(a.add(-60, 0), (0, 0));
        assert_eq!(a.add(-60, 0), (-1, 0));
    }

    #[test]
    fn x11_scroll_buttons_per_notch() {
        assert_eq!(x11_scroll_buttons(0, 2), [4, 4]);
        assert_eq!(x11_scroll_buttons(0, -1), [5]);
        assert_eq!(x11_scroll_buttons(1, 0), [7]);
        assert_eq!(x11_scroll_buttons(-2, 1), [4, 6, 6]);
        assert!(x11_scroll_buttons(0, 0).is_empty());
    }

    #[test]
    fn geometry_maps_pixels_crop_and_logical_space() {
        let mut g = Geometry::default();
        assert_eq!(g.map(10, 20), (10.0, 20.0));
        g.crop = (5, 7);
        assert_eq!(g.map(10, 20), (15.0, 27.0));
        // HiDPI portal (KDE): 3840×2160 buffers, 1920×1080 logical stream.
        let g = Geometry { buffer: (3840, 2160), crop: (0, 0), logical: Some((1920.0, 1080.0)) };
        assert_eq!(g.map(3000, 2000), (1500.0, 1000.0));
        // Logical space but no buffers yet: pass through.
        let g = Geometry { buffer: (0, 0), crop: (0, 0), logical: Some((1920.0, 1080.0)) };
        assert_eq!(g.map(3, 4), (3.0, 4.0));
    }

    #[derive(Default)]
    struct Rec(Vec<String>);
    impl RemoteInput for Rec {
        fn motion_absolute(&mut self, x: f64, y: f64, wait: bool) -> anyhow::Result<()> {
            self.0.push(format!("m {x} {y}{}", if wait { " wait" } else { "" }));
            Ok(())
        }
        fn button(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
            self.0.push(format!("b {code:#x} {down}"));
            Ok(())
        }
        fn axis_discrete(&mut self, axis: u32, steps: i32) -> anyhow::Result<()> {
            self.0.push(format!("a {axis} {steps}"));
            Ok(())
        }
        fn key(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
            self.0.push(format!("k {code} {down}"));
            Ok(())
        }
    }

    #[test]
    fn stream_injector_translates_wire_input() {
        let geo = Arc::new(Mutex::new(Geometry { buffer: (2560, 1440), crop: (0, 0), logical: None }));
        let mut inj = StreamInjector::new(Rec::default(), geo);
        inj.pointer_move(2000, 1000).unwrap();
        inj.pointer_move(1, 2).unwrap();
        inj.pointer_button(button::BACK, true).unwrap();
        inj.pointer_button(7, true).unwrap(); // unknown: ignored
        inj.scroll(0, 120).unwrap(); // up = negative steps
        inj.scroll(-240, -120).unwrap();
        inj.key(30, true).unwrap();
        inj.key(30, false).unwrap();
        assert_eq!(
            inj.input.0,
            [
                "k 240 true",
                "k 240 false",
                "m 2000 1000 wait",
                "m 2000 1000",
                "m 1 2",
                "b 0x113 true",
                "a 0 -1",
                "a 0 1",
                "a 1 -2",
                "k 30 true",
                "k 30 false"
            ]
        );
    }
}
