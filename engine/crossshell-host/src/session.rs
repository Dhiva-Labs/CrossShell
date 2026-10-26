//! One viewer session: handshake, capture → encode → send with ack-based
//! flow control, and input/clipboard from the viewer.
//!
//! Threads per session:
//! - **reader** (the caller's thread): viewer messages → injector, acks.
//! - **capture**: grabs frames into `latest`, encodes when the in-flight
//!   window allows, sends cursor updates.
//! - **writer**: the only thread that writes to the socket.
//! - **clipboard**: polls the host clipboard.

use std::collections::HashSet;
use std::net::{Shutdown, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context};
use crossshell_platform::{Backend, Capture, Capturer, DisplayInfo, Injector};
use crossshell_proto::msg::level;
use crossshell_proto::{
    token_eq, Encoder, FrameRef, LosslessCodec, Message, MessageReader, Quality, HOST_CAPS, MAX_INFLIGHT_FRAMES,
    MAX_PREAUTH_PAYLOAD, TOKEN_LEN, VERSION,
};

use crate::clipboard::ClipboardSync;
use crate::runtime::{self, SessionStatus};
use crate::BackendKind;

/// Time allowed for Hello and Start.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// A session with no viewer traffic for this long is dead (viewers ping every 2 s).
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(15);
/// How often the reader wakes to check whether the session should end.
const READER_TICK: Duration = Duration::from_millis(250);
/// Largest viewer→host message after the handshake (clipboard ≤ 1 MiB).
const MAX_VIEWER_PAYLOAD: u32 = 2 << 20;
/// How long a frame waits for more changes before refinement kicks in.
const REFINE_DELAY: Duration = Duration::from_millis(250);
/// Capture poll interval (also bounds ack → next-frame latency).
const CAPTURE_POLL: Duration = Duration::from_millis(16);

pub struct SessionOptions {
    pub token: [u8; TOKEN_LEN],
    pub backend: BackendKind,
    /// Where to write `status.json` while a viewer is connected.
    pub runtime_dir: Option<PathBuf>,
    pub clipboard: bool,
}

/// The one active session. A newly authenticated viewer takes over from the
/// current one (the usual case is the same person reconnecting, or a
/// session whose viewer vanished and hasn't timed out yet).
pub struct SessionSlot {
    active: Mutex<Option<Active>>,
    freed: Condvar,
    next_id: AtomicU64,
    viewers: Mutex<Viewers>,
}

/// Authenticated connections, for `--exit-when-idle`.
struct Viewers {
    connected: u32,
    /// When `connected` last dropped to 0 (or the slot was created).
    idle_since: Instant,
}

impl Default for SessionSlot {
    fn default() -> Self {
        SessionSlot {
            active: Mutex::default(),
            freed: Condvar::new(),
            next_id: AtomicU64::new(0),
            viewers: Mutex::new(Viewers { connected: 0, idle_since: Instant::now() }),
        }
    }
}

struct Active {
    id: u64,
    stop: Arc<AtomicBool>,
    stream: TcpStream,
}

/// How long a new viewer waits for the previous session to wind down.
const TAKEOVER_WAIT: Duration = Duration::from_secs(3);

impl SessionSlot {
    /// `None` while an authenticated viewer is connected; otherwise how long
    /// there has been none (since the slot was created, or since the last
    /// authenticated viewer disconnected). Failed logins do not count.
    pub fn idle_for(&self) -> Option<Duration> {
        let v = self.viewers.lock().unwrap();
        (v.connected == 0).then(|| v.idle_since.elapsed())
    }

    fn viewer_authenticated(&self) -> ViewerGuard<'_> {
        self.viewers.lock().unwrap().connected += 1;
        ViewerGuard(self)
    }

    fn claim(&self, stream: &TcpStream, stop: &Arc<AtomicBool>) -> Option<SlotGuard<'_>> {
        let mut g = self.active.lock().unwrap();
        if let Some(old) = g.as_ref() {
            log::info!("new viewer takes over the current session");
            old.stop.store(true, Ordering::SeqCst);
            let _ = old.stream.shutdown(Shutdown::Both);
            let (ng, timeout) = self.freed.wait_timeout_while(g, TAKEOVER_WAIT, |a| a.is_some()).unwrap();
            g = ng;
            if timeout.timed_out() {
                return None;
            }
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        *g = Some(Active { id, stop: stop.clone(), stream: stream.try_clone().ok()? });
        Some(SlotGuard { slot: self, id })
    }
}

