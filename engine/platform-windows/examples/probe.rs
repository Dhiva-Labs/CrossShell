//! Hardware probe for the Windows backend. Run it in the signed-in user's
//! session (over SSH it lands in session 0, which has no desktop):
//!
//!     probe.exe [--out DIR] [--seconds N] [--no-input] [--no-switch]
//!
//! 1. Lists displays.
//! 2. Captures the primary display: first-frame latency on a still screen,
//!    pointer-only updates (must not produce frames), then fps while its own
//!    test window animates every vsync. The last frame goes to
//!    `DIR\probe-last.bmp`.
//! 3. Moves the pointer through the injector and checks every pixel of one
//!    row and one column with `GetCursorPos`, plus the hotspot DXGI reports.
//! 4. Clicks, scrolls and types into its own topmost window only (checked
//!    with `WindowFromPoint` / `GetForegroundWindow` before each step) and
//!    verifies the window messages that arrive.
//! 5. Switches input to a desktop of its own for 1.5 s (`--no-switch`
//!    skips this) to stand in for the secure desktop: capture must report
//!    `Unavailable` and recover after switching back.
//!
//! The pointer is put back where it was at the end.

#[cfg(not(windows))]
fn main() {
    eprintln!("the probe runs on Windows only");
}

#[cfg(windows)]
fn main() {
    if let Err(e) = imp::run() {
        println!("PROBE FAILED: {e:#}");
        std::process::exit(1);
    }
}

