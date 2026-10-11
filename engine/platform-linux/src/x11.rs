//! X11 sessions (Xorg: XFCE, MATE, Cinnamon, …): MIT-SHM `GetImage` of each
//! RandR monitor, XDamage to know when to grab, XFixes for the cursor and
//! XTest for input.
//!
//! X11 has no per-monitor scaling: frame pixels are root-window pixels, so
//! input only needs the monitor's offset in the root window.

use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context};
use crossshell_platform::{Backend, Capture, CapturedFrame, Capturer, CursorShape, CursorUpdate, DisplayInfo, Injector};
use crossshell_proto::keymap;
use x11rb::connection::{Connection as _, RequestConnection as _};
use x11rb::protocol::damage::{self, ConnectionExt as _};
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::shm::{self, ConnectionExt as _};
use x11rb::protocol::xfixes::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{self, ConnectionExt as _, ImageFormat, ImageOrder, Window};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

use crate::convert;
use crate::input::{self, ScrollAccum};

/// Shortest gap between two grabs (bounds CPU while the screen changes).
const MIN_GRAB_INTERVAL: Duration = Duration::from_millis(16);
/// Poll interval when the server has no XDamage.
const POLL_INTERVAL: Duration = Duration::from_millis(33);

#[derive(Debug, Clone)]
struct Monitor {
    info: DisplayInfo,
    /// Position in the root window.
    x: i16,
    y: i16,
}

pub struct X11Backend {
    monitors: Vec<Monitor>,
}

fn connect() -> anyhow::Result<(RustConnection, Window)> {
    let (conn, screen) = x11rb::connect(None).context("connecting to the X server")?;
    let root = conn.setup().roots.get(screen).ok_or_else(|| anyhow!("X screen {screen} missing"))?.root;
    Ok((conn, root))
}

/// Root depth must be 24/32 bits stored in 32-bit little-endian pixels,
/// which is BGRX in memory — the wire format.
fn check_pixel_format(conn: &RustConnection, root: Window) -> anyhow::Result<()> {
    let setup = conn.setup();
    let depth = setup.roots.iter().find(|s| s.root == root).map(|s| s.root_depth).unwrap_or(0);
    let bpp = setup.pixmap_formats.iter().find(|f| f.depth == depth).map(|f| f.bits_per_pixel).unwrap_or(0);
    if !(depth == 24 || depth == 32) || bpp != 32 || setup.image_byte_order != ImageOrder::LSB_FIRST {
        bail!("unsupported X visual: depth {depth}, {bpp} bits per pixel, {:?}", setup.image_byte_order);
    }
    Ok(())
}

fn atom_name(conn: &RustConnection, atom: u32) -> Option<String> {
    let r = conn.get_atom_name(atom).ok()?.reply().ok()?;
    Some(String::from_utf8_lossy(&r.name).into_owned())
}

fn list_monitors(conn: &RustConnection, root: Window) -> anyhow::Result<Vec<Monitor>> {
    let screen = conn.setup().roots.iter().find(|s| s.root == root).ok_or_else(|| anyhow!("no root"))?;
    let whole = || Monitor {
        info: DisplayInfo {
            index: 0,
            name: "Screen".into(),
            x: 0,
            y: 0,
            width: screen.width_in_pixels as u32,
            height: screen.height_in_pixels as u32,
            primary: true,
        },
        x: 0,
        y: 0,
    };
    let randr_15 = conn
        .randr_query_version(1, 5)
        .ok()
        .and_then(|c| c.reply().ok())
        .is_some_and(|v| (v.major_version, v.minor_version) >= (1, 5));
    if !randr_15 {
        return Ok(vec![whole()]);
    }
    let reply = conn.randr_get_monitors(root, true)?.reply()?;
    let mut mons: Vec<_> = reply.monitors.into_iter().filter(|m| m.width > 0 && m.height > 0).collect();
    if mons.is_empty() {
        return Ok(vec![whole()]);
    }
    mons.sort_by_key(|m| (!m.primary, m.x, m.y));
    Ok(mons
        .into_iter()
        .enumerate()
        .map(|(i, m)| Monitor {
            info: DisplayInfo {
                index: i as u8,
                name: atom_name(conn, m.name).unwrap_or_else(|| format!("Monitor {}", i + 1)),
                x: m.x as i32,
                y: m.y as i32,
                width: m.width as u32,
                height: m.height as u32,
                primary: m.primary || i == 0,
            },
            x: m.x,
            y: m.y,
        })
        .collect())
}