struct SlotGuard<'a> {
    slot: &'a SessionSlot,
    id: u64,
}

impl Drop for SlotGuard<'_> {
    fn drop(&mut self) {
        let mut g = self.slot.active.lock().unwrap();
        if g.as_ref().is_some_and(|a| a.id == self.id) {
            *g = None;
        }
        self.slot.freed.notify_all();
    }
}

/// Counts one authenticated connection until it ends.
struct ViewerGuard<'a>(&'a SessionSlot);

impl Drop for ViewerGuard<'_> {
    fn drop(&mut self) {
        let mut v = self.0.viewers.lock().unwrap();
        v.connected -= 1;
        if v.connected == 0 {
            v.idle_since = Instant::now();
        }
    }
}

/// Removes status.json when the session ends.
struct StatusGuard(Option<PathBuf>);

impl Drop for StatusGuard {
    fn drop(&mut self) {
        if let Some(p) = &self.0 {
            let _ = std::fs::remove_file(p);
        }
    }
}

fn reject(stream: &mut TcpStream, reason: &str) {
    log::warn!("rejecting viewer: {reason}");
    let _ = Message::Reject { reason: reason.to_owned() }.write_to(stream);
    let _ = stream.shutdown(Shutdown::Both);
}

fn sanitize_name(s: &str) -> String {
    let s: String = s.chars().filter(|c| !c.is_control()).take(64).collect();
    if s.trim().is_empty() { "viewer".into() } else { s }
}

#[derive(Default)]
struct Flow {
    sent: u32,
    acked: u32,
    /// Pending SelectDisplay from the viewer: (display, quality, max_fps).
    select: Option<(u8, u8, u8)>,
}

impl Flow {
    fn inflight(&self) -> u32 {
        self.sent.wrapping_sub(self.acked)
    }

    fn ack(&mut self, seq: u32) {
        // Only accept acks for frames actually sent.
        if seq.wrapping_sub(self.acked) <= self.inflight() {
            self.acked = seq;
        }
    }
}

