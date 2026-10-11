//! Network side of the viewer: handshake, a reader that decodes and acks
//! frames, and a writer that owns all socket writes. The UI thread only ever
//! touches channels and a mutex-guarded framebuffer, never the socket.
//!
//! Threads per session:
//! - **net** (spawned by [`spawn`]): connects, handshakes, then reads.
//! - **writer**: drains the outgoing queue (coalescing pointer moves) and
//!   pings every 2 s.

use std::io::ErrorKind;
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context};
use crossshell_proto::msg::level;
use crossshell_proto::{Decoder, DisplayInfo, Message, Rect, MAX_PAYLOAD, TOKEN_LEN, VERSION};

/// Pings keep the host's idle timer (15 s) fed and measure round trips.
pub const PING_EVERY: Duration = Duration::from_secs(2);
/// No traffic from the host for this long (it answers every ping) = dead.
pub const DEAD_AFTER: Duration = Duration::from_secs(15);

/// Waiting-for-Welcome timing: after `notice_after` the UI is told the remote
/// side may be showing a consent dialog; after `max_wait` we give up.
#[derive(Debug, Clone, Copy)]
pub struct Timing {
    pub notice_after: Duration,
    pub max_wait: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Timing { notice_after: Duration::from_secs(3), max_wait: Duration::from_secs(120) }
    }
}

/// Latest decoded frame, shared with the UI thread. The reader keeps this up
/// to date by copying just the rects each frame touched.
#[derive(Default)]
pub struct FrameBuf {
    pub width: u32,
    pub height: u32,
    /// `0x00RRGGBB`, row-major, `width * height` entries.
    pub pixels: Vec<u32>,
    /// Bumped whenever the frame size changes.
    pub generation: u64,
}

impl FrameBuf {
    /// Bring this copy in line with `dec` after it applied a frame made of `rects`.
    pub fn update(&mut self, dec: &Decoder, rects: &[Rect]) {
        let (w, h) = (dec.width(), dec.height());
        let src = dec.pixels();
        if self.width != w || self.height != h || self.pixels.len() != src.len() {
            self.width = w;
            self.height = h;
            self.pixels.clear();
            self.pixels.extend_from_slice(src);
            self.generation += 1;
            return;
        }
        for r in rects {
            let (x, w) = (r.x as usize, r.w as usize);
            for row in r.y as usize..(r.y as usize + r.h as usize) {
                let o = row * self.width as usize + x;
                self.pixels[o..o + w].copy_from_slice(&src[o..o + w]);
            }
        }
    }
}

#[derive(Default)]
pub struct Shared {
    pub frame: Mutex<FrameBuf>,
    /// Set when the user asked to close: the reader then reports `Local`.
    pub closing: AtomicBool,
}

/// What the UI hands the writer thread.
pub enum Out {
    Msg(Message),
    /// Flush what is queued, then close the connection.
    Close,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloseReason {
    /// The user closed the session.
    Local,
    /// The remote side closed the connection cleanly.
    Peer,
    Error(String),
}

impl CloseReason {
    pub fn text(&self) -> String {
        match self {
            CloseReason::Local => "closed by user".into(),
            CloseReason::Peer => "the remote side closed the connection".into(),
            CloseReason::Error(e) => e.clone(),
        }
    }
}

#[derive(Debug)]
pub enum NetEvent {
    /// No Welcome yet; the remote side may be showing a consent dialog.
    Waiting(String),
    /// Handshake done and Start sent; `display` is the one actually started.
    Connected {
        displays: Vec<DisplayInfo>,
        display: u8,
    },
    /// A frame was decoded into [`Shared::frame`].
    Frame {
        width: u32,
        height: u32,
        bytes: usize,
    },
    CursorShape {
        width: u16,
        height: u16,
        hot_x: u16,
        hot_y: u16,
        rgba: Vec<u8>,
    },
    CursorPos {
        x: i32,
        y: i32,
    },
    Displays(Vec<DisplayInfo>),
    Notice {
        level: u8,
        text: String,
    },
    Clipboard(String),
    Rtt(Duration),
    Closed(CloseReason),
}

pub type Notify = Arc<dyn Fn(NetEvent) + Send + Sync>;

#[derive(Debug, Clone)]
pub struct ConnectOpts {
    pub port: u16,
    pub token: [u8; TOKEN_LEN],
    pub viewer_name: String,
    pub display: u8,
    pub quality: u8,
    pub fps: u8,
    pub view_only: bool,
    pub timing: Timing,
}

pub struct Session {
    pub tx: Sender<Out>,
    pub shared: Arc<Shared>,
    handle: Option<JoinHandle<()>>,
}

impl Session {
    pub fn send(&self, m: Message) {
        let _ = self.tx.send(Out::Msg(m));
    }

