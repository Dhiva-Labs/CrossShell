//! Test client: connect to a host agent, grab frames, save the last one as
//! PNG. Works through an SSH tunnel too.
//!
//!     cargo run --release --example snapshot -- --port 47821 --token <hex> \
//!         [--out shot.png] [--frames 20] [--display 0] [--quality 1] [--move X,Y]
//!
//! `--token -` reads the token from stdin. `--move` injects one pointer
//! motion after the first frame (pointer motion only — never clicks/keys).

use std::io::BufRead;
use std::net::TcpStream;
use std::time::{Duration, Instant};

use crossshell_proto::{from_hex, Decoder, Message, MAX_PAYLOAD, VERSION};

fn main() -> anyhow::Result<()> {
    let mut port = crossshell_proto::DEFAULT_HOST_PORT;
    let mut token_hex = String::new();
    let mut out = "snapshot.png".to_string();
    let mut frames = 20u32;
    let mut display = 0u8;
    let mut quality = 1u8;
    let mut mv: Option<(i32, i32)> = None;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        let mut v = || it.next().ok_or_else(|| anyhow::anyhow!("{a} needs a value"));
        match a.as_str() {
            "--port" => port = v()?.parse()?,
            "--token" => token_hex = v()?,
            "--out" => out = v()?,
            "--frames" => frames = v()?.parse()?,
            "--display" => display = v()?.parse()?,
            "--quality" => quality = v()?.parse()?,
            "--move" => {
                let s = v()?;
                let (x, y) = s.split_once(',').ok_or_else(|| anyhow::anyhow!("--move X,Y"))?;
                mv = Some((x.parse()?, y.parse()?));
            }
            _ => anyhow::bail!("unknown arg {a}"),
        }
    }
    if token_hex == "-" {
        token_hex.clear();
        std::io::stdin().lock().read_line(&mut token_hex)?;
    }
    let token: [u8; 32] = from_hex(&token_hex)
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| anyhow::anyhow!("token must be 64 hex chars"))?;

    let mut s = TcpStream::connect(("127.0.0.1", port))?;
    s.set_read_timeout(Some(Duration::from_secs(120)))?;
    Message::Hello { version: VERSION, token, viewer_name: "snapshot".into(), caps: 0 }.write_to(&mut s)?;
    let displays = match Message::read_from(&mut s, MAX_PAYLOAD)? {
        Message::Welcome { displays, .. } => displays,
        Message::Reject { reason } => anyhow::bail!("rejected: {reason}"),
        m => anyhow::bail!("unexpected {m:?}"),
    };
    for d in &displays {
        eprintln!("display {}: {:?} {}x{} at {},{}{}", d.index, d.name, d.width, d.height, d.x, d.y, if d.primary { " (primary)" } else { "" });
    }
    Message::Start { display, quality, max_fps: 30, view_only: mv.is_none() }.write_to(&mut s)?;

    let mut dec = Decoder::new();
    let started = Instant::now();
    let (mut got, mut bytes) = (0u32, 0usize);
    let mut last_ping = Instant::now();
    s.set_read_timeout(Some(Duration::from_secs(15)))?;
    while got < frames {
        if last_ping.elapsed() > Duration::from_secs(2) {
            Message::Ping(0).write_to(&mut s)?;
            last_ping = Instant::now();
        }
        match Message::read_from(&mut s, MAX_PAYLOAD)? {
            Message::Frame { seq, width, height, rects } => {
                bytes += rects.iter().map(|r| r.data.len()).sum::<usize>();
                dec.apply(width, height, &rects)?;
                Message::FrameAck { seq }.write_to(&mut s)?;
                got += 1;
                if got == 1 {
                    eprintln!("first frame after {:?}", started.elapsed());
                    if let Some((x, y)) = mv {
                        Message::PointerMove { x, y }.write_to(&mut s)?;
                    }
                }
            }
            Message::CursorPos { x, y } => eprintln!("cursor at {x},{y}"),
            Message::CursorShape { width, height, .. } => eprintln!("cursor shape {width}x{height}"),
            Message::Notice { level, text } => eprintln!("notice[{level}]: {text}"),
            _ => {}
        }
    }
    let secs = started.elapsed().as_secs_f64();
    eprintln!("{got} frames, {:.1} KiB, {:.1} fps over {secs:.1}s", bytes as f64 / 1024.0, got as f64 / secs);

    let (w, h) = (dec.width(), dec.height());
    let mut rgb = Vec::with_capacity((w * h * 3) as usize);
    for p in dec.pixels() {
        rgb.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, *p as u8]);
    }
    let f = std::fs::File::create(&out)?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(f), w, h);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()?.write_image_data(&rgb)?;
    eprintln!("wrote {out} ({w}x{h})");
    Ok(())
}