/// Serve one viewer connection to completion.
pub fn serve_connection(mut stream: TcpStream, opts: &SessionOptions, slot: &SessionSlot) -> anyhow::Result<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;

    // --- Hello: authenticate before anything else.
    let hello = Message::read_from(&mut stream, MAX_PREAUTH_PAYLOAD).context("reading hello")?;
    let Message::Hello { version, token, viewer_name, caps } = hello else {
        reject(&mut stream, "expected hello");
        bail!("first message was not hello");
    };
    if !token_eq(&token, &opts.token) {
        reject(&mut stream, "bad token");
        bail!("bad token");
    }
    if version != VERSION {
        reject(&mut stream, &format!("protocol version {version} not supported (host speaks {VERSION})"));
        bail!("version mismatch");
    }
    let _authenticated = slot.viewer_authenticated();
    let stop = Arc::new(AtomicBool::new(false));
    let Some(_slot) = slot.claim(&stream, &stop) else {
        reject(&mut stream, "busy: the previous session is still closing, try again");
        return Ok(());
    };
    let viewer = sanitize_name(&viewer_name);
    // Capabilities both ends have; unknown bits are ignored.
    let caps = caps & HOST_CAPS;
    let codec = LosslessCodec::for_caps(caps);
    log::info!("viewer {viewer:?} authenticated (caps {caps:#x}, lossless tiles: {codec:?})");

    // --- Backend + Welcome. On Wayland this may wait for the consent dialog.
    let mut backend = match crate::start_backend(opts.backend) {
        Ok(b) => b,
        Err(e) => {
            reject(&mut stream, &format!("screen capture unavailable: {e:#}"));
            return Err(e);
        }
    };
    let displays = match backend.displays() {
        Ok(d) if !d.is_empty() => d,
        Ok(_) => {
            reject(&mut stream, "no displays to share");
            bail!("no displays");
        }
        Err(e) => {
            reject(&mut stream, &format!("cannot list displays: {e:#}"));
            return Err(e);
        }
    };
    Message::Welcome { version: VERSION, caps, displays: displays.clone() }.write_to(&mut stream)?;

    // --- Start.
    let start = Message::read_from(&mut stream, MAX_PREAUTH_PAYLOAD).context("reading start")?;
    let Message::Start { display, quality, max_fps, view_only } = start else {
        reject(&mut stream, "expected start");
        bail!("expected start");
    };
    let mut current = find_display(&displays, display)?;
    log::info!(
        "session start: display {} ({}x{}), quality {quality}, {max_fps} fps, view_only={view_only}",
        current.index,
        current.width,
        current.height
    );

    let status_path = opts.runtime_dir.as_ref().map(|d| runtime::status_json_path(d));
    if let Some(p) = &status_path {
        let since = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let st = SessionStatus { pid: std::process::id(), viewer: viewer.clone(), since, view_only };
        let _ = runtime::write_private(p, serde_json::to_string(&st)?.as_bytes());
    }
    let _status = StatusGuard(status_path);

    let capturer = backend.capturer(current.index)?;
    let mut injector = if view_only { None } else { Some(backend.injector(current.index)?) };
    let backend = Arc::new(Mutex::new(backend));

    // --- Threads.
    let flow = Arc::new(Mutex::new(Flow::default()));
    let (tx, rx) = mpsc::sync_channel::<Message>(64);

    let writer = {
        let mut wr = stream.try_clone()?;
        let stop = stop.clone();
        std::thread::Builder::new().name("cs-writer".into()).spawn(move || {
            for m in rx {
                if let Err(e) = m.write_to(&mut wr) {
                    log::info!("write failed, ending session: {e}");
                    break;
                }
            }
            stop.store(true, Ordering::SeqCst);
            let _ = wr.shutdown(Shutdown::Both);
        })?
    };

    let capture = {
        let ctx = CaptureCtx {
            stop: stop.clone(),
            flow: flow.clone(),
            tx: tx.clone(),
            backend: backend.clone(),
        };
        let q = Quality::from_u8(quality);
        std::thread::Builder::new()
            .name("cs-capture".into())
            .spawn(move || capture_loop(ctx, capturer, q, codec, max_fps))?
    };

    let clipboard = opts.clipboard.then(|| Arc::new(ClipboardSync::new()));
    let clip_thread = clipboard.clone().map(|clip| {
        let stop = stop.clone();
        let tx = tx.clone();
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                std::thread::sleep(ClipboardSync::POLL_INTERVAL);
                if let Some(text) = clip.poll() {
                    if tx.send(Message::ClipboardText(text)).is_err() {
                        break;
                    }
                }
            }
        })
    });

    // --- Reader loop. Short read timeouts let it notice `stop` (another
    // viewer took over, capture died) promptly on every OS.
    stream.set_read_timeout(Some(READER_TICK))?;
    let mut reader = MessageReader::new(MAX_VIEWER_PAYLOAD);
    let mut last_rx = Instant::now();
    let mut input = InputState::new(&current);
    let result = (|| -> anyhow::Result<()> {
        while !stop.load(Ordering::SeqCst) {
            let m = match reader.read(&mut stream) {
                Ok(Some(m)) => m,
                Ok(None) => {
                    if last_rx.elapsed() > IDLE_TIMEOUT {
                        bail!("viewer idle for {IDLE_TIMEOUT:?}");
                    }
                    continue;
                }
                Err(crossshell_proto::Error::Io(e))
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::UnexpectedEof
                            | std::io::ErrorKind::ConnectionReset
                            | std::io::ErrorKind::ConnectionAborted
                    ) =>
                {
                    log::info!("viewer disconnected");
                    return Ok(());
                }
                Err(e) if stop.load(Ordering::SeqCst) => {
                    log::debug!("reader ending after stop: {e}");
                    return Ok(());
                }
                Err(e) => return Err(e.into()),
            };
            last_rx = Instant::now();
            match m {
                Message::FrameAck { seq } => flow.lock().unwrap().ack(seq),
                Message::Ping(n) => {
                    let _ = tx.send(Message::Pong(n));
                }
                Message::Pong(_) => {}
                Message::ClipboardText(t) => {
                    if let Some(c) = &clipboard {
                        c.set(t);
                    }
                }
                Message::SelectDisplay { display, quality, max_fps } => {
                    current = find_display(&displays, display)?;
                    if let Some(inj) = injector.as_mut() {
                        input.release_all(inj.as_mut());
                    }
                    if !view_only {
                        injector = Some(backend.lock().unwrap().injector(current.index)?);
                    }
                    input = InputState::new(&current);
                    flow.lock().unwrap().select = Some((display, quality, max_fps));
                }
                Message::PointerMove { .. }
                | Message::PointerButton { .. }
                | Message::Scroll { .. }
                | Message::Key { .. }
                | Message::ReleaseAll => {
                    if let Some(inj) = injector.as_mut() {
                        if let Err(e) = input.apply(inj.as_mut(), &m) {
                            log::warn!("input injection failed: {e:#}");
                        }
                    }
                }
                other => bail!("unexpected message from viewer: {:#04x}", other.kind()),
            }
        }
        Ok(())
    })();

    // --- Teardown.
    stop.store(true, Ordering::SeqCst);
    if let Some(inj) = injector.as_mut() {
        input.release_all(inj.as_mut());
    }
    let _ = stream.shutdown(Shutdown::Both);
    drop(tx);
    let _ = capture.join();
    if let Some(t) = clip_thread {
        let _ = t.join();
    }
    let _ = writer.join();
    log::info!("session with {viewer:?} ended");
    result
}