    /// Ask the connection to wind down and give it a moment to flush
    /// (a final `ReleaseAll` should reach the host).
    pub fn close(&mut self) {
        self.shared.closing.store(true, Ordering::SeqCst);
        let _ = self.tx.send(Out::Close);
        if let Some(h) = &self.handle {
            let until = Instant::now() + Duration::from_millis(400);
            while !h.is_finished() && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
}

/// Start the network thread. `tx`/`rx` are the two ends of the outgoing
/// queue, created by the caller so other threads (clipboard) can hold a
/// sender before the connection exists.
pub fn spawn(
    opts: ConnectOpts,
    shared: Arc<Shared>,
    notify: Notify,
    tx: Sender<Out>,
    rx: Receiver<Out>,
) -> std::io::Result<Session> {
    let handle = {
        let shared = shared.clone();
        let tx = tx.clone();
        std::thread::Builder::new().name("cs-net".into()).spawn(move || {
            let reason = match run(&opts, &shared, &notify, tx, rx) {
                Ok(r) => r,
                Err(e) => {
                    if shared.closing.load(Ordering::SeqCst) {
                        CloseReason::Local
                    } else {
                        CloseReason::Error(format!("{e:#}"))
                    }
                }
            };
            notify(NetEvent::Closed(reason));
        })?
    };
    Ok(Session { tx, shared, handle: Some(handle) })
}

fn run(
    opts: &ConnectOpts,
    shared: &Arc<Shared>,
    notify: &Notify,
    tx: Sender<Out>,
    rx: Receiver<Out>,
) -> anyhow::Result<CloseReason> {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, opts.port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(10)).map_err(|e| match e.kind() {
        ErrorKind::ConnectionRefused => anyhow!("connection refused on {addr} (is the SSH forward up?)"),
        _ => anyhow!("cannot connect to {addr}: {e}"),
    })?;
    let _ = stream.set_nodelay(true);

    let (displays, display) =
        handshake(&mut stream, opts, &shared.closing, &mut |msg| notify(NetEvent::Waiting(msg.into())))?;
    notify(NetEvent::Connected { displays, display });

    let t0 = Instant::now();
    let writer = {
        let wr = stream.try_clone().context("cloning the socket")?;
        std::thread::Builder::new().name("cs-writer".into()).spawn(move || writer_loop(wr, rx, t0))?
    };
    let reason = read_loop(&mut stream, shared, notify, &tx, t0);
    // Unblock and end the writer whichever side ended first.
    let _ = tx.send(Out::Close);
    let _ = stream.shutdown(Shutdown::Both);
    let _ = writer.join();
    Ok(reason)
}

/// Hello → (wait for) Welcome → Start. Returns the host's displays and the
/// display that was started (the requested one, else primary, else first).
pub fn handshake(
    stream: &mut TcpStream,
    opts: &ConnectOpts,
    closing: &AtomicBool,
    on_waiting: &mut dyn FnMut(&str),
) -> anyhow::Result<(Vec<DisplayInfo>, u8)> {
    Message::Hello { version: VERSION, token: opts.token, viewer_name: opts.viewer_name.clone(), caps: 0 }
        .write_to(stream)
        .context("sending hello")?;

    // The host may sit on a consent dialog before answering. Peek (which
    // never consumes) so a read timeout can't tear a message in half.
    let started = Instant::now();
    let mut told = false;
    stream.set_read_timeout(Some(Duration::from_millis(250)))?;
    let mut probe = [0u8; 1];
    loop {
        if closing.load(Ordering::SeqCst) {
            bail!("closed by user");
        }
        match stream.peek(&mut probe) {
            Ok(0) => bail!("the remote side closed the connection before answering"),
            Ok(_) => break,
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) => return Err(e).context("waiting for the remote side"),
        }
        let waited = started.elapsed();
        if waited >= opts.timing.max_wait {
            bail!("the remote side did not answer within {} s", opts.timing.max_wait.as_secs());
        }
        if !told && waited >= opts.timing.notice_after {
            told = true;
            on_waiting("Waiting for the remote side (it may be showing a consent dialog)");
        }
    }
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let (version, displays) = match Message::read_from(stream, MAX_PAYLOAD).context("reading welcome")? {
        Message::Welcome { version, displays, .. } => (version, displays),
        Message::Reject { reason } => bail!("the remote side rejected the connection: {reason}"),
        other => bail!("unexpected message {:#04x} instead of welcome", other.kind()),
    };
    if version != VERSION {
        bail!("host speaks protocol version {version}, this viewer speaks {VERSION}");
    }
    if displays.is_empty() {
        bail!("the remote side has no displays to share");
    }
    let display = if displays.iter().any(|d| d.index == opts.display) {
        opts.display
    } else {
        displays.iter().find(|d| d.primary).unwrap_or(&displays[0]).index
    };
    Message::Start { display, quality: opts.quality, max_fps: opts.fps, view_only: opts.view_only }
        .write_to(stream)
        .context("sending start")?;
    Ok((displays, display))
}

fn writer_loop(mut stream: TcpStream, rx: Receiver<Out>, t0: Instant) {
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    // Ping right away so the first round trip is measured early.
    let mut last_ping = Instant::now().checked_sub(PING_EVERY).unwrap_or_else(Instant::now);
    'outer: loop {
        let wait = PING_EVERY.saturating_sub(last_ping.elapsed());
        let mut batch: Vec<Out> = Vec::new();
        match rx.recv_timeout(wait) {
            Ok(o) => batch.push(o),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        while let Ok(o) = rx.try_recv() {
            batch.push(o);
        }

        buf.clear();
        let mut closing = false;
        // Of several consecutive pointer moves only the last one matters.
        let mut pending_move: Option<Message> = None;
        for o in batch {
            match o {
                Out::Msg(m @ Message::PointerMove { .. }) => pending_move = Some(m),
                Out::Msg(m) => {
                    if let Some(p) = pending_move.take() {
                        buf.extend_from_slice(&p.to_bytes());
                    }
                    buf.extend_from_slice(&m.to_bytes());
                }
                Out::Close => {
                    closing = true;
                    break;
                }
            }
        }
        if let Some(p) = pending_move.take() {
            buf.extend_from_slice(&p.to_bytes());
        }
        if last_ping.elapsed() >= PING_EVERY && !closing {
            buf.extend_from_slice(&Message::Ping(t0.elapsed().as_nanos() as u64).to_bytes());
            last_ping = Instant::now();
        }
        if !buf.is_empty() {
            use std::io::Write;
            if stream.write_all(&buf).is_err() {
                break 'outer;
            }
        }
        if closing {
            break;
        }
    }
    let _ = stream.shutdown(Shutdown::Both);
}

fn read_loop(stream: &mut TcpStream, shared: &Shared, notify: &Notify, tx: &Sender<Out>, t0: Instant) -> CloseReason {
    let _ = stream.set_read_timeout(Some(DEAD_AFTER));
    let mut dec = Decoder::new();
    // An error notice (capture failed) usually precedes the host hanging up;
    // report it as the reason instead of a bare EOF.
    let mut error_notice: Option<String> = None;
    loop {
        let msg = match Message::read_from(stream, MAX_PAYLOAD) {
            Ok(m) => m,
            Err(_) if shared.closing.load(Ordering::SeqCst) => return CloseReason::Local,
            Err(crossshell_proto::Error::Io(e)) => {
                return match e.kind() {
                    ErrorKind::UnexpectedEof
                    | ErrorKind::ConnectionReset
                    | ErrorKind::ConnectionAborted
                    | ErrorKind::BrokenPipe => match error_notice {
                        Some(t) => CloseReason::Error(t),
                        None => CloseReason::Peer,
                    },
                    ErrorKind::WouldBlock | ErrorKind::TimedOut => {
                        CloseReason::Error(format!("the remote side stopped responding for {} s", DEAD_AFTER.as_secs()))
                    }
                    _ => CloseReason::Error(format!("network error: {e}")),
                };
            }
            Err(e) => return CloseReason::Error(e.to_string()),
        };
        match msg {
            Message::Frame { seq, width, height, rects } => {
                let bytes = rects.iter().map(|r| r.data.len()).sum();
                if let Err(e) = dec.apply(width, height, &rects) {
                    return CloseReason::Error(format!("bad frame from the remote side: {e}"));
                }
                // Ack first: the host's window is 2 frames, so ack latency
                // bounds the frame rate.
                let _ = tx.send(Out::Msg(Message::FrameAck { seq }));
                shared.frame.lock().unwrap().update(&dec, &rects);
                notify(NetEvent::Frame { width, height, bytes });
            }
            Message::CursorShape { width, height, hot_x, hot_y, rgba } => {
                notify(NetEvent::CursorShape { width, height, hot_x, hot_y, rgba })
            }
            Message::CursorPos { x, y } => notify(NetEvent::CursorPos { x, y }),
            Message::DisplaysChanged { displays } => notify(NetEvent::Displays(displays)),
            Message::Notice { level, text } => {
                if level >= level::ERROR && !text.is_empty() {
                    error_notice = Some(text.clone());
                } else if text.is_empty() {
                    error_notice = None; // cleared
                }
                notify(NetEvent::Notice { level, text });
            }
            Message::ClipboardText(t) => notify(NetEvent::Clipboard(t)),
            Message::Ping(n) => {
                let _ = tx.send(Out::Msg(Message::Pong(n)));
            }
            Message::Pong(n) => {
                let now = t0.elapsed().as_nanos() as u64;
                notify(NetEvent::Rtt(Duration::from_nanos(now.saturating_sub(n))));
            }
            Message::Reject { reason } => return CloseReason::Error(format!("rejected: {reason}")),
            // Handshake and viewer→host messages are not valid here; ignore.
            _ => {}
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crossshell_proto::{Encoder, FrameRef, Quality};
    use std::net::TcpListener;
    use std::sync::mpsc;

    pub fn test_opts(port: u16) -> ConnectOpts {
        ConnectOpts {
            port,
            token: [7; TOKEN_LEN],
            viewer_name: "test".into(),
            display: 0,
            quality: 1,
            fps: 30,
            view_only: true,
            timing: Timing { notice_after: Duration::from_millis(150), max_wait: Duration::from_secs(5) },
        }
    }

    pub fn display(i: u8, primary: bool) -> DisplayInfo {
        DisplayInfo { index: i, name: format!("D{i}"), x: 0, y: 0, width: 128, height: 96, primary }
    }

    /// A gradient with a moving square: cheap, deterministic, compressible.
    pub fn image(w: u32, h: u32, step: u32) -> Vec<u8> {
        let mut v = vec![0u8; (w * h * 4) as usize];
        for y in 0..h {
            for x in 0..w {
                let i = ((y * w + x) * 4) as usize;
                let inside = x >= step * 4 && x < step * 4 + 24 && (20..44).contains(&y);
                let (b, g, r) = if inside { (0, 0, 255) } else { ((x * 2) as u8, (y * 2) as u8, 90) };
                v[i..i + 4].copy_from_slice(&[b, g, r, 0]);
            }
        }
        v
    }

    #[test]
    fn framebuf_tracks_the_decoder() {
        let (w, h) = (128u32, 96u32);
        let mut enc = Encoder::new(Quality::Lossless);
        let mut dec = Decoder::new();
        let mut fb = FrameBuf::default();
        for step in 0..4 {
            let img = image(w, h, step);
            let rects = enc.encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
            dec.apply(w, h, &rects).unwrap();
            fb.update(&dec, &rects);
            assert_eq!(fb.pixels, dec.pixels(), "step {step}");
        }
        assert_eq!(fb.generation, 1);
        // A size change re-snapshots everything.
        let img = image(64, 64, 0);
        let rects = enc.encode(&FrameRef::new(64, 64, 256, &img).unwrap());
        dec.apply(64, 64, &rects).unwrap();
        fb.update(&dec, &rects);
        assert_eq!((fb.width, fb.height, fb.generation), (64, 64, 2));
        assert_eq!(fb.pixels, dec.pixels());
    }

    /// Minimal host: Hello → (optional delay) → Welcome → Start → `frames`
    /// frames, honouring the 2-frame window. Returns the Start it saw and
    /// the messages it received after Start.
    pub fn fake_host(
        listener: TcpListener,
        welcome_delay: Duration,
        frames: u32,
    ) -> JoinHandle<(Message, Vec<Message>)> {
        std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            match Message::read_from(&mut s, 1024).unwrap() {
                Message::Hello { token, .. } => assert_eq!(token, [7; TOKEN_LEN]),
                m => panic!("expected hello, got {m:?}"),
            }
            std::thread::sleep(welcome_delay);
            Message::Welcome { version: VERSION, caps: 0, displays: vec![display(0, false), display(1, true)] }
                .write_to(&mut s)
                .unwrap();
            let start = Message::read_from(&mut s, 1024).unwrap();
            let (w, h) = (128u32, 96u32);
            let mut enc = Encoder::new(Quality::Lossless);
            let mut inflight = 0u32;
            let mut got = Vec::new();
            for seq in 1..=frames {
                while inflight >= 2 {
                    match Message::read_from(&mut s, 1 << 20).unwrap() {
                        Message::FrameAck { .. } => inflight -= 1,
                        m => got.push(m),
                    }
                }
                let img = image(w, h, seq);
                let rects = enc.encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
                Message::Frame { seq, width: w, height: h, rects }.write_to(&mut s).unwrap();
                inflight += 1;
            }
            // Collect the rest (acks, pings) until the viewer hangs up.
            s.set_read_timeout(Some(Duration::from_millis(800))).unwrap();
            while let Ok(m) = Message::read_from(&mut s, 1 << 20) {
                got.push(m);
            }
            (start, got)
        })
    }

    #[test]
    fn handshake_and_frames_against_fake_host() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let host = fake_host(listener, Duration::ZERO, 6);

        let shared = Arc::new(Shared::default());
        let (ev_tx, ev_rx) = mpsc::channel();
        let notify: Notify = Arc::new(move |e| {
            let _ = ev_tx.send(e);
        });
        let (tx, rx) = mpsc::channel();
        let mut opts = test_opts(port);
        opts.display = 9; // not present: falls back to the primary (1)
        let mut session = spawn(opts, shared.clone(), notify, tx, rx).unwrap();

        let mut frames = 0;
        let mut connected = false;
        while frames < 6 {
            match ev_rx.recv_timeout(Duration::from_secs(5)).expect("event") {
                NetEvent::Connected { displays, display } => {
                    assert_eq!(displays.len(), 2);
                    assert_eq!(display, 1);
                    connected = true;
                }
                NetEvent::Frame { .. } => frames += 1,
                NetEvent::Closed(r) => panic!("closed early: {r:?}"),
                _ => {}
            }
        }
        assert!(connected);
        {
            let fb = shared.frame.lock().unwrap();
            let want = image(128, 96, 6);
            let first = u32::from_le_bytes([want[0], want[1], want[2], 0]);
            assert_eq!((fb.width, fb.height), (128, 96));
            assert_eq!(fb.pixels[0], first);
        }
        session.send(Message::PointerMove { x: 1, y: 2 });
        session.send(Message::PointerMove { x: 3, y: 4 });
        session.send(Message::Key { code: 30, down: true });
        session.close();
        let (start, got) = host.join().unwrap();
        assert_eq!(start, Message::Start { display: 1, quality: 1, max_fps: 30, view_only: true });
        let acks = got.iter().filter(|m| matches!(m, Message::FrameAck { .. })).count();
        assert!(acks >= 1, "no acks in {got:?}");
        assert!(got.iter().any(|m| matches!(m, Message::Ping(_))), "no ping in {got:?}");
        assert!(got.contains(&Message::Key { code: 30, down: true }));
        // Pointer moves queued together collapse to the last one.
        assert!(
            !got.contains(&Message::PointerMove { x: 1, y: 2 }) || got.contains(&Message::PointerMove { x: 3, y: 4 })
        );
    }

