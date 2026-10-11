//! Message framing: `u8 type | u32 len (LE) | payload`.
//!
//! Decoding never panics on hostile input: every read is bounds-checked and
//! every declared length is validated against what is actually present.

use std::io::{Read, Write};

use crate::{proto_err, Error, Result, MAGIC, MAX_PAYLOAD, TOKEN_LEN};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayInfo {
    pub index: u8,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub primary: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Encoding {
    Raw = 0,
    Zstd = 1,
    Jpeg = 2,
    Fill = 3,
}

impl Encoding {
    fn from_u8(v: u8) -> Result<Self> {
        Ok(match v {
            0 => Self::Raw,
            1 => Self::Zstd,
            2 => Self::Jpeg,
            3 => Self::Fill,
            _ => return proto_err(format!("unknown rect encoding {v}")),
        })
    }
}

/// One updated rectangle of a frame. Pixel data is BGRX.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
    pub encoding: Encoding,
    pub data: Vec<u8>,
}

impl Rect {
    const HEADER: usize = 2 * 4 + 1 + 4;
}

pub mod kind {
    pub const HELLO: u8 = 0x01;
    pub const WELCOME: u8 = 0x02;
    pub const REJECT: u8 = 0x03;
    pub const START: u8 = 0x10;
    pub const SELECT_DISPLAY: u8 = 0x11;
    pub const FRAME: u8 = 0x20;
    pub const FRAME_ACK: u8 = 0x21;
    pub const CURSOR_SHAPE: u8 = 0x22;
    pub const CURSOR_POS: u8 = 0x23;
    pub const DISPLAYS_CHANGED: u8 = 0x24;
    pub const POINTER_MOVE: u8 = 0x30;
    pub const POINTER_BUTTON: u8 = 0x31;
    pub const SCROLL: u8 = 0x32;
    pub const KEY: u8 = 0x33;
    pub const RELEASE_ALL: u8 = 0x34;
    pub const CLIPBOARD_TEXT: u8 = 0x40;
    pub const PING: u8 = 0x50;
    pub const PONG: u8 = 0x51;
    pub const NOTICE: u8 = 0x60;
}

/// Pointer buttons on the wire.
pub mod button {
    pub const LEFT: u8 = 1;
    pub const MIDDLE: u8 = 2;
    pub const RIGHT: u8 = 3;
    pub const BACK: u8 = 4;
    pub const FORWARD: u8 = 5;
}

/// Notice levels.
pub mod level {
    pub const INFO: u8 = 0;
    pub const WARN: u8 = 1;
    pub const ERROR: u8 = 2;
}

/// Largest clipboard text accepted.
pub const MAX_CLIPBOARD: usize = 1 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    Hello { version: u16, token: [u8; TOKEN_LEN], viewer_name: String, caps: u32 },
    Welcome { version: u16, caps: u32, displays: Vec<DisplayInfo> },
    Reject { reason: String },
    Start { display: u8, quality: u8, max_fps: u8, view_only: bool },
    SelectDisplay { display: u8, quality: u8, max_fps: u8 },
    Frame { seq: u32, width: u32, height: u32, rects: Vec<Rect> },
    FrameAck { seq: u32 },
    /// `width == 0 || height == 0` means the cursor is hidden.
    CursorShape { width: u16, height: u16, hot_x: u16, hot_y: u16, rgba: Vec<u8> },
    CursorPos { x: i32, y: i32 },
    DisplaysChanged { displays: Vec<DisplayInfo> },
    PointerMove { x: i32, y: i32 },
    PointerButton { button: u8, down: bool },
    /// In 1/120 wheel-notch units; positive `dy` scrolls up.
    Scroll { dx: i16, dy: i16 },
    /// Linux evdev keycode.
    Key { code: u16, down: bool },
    ReleaseAll,
    ClipboardText(String),
    Ping(u64),
    Pong(u64),
    Notice { level: u8, text: String },
}

// ---------------------------------------------------------------- encoding

