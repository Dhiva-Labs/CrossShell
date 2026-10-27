//! Golden fixtures for SecureShell Go's Dart port of the wire protocol and
//! tile decoder.
//!
//!     cargo run -p crossshell-proto --example ssgo_fixtures -- <outdir>
//!
//! The output is deterministic: every image comes from a seeded generator,
//! nothing reads the clock, and the encoder's output does not depend on
//! thread scheduling. Before writing, the example decodes everything again
//! with the Rust decoder and checks it, so a fixture that is written is one
//! the Rust side agrees with.
//!
//! # Frame cases
//!
//! For each case `NAME` (`fill`, `text`, `photo_balanced`, `incremental`,
//! `odd_size`, `refine`):
//!
//! - `NAME.frames`: the complete wire messages (`u8 type | u32 len (LE) |
//!   payload`, as `Message::to_bytes` writes them) of the `Frame`s a host
//!   sends for the case's input frames once `CAP_DEFLATE` is negotiated,
//!   back to back. Sequence numbers start at 1. As in the host, an encode
//!   that finds no change sends nothing, so `refine` has fewer frames than
//!   encodes.
//! - `NAME.bgrx`: the last input frame, `width * height * 4` bytes, rows top
//!   to bottom, each pixel B, G, R, X. The X byte is undefined on the wire
//!   (some cases fill it with junk on purpose): compare B, G and R only.
//! - `NAME.json`: `{"width", "height", "quality": "lossless|balanced|speed",
//!   "frames": N, "exact": bool, "maxMeanAbsError": E}` plus, for
//!   information, `"rustMeanAbsError"` (what the Rust decoder gets) and
//!   `"encodings"` (rect count per encoding across all frames).
//!
//! The check: decode the frames in order onto one framebuffer that starts
//! black. When `exact`, the result equals `NAME.bgrx` in B, G, R. Otherwise
//! the mean absolute error over all B, G and R samples is at most
//! `maxMeanAbsError` (JPEG decoders round differently; `E` leaves room for
//! that but not for a swapped channel or a misplaced rect).
//!
//! # Messages
//!
//! - `messages.bin`: one message of every type (plus a hidden cursor and an
//!   empty notice), back to back, as complete wire messages.
//! - `messages.json`: an array with one entry per message, in order:
//!   `{"kind": "Hello", "type": 1, "offset": byte offset in messages.bin,
//!   "length": bytes including the 5-byte header, "fields": {...}}`. Field
//!   names are those of `crossshell_proto::Message`; byte arrays (token,
//!   rect data, cursor RGBA) are lowercase hex; a rect's `encoding` is its
//!   wire value. u64 values stay below 2^53 so JSON numbers are exact.
//!   Decoding `messages.bin[offset..offset+length]` must give `fields`, and
//!   encoding `fields` must give the same bytes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crossshell_proto::msg::{button, kind, level};
use crossshell_proto::{
    to_hex, Decoder, DisplayInfo, Encoder, Encoding, FrameRef, LosslessCodec, Message, MessageReader, Quality, Rect,
    CAP_DEFLATE, MAX_PAYLOAD, TOKEN_LEN, VERSION,
};
use serde_json::{json, Value};

/// Total output must stay below this (the fixtures are committed to the
/// Dart repository).
const MAX_TOTAL_BYTES: u64 = 2 << 20;

fn main() -> anyhow::Result<()> {
    let out = std::env::args_os().nth(1).map(PathBuf::from).ok_or_else(|| anyhow::anyhow!("usage: ssgo_fixtures <outdir>"))?;
    std::fs::create_dir_all(&out)?;
    let mut total = 0u64;
    for case in cases() {
        total += write_case(&out, &case)?;
    }
    total += write_messages(&out)?;
    anyhow::ensure!(total < MAX_TOTAL_BYTES, "fixtures total {total} bytes, over {MAX_TOTAL_BYTES}");
    println!("wrote {} KiB of fixtures to {}", total / 1024, out.display());
    Ok(())
}

// ------------------------------------------------------------------ images

/// xorshift32: tiny, seeded, the same everywhere.
struct Rng(u32);

impl Rng {
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0
    }

    /// Uniform in `-r..=r`.
    fn noise(&mut self, r: i32) -> i32 {
        (self.next() % (2 * r as u32 + 1)) as i32 - r
    }
}

