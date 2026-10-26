//! Tile codec (see PLAN.md "Tile codec").
//!
//! The encoder diffs each captured frame against the last frame it encoded,
//! in 64×64 tiles, and picks an encoding per tile: `Fill` for flat tiles,
//! zstd (or zlib, see [`LosslessCodec`]) for few-colour tiles (text, UI
//! chrome — stays pixel-exact), JPEG for photographic tiles when the quality
//! allows it. Lossy tiles that then stay still are re-sent losslessly
//! ("refinement") so a static screen always ends up pixel-exact.

use std::io::Write;

use rayon::prelude::*;

use crate::msg::{Encoding, Rect};
use crate::{Error, Result, CAP_DEFLATE};

pub const TILE: u32 = 64;
/// Widest rect produced by merging a run of same-class tiles.
const MAX_MERGED_WIDTH: u32 = 512;
/// Distinct (sampled) colours above which a tile counts as photographic.
const PHOTO_COLORS: usize = 48;
/// Encode calls a lossy tile must stay unchanged before it is refined.
const REFINE_AFTER: u8 = 3;
/// Largest frame dimension either end accepts.
pub const MAX_DIMENSION: u32 = 16_384;
/// zlib level for [`LosslessCodec::Deflate`]: miniz_oxide's fast greedy
/// path, close to zstd level 1 in speed.
const DEFLATE_LEVEL: u32 = 1;

/// How the encoder compresses lossless (non-fill, non-JPEG) tiles. Both
/// carry the same bytes: the rect's BGRX pixels, rows top to bottom.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LosslessCodec {
    /// [`Encoding::Zstd`], level 1. What every viewer decodes.
    #[default]
    Zstd,
    /// [`Encoding::Deflate`]: a zlib stream (RFC 1950). Only for viewers that
    /// negotiated [`CAP_DEFLATE`].
    Deflate,
}

impl LosslessCodec {
    /// The codec for a session whose negotiated `Welcome.caps` are `caps`.
    pub fn for_caps(caps: u32) -> Self {
        if caps & CAP_DEFLATE != 0 {
            LosslessCodec::Deflate
        } else {
            LosslessCodec::Zstd
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quality {
    Lossless = 0,
    Balanced = 1,
    Speed = 2,
}

impl Quality {
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Quality::Lossless,
            2 => Quality::Speed,
            _ => Quality::Balanced,
        }
    }

    fn jpeg_quality(self) -> Option<u8> {
        match self {
            Quality::Lossless => None,
            Quality::Balanced => Some(80),
            Quality::Speed => Some(60),
        }
    }
}

/// A borrowed BGRX frame. `stride` is in bytes and may exceed `width * 4`.
#[derive(Debug, Clone, Copy)]
pub struct FrameRef<'a> {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub data: &'a [u8],
}

impl<'a> FrameRef<'a> {
    pub fn new(width: u32, height: u32, stride: usize, data: &'a [u8]) -> Result<Self> {
        if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
            return Err(Error::Codec(format!("bad frame size {width}x{height}")));
        }
        if stride < width as usize * 4 || data.len() < stride * (height as usize - 1) + width as usize * 4 {
            return Err(Error::Codec("frame buffer too small for its size/stride".into()));
        }
        Ok(FrameRef { width, height, stride, data })
    }

    #[inline]
    fn row(&self, y: u32, x: u32, w: u32) -> &'a [u8] {
        let start = y as usize * self.stride + x as usize * 4;
        &self.data[start..start + w as usize * 4]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Fill([u8; 4]),
    Lossless,
    Photo,
}

pub struct Encoder {
    quality: Quality,
    lossless: LosslessCodec,
    width: u32,
    height: u32,
    /// Last encoded frame, tightly packed BGRX. Empty = send everything.
    prev: Vec<u8>,
    /// Per tile: 0 = exact on the viewer, n>0 = lossy and unchanged for n-1 encodes.
    lossy_age: Vec<u8>,
}

