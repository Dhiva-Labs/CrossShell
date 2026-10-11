//! Pointer state for viewers: Desktop Duplication reports the pointer next
//! to (not inside) the desktop image, as a position + visibility per frame
//! and a shape whenever it changes. This module turns the three DXGI shape
//! formats into straight RGBA and decides what the viewer needs to hear.

use crossshell_platform::{CursorShape, CursorUpdate};

/// `DXGI_OUTDUPL_POINTER_SHAPE_TYPE` values.
pub(crate) const SHAPE_MONOCHROME: u32 = 1;
pub(crate) const SHAPE_COLOR: u32 = 2;
pub(crate) const SHAPE_MASKED_COLOR: u32 = 4;

/// Largest shape sent to viewers. Accessibility pointer sizes at high DPI
/// go beyond this; those are box-downscaled.
pub(crate) const MAX_SIZE: usize = 256;

const TRANSPARENT: [u8; 4] = [0, 0, 0, 0];
const BLACK: [u8; 4] = [0, 0, 0, 255];
const WHITE: [u8; 4] = [255, 255, 255, 255];

/// A pointer shape as `GetFramePointerShape` hands it out.
pub(crate) struct RawShape<'a> {
    pub kind: u32,
    pub width: u32,
    /// For monochrome shapes: twice the pointer height (AND mask, then XOR mask).
    pub height: u32,
    pub pitch: u32,
    pub hot_x: i32,
    pub hot_y: i32,
    pub data: &'a [u8],
}

/// Convert to straight RGBA, capped at [`MAX_SIZE`].
///
/// Pixels that invert the screen (monochrome AND=1/XOR=1, masked-color XOR
/// with a non-zero color — the classic I-beam) have no RGBA equivalent.
/// They become black with a white outline, which reads on any background.
pub(crate) fn convert(raw: &RawShape) -> Option<CursorShape> {
    let w = raw.width as usize;
    let h = if raw.kind == SHAPE_MONOCHROME { raw.height / 2 } else { raw.height } as usize;
    if w == 0 || h == 0 || w > 4096 || h > 4096 {
        return None;
    }
    let pitch = raw.pitch as usize;
    let mut rgba = vec![0u8; w * h * 4];
    let mut invert = vec![false; w * h];

    match raw.kind {
        SHAPE_MONOCHROME => {
            if pitch < w.div_ceil(8) || raw.data.len() < pitch * h * 2 {
                return None;
            }
            for y in 0..h {
                for x in 0..w {
                    let bit = 0x80u8 >> (x % 8);
                    let and = raw.data[y * pitch + x / 8] & bit != 0;
                    let xor = raw.data[(y + h) * pitch + x / 8] & bit != 0;
                    let px = match (and, xor) {
                        (false, false) => BLACK,
                        (false, true) => WHITE,
                        (true, false) => TRANSPARENT,
                        (true, true) => {
                            invert[y * w + x] = true;
                            BLACK
                        }
                    };
                    rgba[(y * w + x) * 4..][..4].copy_from_slice(&px);
                }
            }
        }
        SHAPE_COLOR | SHAPE_MASKED_COLOR => {
            if pitch < w * 4 || raw.data.len() < pitch * (h - 1) + w * 4 {
                return None;
            }
            for y in 0..h {
                for x in 0..w {
                    let s = &raw.data[y * pitch + x * 4..][..4];
                    let (b, g, r, a) = (s[0], s[1], s[2], s[3]);
                    let px = if raw.kind == SHAPE_COLOR {
                        // BGRA with straight alpha.
                        [r, g, b, a]
                    } else if a == 0 {
                        // Masked color: alpha 0 = replace the screen pixel...
                        [r, g, b, 255]
                    } else if r | g | b == 0 {
                        // ...alpha 0xFF = XOR with the screen; XOR 0 is a no-op.
                        TRANSPARENT
                    } else {
                        invert[y * w + x] = true;
                        BLACK
                    };
                    rgba[(y * w + x) * 4..][..4].copy_from_slice(&px);
                }
            }
        }
        _ => return None,
    }

    if invert.iter().any(|&i| i) {
        outline(&mut rgba, &invert, w, h);
    }
    let hot_x = raw.hot_x.clamp(0, w as i32 - 1) as usize;
    let hot_y = raw.hot_y.clamp(0, h as i32 - 1) as usize;
    let (rgba, w, h, hot_x, hot_y) = cap_size(rgba, w, h, hot_x, hot_y);
    Some(CursorShape { width: w as u16, height: h as u16, hot_x: hot_x as u16, hot_y: hot_y as u16, rgba })
}

/// Paint transparent pixels next to inverting ones white.
fn outline(rgba: &mut [u8], invert: &[bool], w: usize, h: usize) {
    let mut white = Vec::new();
    for y in 0..h {
        for x in 0..w {
            if rgba[(y * w + x) * 4 + 3] != 0 {
                continue;
            }
            let near = (y.saturating_sub(1)..(y + 2).min(h))
                .any(|ny| (x.saturating_sub(1)..(x + 2).min(w)).any(|nx| invert[ny * w + nx]));
            if near {
                white.push(y * w + x);
            }
        }
    }
    for i in white {
        rgba[i * 4..][..4].copy_from_slice(&WHITE);
    }
}

