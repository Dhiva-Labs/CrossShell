//! End-to-end: a scripted viewer against a real session over loopback,
//! using the synthetic backend.

use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crossshell_host::session::{serve_connection, SessionOptions, SessionSlot};
use crossshell_host::BackendKind;
use crossshell_proto::{Decoder, Encoding, Message, CAP_DEFLATE, MAX_PAYLOAD, VERSION};

const TOKEN: [u8; 32] = [0x5a; 32];

fn spawn_host() -> u16 {
    spawn_host_with_slot().0
}

fn spawn_host_with_slot() -> (u16, Arc<SessionSlot>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let b = Arc::new(SessionSlot::default());
    let slot = b.clone();
    std::thread::spawn(move || {
        let opts = Arc::new(SessionOptions { token: TOKEN, backend: BackendKind::Synthetic, runtime_dir: None, clipboard: false, notify: false });
        for conn in listener.incoming() {
            let (opts, b) = (opts.clone(), b.clone());
            let s = conn.unwrap();
            std::thread::spawn(move || {
                let _ = serve_connection(s, &opts, &b);
            });
        }
    });
    (port, slot)
}

fn connect(port: u16, token: [u8; 32]) -> (TcpStream, Message) {
    connect_with_caps(port, token, 0)
}

fn connect_with_caps(port: u16, token: [u8; 32], caps: u32) -> (TcpStream, Message) {
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    Message::Hello { version: VERSION, token, viewer_name: "test-viewer".into(), caps }.write_to(&mut s).unwrap();
    let reply = Message::read_from(&mut s, MAX_PAYLOAD).unwrap();
    (s, reply)
}

#[test]
fn bad_token_is_rejected() {
    let port = spawn_host();
    let (_s, reply) = connect(port, [0; 32]);
    assert_eq!(reply, Message::Reject { reason: "bad token".into() });
}