impl Encoder {
    pub fn new(quality: Quality) -> Self {
        Encoder {
            quality,
            lossless: LosslessCodec::Zstd,
            width: 0,
            height: 0,
            prev: Vec::new(),
            lossy_age: Vec::new(),
        }
    }

    /// Compress lossless tiles with `codec` instead of zstd.
    pub fn with_lossless_codec(mut self, codec: LosslessCodec) -> Self {
        self.lossless = codec;
        self
    }

    pub fn quality(&self) -> Quality {
        self.quality
    }

    pub fn lossless_codec(&self) -> LosslessCodec {
        self.lossless
    }

    /// Change quality; the next encode resends the whole frame.
    pub fn set_quality(&mut self, quality: Quality) {
        if quality != self.quality {
            self.quality = quality;
            self.reset();
        }
    }

    /// Forget the previous frame so the next encode is a full refresh.
    pub fn reset(&mut self) {
        self.prev.clear();
    }

    /// True while some lossy tiles still wait for their lossless refresh.
    /// The host should keep calling [`encode`](Self::encode) with the latest
    /// frame (every ~250 ms) until this turns false.
    pub fn needs_refinement(&self) -> bool {
        self.lossy_age.iter().any(|&a| a > 0)
    }

    fn tiles_x(&self) -> u32 {
        self.width.div_ceil(TILE)
    }

    /// Encode `frame` as the rects that changed since the previous call.
    /// Returns an empty vec when nothing changed.
    pub fn encode(&mut self, frame: &FrameRef) -> Vec<Rect> {
        let full = self.prev.is_empty() || frame.width != self.width || frame.height != self.height;
        if full {
            self.width = frame.width;
            self.height = frame.height;
            self.prev = vec![0; (frame.width * frame.height * 4) as usize];
            self.lossy_age = vec![0; (self.tiles_x() * frame.height.div_ceil(TILE)) as usize];
        }
        let (tx_n, ty_n) = (self.tiles_x(), frame.height.div_ceil(TILE));
        let quality = self.quality;
        let prev = &self.prev;
        let width = self.width;
        let lossy_age = &self.lossy_age;

        // Classify every tile in parallel: None = skip.
        let jobs: Vec<Option<Class>> = (0..tx_n * ty_n)
            .into_par_iter()
            .map(|i| {
                let (tx, ty) = (i % tx_n, i / tx_n);
                let (x, y, w, h) = tile_rect(tx, ty, frame.width, frame.height);
                let dirty = full || tile_differs(frame, prev, width, x, y, w, h);
                let refine = !dirty && lossy_age[i as usize] >= REFINE_AFTER;
                if !dirty && !refine {
                    return None;
                }
                Some(if refine { Class::Lossless } else { classify(frame, x, y, w, h, quality) })
            })
            .collect();

        // Ageing: dirty tiles get their new state below, untouched lossy
        // tiles grow older.
        for (i, job) in jobs.iter().enumerate() {
            match job {
                Some(class) => self.lossy_age[i] = if *class == Class::Photo { 1 } else { 0 },
                None if self.lossy_age[i] > 0 => {
                    self.lossy_age[i] = self.lossy_age[i].saturating_add(1)
                }
                None => {}
            }
        }

        // Merge horizontal runs of same-class tiles into wider rects.
        let mut spans: Vec<(u32, u32, u32, Class)> = Vec::new(); // (ty, tx0, tx1 excl, class)
        for ty in 0..ty_n {
            let mut tx = 0;
            while tx < tx_n {
                let Some(class) = jobs[(ty * tx_n + tx) as usize] else {
                    tx += 1;
                    continue;
                };
                let mut end = tx + 1;
                if !matches!(class, Class::Fill(_)) {
                    while end < tx_n
                        && (end - tx + 1) * TILE <= MAX_MERGED_WIDTH
                        && jobs[(ty * tx_n + end) as usize] == Some(class)
                    {
                        end += 1;
                    }
                }
                spans.push((ty, tx, end, class));
                tx = end;
            }
        }

        let jpeg_q = quality.jpeg_quality().unwrap_or(90);
        let codec = self.lossless;
        let rects: Vec<Rect> = spans
            .into_par_iter()
            .map(|(ty, tx0, tx1, class)| {
                let (x, y, _, h) = tile_rect(tx0, ty, frame.width, frame.height);
                let x_end = (tx1 * TILE).min(frame.width);
                let w = x_end - x;
                encode_rect(frame, x, y, w, h, class, jpeg_q, codec)
            })
            .collect();

        // Remember what the viewer now has (source pixels).
        if !rects.is_empty() {
            let row_bytes = (frame.width * 4) as usize;
            for y in 0..frame.height {
                let dst = &mut self.prev[y as usize * row_bytes..][..row_bytes];
                dst.copy_from_slice(frame.row(y, 0, frame.width));
            }
        }
        rects
    }
}