struct Out(Vec<u8>);

impl Out {
    fn u8(&mut self, v: u8) {
        self.0.push(v);
    }
    fn u16(&mut self, v: u16) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn i16(&mut self, v: i16) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn i32(&mut self, v: i32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn bytes(&mut self, b: &[u8]) {
        self.0.extend_from_slice(b);
    }
    fn str(&mut self, s: &str) {
        // Strings are u16-length-prefixed; truncate on a char boundary.
        let mut end = s.len().min(u16::MAX as usize);
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        self.u16(end as u16);
        self.bytes(&s.as_bytes()[..end]);
    }
    fn displays(&mut self, d: &[DisplayInfo]) {
        self.u8(d.len().min(255) as u8);
        for d in d.iter().take(255) {
            self.u8(d.index);
            self.str(&d.name);
            self.i32(d.x);
            self.i32(d.y);
            self.u32(d.width);
            self.u32(d.height);
            self.u8(d.primary as u8);
        }
    }
}

impl Message {
    pub fn kind(&self) -> u8 {
        use kind::*;
        match self {
            Message::Hello { .. } => HELLO,
            Message::Welcome { .. } => WELCOME,
            Message::Reject { .. } => REJECT,
            Message::Start { .. } => START,
            Message::SelectDisplay { .. } => SELECT_DISPLAY,
            Message::Frame { .. } => FRAME,
            Message::FrameAck { .. } => FRAME_ACK,
            Message::CursorShape { .. } => CURSOR_SHAPE,
            Message::CursorPos { .. } => CURSOR_POS,
            Message::DisplaysChanged { .. } => DISPLAYS_CHANGED,
            Message::PointerMove { .. } => POINTER_MOVE,
            Message::PointerButton { .. } => POINTER_BUTTON,
            Message::Scroll { .. } => SCROLL,
            Message::Key { .. } => KEY,
            Message::ReleaseAll => RELEASE_ALL,
            Message::ClipboardText(_) => CLIPBOARD_TEXT,
            Message::Ping(_) => PING,
            Message::Pong(_) => PONG,
            Message::Notice { .. } => NOTICE,
        }
    }

    /// Serialize to a complete frame (header + payload).
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut o = Out(Vec::with_capacity(self.size_hint()));
        o.u8(self.kind());
        o.u32(0); // patched below
        match self {
            Message::Hello { version, token, viewer_name, caps } => {
                o.bytes(&MAGIC);
                o.u16(*version);
                o.bytes(token);
                o.str(viewer_name);
                o.u32(*caps);
            }
            Message::Welcome { version, caps, displays } => {
                o.u16(*version);
                o.u32(*caps);
                o.displays(displays);
            }
            Message::Reject { reason } => o.str(reason),
            Message::Start { display, quality, max_fps, view_only } => {
                o.u8(*display);
                o.u8(*quality);
                o.u8(*max_fps);
                o.u8(*view_only as u8);
            }
            Message::SelectDisplay { display, quality, max_fps } => {
                o.u8(*display);
                o.u8(*quality);
                o.u8(*max_fps);
            }
            Message::Frame { seq, width, height, rects } => {
                o.u32(*seq);
                o.u32(*width);
                o.u32(*height);
                o.u16(rects.len().min(u16::MAX as usize) as u16);
                for r in rects.iter().take(u16::MAX as usize) {
                    o.u16(r.x);
                    o.u16(r.y);
                    o.u16(r.w);
                    o.u16(r.h);
                    o.u8(r.encoding as u8);
                    o.u32(r.data.len() as u32);
                    o.bytes(&r.data);
                }
            }
            Message::FrameAck { seq } => o.u32(*seq),
            Message::CursorShape { width, height, hot_x, hot_y, rgba } => {
                o.u16(*width);
                o.u16(*height);
                o.u16(*hot_x);
                o.u16(*hot_y);
                o.bytes(rgba);
            }
            Message::CursorPos { x, y } | Message::PointerMove { x, y } => {
                o.i32(*x);
                o.i32(*y);
            }
            Message::DisplaysChanged { displays } => o.displays(displays),
            Message::PointerButton { button, down } => {
                o.u8(*button);
                o.u8(*down as u8);
            }
            Message::Scroll { dx, dy } => {
                o.i16(*dx);
                o.i16(*dy);
            }
            Message::Key { code, down } => {
                o.u16(*code);
                o.u8(*down as u8);
            }
            Message::ReleaseAll => {}
            Message::ClipboardText(t) => o.bytes(t.as_bytes()),
            Message::Ping(n) | Message::Pong(n) => o.u64(*n),
            Message::Notice { level, text } => {
                o.u8(*level);
                o.str(text);
            }
        }
        let len = (o.0.len() - 5) as u32;
        o.0[1..5].copy_from_slice(&len.to_le_bytes());
        o.0
    }