#[test]
fn full_session_streams_frames_and_takes_input() {
    let port = spawn_host();
    let (mut s, welcome) = connect(port, TOKEN);
    let Message::Welcome { displays, .. } = welcome else { panic!("expected welcome, got {welcome:?}") };
    assert_eq!(displays.len(), 1);
    let d = &displays[0];
    Message::Start { display: d.index, quality: 1, max_fps: 30, view_only: false }.write_to(&mut s).unwrap();

    let mut dec = Decoder::new();
    let mut frames = 0;
    let mut saw_cursor_shape = false;
    let mut saw_cursor_at_target = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut sent_input = false;
    while Instant::now() < deadline && !(frames >= 10 && saw_cursor_at_target) {
        match Message::read_from(&mut s, MAX_PAYLOAD).unwrap() {
            Message::Frame { seq, width, height, rects } => {
                dec.apply(width, height, &rects).unwrap();
                Message::FrameAck { seq }.write_to(&mut s).unwrap();
                frames += 1;
                if !sent_input {
                    sent_input = true;
                    Message::PointerMove { x: 640, y: 360 }.write_to(&mut s).unwrap();
                    Message::Key { code: 30, down: true }.write_to(&mut s).unwrap();
                    Message::Key { code: 30, down: false }.write_to(&mut s).unwrap();
                    Message::Ping(7).write_to(&mut s).unwrap();
                }
            }
            Message::CursorShape { width, .. } => saw_cursor_shape |= width == 8,
            Message::CursorPos { x, y } => saw_cursor_at_target |= (x, y) == (640, 360),
            Message::Pong(n) => assert_eq!(n, 7),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(frames >= 10, "only {frames} frames");
    assert!(saw_cursor_shape);
    assert!(saw_cursor_at_target, "injected pointer move never came back as cursor position");
    assert_eq!((dec.width(), dec.height()), (d.width, d.height));
    // The synthetic pattern draws a white crosshair at the injected pointer.
    let px = dec.pixels()[(360 * d.width + 640) as usize];
    assert_eq!(px, 0x00ff_ffff);
}

/// Lossless frames from a session with the given Hello caps: the Welcome
/// caps, and the rect encodings seen across `n` decoded frames.
fn lossless_session(caps: u32, n: usize) -> (u32, Vec<Encoding>) {
    let port = spawn_host();
    let (mut s, welcome) = connect_with_caps(port, TOKEN, caps);
    let Message::Welcome { caps: accepted, .. } = welcome else { panic!("expected welcome, got {welcome:?}") };
    Message::Start { display: 0, quality: 0, max_fps: 60, view_only: true }.write_to(&mut s).unwrap();
    let mut dec = Decoder::new();
    let mut seen = Vec::new();
    let mut frames = 0;
    while frames < n {
        if let Message::Frame { seq, width, height, rects } = Message::read_from(&mut s, MAX_PAYLOAD).unwrap() {
            dec.apply(width, height, &rects).unwrap();
            seen.extend(rects.iter().map(|r| r.encoding));
            Message::FrameAck { seq }.write_to(&mut s).unwrap();
            frames += 1;
        }
    }
    (accepted, seen)
}

#[test]
fn deflate_is_used_only_when_negotiated() {
    let (accepted, seen) = lossless_session(CAP_DEFLATE, 5);
    assert_eq!(accepted, CAP_DEFLATE);
    assert!(seen.contains(&Encoding::Deflate), "{seen:?}");
    assert!(!seen.contains(&Encoding::Zstd), "{seen:?}");

    // Viewers that send 0 (CrossShell's own) get zstd, exactly as before.
    let (accepted, seen) = lossless_session(0, 5);
    assert_eq!(accepted, 0);
    assert!(seen.contains(&Encoding::Zstd), "{seen:?}");
    assert!(!seen.contains(&Encoding::Deflate), "{seen:?}");

    // Unknown bits are not echoed.
    let (accepted, seen) = lossless_session(!CAP_DEFLATE, 2);
    assert_eq!(accepted, 0);
    assert!(!seen.contains(&Encoding::Deflate), "{seen:?}");
}

/// Polls `cond` for up to 5 s.
fn eventually(cond: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn idle_time_counts_only_without_an_authenticated_viewer() {
    let (port, slot) = spawn_host_with_slot();
    std::thread::sleep(Duration::from_millis(100));
    let before = slot.idle_for().expect("idle before any viewer");
    assert!(before >= Duration::from_millis(100));

    // A failed login does not reset the idle clock.
    let (_s, reply) = connect(port, [0; 32]);
    assert!(matches!(reply, Message::Reject { .. }));
    assert!(slot.idle_for().unwrap() >= before);

    let (mut s, welcome) = connect(port, TOKEN);
    assert!(matches!(welcome, Message::Welcome { .. }));
    assert_eq!(slot.idle_for(), None);
    Message::Start { display: 0, quality: 1, max_fps: 30, view_only: true }.write_to(&mut s).unwrap();
    assert!(Message::read_from(&mut s, MAX_PAYLOAD).is_ok());
    assert_eq!(slot.idle_for(), None);

    // Disconnect: the clock restarts from zero.
    drop(s);
    assert!(eventually(|| slot.idle_for().is_some()), "session never ended");
    assert!(slot.idle_for().unwrap() < before + Duration::from_secs(5));
    assert!(slot.idle_for().unwrap() < Duration::from_secs(5));
}

#[test]
fn flow_control_caps_unacked_frames() {
    let port = spawn_host();
    let (mut s, _) = connect(port, TOKEN);
    Message::Start { display: 0, quality: 0, max_fps: 60, view_only: true }.write_to(&mut s).unwrap();
    // Never ack: the host must stop after MAX_INFLIGHT_FRAMES frames.
    s.set_read_timeout(Some(Duration::from_millis(1500))).unwrap();
    let mut frames = 0;
    loop {
        match Message::read_from(&mut s, MAX_PAYLOAD) {
            Ok(Message::Frame { .. }) => frames += 1,
            Ok(_) => {}
            Err(_) => break, // timed out: host is waiting for acks
        }
    }
    assert_eq!(frames, crossshell_proto::MAX_INFLIGHT_FRAMES);
}

#[test]
fn a_new_viewer_takes_over_the_session() {
    let port = spawn_host();
    let (mut first, _) = connect(port, TOKEN);
    Message::Start { display: 0, quality: 1, max_fps: 30, view_only: true }.write_to(&mut first).unwrap();
    assert!(matches!(Message::read_from(&mut first, MAX_PAYLOAD), Ok(_)));

    // Same person reconnecting from a new window: they get the session.
    let (_second, reply) = connect(port, TOKEN);
    assert!(matches!(reply, Message::Welcome { .. }), "{reply:?}");

    // The first connection is closed (after any frames already queued).
    first.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut closed = false;
    for _ in 0..1000 {
        if Message::read_from(&mut first, MAX_PAYLOAD).is_err() {
            closed = true;
            break;
        }
    }
    assert!(closed, "first viewer was not disconnected");
}
