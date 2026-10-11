//! A screen-less backend: an animated test pattern that also draws the
//! injected pointer and key presses, so a viewer can see input arrive.
//! Used by tests, CI and `crossshell-host --synthetic`.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::{Backend, Capture, CapturedFrame, Capturer, CursorShape, CursorUpdate, DisplayInfo, Injector};

pub const WIDTH: u32 = 1280;
pub const HEIGHT: u32 = 720;
const FRAME_INTERVAL: Duration = Duration::from_millis(33);

/// Input observed by the synthetic injector.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputEvent {
    Move(i32, i32),
    Button(u8, bool),
    Scroll(i16, i16),
    Key(u16, bool),
}

#[derive(Default)]
struct State {
    pointer: (i32, i32),
    last_key: u16,
    events: Vec<InputEvent>,
}

#[derive(Clone, Default)]
pub struct SyntheticBackend {
    state: Arc<Mutex<State>>,
}

impl SyntheticBackend {
    pub fn new() -> Self {
        Self::default()
    }

    /// Every input event injected so far.
    pub fn events(&self) -> Vec<InputEvent> {
        self.state.lock().unwrap().events.clone()
    }
}

impl Backend for SyntheticBackend {
    fn displays(&mut self) -> anyhow::Result<Vec<DisplayInfo>> {
        Ok(vec![DisplayInfo {
            index: 0,
            name: "Synthetic".into(),
            x: 0,
            y: 0,
            width: WIDTH,
            height: HEIGHT,
            primary: true,
        }])
    }

    fn capturer(&mut self, display: u8) -> anyhow::Result<Box<dyn Capturer>> {
        anyhow::ensure!(display == 0, "no display {display}");
        Ok(Box::new(SyntheticCapturer {
            state: self.state.clone(),
            buf: vec![0; (WIDTH * HEIGHT * 4) as usize],
            start: Instant::now(),
            last: None,
            sent_shape: false,
            last_pos: None,
        }))
    }

    fn injector(&mut self, display: u8) -> anyhow::Result<Box<dyn Injector>> {
        anyhow::ensure!(display == 0, "no display {display}");
        Ok(Box::new(SyntheticInjector { state: self.state.clone() }))
    }
}

struct SyntheticCapturer {
    state: Arc<Mutex<State>>,
    buf: Vec<u8>,
    start: Instant,
    last: Option<Instant>,
    sent_shape: bool,
    last_pos: Option<(i32, i32)>,
}

impl SyntheticCapturer {
    fn fill(&mut self, x0: i32, y0: i32, w: i32, h: i32, bgr: [u8; 3]) {
        for y in y0.max(0)..(y0 + h).min(HEIGHT as i32) {
            for x in x0.max(0)..(x0 + w).min(WIDTH as i32) {
                let i = ((y as u32 * WIDTH + x as u32) * 4) as usize;
                self.buf[i..i + 4].copy_from_slice(&[bgr[0], bgr[1], bgr[2], 255]);
            }
        }
    }

    fn render(&mut self) {
        let t = self.start.elapsed().as_secs_f32();
        let (pointer, last_key) = {
            let s = self.state.lock().unwrap();
            (s.pointer, s.last_key)
        };
        // Static background with a few bands (exercises Fill + Zstd tiles).
        self.fill(0, 0, WIDTH as i32, HEIGHT as i32, [48, 32, 24]);
        for i in 0..8 {
            self.fill(0, 60 + i * 80, WIDTH as i32, 4, [90, 90, 90]);
        }
        // A bouncing box.
        let bx = ((t * 0.7).sin() * 0.5 + 0.5) * (WIDTH as f32 - 160.0);
        let by = ((t * 1.1).cos() * 0.5 + 0.5) * (HEIGHT as f32 - 160.0);
        self.fill(bx as i32, by as i32, 160, 160, [40, 160, 240]);
        // Last key pressed as a bar graph (bit pattern of the evdev code).
        for bit in 0..9 {
            let on = last_key & (1 << bit) != 0;
            let c = if on { [80, 220, 80] } else { [70, 70, 70] };
            self.fill(20 + bit * 28, HEIGHT as i32 - 40, 24, 24, c);
        }
        // Crosshair at the injected pointer.
        self.fill(pointer.0 - 12, pointer.1 - 1, 25, 3, [255, 255, 255]);
        self.fill(pointer.0 - 1, pointer.1 - 12, 3, 25, [255, 255, 255]);
    }
}

impl Capturer for SyntheticCapturer {
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Capture<'_>> {
        if let Some(last) = self.last {
            let due = last + FRAME_INTERVAL;
            let now = Instant::now();
            if due > now {
                let wait = due - now;
                if wait > timeout {
                    std::thread::sleep(timeout);
                    return Ok(Capture::Unchanged);
                }
                std::thread::sleep(wait);
            }
        }
        self.last = Some(Instant::now());
        self.render();
        Ok(Capture::Frame(CapturedFrame { width: WIDTH, height: HEIGHT, stride: (WIDTH * 4) as usize, data: &self.buf }))
    }

    fn cursor(&mut self) -> Option<CursorUpdate> {
        let pos = self.state.lock().unwrap().pointer;
        let mut u = CursorUpdate::default();
        if !self.sent_shape {
            self.sent_shape = true;
            // An 8×8 white square with a black border, hotspot top-left.
            let mut rgba = vec![255u8; 8 * 8 * 4];
            for y in 0..8 {
                for x in 0..8 {
                    if x == 0 || y == 0 || x == 7 || y == 7 {
                        rgba[(y * 8 + x) * 4..][..3].copy_from_slice(&[0, 0, 0]);
                    }
                }
            }
            u.shape = Some(Some(CursorShape { width: 8, height: 8, hot_x: 0, hot_y: 0, rgba }));
        }
        if self.last_pos != Some(pos) {
            self.last_pos = Some(pos);
            u.position = Some(pos);
        }
        (u != CursorUpdate::default()).then_some(u)
    }
}

struct SyntheticInjector {
    state: Arc<Mutex<State>>,
}

impl SyntheticInjector {
    fn push(&self, e: InputEvent) {
        let mut s = self.state.lock().unwrap();
        match e {
            InputEvent::Move(x, y) => s.pointer = (x, y),
            InputEvent::Key(k, true) => s.last_key = k,
            _ => {}
        }
        s.events.push(e);
    }
}

impl Injector for SyntheticInjector {
    fn pointer_move(&mut self, x: i32, y: i32) -> anyhow::Result<()> {
        self.push(InputEvent::Move(x, y));
        Ok(())
    }
    fn pointer_button(&mut self, button: u8, down: bool) -> anyhow::Result<()> {
        self.push(InputEvent::Button(button, down));
        Ok(())
    }
    fn scroll(&mut self, dx: i16, dy: i16) -> anyhow::Result<()> {
        self.push(InputEvent::Scroll(dx, dy));
        Ok(())
    }
    fn key(&mut self, evdev: u16, down: bool) -> anyhow::Result<()> {
        self.push(InputEvent::Key(evdev, down));
        Ok(())
    }
}