fn tile_rect(tx: u32, ty: u32, fw: u32, fh: u32) -> (u32, u32, u32, u32) {
    let x = tx * TILE;
    let y = ty * TILE;
    (x, y, TILE.min(fw - x), TILE.min(fh - y))
}

fn tile_differs(f: &FrameRef, prev: &[u8], width: u32, x: u32, y: u32, w: u32, h: u32) -> bool {
    let row_bytes = (width * 4) as usize;
    (y..y + h).any(|yy| {
        let p = &prev[yy as usize * row_bytes + x as usize * 4..][..w as usize * 4];
        f.row(yy, x, w) != p
    })
}

#[inline]
fn px(b: &[u8]) -> u32 {
    // BGRX → 0x00RRGGBB, ignoring the X byte (capture APIs leave junk there).
    u32::from_le_bytes([b[0], b[1], b[2], 0])
}

fn classify(f: &FrameRef, x: u32, y: u32, w: u32, h: u32, q: Quality) -> Class {
    let first = px(f.row(y, x, 1));
    let uniform = (y..y + h).all(|yy| f.row(yy, x, w).chunks_exact(4).all(|p| px(p) == first));
    if uniform {
        let [b, g, r, _] = first.to_le_bytes();
        return Class::Fill([b, g, r, 0]);
    }
    if q == Quality::Lossless {
        return Class::Lossless;
    }
    // Sparse distinct-colour count with early exit.
    let mut seen = [0u32; PHOTO_COLORS + 1];
    let mut n = 0usize;
    for yy in (y..y + h).step_by(3) {
        for p in f.row(yy, x, w).chunks_exact(4).step_by(3) {
            let c = px(p);
            if !seen[..n].contains(&c) {
                if n == PHOTO_COLORS {
                    return Class::Photo;
                }
                seen[n] = c;
                n += 1;
            }
        }
    }
    Class::Lossless
}