    fn size_hint(&self) -> usize {
        5 + match self {
            Message::Frame { rects, .. } => {
                14 + rects.iter().map(|r| Rect::HEADER + r.data.len()).sum::<usize>()
            }
            Message::CursorShape { rgba, .. } => 8 + rgba.len(),
            Message::ClipboardText(t) => t.len(),
            _ => 64,
        }
    }

    /// Write one message.
    pub fn write_to<W: Write>(&self, w: &mut W) -> Result<()> {
        w.write_all(&self.to_bytes())?;
        Ok(())
    }

    /// Read one message, refusing payloads larger than `max_payload`.
    pub fn read_from<R: Read>(r: &mut R, max_payload: u32) -> Result<Message> {
        let mut head = [0u8; 5];
        r.read_exact(&mut head)?;
        let kind = head[0];
        let len = u32::from_le_bytes([head[1], head[2], head[3], head[4]]);
        if len > max_payload.min(MAX_PAYLOAD) {
            return proto_err(format!("payload of {len} bytes for type {kind:#04x} exceeds limit"));
        }
        let mut payload = vec![0u8; len as usize];
        r.read_exact(&mut payload)?;
        Self::decode(kind, &payload)
    }

    /// Decode a payload of the given message type.
    pub fn decode(kind: u8, payload: &[u8]) -> Result<Message> {
        let mut c = In { b: payload, p: 0 };
        let m = match kind {
            kind::HELLO => {
                if c.take(4)? != MAGIC {
                    return proto_err("bad magic");
                }
                let version = c.u16()?;
                let mut token = [0u8; TOKEN_LEN];
                token.copy_from_slice(c.take(TOKEN_LEN)?);
                Message::Hello { version, token, viewer_name: c.str()?, caps: c.u32()? }
            }
            kind::WELCOME => Message::Welcome {
                version: c.u16()?,
                caps: c.u32()?,
                displays: c.displays()?,
            },
            kind::REJECT => Message::Reject { reason: c.str()? },
            kind::START => Message::Start {
                display: c.u8()?,
                quality: c.u8()?,
                max_fps: c.u8()?,
                view_only: c.u8()? & 1 == 1,
            },
            kind::SELECT_DISPLAY => Message::SelectDisplay {
                display: c.u8()?,
                quality: c.u8()?,
                max_fps: c.u8()?,
            },
            kind::FRAME => {
                let seq = c.u32()?;
                let width = c.u32()?;
                let height = c.u32()?;
                let n = c.u16()? as usize;
                // Each rect needs at least its header; reject absurd counts
                // before allocating.
                if n * Rect::HEADER > c.remaining() {
                    return proto_err("rect count exceeds payload");
                }
                let mut rects = Vec::with_capacity(n);
                for _ in 0..n {
                    let x = c.u16()?;
                    let y = c.u16()?;
                    let w = c.u16()?;
                    let h = c.u16()?;
                    let encoding = Encoding::from_u8(c.u8()?)?;
                    let len = c.u32()? as usize;
                    let data = c.take(len)?.to_vec();
                    rects.push(Rect { x, y, w, h, encoding, data });
                }
                Message::Frame { seq, width, height, rects }
            }
            kind::FRAME_ACK => Message::FrameAck { seq: c.u32()? },
            kind::CURSOR_SHAPE => {
                let width = c.u16()?;
                let height = c.u16()?;
                let hot_x = c.u16()?;
                let hot_y = c.u16()?;
                let need = width as usize * height as usize * 4;
                if width > 256 || height > 256 {
                    return proto_err("cursor larger than 256x256");
                }
                let rgba = c.take(need)?.to_vec();
                Message::CursorShape { width, height, hot_x, hot_y, rgba }
            }
            kind::CURSOR_POS => Message::CursorPos { x: c.i32()?, y: c.i32()? },
            kind::DISPLAYS_CHANGED => Message::DisplaysChanged { displays: c.displays()? },
            kind::POINTER_MOVE => Message::PointerMove { x: c.i32()?, y: c.i32()? },
            kind::POINTER_BUTTON => Message::PointerButton { button: c.u8()?, down: c.u8()? != 0 },
            kind::SCROLL => Message::Scroll { dx: c.i16()?, dy: c.i16()? },
            kind::KEY => Message::Key { code: c.u16()?, down: c.u8()? != 0 },
            kind::RELEASE_ALL => Message::ReleaseAll,
            kind::CLIPBOARD_TEXT => {
                if payload.len() > MAX_CLIPBOARD {
                    return proto_err("clipboard text too large");
                }
                let t = std::str::from_utf8(c.take(payload.len())?)
                    .map_err(|_| Error::Protocol("clipboard text is not utf-8".into()))?;
                Message::ClipboardText(t.to_owned())
            }
            kind::PING => Message::Ping(c.u64()?),
            kind::PONG => Message::Pong(c.u64()?),
            kind::NOTICE => Message::Notice { level: c.u8()?, text: c.str()? },
            other => return proto_err(format!("unknown message type {other:#04x}")),
        };
        if c.remaining() != 0 {
            return proto_err(format!("{} trailing bytes in message {kind:#04x}", c.remaining()));
        }
        Ok(m)
    }
}

