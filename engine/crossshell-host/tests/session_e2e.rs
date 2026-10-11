//! End-to-end: a scripted viewer against a real session over loopback,
//! using the synthetic backend.

use std::net::{TcpListener, TcpStream};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crossshell_host::session::{serve_connection, SessionOptions};
use crossshell_host::BackendKind;
use crossshell_proto::{Decoder, Message, MAX_PAYLOAD, VERSION};

const TOKEN: [u8; 32] = [0x5a; 32];

fn spawn_host() -> (u16, Arc<AtomicBool>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let busy = Arc::new(AtomicBool::new(false));
    let b = busy.clone();
    std::thread::spawn(move || {
        let opts = Arc::new(SessionOptions { token: TOKEN, backend: BackendKind::Synthetic, runtime_dir: None, clipboard: false });
        for conn in listener.incoming() {
            let (opts, b) = (opts.clone(), b.clone());
            let s = conn.unwrap();
            std::thread::spawn(move || {
                let _ = serve_connection(s, &opts, &b);
            });
        }
    });
    (port, busy)
}

fn connect(port: u16, token: [u8; 32]) -> (TcpStream, Message) {
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    Message::Hello { version: VERSION, token, viewer_name: "test-viewer".into(), caps: 0 }.write_to(&mut s).unwrap();
    let reply = Message::read_from(&mut s, MAX_PAYLOAD).unwrap();
    (s, reply)
}

#[test]
fn bad_token_is_rejected() {
    let (port, _) = spawn_host();
    let (_s, reply) = connect(port, [0; 32]);
    assert_eq!(reply, Message::Reject { reason: "bad token".into() });
}

#[test]
fn full_session_streams_frames_and_takes_input() {
    let (port, _) = spawn_host();
    let (mut s, welcome) = connect(port, TOKEN);
    let Message::Welcome { displays, .. } = welcome else { panic!("expected welcome, got {welcome:?}") };
    assert_eq!(displays.len(), 1);
    let d = &displays[0];
    Message::Start { display: d.index, quality: 1, max_fps: 30, view_only: false }.write_to(&mut s).unwrap();

    // A second viewer is turned away while this one is connected.
    let (_s2, busy) = connect(port, TOKEN);
    assert!(matches!(busy, Message::Reject { ref reason } if reason.starts_with("busy")), "{busy:?}");

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

#[test]
fn flow_control_caps_unacked_frames() {
    let (port, _) = spawn_host();
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