fn find_display(displays: &[DisplayInfo], index: u8) -> anyhow::Result<DisplayInfo> {
    displays.iter().find(|d| d.index == index).cloned().ok_or_else(|| anyhow!("no display {index}"))
}

struct CaptureCtx {
    stop: Arc<AtomicBool>,
    flow: Arc<Mutex<Flow>>,
    tx: SyncSender<Message>,
    backend: Arc<Mutex<Box<dyn Backend>>>,
}

/// Minimum gap between frames. A few ms of slack so a 30 fps cap on a 60 Hz
/// source sends every second frame instead of every third.
fn frame_interval(max_fps: u8) -> Duration {
    (Duration::from_secs(1) / u32::from(max_fps.clamp(1, 120))).saturating_sub(Duration::from_millis(4))
}

fn capture_loop(ctx: CaptureCtx, capturer: Box<dyn Capturer>, quality: Quality, codec: LosslessCodec, max_fps: u8) {
    if let Err(e) = capture_loop_inner(&ctx, capturer, quality, codec, max_fps) {
        if !ctx.stop.load(Ordering::SeqCst) {
            log::error!("capture failed: {e:#}");
            let _ = ctx.tx.send(Message::Notice { level: level::ERROR, text: format!("capture failed: {e:#}") });
        }
    }
    // The reader notices on the viewer's next ping (every 2 s) and tears
    // the session down; the viewer also closes after an error notice.
    ctx.stop.store(true, Ordering::SeqCst);
}