/// Box-downscale by the smallest integer factor that fits [`MAX_SIZE`],
/// averaging in premultiplied space so edges don't pick up dark fringes.
fn cap_size(rgba: Vec<u8>, w: usize, h: usize, hot_x: usize, hot_y: usize) -> (Vec<u8>, usize, usize, usize, usize) {
    let f = w.max(h).div_ceil(MAX_SIZE);
    if f <= 1 {
        return (rgba, w, h, hot_x, hot_y);
    }
    let (nw, nh) = (w.div_ceil(f), h.div_ceil(f));
    let mut out = vec![0u8; nw * nh * 4];
    for oy in 0..nh {
        for ox in 0..nw {
            let (mut sum, mut a_sum, mut n) = ([0u32; 3], 0u32, 0u32);
            for y in oy * f..((oy + 1) * f).min(h) {
                for x in ox * f..((ox + 1) * f).min(w) {
                    let p = &rgba[(y * w + x) * 4..][..4];
                    let a = u32::from(p[3]);
                    for c in 0..3 {
                        sum[c] += u32::from(p[c]) * a;
                    }
                    a_sum += a;
                    n += 1;
                }
            }
            let o = &mut out[(oy * nw + ox) * 4..][..4];
            for c in 0..3 {
                o[c] = sum[c].checked_div(a_sum).unwrap_or(0) as u8;
            }
            o[3] = (a_sum / n) as u8;
        }
    }
    (out, nw, nh, hot_x / f, hot_y / f)
}

/// What the pointer looks like and where it is, and what was last reported.
#[derive(Default)]
pub(crate) struct CursorTracker {
    /// `None` until DXGI has reported the pointer once.
    visible: Option<bool>,
    /// Top-left of the pointer image, display-relative (what DXGI reports).
    pos: (i32, i32),
    shape: Option<CursorShape>,
    /// Hotspot in unscaled shape pixels, to turn `pos` into the hotspot.
    hot: (i32, i32),
    shape_gen: u32,
    sent_visible: Option<bool>,
    sent_gen: u32,
    sent_pos: Option<(i32, i32)>,
}

impl CursorTracker {
    /// From `DXGI_OUTDUPL_FRAME_INFO.PointerPosition` (only valid when
    /// `LastMouseUpdateTime` is non-zero). `visible` is false while the
    /// pointer is on another display or hidden by an app.
    pub fn set_position(&mut self, visible: bool, x: i32, y: i32) {
        self.visible = Some(visible);
        if visible {
            self.pos = (x, y);
        }
    }

    pub fn set_shape(&mut self, raw: &RawShape) {
        match convert(raw) {
            // Apps re-set the same cursor all the time; don't resend it.
            Some(s) if self.shape.as_ref() == Some(&s) => self.hot = (raw.hot_x, raw.hot_y),
            Some(s) => {
                log::debug!(
                    "pointer shape: type {} {}x{} hotspot {},{} -> {}x{}",
                    raw.kind,
                    raw.width,
                    raw.height,
                    raw.hot_x,
                    raw.hot_y,
                    s.width,
                    s.height
                );
                self.hot = (raw.hot_x, raw.hot_y);
                self.shape = Some(s);
                self.shape_gen = self.shape_gen.wrapping_add(1);
            }
            None => log::debug!("ignoring pointer shape type {} {}x{}", raw.kind, raw.width, raw.height),
        }
    }