#[cfg(windows)]
mod imp {
    use std::io::Write;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU32, Ordering};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    use anyhow::{bail, Context};
    use crossshell_platform::{Capture, Capturer, DisplayInfo, Injector};
    use crossshell_proto::keymap::evdev::*;
    use crossshell_proto::msg::button;
    use windows::core::{w, PCWSTR};
    use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
    use windows::Win32::Graphics::Dwm::DwmFlush;
    use windows::Win32::Graphics::Gdi::{
        BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, InvalidateRect, ScreenToClient, SetBkMode,
        SetTextColor, TextOutW, PAINTSTRUCT, TRANSPARENT,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::System::StationsAndDesktops::{
        CloseDesktop, CreateDesktopW, OpenDesktopW, SwitchDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_CREATEWINDOW,
        DESKTOP_READOBJECTS, DESKTOP_SWITCHDESKTOP, HDESK,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, VK_NUMLOCK};
    use windows::Win32::UI::WindowsAndMessaging::*;

    // ---------------------------------------------------------------- log

    struct StdoutLog(Instant);

    /// Pointer-only DXGI updates the capturer swallowed (it traces each).
    static POINTER_ONLY: AtomicU32 = AtomicU32::new(0);

    impl log::Log for StdoutLog {
        fn enabled(&self, m: &log::Metadata) -> bool {
            m.level() <= log::Level::Trace
        }
        fn log(&self, r: &log::Record) {
            if r.level() == log::Level::Trace {
                if r.args().to_string() == "pointer-only update" {
                    POINTER_ONLY.fetch_add(1, Ordering::SeqCst);
                }
                return;
            }
            println!("[{:7.3}] {:5} {}", self.0.elapsed().as_secs_f64(), r.level(), r.args());
        }
        fn flush(&self) {
            let _ = std::io::stdout().flush();
        }
    }

    // ------------------------------------------------------- test window

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Ev {
        Key { down: bool, vk: u32, scan: u32, ext: bool },
        Char(u32),
        Button { b: u8, down: bool, x: i32, y: i32 },
        Wheel(i16),
        HWheel(i16),
    }

    static EVENTS: Mutex<Vec<Ev>> = Mutex::new(Vec::new());
    static ANIMATE: AtomicBool = AtomicBool::new(false);
    static QUIT: AtomicBool = AtomicBool::new(false);
    static HWND_VAL: AtomicIsize = AtomicIsize::new(0);
    static TICK: AtomicU32 = AtomicU32::new(0);
    /// Index into `CURSORS` the test window shows.
    static CURSOR_KIND: AtomicU32 = AtomicU32::new(0);
    const CURSORS: [(&str, PCWSTR); 6] = [
        ("arrow", IDC_ARROW),
        ("ibeam", IDC_IBEAM),
        ("hand", IDC_HAND),
        ("cross", IDC_CROSS),
        ("sizeall", IDC_SIZEALL),
        ("no", IDC_NO),
    ];

    const WIN_W: i32 = 640;
    const WIN_H: i32 = 400;

    fn push(e: Ev) {
        EVENTS.lock().unwrap().push(e);
    }

    fn lo(l: isize) -> i32 {
        (l & 0xFFFF) as i16 as i32
    }
    fn hi(l: isize) -> i32 {
        ((l >> 16) & 0xFFFF) as i16 as i32
    }

    unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
        let key = |down| {
            push(Ev::Key { down, vk: wp.0 as u32, scan: ((lp.0 >> 16) & 0xFF) as u32, ext: (lp.0 >> 24) & 1 == 1 });
            LRESULT(0)
        };
        let btn = |b, down| {
            push(Ev::Button { b, down, x: lo(lp.0), y: hi(lp.0) });
            LRESULT(0)
        };
        match msg {
            WM_KEYDOWN | WM_SYSKEYDOWN => key(true),
            WM_KEYUP | WM_SYSKEYUP => key(false),
            WM_CHAR => {
                push(Ev::Char(wp.0 as u32));
                LRESULT(0)
            }
            WM_LBUTTONDOWN => btn(button::LEFT, true),
            WM_LBUTTONUP => btn(button::LEFT, false),
            WM_MBUTTONDOWN => btn(button::MIDDLE, true),
            WM_MBUTTONUP => btn(button::MIDDLE, false),
            WM_RBUTTONDOWN => btn(button::RIGHT, true),
            WM_RBUTTONUP => btn(button::RIGHT, false),
            WM_XBUTTONDOWN | WM_XBUTTONUP => {
                let b = if hi(wp.0 as isize) as u16 == XBUTTON1 { button::BACK } else { button::FORWARD };
                push(Ev::Button { b, down: msg == WM_XBUTTONDOWN, x: lo(lp.0), y: hi(lp.0) });
                // Handled: keeps DefWindowProc from turning it into a
                // browser-back WM_APPCOMMAND for the shell.
                LRESULT(1)
            }
            WM_APPCOMMAND => LRESULT(1),
            WM_MOUSEWHEEL => {
                push(Ev::Wheel(hi(wp.0 as isize) as i16));
                LRESULT(0)
            }
            WM_MOUSEHWHEEL => {
                push(Ev::HWheel(hi(wp.0 as isize) as i16));
                LRESULT(0)
            }
            WM_CONTEXTMENU => LRESULT(0),
            WM_SETCURSOR if (lp.0 & 0xFFFF) as u32 == HTCLIENT => {
                let id = CURSORS[CURSOR_KIND.load(Ordering::SeqCst) as usize].1;
                unsafe { SetCursor(LoadCursorW(None, id).ok()) };
                LRESULT(1)
            }
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                unsafe {
                    let dc = BeginPaint(hwnd, &mut ps);
                    let t = TICK.load(Ordering::Relaxed);
                    let (r, g, b) = ((t * 3) % 256, (t * 5) % 256, 160u32);
                    let brush = CreateSolidBrush(COLORREF(r | (g << 8) | (b << 16)));
                    let rc = RECT { left: 0, top: 0, right: 10000, bottom: 10000 };
                    FillRect(dc, &rc, brush);
                    let _ = DeleteObject(brush.into());
                    SetBkMode(dc, TRANSPARENT);
                    SetTextColor(dc, COLORREF(0xFFFFFF));
                    let text: Vec<u16> = format!("CrossShell probe - frame {t}").encode_utf16().collect();
                    let _ = TextOutW(dc, 20, 20, &text);
                    let _ = EndPaint(hwnd, &ps);
                }
                LRESULT(0)
            }
            _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
        }
    }

    /// Topmost test window centred on `d`, pumped on its own thread; it
    /// repaints every vsync while `ANIMATE` is set.
    fn spawn_window(d: &DisplayInfo) -> std::thread::JoinHandle<()> {
        let x = d.x + (d.width as i32 - WIN_W) / 2;
        let y = d.y + (d.height as i32 - WIN_H) / 2;
        std::thread::spawn(move || unsafe {
            let inst = GetModuleHandleW(None).unwrap();
            let wc = WNDCLASSW {
                lpfnWndProc: Some(wndproc),
                hInstance: inst.into(),
                lpszClassName: w!("CrossShellProbe"),
                hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
                ..Default::default()
            };
            RegisterClassW(&wc);
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST,
                w!("CrossShellProbe"),
                w!("CrossShell probe"),
                WS_POPUP | WS_BORDER | WS_VISIBLE,
                x,
                y,
                WIN_W,
                WIN_H,
                None,
                None,
                Some(inst.into()),
                None,
            )
            .expect("CreateWindowExW");
            HWND_VAL.store(hwnd.0 as isize, Ordering::SeqCst);
            let mut msg = MSG::default();
            while !QUIT.load(Ordering::SeqCst) {
                while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
                if ANIMATE.load(Ordering::Relaxed) {
                    TICK.fetch_add(1, Ordering::Relaxed);
                    let _ = InvalidateRect(Some(hwnd), None, false);
                }
                if DwmFlush().is_err() {
                    std::thread::sleep(Duration::from_millis(8));
                }
            }
            let _ = DestroyWindow(hwnd);
        })
    }

    fn hwnd() -> HWND {
        HWND(HWND_VAL.load(Ordering::SeqCst) as *mut _)
    }

    /// Move/resize the test window (topmost). Covering the whole display
    /// hides whatever else is animating there (videos, clocks).
    fn place_window(x: i32, y: i32, w: i32, h: i32) {
        unsafe {
            let _ = SetWindowPos(hwnd(), Some(HWND_TOPMOST), x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
            let _ = InvalidateRect(Some(hwnd()), None, true);
        }
        std::thread::sleep(Duration::from_millis(300));
    }

    // ------------------------------------------------------------ helpers

    fn cursor_pos() -> (i32, i32) {
        let mut p = POINT::default();
        unsafe { GetCursorPos(&mut p) }.ok();
        (p.x, p.y)
    }

    /// Wait until the window has received events satisfying `done`.
    fn wait_events(timeout: Duration, done: impl Fn(&[Ev]) -> bool) -> Vec<Ev> {
        let t = Instant::now();
        loop {
            let ev = EVENTS.lock().unwrap().clone();
            if done(&ev) || t.elapsed() > timeout {
                return ev;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn clear_events() {
        EVENTS.lock().unwrap().clear();
    }

    struct Tally {
        pass: u32,
        fail: u32,
    }

    impl Tally {
        fn check(&mut self, name: &str, ok: bool, detail: impl std::fmt::Display) {
            if ok {
                self.pass += 1;
                println!("PASS {name}: {detail}");
            } else {
                self.fail += 1;
                println!("FAIL {name}: {detail}");
            }
        }
    }

    fn write_bmp(path: &PathBuf, w: u32, h: u32, bgrx: &[u8]) -> std::io::Result<()> {
        let size = 54 + bgrx.len() as u32;
        let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
        f.write_all(b"BM")?;
        f.write_all(&size.to_le_bytes())?;
        f.write_all(&0u32.to_le_bytes())?;
        f.write_all(&54u32.to_le_bytes())?;
        f.write_all(&40u32.to_le_bytes())?;
        f.write_all(&(w as i32).to_le_bytes())?;
        f.write_all(&(-(h as i32)).to_le_bytes())?; // top-down
        f.write_all(&1u16.to_le_bytes())?;
        f.write_all(&32u16.to_le_bytes())?;
        f.write_all(&[0u8; 24])?; // BI_RGB, sizes, resolution, palette
        f.write_all(bgrx)
    }

    /// Run the capturer for `dur`, feeding cursor updates to `on_cursor`.
    /// Returns (frames, unchanged, unavailable).
    fn pump(
        cap: &mut dyn Capturer,
        dur: Duration,
        last: &mut Option<(u32, u32, Vec<u8>)>,
        mut on_cursor: impl FnMut(crossshell_platform::CursorUpdate),
    ) -> anyhow::Result<(u32, u32, u32)> {
        let (mut frames, mut unchanged, mut unavailable) = (0, 0, 0);
        let t = Instant::now();
        while t.elapsed() < dur {
            match cap.next_frame(Duration::from_millis(16))? {
                Capture::Frame(f) => {
                    frames += 1;
                    let row = f.width as usize * 4;
                    let mut packed = Vec::with_capacity(row * f.height as usize);
                    for y in 0..f.height as usize {
                        packed.extend_from_slice(&f.data[y * f.stride..y * f.stride + row]);
                    }
                    *last = Some((f.width, f.height, packed));
                }
                Capture::Unchanged => unchanged += 1,
                Capture::Unavailable(r) => {
                    unavailable += 1;
                    println!("unavailable: {r}");
                    std::thread::sleep(Duration::from_millis(500));
                }
            }
            if let Some(u) = cap.cursor() {
                on_cursor(u);
            }
        }
        Ok((frames, unchanged, unavailable))
    }

    fn describe(u: &crossshell_platform::CursorUpdate) -> String {
        let shape = match &u.shape {
            None => String::new(),
            Some(None) => " shape=hidden".into(),
            Some(Some(s)) => {
                let opaque = s.rgba.chunks(4).filter(|p| p[3] != 0).count();
                format!(" shape={}x{} hot={},{} opaque_px={opaque}", s.width, s.height, s.hot_x, s.hot_y)
            }
        };
        let pos = u.position.map(|(x, y)| format!(" pos={x},{y}")).unwrap_or_default();
        format!("cursor update:{shape}{pos}")
    }

    // --------------------------------------------------------------- main

    pub fn run() -> anyhow::Result<()> {
        static LOGGER: std::sync::OnceLock<StdoutLog> = std::sync::OnceLock::new();
        let _ = log::set_logger(LOGGER.get_or_init(|| StdoutLog(Instant::now())));
        log::set_max_level(log::LevelFilter::Trace);

        let mut out = PathBuf::from(".");
        let mut seconds = 3u64;
        let mut input = true;
        let mut switch = true;
        let mut it = std::env::args().skip(1);
        while let Some(a) = it.next() {
            match a.as_str() {
                "--out" => out = it.next().context("--out DIR")?.into(),
                "--seconds" => seconds = it.next().context("--seconds N")?.parse()?,
                "--no-input" => input = false,
                "--no-switch" => switch = false,
                "--version" => {
                    println!("probe {}", env!("CARGO_PKG_VERSION"));
                    return Ok(());
                }
                _ => bail!("unknown argument {a}"),
            }
        }

        crossshell_platform_windows::init();
        let mut t = Tally { pass: 0, fail: 0 };
        let mut be = crossshell_platform_windows::start_backend()?;
        let displays = be.displays()?;
        for d in &displays {
            println!(
                "display {}: {:?} {}x{} at {},{}{}",
                d.index,
                d.name,
                d.width,
                d.height,
                d.x,
                d.y,
                if d.primary { " (primary)" } else { "" }
            );
        }
        let d = displays.iter().find(|d| d.primary).or(displays.first()).context("no displays")?.clone();
        let home = cursor_pos();
        println!("pointer starts at {home:?}");

        let win_thread = spawn_window(&d);
        while HWND_VAL.load(Ordering::SeqCst) == 0 {
            std::thread::sleep(Duration::from_millis(10));
        }
        std::thread::sleep(Duration::from_millis(500));
        let win_x = d.x + (d.width as i32 - WIN_W) / 2;
        let win_y = d.y + (d.height as i32 - WIN_H) / 2;

        // --- First frame on a still screen (the window covers the display).
        place_window(d.x, d.y, d.width as i32, d.height as i32);
        let started = Instant::now();
        let mut cap = be.capturer(d.index)?;
        let created = started.elapsed();
        let mut last = None;
        let mut first = None;
        while started.elapsed() < Duration::from_secs(5) {
            match cap.next_frame(Duration::from_millis(16))? {
                Capture::Frame(f) => {
                    first = Some(started.elapsed());
                    println!("first frame {}x{} stride {} ({} bytes)", f.width, f.height, f.stride, f.data.len());
                    let row = f.width as usize * 4;
                    let mut packed = Vec::with_capacity(row * f.height as usize);
                    for y in 0..f.height as usize {
                        packed.extend_from_slice(&f.data[y * f.stride..y * f.stride + row]);
                    }
                    // The covering window is painted with blue 160.
                    let (cx, cy) = (f.width as usize / 2, f.height as usize / 2);
                    let p = &packed[(cy * f.width as usize + cx) * 4..][..4];
                    t.check(
                        "first frame shows the screen (not black)",
                        p[0] == 160,
                        format!("centre pixel BGRX {p:?}"),
                    );
                    write_bmp(&out.join("probe-first.bmp"), f.width, f.height, &packed)?;
                    break;
                }
                Capture::Unavailable(r) => bail!("capture unavailable: {r}"),
                Capture::Unchanged => {}
            }
        }
        t.check(
            "first frame on a still screen",
            first.is_some(),
            format!("capturer created in {created:?}, first frame after {first:?}"),
        );
        if let Some(u) = cap.cursor() {
            println!("{}", describe(&u));
        }

        // --- Pointer-only motion: cursor updates, no frames. Stay inside
        // the test window so nothing on screen reacts to hover.
        let mut inj = be.injector(d.index)?;
        let (rx, ry) = (win_x - d.x, win_y - d.y);
        let mut cursor_updates = Vec::new();
        let (idle, _, _) = pump(cap.as_mut(), Duration::from_millis(500), &mut last, |u| cursor_updates.push(u))?;
        let swallowed = POINTER_ONLY.load(Ordering::SeqCst);
        let mut frames_on_move = 0;
        for (px, py) in [(100, 100), (300, 200), (500, 300), (200, 250)] {
            inj.pointer_move(rx + px, ry + py)?;
            let (f, _, _) = pump(cap.as_mut(), Duration::from_millis(150), &mut last, |u| cursor_updates.push(u))?;
            frames_on_move += f;
        }
        let swallowed = POINTER_ONLY.load(Ordering::SeqCst) - swallowed;
        for u in &cursor_updates {
            println!("{}", describe(u));
        }
        // Frames can still come from unrelated changes (a toast above the
        // test window); what matters is that pointer-only updates were swallowed.
        t.check(
            "pointer-only updates give no frames",
            swallowed > 0 && frames_on_move <= idle.max(1),
            format!("{idle} frames while idle, {frames_on_move} while moving, {swallowed} pointer-only updates"),
        );
        let want = (rx + 200, ry + 250);
        let got = cursor_updates.iter().rev().find_map(|u| u.position);
        t.check("DXGI hotspot matches injected position", got == Some(want), format!("want {want:?}, got {got:?}"));
        let screen = cursor_pos();
        t.check(
            "GetCursorPos matches injected position",
            screen == (d.x + want.0, d.y + want.1),
            format!("GetCursorPos {screen:?}"),
        );

        // --- Pointer shapes: each system cursor over the test window, saved
        // as raw RGBA for inspection (cursor-<name>-<w>x<h>-<hx>,<hy>.rgba).
        for (i, (name, _)) in CURSORS.iter().enumerate().skip(1).chain(CURSORS.iter().enumerate().take(1)) {
            CURSOR_KIND.store(i as u32, Ordering::SeqCst);
            // WM_SETCURSOR comes with pointer motion.
            inj.pointer_move(rx + 210 + i as i32, ry + 250)?;
            let mut shape = None;
            pump(cap.as_mut(), Duration::from_millis(200), &mut last, |u| {
                if let Some(Some(s)) = u.shape {
                    shape = Some(s);
                }
            })?;
            match shape {
                Some(s) => {
                    let opaque = s.rgba.chunks(4).filter(|p| p[3] != 0).count();
                    let f = format!("cursor-{name}-{}x{}-{},{}.rgba", s.width, s.height, s.hot_x, s.hot_y);
                    std::fs::write(out.join(&f), &s.rgba)?;
                    t.check(
                        &format!("{name} cursor shape"),
                        opaque > 0,
                        format!("{}x{} hot {},{} {opaque} opaque px -> {f}", s.width, s.height, s.hot_x, s.hot_y),
                    );
                }
                None => t.check(&format!("{name} cursor shape"), false, "no shape update"),
            }
        }

        // --- Capture rate with the window repainting every vsync.
        place_window(win_x, win_y, WIN_W, WIN_H);
        ANIMATE.store(true, Ordering::SeqCst);
        let (frames, unchanged, unavailable) = pump(cap.as_mut(), Duration::from_secs(seconds), &mut last, |_| {})?;
        ANIMATE.store(false, Ordering::SeqCst);
        let fps = frames as f64 / seconds as f64;
        println!(
            "animated: {frames} frames in {seconds}s = {fps:.1} fps ({unchanged} unchanged, {unavailable} unavailable)"
        );
        t.check("capture keeps up with an animating window", fps >= 25.0, format!("{fps:.1} fps"));
        if let Some((w, h, px)) = &last {
            let path = out.join("probe-last.bmp");
            write_bmp(&path, *w, *h, px)?;
            println!("wrote {} ({w}x{h})", path.display());
            // The window's top-left pixel must show its paint color.
            let i = ((win_y - d.y) as usize + 5) * *w as usize * 4 + ((win_x - d.x) as usize + 5) * 4;
            let p = &px[i..i + 4];
            let tick = TICK.load(Ordering::SeqCst);
            println!("window pixel BGRX {p:?} at tick {tick}");
            t.check("captured window pixel has the paint's blue channel", p[0] == 160, format!("{p:?}"));
        }

        // --- Pointer placement: every pixel of one row and one column.
        let mut misses = Vec::new();
        let mut moves = 0;
        let y = d.height as i32 / 2;
        let x = d.width as i32 / 2;
        let targets = (0..d.width as i32).map(|x| (x, y)).chain((0..d.height as i32).map(|y| (x, y)));
        let mut prev = cursor_pos();
        for (tx, ty) in targets {
            inj.pointer_move(tx, ty)?;
            moves += 1;
            let want = (d.x + tx, d.y + ty);
            let t0 = Instant::now();
            let mut now = cursor_pos();
            while now == prev && now != want && t0.elapsed() < Duration::from_millis(30) {
                std::thread::sleep(Duration::from_micros(200));
                now = cursor_pos();
            }
            if now != want {
                misses.push((want, now));
            }
            prev = now;
        }
        t.check(
            "pointer lands on the exact pixel (row + column sweep)",
            misses.is_empty(),
            format!("{moves} moves, {} misses, first: {:?}", misses.len(), misses.iter().take(5).collect::<Vec<_>>()),
        );
        for (tx, ty) in [(0, 0), (d.width as i32 - 1, d.height as i32 - 1)] {
            inj.pointer_move(tx, ty)?;
            std::thread::sleep(Duration::from_millis(30));
            let got = cursor_pos();
            t.check("corner", got == (d.x + tx, d.y + ty), format!("({tx},{ty}) -> {got:?}"));
        }

        if input {
            input_tests(&mut t, inj.as_mut(), &d, win_x, win_y)?;
        }

        // Unknown key codes are ignored.
        inj.key(0, true)?;
        inj.key(999, true)?;

        if switch {
            desktop_switch_test(&mut t, cap.as_mut(), inj.as_mut())?;
        }

        unsafe { SetCursorPos(home.0, home.1) }.ok();
        QUIT.store(true, Ordering::SeqCst);
        let _ = win_thread.join();
        drop(cap);
        println!("RESULT: {} passed, {} failed", t.pass, t.fail);
        if t.fail > 0 {
            bail!("{} checks failed", t.fail);
        }
        Ok(())
    }

    static SWITCHED: AtomicBool = AtomicBool::new(false);

    /// Switches input back to `Default` however the test ends.
    struct SwitchBack(HDESK);

    impl Drop for SwitchBack {
        fn drop(&mut self) {
            if SWITCHED.swap(false, Ordering::SeqCst) {
                unsafe { SwitchDesktop(self.0) }.ok();
            }
        }
    }

    /// Simulates the secure desktop: switch input to a desktop of our own
    /// for ~1.5 s (what KeePass's secure password entry does), check the
    /// capturer reports it, then switch back and check capture recovers.
    fn desktop_switch_test(t: &mut Tally, cap: &mut dyn Capturer, inj: &mut dyn Injector) -> anyhow::Result<()> {
        let default = unsafe { OpenDesktopW(w!("Default"), DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_SWITCHDESKTOP.0) }
            .context("OpenDesktop(Default)")?;
        let access = DESKTOP_SWITCHDESKTOP.0 | DESKTOP_CREATEWINDOW.0 | DESKTOP_READOBJECTS.0;
        let other = unsafe {
            CreateDesktopW(w!("CrossShellProbe"), PCWSTR::null(), None, DESKTOP_CONTROL_FLAGS(0), access, None)
        }
        .context("CreateDesktop")?;

        ANIMATE.store(true, Ordering::SeqCst);
        let mut last = None;
        pump(cap, Duration::from_millis(300), &mut last, |_| {})?;

        // Belt and braces: a watchdog switches back even if this thread hangs.
        let default_raw = default.0 as isize;
        let watchdog = std::thread::spawn(move || {
            let t0 = Instant::now();
            while SWITCHED.load(Ordering::SeqCst) && t0.elapsed() < Duration::from_secs(5) {
                std::thread::sleep(Duration::from_millis(20));
            }
            if SWITCHED.swap(false, Ordering::SeqCst) {
                unsafe { SwitchDesktop(HDESK(default_raw as *mut _)) }.ok();
                println!("watchdog switched back to Default");
            }
        });
        SWITCHED.store(true, Ordering::SeqCst);
        let back = SwitchBack(default);
        let switched_at = Instant::now();
        unsafe { SwitchDesktop(other) }.context("SwitchDesktop")?;

        let (mut reasons, mut frames_during) = (Vec::new(), 0);
        while switched_at.elapsed() < Duration::from_millis(1500) {
            match cap.next_frame(Duration::from_millis(16))? {
                Capture::Unavailable(r) => {
                    if reasons.is_empty() {
                        println!("unavailable after {:?}: {r}", switched_at.elapsed());
                    }
                    reasons.push(r);
                    std::thread::sleep(Duration::from_millis(500)); // as the host core does
                }
                Capture::Frame(_) => frames_during += 1,
                Capture::Unchanged => {}
            }
        }
        // Input to the other desktop is refused; that must not be an error.
        inj.pointer_move(10, 10)?;
        drop(back);
        let back_at = Instant::now();
        let mut recovered = None;
        while back_at.elapsed() < Duration::from_secs(4) {
            match cap.next_frame(Duration::from_millis(16))? {
                Capture::Frame(_) => {
                    recovered = Some(back_at.elapsed());
                    break;
                }
                Capture::Unavailable(_) => std::thread::sleep(Duration::from_millis(500)),
                Capture::Unchanged => {}
            }
        }
        ANIMATE.store(false, Ordering::SeqCst);
        let _ = watchdog.join();
        unsafe {
            let _ = CloseDesktop(other);
            let _ = CloseDesktop(default);
        }
        t.check(
            "other desktop reported as unavailable",
            reasons.first().is_some_and(|r| r.contains("secure screen")),
            format!("{} unavailable results, {frames_during} frames while switched", reasons.len()),
        );
        t.check(
            "capture recovers after switching back",
            recovered.is_some(),
            format!("first frame after {recovered:?}"),
        );
        Ok(())
    }

    fn input_tests(
        t: &mut Tally,
        inj: &mut dyn Injector,
        d: &DisplayInfo,
        win_x: i32,
        win_y: i32,
    ) -> anyhow::Result<()> {
        // Point at the middle of our window and make sure it is ours.
        let (cx, cy) = (WIN_W / 2, WIN_H / 2);
        inj.pointer_move(win_x - d.x + cx, win_y - d.y + cy)?;
        std::thread::sleep(Duration::from_millis(50));
        let (sx, sy) = cursor_pos();
        let under = unsafe { GetAncestor(WindowFromPoint(POINT { x: sx, y: sy }), GA_ROOT) };
        if under != hwnd() {
            t.check("test window is under the pointer", false, "something covers it; skipping clicks and keys");
            return Ok(());
        }

        let mut client = POINT { x: sx, y: sy };
        let _ = unsafe { ScreenToClient(hwnd(), &mut client) };
        let (cx, cy) = (client.x, client.y);

        // Left click: activates the window and arrives at the right spot.
        clear_events();
        inj.pointer_button(button::LEFT, true)?;
        inj.pointer_button(button::LEFT, false)?;
        let ev = wait_events(Duration::from_millis(500), |e| e.len() >= 2);
        t.check(
            "left click",
            ev == [
                Ev::Button { b: button::LEFT, down: true, x: cx, y: cy },
                Ev::Button { b: button::LEFT, down: false, x: cx, y: cy },
            ],
            format!("{ev:?}"),
        );

        for (b, name) in [
            (button::RIGHT, "right"),
            (button::MIDDLE, "middle"),
            (button::BACK, "back/X1"),
            (button::FORWARD, "forward/X2"),
        ] {
            if unsafe { GetAncestor(WindowFromPoint(POINT { x: sx, y: sy }), GA_ROOT) } != hwnd() {
                t.check("test window still under the pointer", false, "stopping");
                return Ok(());
            }
            clear_events();
            inj.pointer_button(b, true)?;
            inj.pointer_button(b, false)?;
            let ev = wait_events(Duration::from_millis(500), |e| e.len() >= 2);
            let ok = ev.len() == 2
                && matches!(ev[0], Ev::Button { b: x, down: true, .. } if x == b)
                && matches!(ev[1], Ev::Button { b: x, down: false, .. } if x == b);
            t.check(&format!("{name} button"), ok, format!("{ev:?}"));
        }

        for (dx, dy, want) in [
            (0, 120, Ev::Wheel(120)),
            (0, -240, Ev::Wheel(-240)),
            (120, 0, Ev::HWheel(120)),
            (-120, 0, Ev::HWheel(-120)),
        ] {
            clear_events();
            inj.scroll(dx, dy)?;
            let ev = wait_events(Duration::from_millis(500), |e| !e.is_empty());
            t.check(&format!("scroll dx={dx} dy={dy}"), ev == [want], format!("{ev:?}"));
        }

        let fg = unsafe { GetForegroundWindow() };
        t.check("click focused the test window", fg == hwnd(), format!("foreground {fg:?}, ours {:?}", hwnd()));
        if fg != hwnd() {
            println!("skipping key tests: the test window is not in the foreground");
            return Ok(());
        }

        struct KeyCase {
            name: &'static str,
            keys: &'static [(u16, bool)],
            /// (vk, scan, extended) of the first WM_KEYDOWN; vk 0 = don't care.
            down: (u32, u32, bool),
            chars: &'static str,
        }
        let numlock_on = unsafe { GetKeyState(VK_NUMLOCK.0 as i32) } & 1 == 1;
        let cases = [
            KeyCase { name: "A", keys: &[(KEY_A, true), (KEY_A, false)], down: (0x41, 0x1E, false), chars: "a" },
            KeyCase {
                name: "Shift+A",
                keys: &[(KEY_LEFTSHIFT, true), (KEY_A, true), (KEY_A, false), (KEY_LEFTSHIFT, false)],
                down: (0x10, 0x2A, false),
                chars: "A",
            },
            KeyCase { name: "1", keys: &[(KEY_1, true), (KEY_1, false)], down: (0x31, 0x02, false), chars: "1" },
            KeyCase {
                name: "Enter",
                keys: &[(KEY_ENTER, true), (KEY_ENTER, false)],
                down: (0x0D, 0x1C, false),
                chars: "\r",
            },
            KeyCase {
                name: "Esc",
                keys: &[(KEY_ESC, true), (KEY_ESC, false)],
                down: (0x1B, 0x01, false),
                chars: "\u{1b}",
            },
            KeyCase { name: "Up arrow", keys: &[(KEY_UP, true), (KEY_UP, false)], down: (0x26, 0x48, true), chars: "" },
            KeyCase {
                name: "Keypad 8",
                keys: &[(KEY_KP8, true), (KEY_KP8, false)],
                down: (0, 0x48, false),
                chars: if numlock_on { "8" } else { "" },
            },
            KeyCase {
                name: "Delete",
                keys: &[(KEY_DELETE, true), (KEY_DELETE, false)],
                down: (0x2E, 0x53, true),
                chars: "",
            },
            KeyCase {
                name: "Right Ctrl",
                keys: &[(KEY_RIGHTCTRL, true), (KEY_RIGHTCTRL, false)],
                down: (0x11, 0x1D, true),
                chars: "",
            },
            KeyCase {
                name: "Keypad Enter",
                keys: &[(KEY_KPENTER, true), (KEY_KPENTER, false)],
                down: (0x0D, 0x1C, true),
                chars: "\r",
            },
            KeyCase {
                name: "Pause (VK path)",
                keys: &[(KEY_PAUSE, true), (KEY_PAUSE, false)],
                down: (0x13, 0, false),
                chars: "",
            },
        ];
        for c in &cases {
            if unsafe { GetForegroundWindow() } != hwnd() {
                t.check("test window still focused", false, "stopping key tests");
                return Ok(());
            }
            clear_events();
            for &(k, down) in c.keys {
                inj.key(k, down)?;
            }
            let n_up = c.keys.iter().filter(|k| !k.1).count();
            wait_events(Duration::from_millis(500), |e| {
                e.iter().filter(|x| matches!(x, Ev::Key { down: false, .. })).count() >= n_up
            });
            // WM_CHAR trails the key-up when TranslateMessage runs late.
            std::thread::sleep(Duration::from_millis(30));
            let ev = EVENTS.lock().unwrap().clone();
            let first = ev.iter().find_map(|e| match *e {
                Ev::Key { down: true, vk, scan, ext } => Some((vk, scan, ext)),
                _ => None,
            });
            let chars: String = ev
                .iter()
                .filter_map(|e| match *e {
                    Ev::Char(c) => char::from_u32(c),
                    _ => None,
                })
                .collect();
            let downs = ev.iter().filter(|e| matches!(e, Ev::Key { down: true, .. })).count();
            let ups = ev.iter().filter(|e| matches!(e, Ev::Key { down: false, .. })).count();
            let key_ok = first.is_some_and(|(vk, scan, ext)| {
                (c.down.0 == 0 || vk == c.down.0) && (c.down.1 == 0 || scan == c.down.1) && ext == c.down.2
            });
            let ok = key_ok && chars == c.chars && downs == c.keys.len() - n_up && ups == n_up;
            t.check(
                &format!("key {}", c.name),
                ok,
                format!("first down {first:x?}, chars {chars:?}, {downs} down / {ups} up"),
            );
        }

        // NumLock goes through the virtual-key path; it must toggle the lock.
        let before = unsafe { GetKeyState(VK_NUMLOCK.0 as i32) } & 1;
        for round in 0..2 {
            clear_events();
            inj.key(KEY_NUMLOCK, true)?;
            inj.key(KEY_NUMLOCK, false)?;
            let ev = wait_events(Duration::from_millis(500), |e| e.len() >= 2);
            std::thread::sleep(Duration::from_millis(50));
            let state = unsafe { GetKeyState(VK_NUMLOCK.0 as i32) } & 1;
            let want = if round == 0 { before ^ 1 } else { before };
            let vk_ok = matches!(ev.first(), Some(Ev::Key { down: true, vk: 0x90, .. }));
            t.check(
                &format!("NumLock toggles (press {})", round + 1),
                vk_ok && state == want,
                format!("{ev:x?}, lock {before} -> {state}"),
            );
        }

        Ok(())
    }
}
