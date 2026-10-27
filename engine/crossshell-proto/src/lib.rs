//! CrossShell remote-desktop wire protocol, tile codec and keymaps.
//!
//! The protocol is specified in `PLAN.md` ("Wire protocol"). This crate is
//! the single implementation both the host agent and the viewer link, so the
//! two ends can never drift apart.

pub mod codec;
pub mod keymap;
pub mod msg;

pub use codec::{Decoder, Encoder, FrameRef, LosslessCodec, Quality};
pub use msg::{DisplayInfo, Encoding, Message, MessageReader, Rect};

/// Protocol magic sent at the start of `Hello`.
pub const MAGIC: [u8; 4] = *b"CSRD";
/// Wire protocol version. Bump on any incompatible change.
pub const VERSION: u16 = 1;
/// Default loopback port of the host agent.
pub const DEFAULT_HOST_PORT: u16 = 47821;
/// Largest payload accepted after the handshake.
pub const MAX_PAYLOAD: u32 = 64 << 20;
/// Largest payload accepted before the token has been checked.
pub const MAX_PREAUTH_PAYLOAD: u32 = 1024;
/// Session token length in bytes.
pub const TOKEN_LEN: usize = 32;
/// Frames the host may have in flight without an ack.
pub const MAX_INFLIGHT_FRAMES: u32 = 2;

/// `Hello.caps` / `Welcome.caps` bit: the viewer decodes
/// [`Encoding::Deflate`] rects, and the host then sends lossless tiles as
/// zlib streams instead of zstd (for viewers without a zstd decoder).
pub const CAP_DEFLATE: u32 = 1 << 0;
/// Every capability bit this implementation understands. A host answers
/// `Welcome.caps = Hello.caps & HOST_CAPS`; unknown bits are ignored.
pub const HOST_CAPS: u32 = CAP_DEFLATE;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("i/o: {0}")]
    Io(#[from] std::io::Error),
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("codec: {0}")]
    Codec(String),
}

pub type Result<T> = std::result::Result<T, Error>;

pub(crate) fn proto_err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error::Protocol(msg.into()))
}

/// Constant-time token comparison.
pub fn token_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    // black_box keeps the optimizer from short-circuiting the fold.
    std::hint::black_box(diff) == 0
}

/// Lowercase hex encoding (tokens travel as hex in host.json and on stdin).
pub fn to_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}

/// Parse hex produced by [`to_hex`] (case-insensitive). Whitespace is trimmed.
pub fn from_hex(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return None;
    }
    let nib = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    };
    s.as_bytes()
        .chunks(2)
        .map(|p| Some(nib(p[0])? << 4 | nib(p[1])?))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trip() {
        let b = [0u8, 1, 0xab, 0xff, 0x10];
        assert_eq!(from_hex(&to_hex(&b)).unwrap(), b);
        assert_eq!(from_hex(" 0A ").unwrap(), [0x0a]);
        assert!(from_hex("abc").is_none());
        assert!(from_hex("zz").is_none());
    }

    #[test]
    fn token_eq_works() {
        assert!(token_eq(&[1, 2, 3], &[1, 2, 3]));
        assert!(!token_eq(&[1, 2, 3], &[1, 2, 4]));
        assert!(!token_eq(&[1, 2], &[1, 2, 3]));
    }
}