fn gather(f: &FrameRef, x: u32, y: u32, w: u32, h: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity((w * h * 4) as usize);
    for yy in y..y + h {
        out.extend_from_slice(f.row(yy, x, w));
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn encode_rect(f: &FrameRef, x: u32, y: u32, w: u32, h: u32, class: Class, jpeg_q: u8, codec: LosslessCodec) -> Rect {
    let mk = |encoding, data| Rect { x: x as u16, y: y as u16, w: w as u16, h: h as u16, encoding, data };
    match class {
        Class::Fill(c) => mk(Encoding::Fill, c.to_vec()),
        Class::Photo => {
            let raw = gather(f, x, y, w, h);
            let mut out = Vec::with_capacity(raw.len() / 8);
            let enc = jpeg_encoder::Encoder::new(&mut out, jpeg_q);
            match enc.encode(&raw, w as u16, h as u16, jpeg_encoder::ColorType::Bgra) {
                Ok(()) => mk(Encoding::Jpeg, out),
                Err(_) => lossless(mk, raw, codec),
            }
        }
        Class::Lossless => lossless(mk, gather(f, x, y, w, h), codec),
    }
}

/// Compressed with `codec`, or `Raw` when that would not be smaller.
fn lossless(mk: impl Fn(Encoding, Vec<u8>) -> Rect, raw: Vec<u8>, codec: LosslessCodec) -> Rect {
    let packed = match codec {
        LosslessCodec::Zstd => zstd::bulk::compress(&raw, 1).ok().map(|z| (Encoding::Zstd, z)),
        LosslessCodec::Deflate => deflate(&raw).map(|z| (Encoding::Deflate, z)),
    };
    match packed {
        Some((encoding, z)) if z.len() < raw.len() => mk(encoding, z),
        _ => mk(Encoding::Raw, raw),
    }
}

/// One complete zlib stream (header, deflate data, Adler-32 trailer).
fn deflate(raw: &[u8]) -> Option<Vec<u8>> {
    let mut z = flate2::write::ZlibEncoder::new(
        Vec::with_capacity(raw.len() / 4 + 64),
        flate2::Compression::new(DEFLATE_LEVEL),
    );
    z.write_all(raw).ok()?;
    z.finish().ok()
}

/// Inflate exactly one zlib stream that must decode to `expect` bytes. The
/// output buffer is capped, so a hostile stream cannot inflate past it, and
/// trailing bytes after the stream are an error.
fn inflate(data: &[u8], expect: usize) -> Option<Vec<u8>> {
    let mut d = flate2::Decompress::new(true);
    // One spare byte tells "too long" apart from "exactly right".
    let mut out = Vec::with_capacity(expect + 1);
    match d.decompress_vec(data, &mut out, flate2::FlushDecompress::Finish) {
        Ok(flate2::Status::StreamEnd) if out.len() == expect && d.total_in() == data.len() as u64 => Some(out),
        _ => None,
    }
}

// ------------------------------------------------------------------ decoder

/// Viewer-side framebuffer. Pixels are `0x00RRGGBB` (softbuffer layout).
#[derive(Default)]
pub struct Decoder {
    width: u32,
    height: u32,
    pixels: Vec<u32>,
}

impl Decoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn pixels(&self) -> &[u32] {
        &self.pixels
    }

    /// Apply one `Frame` message. A size change clears the buffer to black.
    pub fn apply(&mut self, width: u32, height: u32, rects: &[Rect]) -> Result<()> {
        if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
            return Err(Error::Codec(format!("bad frame size {width}x{height}")));
        }
        if width != self.width || height != self.height {
            self.width = width;
            self.height = height;
            self.pixels = vec![0; (width * height) as usize];
        }
        for r in rects {
            if r.w == 0 || r.h == 0 || r.x as u32 + r.w as u32 > width || r.y as u32 + r.h as u32 > height {
                return Err(Error::Codec(format!(
                    "rect {}x{}+{}+{} outside {width}x{height}",
                    r.w, r.h, r.x, r.y
                )));
            }
        }
        let decoded: Vec<Vec<u32>> = rects.par_iter().map(decode_rect).collect::<Result<_>>()?;
        for (r, px) in rects.iter().zip(decoded) {
            let w = r.w as usize;
            for row in 0..r.h as usize {
                let dst = (r.y as usize + row) * width as usize + r.x as usize;
                self.pixels[dst..dst + w].copy_from_slice(&px[row * w..row * w + w]);
            }
        }
        Ok(())
    }
}

fn bgrx_to_u32(b: &[u8]) -> Vec<u32> {
    b.chunks_exact(4).map(|p| u32::from_le_bytes([p[0], p[1], p[2], 0])).collect()
}

