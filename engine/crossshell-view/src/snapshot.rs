//! Headless mode: connect, collect frames, write the framebuffer as PNG.

use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context};
use crossshell_proto::TOKEN_LEN;

use crate::args::Args;
use crate::net::{self, ConnectOpts, FrameBuf, NetEvent, Notify, Shared, Timing};

/// After at least one frame, a screen that stays still this long ends the run
/// (the host only sends frames when something changes).
const IDLE_END: Duration = Duration::from_secs(2);
/// Consent dialog allowance (120 s) plus time for the first frame.
const FIRST_FRAME_MAX: Duration = Duration::from_secs(150);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stats {
    pub frames: u32,
    pub kib: f64,
    pub fps: f64,
    pub width: u32,
    pub height: u32,
}

pub fn run(args: &Args, token: [u8; TOKEN_LEN]) -> anyhow::Result<Stats> {
    let out = args.snapshot.as_ref().ok_or_else(|| anyhow!("no --snapshot path"))?;
    let shared = Arc::new(Shared::default());
    let (ev_tx, ev_rx) = mpsc::channel();
    let notify: Notify = Arc::new(move |e| {
        let _ = ev_tx.send(e);
    });
    let (tx, rx) = mpsc::channel();
    let opts = ConnectOpts {
        port: args.port,
        token,
        viewer_name: format!("{} (snapshot)", crate::viewer_name()),
        display: args.display,
        quality: args.quality,
        fps: args.fps,
        view_only: true,
        timing: Timing::default(),
    };
    let mut session = net::spawn(opts, shared.clone(), notify, tx, rx).context("starting the network thread")?;

    let started = Instant::now();
    let (mut frames, mut bytes) = (0u32, 0usize);
    let (mut first_at, mut last_at) = (None::<Instant>, Instant::now());
    let outcome: anyhow::Result<()> = loop {
        if frames >= args.frames {
            break Ok(());
        }
        if frames > 0 && last_at.elapsed() >= IDLE_END {
            eprintln!("screen is idle; stopping after {frames} frames");
            break Ok(());
        }
        if frames == 0 && started.elapsed() >= FIRST_FRAME_MAX {
            break Err(anyhow!("no frame arrived within {} s", FIRST_FRAME_MAX.as_secs()));
        }
        match ev_rx.recv_timeout(Duration::from_millis(250)) {
            Ok(NetEvent::Frame { bytes: b, .. }) => {
                frames += 1;
                bytes += b;
                last_at = Instant::now();
                first_at.get_or_insert(last_at);
            }
            Ok(NetEvent::Waiting(m)) => eprintln!("{m}"),
            Ok(NetEvent::Connected { displays, display }) => {
                for d in &displays {
                    eprintln!(
                        "display {}: {:?} {}x{} at {},{}{}{}",
                        d.index,
                        d.name,
                        d.width,
                        d.height,
                        d.x,
                        d.y,
                        if d.primary { " (primary)" } else { "" },
                        if d.index == display { " <- capturing" } else { "" }
                    );
                }
            }
            Ok(NetEvent::Notice { level, text }) => eprintln!("notice[{level}]: {text}"),
            Ok(NetEvent::Closed(reason)) => {
                if frames == 0 {
                    break Err(anyhow!("{}", reason.text()));
                }
                break Ok(());
            }
            Ok(_) => {}
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break Err(anyhow!("network thread ended")),
        }
    };
    session.close();
    outcome?;

    let fb = shared.frame.lock().unwrap();
    write_png(out, &fb)?;
    let span = match (first_at, frames) {
        (Some(f), n) if n > 1 => last_at.duration_since(f).as_secs_f64(),
        _ => 0.0,
    };
    Ok(Stats {
        frames,
        kib: bytes as f64 / 1024.0,
        fps: if span > 0.0 { (frames - 1) as f64 / span } else { 0.0 },
        width: fb.width,
        height: fb.height,
    })
}

pub fn write_png(path: &std::path::Path, fb: &FrameBuf) -> anyhow::Result<()> {
    if fb.width == 0 || fb.height == 0 || fb.pixels.len() != (fb.width * fb.height) as usize {
        bail!("no frame to write");
    }
    let mut rgb = Vec::with_capacity(fb.pixels.len() * 3);
    for p in &fb.pixels {
        rgb.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, *p as u8]);
    }
    let file = std::fs::File::create(path).with_context(|| format!("creating {}", path.display()))?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), fb.width, fb.height);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()?.write_image_data(&rgb)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::tests::{fake_host, image};
    use std::net::TcpListener;

    #[test]
    fn snapshot_against_fake_host_writes_the_last_frame() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let host = fake_host(listener, Duration::ZERO, 8);
        let dir = std::env::temp_dir().join(format!("csview-snap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let out = dir.join("shot.png");
        let args = Args {
            port,
            title: String::new(),
            view_only: true,
            quality: 0,
            fps: 30,
            display: 1,
            clipboard: false,
            snapshot: Some(out.clone()),
            frames: 8,
        };
        let stats = run(&args, [7; TOKEN_LEN]).unwrap();
        assert_eq!(stats.frames, 8);
        assert_eq!((stats.width, stats.height), (128, 96));
        assert!(stats.kib > 0.0);
        let (start, _) = host.join().unwrap();
        assert_eq!(start, crossshell_proto::Message::Start { display: 1, quality: 0, max_fps: 30, view_only: true });

        // Decode the PNG and compare with the last image the host drew.
        let dec = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(&out).unwrap()));
        let mut reader = dec.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut buf).unwrap();
        assert_eq!((info.width, info.height), (128, 96));
        let want = image(128, 96, 8); // BGRX
        for (i, px) in buf.chunks_exact(3).enumerate() {
            assert_eq!(px, [want[i * 4 + 2], want[i * 4 + 1], want[i * 4]], "pixel {i}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_png_rejects_empty_frames() {
        let p = std::env::temp_dir().join("never-written.png");
        assert!(write_png(&p, &FrameBuf::default()).is_err());
    }
}