impl X11Backend {
    pub fn start() -> anyhow::Result<Self> {
        if std::env::var_os("DISPLAY").is_none_or(|d| d.is_empty()) {
            bail!("DISPLAY is not set");
        }
        let (conn, root) = connect()?;
        check_pixel_format(&conn, root)?;
        let monitors = list_monitors(&conn, root)?;
        for m in &monitors {
            log::info!("x11: display {} {:?} {}x{} at {},{}", m.info.index, m.info.name, m.info.width, m.info.height, m.x, m.y);
        }
        Ok(X11Backend { monitors })
    }

    fn monitor(&self, display: u8) -> anyhow::Result<&Monitor> {
        self.monitors.iter().find(|m| m.info.index == display).ok_or_else(|| anyhow!("no display {display}"))
    }
}

impl Backend for X11Backend {
    fn displays(&mut self) -> anyhow::Result<Vec<DisplayInfo>> {
        Ok(self.monitors.iter().map(|m| m.info.clone()).collect())
    }

    fn capturer(&mut self, display: u8) -> anyhow::Result<Box<dyn Capturer>> {
        Ok(Box::new(X11Capturer::new(self.monitor(display)?.clone())?))
    }

    fn injector(&mut self, display: u8) -> anyhow::Result<Box<dyn Injector>> {
        let m = self.monitor(display)?;
        let (conn, root) = connect()?;
        conn.extension_information(x11rb::protocol::xtest::X11_EXTENSION_NAME)?
            .ok_or_else(|| anyhow!("the X server has no XTEST extension"))?;
        Ok(Box::new(X11Injector { conn, root, origin: (m.x, m.y), scroll: ScrollAccum::default() }))
    }
}

/// A shared-memory segment the X server writes images into.
struct ShmSeg {
    seg: shm::Seg,
    ptr: *mut u8,
    len: usize,
}

// The mapping is only touched by the capturer that owns it.
unsafe impl Send for ShmSeg {}

impl ShmSeg {
    fn new(conn: &RustConnection, len: usize) -> anyhow::Result<Self> {
        conn.extension_information(shm::X11_EXTENSION_NAME)?.ok_or_else(|| anyhow!("no MIT-SHM"))?;
        // SAFETY: plain libc calls; the fd is owned right after creation.
        let fd = unsafe {
            let fd = libc::memfd_create(c"crossshell-x11".as_ptr(), libc::MFD_CLOEXEC);
            if fd < 0 {
                bail!("memfd_create: {}", std::io::Error::last_os_error());
            }
            OwnedFd::from_raw_fd(fd)
        };
        if unsafe { libc::ftruncate(fd.as_raw_fd(), len as libc::off_t) } != 0 {
            bail!("ftruncate: {}", std::io::Error::last_os_error());
        }
        let ptr = unsafe {
            libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd.as_raw_fd(), 0)
        };
        if ptr == libc::MAP_FAILED {
            bail!("mmap: {}", std::io::Error::last_os_error());
        }
        let seg = ShmSeg { seg: conn.generate_id()?, ptr: ptr as *mut u8, len };
        // A remote X server cannot map our memory; this fails there.
        conn.shm_attach_fd(seg.seg, fd, false)?.check().context("MIT-SHM AttachFd")?;
        Ok(seg)
    }

    fn data(&self) -> &[u8] {
        // SAFETY: mapped for `len` bytes for the life of `self`.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Drop for ShmSeg {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.ptr as *mut libc::c_void, self.len) };
    }
}

struct X11Capturer {
    conn: RustConnection,
    root: Window,
    mon: Monitor,
    shm: Option<ShmSeg>,
    damage: Option<damage::Damage>,
    /// Last frame handed out (packed BGRX) and the grab buffer.
    frame: Vec<u8>,
    scratch: Vec<u8>,
    have_frame: bool,
    /// Damage reported since the last grab.
    dirty: bool,
    next_grab: Instant,
    xfixes: bool,
    shape_dirty: bool,
    last_pos: Option<(i32, i32)>,
}