/// Incremental message reader for sockets with a read timeout: bytes
/// accumulate across calls, so a timeout can never split a message. This
/// lets a reader loop wake up regularly (to notice it should stop) without
/// relying on `shutdown` to unblock a read, which Windows doesn't do.
pub struct MessageReader {
    buf: Vec<u8>,
    max_payload: u32,
}

impl MessageReader {
    pub fn new(max_payload: u32) -> Self {
        MessageReader { buf: Vec::new(), max_payload }
    }

    /// One read from `r`. `Ok(None)` = no complete message yet (including a
    /// read timeout); EOF is an `UnexpectedEof` I/O error.
    pub fn read<R: Read>(&mut self, r: &mut R) -> Result<Option<Message>> {
        if let Some(m) = self.take()? {
            return Ok(Some(m));
        }
        let mut chunk = [0u8; 16 * 1024];
        match r.read(&mut chunk) {
            Ok(0) => Err(Error::Io(std::io::ErrorKind::UnexpectedEof.into())),
            Ok(n) => {
                self.buf.extend_from_slice(&chunk[..n]);
                self.take()
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted
                ) =>
            {
                Ok(None)
            }
            Err(e) => Err(e.into()),
        }
    }

    fn take(&mut self) -> Result<Option<Message>> {
        if self.buf.len() < 5 {
            return Ok(None);
        }
        let kind = self.buf[0];
        let len = u32::from_le_bytes([self.buf[1], self.buf[2], self.buf[3], self.buf[4]]);
        if len > self.max_payload.min(MAX_PAYLOAD) {
            return proto_err(format!("payload of {len} bytes for type {kind:#04x} exceeds limit"));
        }
        let end = 5 + len as usize;
        if self.buf.len() < end {
            return Ok(None);
        }
        let m = Message::decode(kind, &self.buf[5..end]);
        self.buf.drain(..end);
        m.map(Some)
    }
}