    #[test]
    fn waiting_notice_fires_when_welcome_is_slow() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let host = fake_host(listener, Duration::from_millis(600), 1);
        let shared = Arc::new(Shared::default());
        let (ev_tx, ev_rx) = mpsc::channel();
        let notify: Notify = Arc::new(move |e| {
            let _ = ev_tx.send(e);
        });
        let (tx, rx) = mpsc::channel();
        let mut session = spawn(test_opts(port), shared, notify, tx, rx).unwrap();
        let mut order = Vec::new();
        loop {
            match ev_rx.recv_timeout(Duration::from_secs(5)).expect("event") {
                NetEvent::Waiting(_) => order.push("waiting"),
                NetEvent::Connected { .. } => {
                    order.push("connected");
                    break;
                }
                NetEvent::Closed(r) => panic!("closed early: {r:?}"),
                _ => {}
            }
        }
        assert_eq!(order, ["waiting", "connected"]);
        session.close();
        let _ = host.join();
    }

    #[test]
    fn reject_is_reported_with_the_reason() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = Message::read_from(&mut s, 1024);
            Message::Reject { reason: "bad token".into() }.write_to(&mut s).unwrap();
        });
        let shared = Arc::new(Shared::default());
        let (ev_tx, ev_rx) = mpsc::channel();
        let notify: Notify = Arc::new(move |e| {
            let _ = ev_tx.send(e);
        });
        let (tx, rx) = mpsc::channel();
        let _session = spawn(test_opts(port), shared, notify, tx, rx).unwrap();
        match ev_rx.recv_timeout(Duration::from_secs(5)).unwrap() {
            NetEvent::Closed(CloseReason::Error(e)) => assert!(e.contains("bad token"), "{e}"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn connection_refused_has_a_helpful_message() {
        // Grab a port, then free it so nothing is listening there.
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let shared = Arc::new(Shared::default());
        let (ev_tx, ev_rx) = mpsc::channel();
        let notify: Notify = Arc::new(move |e| {
            let _ = ev_tx.send(e);
        });
        let (tx, rx) = mpsc::channel();
        let _session = spawn(test_opts(port), shared, notify, tx, rx).unwrap();
        match ev_rx.recv_timeout(Duration::from_secs(5)).unwrap() {
            NetEvent::Closed(CloseReason::Error(e)) => assert!(e.contains("refused"), "{e}"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn host_hangup_is_a_peer_close_and_error_notice_becomes_the_reason() {
        for (notice, want_peer) in [(None, true), (Some("capture failed: boom"), false)] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            std::thread::spawn(move || {
                let (mut s, _) = listener.accept().unwrap();
                let _ = Message::read_from(&mut s, 1024);
                Message::Welcome { version: VERSION, caps: 0, displays: vec![display(0, true)] }
                    .write_to(&mut s)
                    .unwrap();
                let _ = Message::read_from(&mut s, 1024);
                if let Some(t) = notice {
                    Message::Notice { level: level::ERROR, text: t.into() }.write_to(&mut s).unwrap();
                }
                // Dropping the socket hangs up.
            });
            let shared = Arc::new(Shared::default());
            let (ev_tx, ev_rx) = mpsc::channel();
            let notify: Notify = Arc::new(move |e| {
                let _ = ev_tx.send(e);
            });
            let (tx, rx) = mpsc::channel();
            let _session = spawn(test_opts(port), shared, notify, tx, rx).unwrap();
            loop {
                if let NetEvent::Closed(r) = ev_rx.recv_timeout(Duration::from_secs(5)).unwrap() {
                    if want_peer {
                        assert_eq!(r, CloseReason::Peer);
                    } else {
                        assert_eq!(r, CloseReason::Error("capture failed: boom".into()));
                    }
                    break;
                }
            }
        }
    }
}