fn capture_loop_inner(
    ctx: &CaptureCtx,
    mut capturer: Box<dyn Capturer>,
    quality: Quality,
    codec: LosslessCodec,
    max_fps: u8,
) -> anyhow::Result<()> {
    let mut encoder = Encoder::new(quality).with_lossless_codec(codec);
    let mut interval = frame_interval(max_fps);
    // Latest captured frame, tightly packed BGRX.
    let mut latest: Vec<u8> = Vec::new();
    let (mut lw, mut lh) = (0u32, 0u32);
    let mut dirty = false;
    let mut last_change = Instant::now();
    let mut last_sent: Option<Instant> = None;
    let mut seq = 0u32;
    let mut unavailable: Option<String> = None;

    while !ctx.stop.load(Ordering::SeqCst) {
        // Display / quality switch requested by the viewer.
        let select = ctx.flow.lock().unwrap().select.take();
        if let Some((display, q, fps)) = select {
            capturer = ctx.backend.lock().unwrap().capturer(display)?;
            encoder = Encoder::new(Quality::from_u8(q)).with_lossless_codec(codec);
            interval = frame_interval(fps);
            latest.clear();
            dirty = false;
        }

        match capturer.next_frame(CAPTURE_POLL)? {
            Capture::Frame(f) => {
                let row = f.width as usize * 4;
                anyhow::ensure!(f.stride >= row && f.data.len() >= f.stride * (f.height as usize - 1) + row, "backend returned a short frame");
                if (f.width, f.height) != (lw, lh) {
                    lw = f.width;
                    lh = f.height;
                    latest = vec![0; row * f.height as usize];
                }
                for y in 0..f.height as usize {
                    latest[y * row..(y + 1) * row].copy_from_slice(&f.data[y * f.stride..y * f.stride + row]);
                }
                dirty = true;
                last_change = Instant::now();
                if unavailable.take().is_some() {
                    send(ctx, Message::Notice { level: level::INFO, text: String::new() })?;
                }
            }
            Capture::Unchanged => {}
            Capture::Unavailable(reason) => {
                if unavailable.as_deref() != Some(reason.as_str()) {
                    log::info!("capture unavailable: {reason}");
                    send(ctx, Message::Notice { level: level::WARN, text: reason.clone() })?;
                    unavailable = Some(reason);
                }
                std::thread::sleep(Duration::from_millis(500));
                continue;
            }
        }

        if let Some(cu) = capturer.cursor() {
            if let Some(shape) = cu.shape {
                let m = match shape {
                    Some(s) => Message::CursorShape {
                        width: s.width,
                        height: s.height,
                        hot_x: s.hot_x,
                        hot_y: s.hot_y,
                        rgba: s.rgba,
                    },
                    None => Message::CursorShape { width: 0, height: 0, hot_x: 0, hot_y: 0, rgba: Vec::new() },
                };
                send(ctx, m)?;
            }
            if let Some((x, y)) = cu.position {
                send(ctx, Message::CursorPos { x, y })?;
            }
        }

        if latest.is_empty() {
            continue;
        }
        let now = Instant::now();
        let due = last_sent.is_none_or(|t| now.duration_since(t) >= interval);
        let window_open = ctx.flow.lock().unwrap().inflight() < MAX_INFLIGHT_FRAMES;
        let refine = !dirty && encoder.needs_refinement() && now.duration_since(last_change) >= REFINE_DELAY;
        if (dirty || refine) && due && window_open {
            let frame = FrameRef::new(lw, lh, lw as usize * 4, &latest)?;
            let rects = encoder.encode(&frame);
            dirty = false;
            if !rects.is_empty() {
                seq = seq.wrapping_add(1);
                ctx.flow.lock().unwrap().sent = seq;
                send(ctx, Message::Frame { seq, width: lw, height: lh, rects })?;
                last_sent = Some(now);
            }
        }
    }
    Ok(())
}

fn send(ctx: &CaptureCtx, m: Message) -> anyhow::Result<()> {
    ctx.tx.send(m).map_err(|_| anyhow!("writer gone"))
}

/// Tracks what the viewer holds down so it can always be released, and
/// clamps pointer coordinates to the display.
struct InputState {
    keys: HashSet<u16>,
    buttons: HashSet<u8>,
    width: u32,
    height: u32,
}

impl InputState {
    fn new(d: &DisplayInfo) -> Self {
        InputState { keys: HashSet::new(), buttons: HashSet::new(), width: d.width, height: d.height }
    }

    fn apply(&mut self, inj: &mut dyn Injector, m: &Message) -> anyhow::Result<()> {
        match *m {
            Message::PointerMove { x, y } => {
                let x = x.clamp(0, self.width.saturating_sub(1) as i32);
                let y = y.clamp(0, self.height.saturating_sub(1) as i32);
                inj.pointer_move(x, y)
            }
            Message::PointerButton { button, down } => {
                if !(1..=5).contains(&button) {
                    return Ok(());
                }
                if down {
                    self.buttons.insert(button);
                } else if !self.buttons.remove(&button) {
                    return Ok(()); // release of a button we never pressed
                }
                inj.pointer_button(button, down)
            }
            Message::Scroll { dx, dy } => inj.scroll(dx, dy),
            Message::Key { code, down } => {
                if down {
                    self.keys.insert(code);
                } else if !self.keys.remove(&code) {
                    return Ok(());
                }
                inj.key(code, down)
            }
            Message::ReleaseAll => {
                self.release_all(inj);
                Ok(())
            }
            _ => Ok(()),
        }
    }

    fn release_all(&mut self, inj: &mut dyn Injector) {
        for k in self.keys.drain() {
            let _ = inj.key(k, false);
        }
        for b in self.buttons.drain() {
            let _ = inj.pointer_button(b, false);
        }
    }
}