    /// Changes since the last call; position is the hotspot.
    pub fn take_update(&mut self) -> Option<CursorUpdate> {
        let mut u = CursorUpdate::default();
        match self.visible {
            None => return None,
            Some(false) => {
                if self.sent_visible != Some(false) {
                    u.shape = Some(None);
                    self.sent_visible = Some(false);
                }
            }
            Some(true) => {
                if let Some(s) = &self.shape {
                    if self.sent_visible != Some(true) || self.sent_gen != self.shape_gen {
                        u.shape = Some(Some(s.clone()));
                        self.sent_visible = Some(true);
                        self.sent_gen = self.shape_gen;
                    }
                }
                let p = (self.pos.0 + self.hot.0, self.pos.1 + self.hot.1);
                if self.sent_pos != Some(p) {
                    u.position = Some(p);
                    self.sent_pos = Some(p);
                }
            }
        }
        (u != CursorUpdate::default()).then_some(u)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn px(s: &CursorShape, x: usize, y: usize) -> [u8; 4] {
        s.rgba[(y * s.width as usize + x) * 4..][..4].try_into().unwrap()
    }

    #[test]
    fn monochrome_masks() {
        // 8x2 pointer, pitch 1: AND rows then XOR rows. Columns 0-3 cover
        // the four AND/XOR combinations.
        let and = [0b0011_1111u8, 0b1111_1111];
        let xor = [0b0101_0000u8, 0b0000_0000];
        let data = [and[0], and[1], xor[0], xor[1]];
        let raw = RawShape { kind: SHAPE_MONOCHROME, width: 8, height: 4, pitch: 1, hot_x: 1, hot_y: 0, data: &data };
        let s = convert(&raw).unwrap();
        assert_eq!((s.width, s.height, s.hot_x, s.hot_y), (8, 2, 1, 0));
        assert_eq!(px(&s, 0, 0), BLACK); // AND 0 XOR 0
        assert_eq!(px(&s, 1, 0), WHITE); // AND 0 XOR 1
        assert_eq!(px(&s, 2, 0)[3], 0xFF); // AND 1 XOR 0 next to the inverting pixel: outline
        assert_eq!(px(&s, 3, 0), BLACK); // AND 1 XOR 1: inverting
        assert_eq!(px(&s, 4, 0), WHITE); // outline right of it
        assert_eq!(px(&s, 6, 0), TRANSPARENT);
        assert_eq!(px(&s, 6, 1), TRANSPARENT);
    }

    #[test]
    fn color_is_bgra_to_rgba() {
        // 2x1 with pitch 12 (padding must be skipped).
        let data = [10, 20, 30, 255, 1, 2, 3, 128, 0, 0, 0, 0];
        let raw = RawShape { kind: SHAPE_COLOR, width: 2, height: 1, pitch: 12, hot_x: 9, hot_y: 9, data: &data };
        let s = convert(&raw).unwrap();
        assert_eq!(s.rgba, vec![30, 20, 10, 255, 3, 2, 1, 128]);
        assert_eq!((s.hot_x, s.hot_y), (1, 0)); // clamped into the image
    }

    #[test]
    fn masked_color() {
        let data = [
            10, 20, 30, 0, // replace
            0, 0, 0, 255, // XOR black: transparent
            0, 0, 0, 255, // XOR black: transparent, but next to the inverting pixel
            255, 255, 255, 255, // XOR white: inverting
        ];
        let raw =
            RawShape { kind: SHAPE_MASKED_COLOR, width: 4, height: 1, pitch: 16, hot_x: 0, hot_y: 0, data: &data };
        let s = convert(&raw).unwrap();
        assert_eq!(px(&s, 0, 0), [30, 20, 10, 255]);
        assert_eq!(px(&s, 1, 0), TRANSPARENT);
        assert_eq!(px(&s, 2, 0), WHITE);
        assert_eq!(px(&s, 3, 0), BLACK);
    }

    #[test]
    fn oversized_shapes_are_downscaled() {
        let (w, h) = (300usize, 40usize);
        let mut data = vec![0u8; w * h * 4];
        for p in data.chunks_mut(4) {
            p.copy_from_slice(&[0, 0, 255, 255]);
        }
        let raw = RawShape {
            kind: SHAPE_COLOR,
            width: w as u32,
            height: h as u32,
            pitch: (w * 4) as u32,
            hot_x: 100,
            hot_y: 21,
            data: &data,
        };
        let s = convert(&raw).unwrap();
        assert_eq!((s.width, s.height, s.hot_x, s.hot_y), (150, 20, 50, 10));
        assert_eq!(px(&s, 149, 19), [255, 0, 0, 255]);
    }

    #[test]
    fn short_buffers_are_rejected() {
        let raw = RawShape { kind: SHAPE_COLOR, width: 4, height: 4, pitch: 16, hot_x: 0, hot_y: 0, data: &[0; 20] };
        assert!(convert(&raw).is_none());
        let raw = RawShape { kind: 3, width: 1, height: 1, pitch: 4, hot_x: 0, hot_y: 0, data: &[0; 4] };
        assert!(convert(&raw).is_none());
    }

    #[test]
    fn tracker_reports_changes_only() {
        let mut t = CursorTracker::default();
        assert_eq!(t.take_update(), None);
        let data = [0u8; 4 * 4 * 4];
        t.set_shape(&RawShape { kind: SHAPE_COLOR, width: 4, height: 4, pitch: 16, hot_x: 2, hot_y: 3, data: &data });
        assert_eq!(t.take_update(), None, "nothing until DXGI reports a position");
        t.set_position(true, 100, 50);
        let u = t.take_update().unwrap();
        assert!(matches!(u.shape, Some(Some(_))));
        assert_eq!(u.position, Some((102, 53)));
        assert_eq!(t.take_update(), None);
        t.set_position(true, 101, 50);
        assert_eq!(t.take_update(), Some(CursorUpdate { shape: None, position: Some((103, 53)) }));
        // The same shape again is not news.
        t.set_shape(&RawShape { kind: SHAPE_COLOR, width: 4, height: 4, pitch: 16, hot_x: 2, hot_y: 3, data: &data });
        assert_eq!(t.take_update(), None);
        // Leaves the display: hidden once, and the shape comes back with it.
        t.set_position(false, 0, 0);
        assert_eq!(t.take_update(), Some(CursorUpdate { shape: Some(None), position: None }));
        assert_eq!(t.take_update(), None);
        t.set_position(true, 101, 50);
        let u = t.take_update().unwrap();
        assert!(matches!(u.shape, Some(Some(_))));
        assert_eq!(u.position, None);
    }
}
