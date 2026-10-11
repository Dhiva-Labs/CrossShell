//! Exercise the native Linux backend without a viewer.
//!
//!     cargo run --release -p crossshell-platform-linux --example probe -- \
//!         [--display N] [--seconds S] [--ppm out.ppm] [--move X,Y] [--input]
//!
//! Lists displays, captures for S seconds (default 3) and reports frame
//! rate and cursor updates. `--move` injects one pointer motion. `--input`
//! plays a short click/key/scroll script — only against a test session
//! (headless GNOME, Xvfb), never a desktop someone is using. Both refuse to
//! run unless `CROSSSHELL_PROBE_INPUT_OK=1` and `DBUS_SESSION_BUS_ADDRESS`
//! names a bus other than the user's default one.
#![cfg(target_os = "linux")]

use std::io::Write;
use std::time::{Duration, Instant};

use crossshell_platform::Capture;
use crossshell_proto::keymap::evdev;
use crossshell_proto::msg::button;

fn main() -> anyhow::Result<()> {
    let mut display = 0u8;
    let mut seconds = 3.0f64;
    let mut ppm: Option<String> = None;
    let mut mv: Option<(i32, i32)> = None;
    let mut script = false;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        let mut v = || it.next().ok_or_else(|| anyhow::anyhow!("{a} needs a value"));
        match a.as_str() {
            "--display" => display = v()?.parse()?,
            "--seconds" => seconds = v()?.parse()?,
            "--ppm" => ppm = Some(v()?),
            "--move" => {
                let s = v()?;
                let (x, y) = s.split_once(',').ok_or_else(|| anyhow::anyhow!("--move X,Y"))?;
                mv = Some((x.parse()?, y.parse()?));
            }
            "--input" => script = true,
            _ => anyhow::bail!("unknown arg {a}"),
        }
    }
    if mv.is_some() || script {
        guard_test_session()?;
    }
    let level = std::env::var("RUST_LOG").ok().and_then(|l| l.parse().ok()).unwrap_or(log::LevelFilter::Info);
    static LOGGER: Stderr = Stderr;
    log::set_logger(&LOGGER).ok();
    log::set_max_level(level);

    crossshell_platform_linux::init();
    let t0 = Instant::now();
    let mut backend = crossshell_platform_linux::start_backend()?;
    eprintln!("backend up in {:?}", t0.elapsed());
    for d in backend.displays()? {
        eprintln!("display {}: {:?} {}x{} at {},{}{}", d.index, d.name, d.width, d.height, d.x, d.y, if d.primary { " (primary)" } else { "" });
    }
    let mut cap = backend.capturer(display)?;
    let mut inj = if mv.is_some() || script { Some(backend.injector(display)?) } else { None };

    let start = Instant::now();
    let (mut frames, mut cursors, mut shapes) = (0u32, 0u32, 0u32);
    let mut first: Option<Duration> = None;
    let mut last: Option<(u32, u32, Vec<u8>)> = None;
    let mut moved = false;
    let mut script_step = 0usize;
    let mut next_step = Instant::now();
    while start.elapsed().as_secs_f64() < seconds {
        if let Capture::Frame(f) = cap.next_frame(Duration::from_millis(16))? {
            frames += 1;
            if first.is_none() {
                first = Some(start.elapsed());
                eprintln!("first frame {}x{} after {:?}", f.width, f.height, start.elapsed());
            }
            if ppm.is_some() {
                let mut px = Vec::with_capacity(f.width as usize * f.height as usize * 4);
                for y in 0..f.height as usize {
                    px.extend_from_slice(&f.data[y * f.stride..y * f.stride + f.width as usize * 4]);
                }
                last = Some((f.width, f.height, px));
            }
        }
        if let Some(c) = cap.cursor() {
            cursors += 1;
            if let Some(s) = &c.shape {
                shapes += 1;
                match s {
                    Some(s) => eprintln!("cursor shape {}x{} hot {},{}", s.width, s.height, s.hot_x, s.hot_y),
                    None => eprintln!("cursor hidden"),
                }
            }
            if let Some(p) = c.position {
                log::debug!("cursor at {p:?}");
            }
        }
        if let (Some(inj), Some((x, y)), false) = (inj.as_mut(), mv, moved) {
            if first.is_some() {
                inj.pointer_move(x, y)?;
                moved = true;
                eprintln!("moved pointer to {x},{y}");
            }
        }
        // Give the compositor a moment to add its virtual input devices.
        if script && start.elapsed() > Duration::from_secs(1) && Instant::now() >= next_step {
            if let Some(inj) = inj.as_mut() {
                if play(inj.as_mut(), script_step)? {
                    script_step += 1;
                    next_step = Instant::now() + Duration::from_millis(150);
                }
            }
        }
    }
    let secs = start.elapsed().as_secs_f64();
    eprintln!("{frames} frames in {secs:.1}s ({:.1} fps), {cursors} cursor updates ({shapes} shapes)", frames as f64 / secs);
    if let (Some(path), Some((w, h, px))) = (ppm, last) {
        let mut f = std::fs::File::create(&path)?;
        write!(f, "P6\n{w} {h}\n255\n")?;
        let rgb: Vec<u8> = px.chunks_exact(4).flat_map(|p| [p[2], p[1], p[0]]).collect();
        f.write_all(&rgb)?;
        eprintln!("wrote {path}");
    }
    Ok(())
}