fn decode_rect(r: &Rect) -> Result<Vec<u32>> {
    let n = r.w as usize * r.h as usize;
    let bad = |what: &str| Error::Codec(format!("{what} in {:?} rect", r.encoding));
    match r.encoding {
        Encoding::Fill => {
            if r.data.len() != 4 {
                return Err(bad("fill colour is not 4 bytes"));
            }
            Ok(vec![u32::from_le_bytes([r.data[0], r.data[1], r.data[2], 0]); n])
        }
        Encoding::Raw => {
            if r.data.len() != n * 4 {
                return Err(bad("wrong data length"));
            }
            Ok(bgrx_to_u32(&r.data))
        }
        Encoding::Zstd => {
            let raw = zstd::bulk::decompress(&r.data, n * 4).map_err(|_| bad("corrupt zstd"))?;
            if raw.len() != n * 4 {
                return Err(bad("wrong decompressed length"));
            }
            Ok(bgrx_to_u32(&raw))
        }
        Encoding::Deflate => {
            let raw = inflate(&r.data, n * 4).ok_or_else(|| bad("corrupt or wrong-length zlib stream"))?;
            Ok(bgrx_to_u32(&raw))
        }
        Encoding::Jpeg => {
            use zune_core::bytestream::ZCursor;
            use zune_core::colorspace::ColorSpace;
            use zune_core::options::DecoderOptions;
            let opts = DecoderOptions::default()
                .jpeg_set_out_colorspace(ColorSpace::RGB)
                .set_max_width(r.w as usize)
                .set_max_height(r.h as usize);
            let mut d = zune_jpeg::JpegDecoder::new_with_options(ZCursor::new(&r.data[..]), opts);
            let rgb = d.decode().map_err(|_| bad("corrupt jpeg"))?;
            let info = d.info().ok_or_else(|| bad("jpeg without header"))?;
            if info.width as usize != r.w as usize || info.height as usize != r.h as usize || rgb.len() != n * 3 {
                return Err(bad("jpeg size mismatch"));
            }
            Ok(rgb.chunks_exact(3).map(|p| u32::from_le_bytes([p[2], p[1], p[0], 0])).collect())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic test image: flat background, a "text" area of two
    /// colours and a noisy "photo" area.
    fn image(w: u32, h: u32, seed: u32) -> Vec<u8> {
        let mut v = vec![0u8; (w * h * 4) as usize];
        let mut s = seed | 1;
        for y in 0..h {
            for x in 0..w {
                let i = ((y * w + x) * 4) as usize;
                let (b, g, r) = if x < w / 3 {
                    (200, 180, 160)
                } else if x < 2 * w / 3 {
                    if (x / 3 + y / 5) % 2 == 0 { (0, 0, 0) } else { (255, 255, 255) }
                } else {
                    s ^= s << 13;
                    s ^= s >> 17;
                    s ^= s << 5;
                    (s as u8, (s >> 8) as u8, (s >> 16) as u8)
                };
                v[i..i + 4].copy_from_slice(&[b, g, r, 0xff]);
            }
        }
        v
    }

    fn to_u32(v: &[u8]) -> Vec<u32> {
        bgrx_to_u32(v)
    }

    #[test]
    fn lossless_round_trip_is_exact() {
        let (w, h) = (300, 170); // not tile multiples
        let img = image(w, h, 7);
        let mut enc = Encoder::new(Quality::Lossless);
        let mut dec = Decoder::new();
        let rects = enc.encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
        assert!(!rects.is_empty());
        assert!(rects.iter().all(|r| r.encoding != Encoding::Jpeg));
        dec.apply(w, h, &rects).unwrap();
        assert_eq!(dec.pixels(), &to_u32(&img)[..]);
    }

    #[test]
    fn unchanged_frame_encodes_to_nothing() {
        let (w, h) = (256, 128);
        let img = image(w, h, 1);
        let f = FrameRef::new(w, h, (w * 4) as usize, &img).unwrap();
        let mut enc = Encoder::new(Quality::Lossless);
        assert!(!enc.encode(&f).is_empty());
        assert!(enc.encode(&f).is_empty());
    }

    #[test]
    fn only_dirty_tiles_are_sent() {
        let (w, h) = (640, 320);
        let mut img = image(w, h, 3);
        let mut enc = Encoder::new(Quality::Lossless);
        let mut dec = Decoder::new();
        dec.apply(w, h, &enc.encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap())).unwrap();
        // Change one pixel in tile (1, 2).
        let i = ((130 * w + 70) * 4) as usize;
        img[i] ^= 0xff;
        let rects = enc.encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
        assert_eq!(rects.len(), 1);
        assert_eq!((rects[0].x, rects[0].y, rects[0].w, rects[0].h), (64, 128, 64, 64));
        dec.apply(w, h, &rects).unwrap();
        assert_eq!(dec.pixels(), &to_u32(&img)[..]);
    }

    #[test]
    fn padded_stride_is_honoured() {
        let (w, h) = (100, 70);
        let img = image(w, h, 5);
        let stride = (w * 4 + 64) as usize;
        let mut padded = vec![0xAAu8; stride * h as usize];
        for y in 0..h as usize {
            padded[y * stride..y * stride + (w * 4) as usize]
                .copy_from_slice(&img[y * (w * 4) as usize..(y + 1) * (w * 4) as usize]);
        }
        let mut enc = Encoder::new(Quality::Lossless);
        let mut dec = Decoder::new();
        dec.apply(w, h, &enc.encode(&FrameRef::new(w, h, stride, &padded).unwrap())).unwrap();
        assert_eq!(dec.pixels(), &to_u32(&img)[..]);
    }

    #[test]
    fn balanced_uses_jpeg_for_photos_and_refines_to_exact() {
        let (w, h) = (384, 192);
        let img = image(w, h, 11);
        let f = FrameRef::new(w, h, (w * 4) as usize, &img).unwrap();
        let mut enc = Encoder::new(Quality::Balanced);
        let mut dec = Decoder::new();
        let first = enc.encode(&f);
        assert!(first.iter().any(|r| r.encoding == Encoding::Jpeg), "photo area should be jpeg");
        assert!(first.iter().any(|r| r.encoding == Encoding::Fill), "flat area should be fill");
        assert!(first.iter().any(|r| r.encoding == Encoding::Zstd), "text area should be zstd");
        dec.apply(w, h, &first).unwrap();
        assert_ne!(dec.pixels(), &to_u32(&img)[..]);
        assert!(enc.needs_refinement());
        // Static screen: after REFINE_AFTER encodes, lossy tiles are resent exactly.
        for _ in 0..REFINE_AFTER + 1 {
            let rects = enc.encode(&f);
            assert!(rects.iter().all(|r| r.encoding != Encoding::Jpeg));
            dec.apply(w, h, &rects).unwrap();
        }
        assert!(!enc.needs_refinement());
        assert_eq!(dec.pixels(), &to_u32(&img)[..]);
    }

    #[test]
    fn resize_forces_full_frame() {
        let mut enc = Encoder::new(Quality::Lossless);
        let a = image(128, 128, 1);
        let b = image(192, 64, 1);
        enc.encode(&FrameRef::new(128, 128, 512, &a).unwrap());
        let rects = enc.encode(&FrameRef::new(192, 64, 768, &b).unwrap());
        let area: u32 = rects.iter().map(|r| r.w as u32 * r.h as u32).sum();
        assert_eq!(area, 192 * 64);
    }

    #[test]
    fn decoder_rejects_out_of_bounds_and_corrupt_rects() {
        let mut dec = Decoder::new();
        let oob = Rect { x: 60, y: 0, w: 10, h: 1, encoding: Encoding::Fill, data: vec![0; 4] };
        assert!(dec.apply(64, 64, &[oob]).is_err());
        let short = Rect { x: 0, y: 0, w: 2, h: 2, encoding: Encoding::Raw, data: vec![0; 15] };
        assert!(dec.apply(64, 64, &[short]).is_err());
        let junk = Rect { x: 0, y: 0, w: 2, h: 2, encoding: Encoding::Zstd, data: vec![1, 2, 3] };
        assert!(dec.apply(64, 64, &[junk]).is_err());
        let jpeg = Rect { x: 0, y: 0, w: 2, h: 2, encoding: Encoding::Jpeg, data: vec![0xff, 0xd8, 0] };
        assert!(dec.apply(64, 64, &[jpeg]).is_err());
        assert!(dec.apply(0, 64, &[]).is_err());
        assert!(dec.apply(MAX_DIMENSION + 1, 1, &[]).is_err());
    }

    #[test]
    fn frame_ref_validates_buffer() {
        assert!(FrameRef::new(10, 10, 40, &[0; 399]).is_err());
        assert!(FrameRef::new(10, 10, 39, &[0; 400]).is_err());
        assert!(FrameRef::new(10, 10, 40, &[0; 400]).is_ok());
    }

    fn deflate_encoder(q: Quality) -> Encoder {
        Encoder::new(q).with_lossless_codec(LosslessCodec::Deflate)
    }

    #[test]
    fn codec_follows_the_negotiated_caps() {
        assert_eq!(LosslessCodec::for_caps(0), LosslessCodec::Zstd);
        assert_eq!(LosslessCodec::for_caps(CAP_DEFLATE), LosslessCodec::Deflate);
        assert_eq!(LosslessCodec::for_caps(!0), LosslessCodec::Deflate);
        assert_eq!(LosslessCodec::for_caps(!CAP_DEFLATE), LosslessCodec::Zstd);
        assert_eq!(Encoder::new(Quality::Lossless).lossless_codec(), LosslessCodec::Zstd);
    }

    #[test]
    fn default_encoder_never_sends_deflate() {
        let (w, h) = (300, 170);
        let img = image(w, h, 7);
        for q in [Quality::Lossless, Quality::Balanced] {
            let rects = Encoder::new(q).encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
            assert!(rects.iter().any(|r| r.encoding == Encoding::Zstd));
            assert!(rects.iter().all(|r| r.encoding != Encoding::Deflate));
        }
    }

    #[test]
    fn deflate_round_trip_is_exact() {
        let (w, h) = (300, 170); // not tile multiples
        let img = image(w, h, 7);
        let mut enc = deflate_encoder(Quality::Lossless);
        let mut dec = Decoder::new();
        let rects = enc.encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
        assert!(rects.iter().any(|r| r.encoding == Encoding::Deflate));
        assert!(rects.iter().all(|r| r.encoding != Encoding::Zstd && r.encoding != Encoding::Jpeg));
        dec.apply(w, h, &rects).unwrap();
        assert_eq!(dec.pixels(), &to_u32(&img)[..]);
    }

    #[test]
    fn deflate_payload_is_a_plain_zlib_stream_of_the_rect_pixels() {
        use std::io::Read;
        let (w, h) = (200, 100);
        let img = image(w, h, 13);
        let f = FrameRef::new(w, h, (w * 4) as usize, &img).unwrap();
        let rects = deflate_encoder(Quality::Lossless).encode(&f);
        let mut checked = 0;
        for r in rects.iter().filter(|r| r.encoding == Encoding::Deflate) {
            // RFC 1950 header: CM = 8 (deflate), header checksum.
            assert_eq!(r.data[0] & 0x0f, 8);
            assert_eq!(u16::from_be_bytes([r.data[0], r.data[1]]) % 31, 0);
            let mut raw = Vec::new();
            flate2::read::ZlibDecoder::new(&r.data[..]).read_to_end(&mut raw).unwrap();
            // Exactly the rect's BGRX rows, X bytes included.
            assert_eq!(raw, gather(&f, r.x.into(), r.y.into(), r.w.into(), r.h.into()));
            checked += 1;
        }
        assert!(checked > 0);
    }

    #[test]
    fn deflate_balanced_refines_to_exact_without_zstd() {
        let (w, h) = (384, 192);
        let img = image(w, h, 11);
        let f = FrameRef::new(w, h, (w * 4) as usize, &img).unwrap();
        let mut enc = deflate_encoder(Quality::Balanced);
        let mut dec = Decoder::new();
        let first = enc.encode(&f);
        assert!(first.iter().any(|r| r.encoding == Encoding::Jpeg));
        assert!(first.iter().any(|r| r.encoding == Encoding::Deflate));
        dec.apply(w, h, &first).unwrap();
        while enc.needs_refinement() {
            let rects = enc.encode(&f);
            assert!(rects.iter().all(|r| !matches!(r.encoding, Encoding::Jpeg | Encoding::Zstd)));
            dec.apply(w, h, &rects).unwrap();
        }
        assert_eq!(dec.pixels(), &to_u32(&img)[..]);
    }

    #[test]
    fn incompressible_tiles_fall_back_to_raw() {
        // Pure noise does not shrink under zlib level 1.
        let (w, h) = (64, 64);
        let mut s = 0x9e37_79b9u32;
        let img: Vec<u8> = (0..w * h * 4)
            .map(|_| {
                s ^= s << 13;
                s ^= s >> 17;
                s ^= s << 5;
                s as u8
            })
            .collect();
        let rects = deflate_encoder(Quality::Lossless).encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0].encoding, Encoding::Raw);
        assert_eq!(rects[0].data, img);
    }

    #[test]
    fn decoder_rejects_bad_deflate_rects() {
        let px = vec![7u8; 2 * 2 * 4];
        let good = deflate(&px).unwrap();
        let rect = |data: Vec<u8>| Rect { x: 0, y: 0, w: 2, h: 2, encoding: Encoding::Deflate, data };
        let mut dec = Decoder::new();
        dec.apply(64, 64, &[rect(good.clone())]).unwrap();
        assert_eq!(dec.pixels()[0], 0x0007_0707);
        // Truncated (no Adler-32 trailer), corrupted checksum, trailing junk.
        assert!(dec.apply(64, 64, &[rect(good[..good.len() - 4].to_vec())]).is_err());
        let mut bad_sum = good.clone();
        *bad_sum.last_mut().unwrap() ^= 1;
        assert!(dec.apply(64, 64, &[rect(bad_sum)]).is_err());
        let mut trailing = good.clone();
        trailing.push(0);
        assert!(dec.apply(64, 64, &[rect(trailing)]).is_err());
        // Wrong length: one pixel short, one pixel long, and a "bomb".
        assert!(dec.apply(64, 64, &[rect(deflate(&px[..12]).unwrap())]).is_err());
        assert!(dec.apply(64, 64, &[rect(deflate(&[7u8; 20]).unwrap())]).is_err());
        assert!(dec.apply(64, 64, &[rect(deflate(&vec![0u8; 1 << 20]).unwrap())]).is_err());
        // Raw deflate without the zlib wrapper, and junk.
        assert!(dec.apply(64, 64, &[rect(good[2..good.len() - 4].to_vec())]).is_err());
        assert!(dec.apply(64, 64, &[rect(vec![1, 2, 3])]).is_err());
    }

    #[test]
    fn full_hd_encodes_quickly_enough() {
        // Smoke check, not a benchmark: a full 1080p balanced frame should
        // compress well below raw size.
        let (w, h) = (1920, 1080);
        let img = image(w, h, 9);
        let mut enc = Encoder::new(Quality::Balanced);
        let rects = enc.encode(&FrameRef::new(w, h, (w * 4) as usize, &img).unwrap());
        let bytes: usize = rects.iter().map(|r| r.data.len()).sum();
        assert!(bytes < (w * h * 4) as usize / 2, "compressed {bytes} bytes");
    }
}