struct In<'a> {
    b: &'a [u8],
    p: usize,
}

impl<'a> In<'a> {
    fn remaining(&self) -> usize {
        self.b.len() - self.p
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if n > self.remaining() {
            return proto_err("truncated message");
        }
        let s = &self.b[self.p..self.p + n];
        self.p += n;
        Ok(s)
    }
    fn arr<const N: usize>(&mut self) -> Result<[u8; N]> {
        let mut a = [0u8; N];
        a.copy_from_slice(self.take(N)?);
        Ok(a)
    }
    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.arr()?))
    }
    fn i16(&mut self) -> Result<i16> {
        Ok(i16::from_le_bytes(self.arr()?))
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.arr()?))
    }
    fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_le_bytes(self.arr()?))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.arr()?))
    }
    fn str(&mut self) -> Result<String> {
        let n = self.u16()? as usize;
        let b = self.take(n)?;
        String::from_utf8(b.to_vec()).map_err(|_| Error::Protocol("string is not utf-8".into()))
    }
    fn displays(&mut self) -> Result<Vec<DisplayInfo>> {
        let n = self.u8()? as usize;
        let mut v = Vec::with_capacity(n);
        for _ in 0..n {
            v.push(DisplayInfo {
                index: self.u8()?,
                name: self.str()?,
                x: self.i32()?,
                y: self.i32()?,
                width: self.u32()?,
                height: self.u32()?,
                primary: self.u8()? != 0,
            });
        }
        Ok(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(m: Message) {
        let bytes = m.to_bytes();
        let back = Message::read_from(&mut &bytes[..], MAX_PAYLOAD).unwrap();
        assert_eq!(back, m);
    }

    fn display(i: u8) -> DisplayInfo {
        DisplayInfo {
            index: i,
            name: format!("Monitor {i} — ünïcode"),
            x: -1920,
            y: 0,
            width: 1920,
            height: 1080,
            primary: i == 0,
        }
    }

    #[test]
    fn every_message_round_trips() {
        round_trip(Message::Hello {
            version: 1,
            token: [7; TOKEN_LEN],
            viewer_name: "linux-pc".into(),
            caps: 0xdead_beef,
        });
        round_trip(Message::Welcome { version: 1, caps: 3, displays: vec![display(0), display(1)] });
        round_trip(Message::Reject { reason: "bad token".into() });
        round_trip(Message::Start { display: 1, quality: 2, max_fps: 30, view_only: true });
        round_trip(Message::SelectDisplay { display: 0, quality: 1, max_fps: 60 });
        round_trip(Message::Frame {
            seq: 9,
            width: 1920,
            height: 1080,
            rects: vec![
                Rect { x: 0, y: 64, w: 64, h: 64, encoding: Encoding::Fill, data: vec![1, 2, 3, 0] },
                Rect { x: 64, y: 0, w: 2, h: 1, encoding: Encoding::Raw, data: vec![9; 8] },
            ],
        });
        round_trip(Message::FrameAck { seq: u32::MAX });
        round_trip(Message::CursorShape { width: 2, height: 2, hot_x: 1, hot_y: 0, rgba: vec![255; 16] });
        round_trip(Message::CursorShape { width: 0, height: 0, hot_x: 0, hot_y: 0, rgba: vec![] });
        round_trip(Message::CursorPos { x: -5, y: 700 });
        round_trip(Message::DisplaysChanged { displays: vec![display(3)] });
        round_trip(Message::PointerMove { x: 10, y: 20 });
        round_trip(Message::PointerButton { button: button::RIGHT, down: true });
        round_trip(Message::Scroll { dx: -120, dy: 240 });
        round_trip(Message::Key { code: 30, down: false });
        round_trip(Message::ReleaseAll);
        round_trip(Message::ClipboardText("héllo\nworld".into()));
        round_trip(Message::Ping(123456789));
        round_trip(Message::Pong(u64::MAX));
        round_trip(Message::Notice { level: level::WARN, text: "screen locked".into() });
    }

    #[test]
    fn oversized_payload_is_rejected_before_allocation() {
        let mut bytes = vec![kind::HELLO];
        bytes.extend_from_slice(&(10_000u32).to_le_bytes());
        let err = Message::read_from(&mut &bytes[..], crate::MAX_PREAUTH_PAYLOAD).unwrap_err();
        assert!(matches!(err, Error::Protocol(_)));
    }

    #[test]
    fn truncated_and_trailing_payloads_are_errors() {
        let full = Message::Key { code: 1, down: true }.to_bytes();
        assert!(Message::decode(kind::KEY, &full[5..full.len() - 1]).is_err());
        let mut extra = full[5..].to_vec();
        extra.push(0);
        assert!(Message::decode(kind::KEY, &extra).is_err());
        assert!(Message::decode(0xEE, &[]).is_err());
    }

    #[test]
    fn hostile_rect_counts_do_not_allocate() {
        // Claims 65535 rects in a 14-byte payload.
        let mut p = Vec::new();
        p.extend_from_slice(&1u32.to_le_bytes());
        p.extend_from_slice(&1u32.to_le_bytes());
        p.extend_from_slice(&1u32.to_le_bytes());
        p.extend_from_slice(&u16::MAX.to_le_bytes());
        assert!(Message::decode(kind::FRAME, &p).is_err());
    }

    #[test]
    fn message_reader_survives_timeouts_mid_message() {
        // A reader that returns one byte at a time and times out in between.
        struct Trickle {
            data: Vec<u8>,
            pos: usize,
            tick: bool,
        }
        impl Read for Trickle {
            fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
                self.tick = !self.tick;
                if self.tick {
                    return Err(std::io::ErrorKind::WouldBlock.into());
                }
                if self.pos == self.data.len() {
                    return Ok(0);
                }
                out[0] = self.data[self.pos];
                self.pos += 1;
                Ok(1)
            }
        }
        let a = Message::Key { code: 30, down: true };
        let b = Message::ClipboardText("hi".into());
        let mut data = a.to_bytes();
        data.extend(b.to_bytes());
        let mut src = Trickle { data, pos: 0, tick: false };
        let mut rd = MessageReader::new(MAX_PAYLOAD);
        let mut got = Vec::new();
        loop {
            match rd.read(&mut src) {
                Ok(Some(m)) => got.push(m),
                Ok(None) => {}
                Err(Error::Io(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => panic!("{e}"),
            }
        }
        assert_eq!(got, vec![a, b]);
    }

    #[test]
    fn message_reader_enforces_the_limit() {
        let bytes = Message::ClipboardText("x".repeat(100)).to_bytes();
        let mut rd = MessageReader::new(10);
        assert!(rd.read(&mut &bytes[..]).is_err());
    }

    #[test]
    fn bad_magic_is_rejected() {
        let mut b = Message::Hello { version: 1, token: [0; 32], viewer_name: String::new(), caps: 0 }
            .to_bytes();
        b[5] = b'X';
        assert!(Message::read_from(&mut &b[..], MAX_PAYLOAD).is_err());
    }

    #[test]
    fn decoding_garbage_never_panics() {
        // Cheap deterministic fuzz over every message type.
        let mut seed = 0x1234_5678u32;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        for _ in 0..20_000 {
            let kind = (next() & 0x7f) as u8;
            let len = (next() % 96) as usize;
            let payload: Vec<u8> = (0..len).map(|_| next() as u8).collect();
            let _ = Message::decode(kind, &payload);
        }
    }

    #[test]
    fn long_strings_truncate_on_char_boundary() {
        let s = "é".repeat(40_000); // 80_000 bytes
        let m = Message::Reject { reason: s };
        let b = m.to_bytes();
        match Message::read_from(&mut &b[..], MAX_PAYLOAD).unwrap() {
            Message::Reject { reason } => assert!(reason.len() <= u16::MAX as usize),
            _ => unreachable!(),
        }
    }
}