/// What to put in the X byte.
#[derive(Clone, Copy)]
enum XByte {
    Opaque,
    /// Seeded junk, as some capture APIs leave it.
    Junk(u32),
}

#[derive(Clone)]
struct Img {
    w: u32,
    h: u32,
    px: Vec<u8>,
}

impl Img {
    fn new(w: u32, h: u32, bgr: [u8; 3], x: XByte) -> Img {
        let mut img = Img { w, h, px: vec![0; (w * h * 4) as usize] };
        img.rect(0, 0, w, h, bgr);
        let mut rng = match x {
            XByte::Opaque => None,
            XByte::Junk(seed) => Some(Rng(seed)),
        };
        for p in img.px.chunks_exact_mut(4) {
            p[3] = rng.as_mut().map_or(0xff, |r| r.next() as u8);
        }
        img
    }

    fn set(&mut self, x: u32, y: u32, bgr: [u8; 3]) {
        if x < self.w && y < self.h {
            let i = ((y * self.w + x) * 4) as usize;
            self.px[i..i + 3].copy_from_slice(&bgr);
        }
    }

    fn rect(&mut self, x0: u32, y0: u32, w: u32, h: u32, bgr: [u8; 3]) {
        for y in y0..y0 + h {
            for x in x0..x0 + w {
                self.set(x, y, bgr);
            }
        }
    }

    /// Lines of pseudo-glyphs (5×8 cells of 1×1 dots), like small UI text.
    fn text(&mut self, x0: u32, y0: u32, cols: u32, lines: u32, bgr: [u8; 3], rng: &mut Rng) {
        for line in 0..lines {
            for col in 0..cols {
                let bits = rng.next();
                if bits.is_multiple_of(7) {
                    continue; // a space
                }
                for gy in 0..8 {
                    for gx in 0..5 {
                        if (bits >> ((gy * 5 + gx) % 32)) & 1 == 1 {
                            self.set(x0 + col * 7 + gx, y0 + line * 13 + gy, bgr);
                        }
                    }
                }
            }
        }
    }

    /// A noisy diagonal gradient: photographic content for the JPEG path.
    fn photo(&mut self, x0: u32, y0: u32, w: u32, h: u32, rng: &mut Rng) {
        for y in y0..y0 + h {
            for x in x0..x0 + w {
                let fx = (x - x0) * 255 / w.max(2).saturating_sub(1);
                let fy = (y - y0) * 255 / h.max(2).saturating_sub(1);
                let c = |base: u32, rng: &mut Rng| (base as i32 + rng.noise(18)).clamp(0, 255) as u8;
                let bgr = [c((fx + fy) / 2, rng), c(fy, rng), c(fx, rng)];
                self.set(x, y, bgr);
            }
        }
    }

    fn frame(&self) -> FrameRef<'_> {
        FrameRef::new(self.w, self.h, (self.w * 4) as usize, &self.px).unwrap()
    }
}

const WHITE: [u8; 3] = [0xfa, 0xfa, 0xfa];
const INK: [u8; 3] = [0x30, 0x2a, 0x26];
const ACCENT: [u8; 3] = [0xd0, 0x70, 0x20]; // BGR: a blue
const PANEL: [u8; 3] = [0x3c, 0x34, 0x2e];

/// A small window: title bar, sidebar, text, a button and a selection.
fn ui(w: u32, h: u32, x: XByte, seed: u32) -> Img {
    let mut rng = Rng(seed);
    let mut img = Img::new(w, h, WHITE, x);
    img.rect(0, 0, w, 22, PANEL);
    img.text(8, 7, (w / 7).saturating_sub(4).min(24), 1, WHITE, &mut rng);
    img.rect(0, 22, 56.min(w), h - 22, [0xf0, 0xec, 0xe8]);
    img.text(6, 32, 6, (h - 40) / 13, INK, &mut rng);
    img.text(66, 32, (w.saturating_sub(76)) / 7, (h - 70) / 13, INK, &mut rng);
    img.rect(66, 58, (w / 3).min(140), 13, [0xf5, 0xd9, 0xb8]); // selection
    img.text(66, 60, ((w / 3).min(140)) / 7, 1, INK, &mut rng);
    let (bx, by) = (w.saturating_sub(90), h.saturating_sub(30));
    img.rect(bx, by, 80, 22, ACCENT);
    img.text(bx + 12, by + 7, 8, 1, WHITE, &mut rng);
    img
}