/// Refuse to inject input unless the target is clearly a private test
/// session: the caller must opt in, and the session bus must be set
/// explicitly to something other than this user's default bus (an unset
/// variable makes D-Bus fall back to the live desktop's bus).
fn guard_test_session() -> anyhow::Result<()> {
    if std::env::var("CROSSSHELL_PROBE_INPUT_OK").as_deref() != Ok("1") {
        anyhow::bail!("--input/--move inject real input; set CROSSSHELL_PROBE_INPUT_OK=1 and point DBUS_SESSION_BUS_ADDRESS (and WAYLAND_DISPLAY/DISPLAY) at a test session");
    }
    let bus = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap_or_default();
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_default();
    let default_bus = format!("unix:path={runtime}/bus");
    if bus.is_empty() || bus == default_bus || bus.starts_with(&format!("{default_bus},")) {
        anyhow::bail!("refusing to inject input: DBUS_SESSION_BUS_ADDRESS is unset or the default user bus ({default_bus})");
    }
    Ok(())
}

/// One step of the input script; returns false once finished.
fn play(inj: &mut dyn crossshell_platform::Injector, step: usize) -> anyhow::Result<bool> {
    let s = match step {
        0 => inj.pointer_move(200, 150).map(|_| "move 200,150"),
        1 => inj.pointer_button(button::LEFT, true).map(|_| "left down"),
        2 => inj.pointer_button(button::LEFT, false).map(|_| "left up"),
        3 => inj.pointer_button(button::RIGHT, true).and_then(|_| inj.pointer_button(button::RIGHT, false)).map(|_| "right click"),
        4 => inj.pointer_button(button::BACK, true).and_then(|_| inj.pointer_button(button::BACK, false)).map(|_| "back click"),
        5 => inj.key(evdev::KEY_A, true).and_then(|_| inj.key(evdev::KEY_A, false)).map(|_| "key a"),
        6 => inj.key(evdev::KEY_LEFTSHIFT, true).map(|_| "shift down"),
        7 => inj.key(evdev::KEY_B, true).and_then(|_| inj.key(evdev::KEY_B, false)).map(|_| "key b (shifted)"),
        8 => inj.key(evdev::KEY_LEFTSHIFT, false).map(|_| "shift up"),
        9 => inj.scroll(0, 120).map(|_| "scroll up 1"),
        10 => inj.scroll(0, -240).map(|_| "scroll down 2"),
        11 => inj.scroll(60, 0).and_then(|_| inj.scroll(60, 0)).map(|_| "scroll right 1 (2 halves)"),
        12 => inj.pointer_move(400, 300).map(|_| "move 400,300"),
        _ => return Ok(false),
    }?;
    eprintln!("input: {s}");
    Ok(true)
}

struct Stderr;
impl log::Log for Stderr {
    fn enabled(&self, _: &log::Metadata) -> bool {
        true
    }
    fn log(&self, r: &log::Record) {
        eprintln!("[{} {}] {}", r.level(), r.target(), r.args());
    }
    fn flush(&self) {}
}