impl X11Capturer {
    fn new(mon: Monitor) -> anyhow::Result<Self> {
        let (conn, root) = connect()?;
        let len = mon.info.width as usize * mon.info.height as usize * 4;
        let shm = match ShmSeg::new(&conn, len) {
            Ok(s) => Some(s),
            Err(e) => {
                log::info!("x11: MIT-SHM unavailable ({e:#}); using plain GetImage");
                None
            }
        };
        let damage = match conn.extension_information(damage::X11_EXTENSION_NAME)? {
            Some(_) => {
                conn.damage_query_version(1, 1)?.reply()?;
                let id = conn.generate_id()?;
                conn.damage_create(id, root, damage::ReportLevel::NON_EMPTY)?.check()?;
                Some(id)
            }
            None => {
                log::info!("x11: no XDamage; polling every {POLL_INTERVAL:?}");
                None
            }
        };
        let xfixes = conn.extension_information(xfixes::X11_EXTENSION_NAME)?.is_some()
            && conn.xfixes_query_version(4, 0)?.reply().is_ok()
            && conn.xfixes_select_cursor_input(root, xfixes::CursorNotifyMask::DISPLAY_CURSOR)?.check().is_ok();
        conn.flush()?;
        log::info!(
            "x11: capturing {}x{} at {},{} (shm: {}, damage: {}, xfixes: {xfixes})",
            mon.info.width,
            mon.info.height,
            mon.x,
            mon.y,
            shm.is_some(),
            damage.is_some()
        );
        Ok(X11Capturer {
            conn,
            root,
            mon,
            shm,
            damage,
            frame: Vec::new(),
            scratch: Vec::new(),
            have_frame: false,
            dirty: true,
            next_grab: Instant::now(),
            xfixes,
            shape_dirty: true,
            last_pos: None,
        })
    }

    /// Handle queued events without blocking.
    fn pump(&mut self) -> anyhow::Result<()> {
        while let Some(ev) = self.conn.poll_for_event()? {
            match ev {
                Event::DamageNotify(_) => self.dirty = true,
                Event::XfixesCursorNotify(_) => self.shape_dirty = true,
                Event::Error(e) => log::debug!("x11: {e:?}"),
                _ => {}
            }
        }
        Ok(())
    }

    /// Block until the X connection is readable or `timeout` passes.
    fn wait(&self, timeout: Duration) {
        let mut pfd = libc::pollfd { fd: self.conn.stream().as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let ms = timeout.as_millis().clamp(1, i32::MAX as u128) as i32;
        unsafe { libc::poll(&mut pfd, 1, ms) };
    }

    /// Grab the monitor into `scratch`; true if it differs from `frame`.
    fn grab(&mut self) -> anyhow::Result<bool> {
        let (w, h) = (self.mon.info.width as u16, self.mon.info.height as u16);
        let row = w as usize * 4;
        if let Some(seg) = &self.shm {
            let r = self
                .conn
                .shm_get_image(self.root, self.mon.x, self.mon.y, w, h, !0, ImageFormat::Z_PIXMAP.into(), seg.seg, 0)?
                .reply();
            match r {
                Ok(_) => {
                    self.scratch.clear();
                    self.scratch.extend_from_slice(&seg.data()[..row * h as usize]);
                }
                Err(e) => {
                    log::warn!("x11: SHM GetImage failed ({e}); falling back to GetImage");
                    self.shm = None;
                }
            }
        }
        if self.shm.is_none() {
            let r = self.conn.get_image(ImageFormat::Z_PIXMAP, self.root, self.mon.x, self.mon.y, w, h, !0)?.reply()?;
            if r.data.len() < row * h as usize {
                bail!("short GetImage reply ({} bytes)", r.data.len());
            }
            self.scratch.clear();
            self.scratch.extend_from_slice(&r.data[..row * h as usize]);
        }
        if self.have_frame && self.scratch == self.frame {
            return Ok(false);
        }
        std::mem::swap(&mut self.scratch, &mut self.frame);
        self.have_frame = true;
        Ok(true)
    }

    /// Wait up to `timeout` for a changed frame.
    fn wait_for_change(&mut self, timeout: Duration) -> anyhow::Result<bool> {
        let deadline = Instant::now() + timeout;
        loop {
            self.pump()?;
            let now = Instant::now();
            let wanted = !self.have_frame || self.dirty || self.damage.is_none();
            if wanted && now >= self.next_grab {
                // Clear the damage first so changes during the grab re-arm it.
                if let Some(d) = self.damage {
                    self.conn.damage_subtract(d, x11rb::NONE, x11rb::NONE)?;
                }
                self.dirty = false;
                self.next_grab = now + if self.damage.is_some() { MIN_GRAB_INTERVAL } else { POLL_INTERVAL };
                if self.grab()? {
                    return Ok(true);
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(false);
            }
            let wake = if self.dirty || self.damage.is_none() { self.next_grab.min(deadline) } else { deadline };
            self.wait(wake.saturating_duration_since(now));
        }
    }
}

impl Drop for X11Capturer {
    fn drop(&mut self) {
        if let Some(d) = self.damage {
            let _ = self.conn.damage_destroy(d);
        }
        if let Some(seg) = &self.shm {
            let _ = self.conn.shm_detach(seg.seg);
        }
        let _ = self.conn.flush();
    }
}

impl Capturer for X11Capturer {
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Capture<'_>> {
        if !self.wait_for_change(timeout)? {
            return Ok(Capture::Unchanged);
        }
        Ok(Capture::Frame(CapturedFrame {
            width: self.mon.info.width,
            height: self.mon.info.height,
            stride: self.mon.info.width as usize * 4,
            data: &self.frame,
        }))
    }

    fn cursor(&mut self) -> Option<CursorUpdate> {
        let mut u = CursorUpdate::default();
        if self.xfixes && self.shape_dirty {
            self.shape_dirty = false;
            match self.conn.xfixes_get_cursor_image().ok().and_then(|c| c.reply().ok()) {
                Some(img) if img.width > 0 && img.height > 0 => {
                    u.shape = Some(Some(CursorShape {
                        width: img.width,
                        height: img.height,
                        hot_x: img.xhot.min(img.width - 1),
                        hot_y: img.yhot.min(img.height - 1),
                        rgba: convert::argb32_to_rgba(&img.cursor_image),
                    }));
                }
                Some(_) => u.shape = Some(None),
                None => {}
            }
        }
        if let Some(p) = self.conn.query_pointer(self.root).ok().and_then(|c| c.reply().ok()) {
            let pos = (p.root_x as i32 - self.mon.x as i32, p.root_y as i32 - self.mon.y as i32);
            if self.last_pos != Some(pos) {
                self.last_pos = Some(pos);
                u.position = Some(pos);
            }
        }
        (u != CursorUpdate::default()).then_some(u)
    }
}

struct X11Injector {
    conn: RustConnection,
    root: Window,
    origin: (i16, i16),
    scroll: ScrollAccum,
}

impl X11Injector {
    fn fake(&self, kind: u8, detail: u8, x: i16, y: i16) -> anyhow::Result<()> {
        let root = if kind == xproto::MOTION_NOTIFY_EVENT { self.root } else { x11rb::NONE };
        self.conn.xtest_fake_input(kind, detail, x11rb::CURRENT_TIME, root, x, y, 0)?;
        Ok(())
    }