// ------------------------------------------------------------------- cases

struct Case {
    name: &'static str,
    quality: Quality,
    /// Input frames, encoded in order.
    inputs: Vec<Img>,
    /// Keep encoding the last frame until the encoder has nothing lossy left.
    refine: bool,
}

fn cases() -> Vec<Case> {
    let fill = Img::new(192, 128, [0x33, 0x66, 0x99], XByte::Opaque);

    let text = ui(320, 200, XByte::Opaque, 0x7e57_0001);

    let mut photo = Img::new(256, 160, [0x40, 0x40, 0x40], XByte::Junk(0x5eed_0002));
    photo.rect(0, 0, 64, 160, [0xe0, 0xe0, 0xe0]); // flat sidebar: Fill tiles
    photo.photo(64, 0, 192, 160, &mut Rng(0x5eed_0003));

    let a = ui(256, 192, XByte::Opaque, 0x1ac2_0004);
    let mut b = a.clone();
    b.rect(100, 70, 2, 14, INK); // a caret in one tile
    b.text(200, 150, 4, 1, ACCENT, &mut Rng(0x1ac2_0005)); // a word in another
    let mut c = b.clone();
    c.rect(50, 120, 100, 10, [0x20, 0xc0, 0x40]); // a bar across tile rows and columns
    c.rect(100, 70, 2, 14, WHITE); // caret gone

    // Edge tiles 13 px wide and 25 px tall. Text runs into the right edge;
    // the bottom-right tile is noise next to a flat tile, so it is sent
    // alone and Raw (zlib cannot shrink it).
    let mut odd = Img::new(333, 217, WHITE, XByte::Junk(0x0dd5_0006));
    let mut rng = Rng(0x0dd5_0007);
    odd.rect(0, 0, 333, 22, PANEL);
    odd.text(8, 7, 20, 1, WHITE, &mut rng);
    odd.text(10, 30, 46, 11, INK, &mut rng);
    odd.rect(200, 100, 133, 40, ACCENT);
    let mut rng = Rng(0x0dd5_0008);
    for y in 192..217 {
        for x in 320..333 {
            odd.set(x, y, [rng.next() as u8, rng.next() as u8, rng.next() as u8]);
        }
    }

    let mut refine = Img::new(256, 160, [0, 0, 0], XByte::Opaque);
    refine.photo(0, 0, 256, 160, &mut Rng(0x2ef1_0009));
    refine.text(10, 10, 20, 2, WHITE, &mut Rng(0x2ef1_000a));

    vec![
        Case { name: "fill", quality: Quality::Lossless, inputs: vec![fill], refine: false },
        Case { name: "text", quality: Quality::Lossless, inputs: vec![text], refine: false },
        Case { name: "photo_balanced", quality: Quality::Balanced, inputs: vec![photo], refine: false },
        Case { name: "incremental", quality: Quality::Lossless, inputs: vec![a, b, c], refine: false },
        Case { name: "odd_size", quality: Quality::Lossless, inputs: vec![odd], refine: false },
        Case { name: "refine", quality: Quality::Balanced, inputs: vec![refine], refine: true },
    ]
}

fn quality_name(q: Quality) -> &'static str {
    match q {
        Quality::Lossless => "lossless",
        Quality::Balanced => "balanced",
        Quality::Speed => "speed",
    }
}

fn encoding_name(e: Encoding) -> &'static str {
    match e {
        Encoding::Raw => "Raw",
        Encoding::Zstd => "Zstd",
        Encoding::Jpeg => "Jpeg",
        Encoding::Fill => "Fill",
        Encoding::Deflate => "Deflate",
    }
}

/// Mean absolute error over the B, G, R samples of `decoded` (0x00RRGGBB)
/// against BGRX `expected`.
fn mean_abs_error(decoded: &[u32], expected: &[u8]) -> f64 {
    let mut sum = 0u64;
    for (d, e) in decoded.iter().zip(expected.chunks_exact(4)) {
        let [b, g, r, _] = d.to_le_bytes();
        sum += (b.abs_diff(e[0]) as u64) + (g.abs_diff(e[1]) as u64) + (r.abs_diff(e[2]) as u64);
    }
    sum as f64 / (decoded.len() as f64 * 3.0)
}

fn write_case(out: &Path, case: &Case) -> anyhow::Result<u64> {
    let mut enc = Encoder::new(case.quality).with_lossless_codec(LosslessCodec::for_caps(CAP_DEFLATE));
    let mut wire = Vec::new();
    let mut seq = 0u32;
    let mut send = |img: &Img, enc: &mut Encoder| {
        let rects = enc.encode(&img.frame());
        if !rects.is_empty() {
            seq += 1;
            wire.extend(Message::Frame { seq, width: img.w, height: img.h, rects }.to_bytes());
        }
    };
    for img in &case.inputs {
        send(img, &mut enc);
    }
    let last = case.inputs.last().unwrap();
    if case.refine {
        anyhow::ensure!(enc.needs_refinement(), "{}: nothing to refine", case.name);
        let mut rounds = 0;
        while enc.needs_refinement() {
            send(last, &mut enc);
            rounds += 1;
            anyhow::ensure!(rounds < 16, "{}: refinement does not finish", case.name);
        }
    }
    let frames = seq;

    // Decode the wire bytes back, as a viewer would.
    let mut dec = Decoder::new();
    let mut reader = MessageReader::new(MAX_PAYLOAD);
    let mut src = &wire[..];
    let mut encodings: BTreeMap<&str, u32> = BTreeMap::new();
    let mut n = 0;
    loop {
        match reader.read(&mut src) {
            Ok(Some(Message::Frame { seq, width, height, rects })) => {
                n += 1;
                anyhow::ensure!(seq == n, "{}: frame seq {seq}, expected {n}", case.name);
                for r in &rects {
                    *encodings.entry(encoding_name(r.encoding)).or_default() += 1;
                }
                dec.apply(width, height, &rects)?;
            }
            Ok(Some(m)) => anyhow::bail!("{}: unexpected {m:?}", case.name),
            Ok(None) => {}
            Err(crossshell_proto::Error::Io(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(e.into()),
        }
    }
    anyhow::ensure!(n == frames, "{}: decoded {n} of {frames} frames", case.name);
    anyhow::ensure!(!encodings.contains_key("Zstd"), "{}: zstd rect despite CAP_DEFLATE", case.name);
    let mae = mean_abs_error(dec.pixels(), &last.px);
    let exact = case.quality == Quality::Lossless || case.refine;
    let max_mae = if exact {
        anyhow::ensure!(mae == 0.0, "{}: lossless case decodes with error {mae}", case.name);
        0.0
    } else {
        anyhow::ensure!(mae > 0.0, "{}: lossy case came out exact", case.name);
        // Room for another JPEG decoder's rounding and upsampling.
        ((mae * 1.5 + 1.0) * 100.0).ceil() / 100.0
    };

    let meta = json!({
        "width": last.w,
        "height": last.h,
        "quality": quality_name(case.quality),
        "frames": frames,
        "exact": exact,
        "maxMeanAbsError": max_mae,
        "rustMeanAbsError": (mae * 1000.0).round() / 1000.0,
        "encodings": encodings,
    });
    let json = serde_json::to_string_pretty(&meta)? + "\n";
    std::fs::write(out.join(format!("{}.frames", case.name)), &wire)?;
    std::fs::write(out.join(format!("{}.bgrx", case.name)), &last.px)?;
    std::fs::write(out.join(format!("{}.json", case.name)), &json)?;
    println!(
        "{:<15} {}x{} {:>8} {} frame(s) {:>7} B wire  mae {:.3}  {:?}",
        case.name,
        last.w,
        last.h,
        quality_name(case.quality),
        frames,
        wire.len(),
        mae,
        encodings
    );
    Ok((wire.len() + last.px.len() + json.len()) as u64)
}

// ---------------------------------------------------------------- messages

fn displays_json(d: &[DisplayInfo]) -> Value {
    d.iter()
        .map(|d| {
            json!({"index": d.index, "name": d.name, "x": d.x, "y": d.y,
                   "width": d.width, "height": d.height, "primary": d.primary})
        })
        .collect()
}

/// The `kind` name and fields of `m`. The match is exhaustive, so a new
/// message type cannot be left out of the fixture by accident.
fn describe(m: &Message) -> (&'static str, Value) {
    match m {
        Message::Hello { version, token, viewer_name, caps } => (
            "Hello",
            json!({"version": version, "token": to_hex(token), "viewer_name": viewer_name, "caps": caps}),
        ),
        Message::Welcome { version, caps, displays } => {
            ("Welcome", json!({"version": version, "caps": caps, "displays": displays_json(displays)}))
        }
        Message::Reject { reason } => ("Reject", json!({ "reason": reason })),
        Message::Start { display, quality, max_fps, view_only } => (
            "Start",
            json!({"display": display, "quality": quality, "max_fps": max_fps, "view_only": view_only}),
        ),
        Message::SelectDisplay { display, quality, max_fps } => {
            ("SelectDisplay", json!({"display": display, "quality": quality, "max_fps": max_fps}))
        }
        Message::Frame { seq, width, height, rects } => {
            let rects: Vec<Value> = rects
                .iter()
                .map(|r| {
                    json!({"x": r.x, "y": r.y, "w": r.w, "h": r.h, "encoding": r.encoding as u8,
                           "encoding_name": encoding_name(r.encoding), "data": to_hex(&r.data)})
                })
                .collect();
            ("Frame", json!({"seq": seq, "width": width, "height": height, "rects": rects}))
        }
        Message::FrameAck { seq } => ("FrameAck", json!({ "seq": seq })),
        Message::CursorShape { width, height, hot_x, hot_y, rgba } => (
            "CursorShape",
            json!({"width": width, "height": height, "hot_x": hot_x, "hot_y": hot_y, "rgba": to_hex(rgba)}),
        ),
        Message::CursorPos { x, y } => ("CursorPos", json!({"x": x, "y": y})),
        Message::DisplaysChanged { displays } => ("DisplaysChanged", json!({ "displays": displays_json(displays) })),
        Message::PointerMove { x, y } => ("PointerMove", json!({"x": x, "y": y})),
        Message::PointerButton { button, down } => ("PointerButton", json!({"button": button, "down": down})),
        Message::Scroll { dx, dy } => ("Scroll", json!({"dx": dx, "dy": dy})),
        Message::Key { code, down } => ("Key", json!({"code": code, "down": down})),
        Message::ReleaseAll => ("ReleaseAll", json!({})),
        Message::ClipboardText(text) => ("ClipboardText", json!({ "text": text })),
        Message::Ping(v) => ("Ping", json!({ "value": v })),
        Message::Pong(v) => ("Pong", json!({ "value": v })),
        Message::Notice { level, text } => ("Notice", json!({"level": level, "text": text})),
    }
}

fn messages() -> anyhow::Result<Vec<Message>> {
    let mut token = [0u8; TOKEN_LEN];
    let mut rng = Rng(0x70ce_0001);
    token.iter_mut().for_each(|b| *b = rng.next() as u8);
    let display = |index: u8, name: &str, x: i32, y: i32, width: u32, height: u32, primary: bool| DisplayInfo {
        index,
        name: name.into(),
        x,
        y,
        width,
        height,
        primary,
    };
    let displays = vec![
        display(0, "Built-in Retina — eDP-1", 0, 0, 2560, 1600, true),
        display(1, "DELL U2720Q", -3840, -560, 3840, 2160, false),
    ];

    // One small rect of every encoding, each with real data for its size.
    let px2x2: Vec<u8> = (0..16u8).map(|i| i.wrapping_mul(37)).collect();
    let zstd = zstd::bulk::compress(&px2x2, 1)?;
    let deflate = {
        use std::io::Write;
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::new(1));
        z.write_all(&px2x2)?;
        z.finish()?
    };
    let jpeg = {
        let mut rng = Rng(0x1e9_0002);
        let px: Vec<u8> = (0..8 * 8 * 4).map(|_| rng.next() as u8).collect();
        let mut out = Vec::new();
        jpeg_encoder::Encoder::new(&mut out, 80).encode(&px, 8, 8, jpeg_encoder::ColorType::Bgra)?;
        out
    };
    let rects = vec![
        Rect { x: 0, y: 0, w: 2, h: 1, encoding: Encoding::Raw, data: px2x2[..8].to_vec() },
        Rect { x: 2, y: 0, w: 2, h: 2, encoding: Encoding::Zstd, data: zstd },
        Rect { x: 8, y: 0, w: 8, h: 8, encoding: Encoding::Jpeg, data: jpeg },
        Rect { x: 0, y: 64, w: 64, h: 64, encoding: Encoding::Fill, data: vec![0x10, 0x20, 0x30, 0] },
        Rect { x: 4, y: 0, w: 2, h: 2, encoding: Encoding::Deflate, data: deflate },
    ];

    let cursor: Vec<u8> = (0..3 * 2 * 4).map(|i| (i * 11) as u8).collect();
    Ok(vec![
        Message::Hello { version: VERSION, token, viewer_name: "Pixel 9 — SecureShell Go".into(), caps: CAP_DEFLATE },
        Message::Welcome { version: VERSION, caps: CAP_DEFLATE, displays: displays.clone() },
        Message::Reject { reason: "bad token".into() },
        Message::Start { display: 1, quality: Quality::Balanced as u8, max_fps: 30, view_only: true },
        Message::SelectDisplay { display: 0, quality: Quality::Lossless as u8, max_fps: 60 },
        Message::Frame { seq: 0x0102_0304, width: 1920, height: 1080, rects },
        Message::FrameAck { seq: u32::MAX },
        Message::CursorShape { width: 3, height: 2, hot_x: 1, hot_y: 0, rgba: cursor },
        Message::CursorShape { width: 0, height: 0, hot_x: 0, hot_y: 0, rgba: Vec::new() },
        Message::CursorPos { x: -12, y: 70_000 },
        Message::DisplaysChanged { displays: vec![displays[1].clone()] },
        Message::PointerMove { x: 1919, y: -1 },
        Message::PointerButton { button: button::BACK, down: true },
        Message::Scroll { dx: -120, dy: 360 },
        Message::Key { code: 125, down: false },
        Message::ReleaseAll,
        Message::ClipboardText("héllo\nwörld\t✓ 🦀".into()),
        Message::Ping(0x0012_3456_789a_bcde),
        Message::Pong((1 << 53) - 1),
        Message::Notice { level: level::WARN, text: "Screen locked".into() },
        Message::Notice { level: level::INFO, text: String::new() },
    ])
}

fn write_messages(out: &Path) -> anyhow::Result<u64> {
    let msgs = messages()?;
    let mut bin = Vec::new();
    let mut entries = Vec::new();
    for m in &msgs {
        let bytes = m.to_bytes();
        let (name, fields) = describe(m);
        entries.push(json!({"kind": name, "type": m.kind(), "offset": bin.len(), "length": bytes.len(), "fields": fields}));
        bin.extend(bytes);
    }

    // Every message type is present, and the bytes decode back to the same messages.
    let mut kinds: Vec<u8> = msgs.iter().map(Message::kind).collect();
    kinds.sort_unstable();
    kinds.dedup();
    let all = [
        kind::HELLO,
        kind::WELCOME,
        kind::REJECT,
        kind::START,
        kind::SELECT_DISPLAY,
        kind::FRAME,
        kind::FRAME_ACK,
        kind::CURSOR_SHAPE,
        kind::CURSOR_POS,
        kind::DISPLAYS_CHANGED,
        kind::POINTER_MOVE,
        kind::POINTER_BUTTON,
        kind::SCROLL,
        kind::KEY,
        kind::RELEASE_ALL,
        kind::CLIPBOARD_TEXT,
        kind::PING,
        kind::PONG,
        kind::NOTICE,
    ];
    let mut all = all.to_vec();
    all.sort_unstable();
    anyhow::ensure!(kinds == all, "messages fixture misses a type");
    let mut src = &bin[..];
    for m in &msgs {
        let back = Message::read_from(&mut src, MAX_PAYLOAD)?;
        anyhow::ensure!(&back == m, "{m:?} does not round-trip");
    }
    if let Message::Frame { width, height, rects, .. } = &msgs[5] {
        Decoder::new().apply(*width, *height, rects)?;
    }

    let json = serde_json::to_string_pretty(&Value::Array(entries))? + "\n";
    std::fs::write(out.join("messages.bin"), &bin)?;
    std::fs::write(out.join("messages.json"), &json)?;
    println!("messages        {} messages, {} B", msgs.len(), bin.len());
    Ok((bin.len() + json.len()) as u64)
}