    fn flush(&self) -> anyhow::Result<()> {
        self.conn.flush()?;
        // Errors for unchecked requests queue up as events; drain them.
        while let Some(ev) = self.conn.poll_for_event()? {
            if let Event::Error(e) = ev {
                log::debug!("x11 input: {e:?}");
            }
        }
        Ok(())
    }
}

impl Injector for X11Injector {
    fn pointer_move(&mut self, x: i32, y: i32) -> anyhow::Result<()> {
        let rx = (self.origin.0 as i32 + x).clamp(i16::MIN as i32, i16::MAX as i32) as i16;
        let ry = (self.origin.1 as i32 + y).clamp(i16::MIN as i32, i16::MAX as i32) as i16;
        self.fake(xproto::MOTION_NOTIFY_EVENT, 0, rx, ry)?;
        self.flush()
    }

    fn pointer_button(&mut self, b: u8, down: bool) -> anyhow::Result<()> {
        let Some(b) = input::x11_button(b) else { return Ok(()) };
        self.fake(if down { xproto::BUTTON_PRESS_EVENT } else { xproto::BUTTON_RELEASE_EVENT }, b, 0, 0)?;
        self.flush()
    }

    fn scroll(&mut self, dx: i16, dy: i16) -> anyhow::Result<()> {
        let (nx, ny) = self.scroll.add(dx, dy);
        for b in input::x11_scroll_buttons(nx, ny) {
            self.fake(xproto::BUTTON_PRESS_EVENT, b, 0, 0)?;
            self.fake(xproto::BUTTON_RELEASE_EVENT, b, 0, 0)?;
        }
        self.flush()
    }

    fn key(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
        let Some(kc) = keymap::evdev_to_x11(code) else { return Ok(()) };
        self.fake(if down { xproto::KEY_PRESS_EVENT } else { xproto::KEY_RELEASE_EVENT }, kc, 0, 0)?;
        self.flush()
    }
}
