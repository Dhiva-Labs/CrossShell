//! Pixel conversions: screen frames to packed BGRX, cursor images to
//! straight RGBA.

/// Where the colour (and alpha) bytes sit inside a 4-byte pixel.
#[cfg_attr(not(feature = "pipewire"), allow(dead_code))] // PipeWire formats
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Channels {
    pub r: usize,
    pub g: usize,
    pub b: usize,
    pub a: Option<usize>,
}

#[cfg_attr(not(feature = "pipewire"), allow(dead_code))]
impl Channels {
    pub const BGRX: Channels = Channels { r: 2, g: 1, b: 0, a: None };
    pub const BGRA: Channels = Channels { r: 2, g: 1, b: 0, a: Some(3) };
    pub const RGBX: Channels = Channels { r: 0, g: 1, b: 2, a: None };
    pub const RGBA: Channels = Channels { r: 0, g: 1, b: 2, a: Some(3) };
    pub const XRGB: Channels = Channels { r: 1, g: 2, b: 3, a: None };
    pub const ARGB: Channels = Channels { r: 1, g: 2, b: 3, a: Some(0) };
    pub const XBGR: Channels = Channels { r: 3, g: 2, b: 1, a: None };
    pub const ABGR: Channels = Channels { r: 3, g: 2, b: 1, a: Some(0) };

    /// Already in the wire layout (B, G, R, X): rows can be copied as-is.
    fn is_bgr(self) -> bool {
        (self.b, self.g, self.r) == (0, 1, 2)
    }
}

/// Copy a `width`×`height` image (rows `stride` bytes apart) into `dst` as
/// packed BGRX. `dst` is resized to `width * height * 4`.
///
/// Returns `false` (leaving `dst` untouched) if `src` is too short.
#[cfg_attr(not(feature = "pipewire"), allow(dead_code))]
pub fn to_bgrx(src: &[u8], stride: usize, width: usize, height: usize, ch: Channels, dst: &mut Vec<u8>) -> bool {
    let row = width * 4;
    if width == 0 || height == 0 || stride < row || src.len() < stride * (height - 1) + row {
        return false;
    }
    dst.resize(row * height, 0);
    if ch.is_bgr() {
        if stride == row {
            dst.copy_from_slice(&src[..row * height]);
        } else {
            for (d, s) in dst.chunks_exact_mut(row).zip(src.chunks(stride)) {
                d.copy_from_slice(&s[..row]);
            }
        }
        return true;
    }
    for (d, s) in dst.chunks_exact_mut(row).zip(src.chunks(stride)) {
        for (dp, sp) in d.chunks_exact_mut(4).zip(s[..row].chunks_exact(4)) {
            dp[0] = sp[ch.b];
            dp[1] = sp[ch.g];
            dp[2] = sp[ch.r];
            dp[3] = 255;
        }
    }
    true
}

/// Convert a cursor image to straight RGBA. Images without an alpha channel
/// come out opaque. Premultiplied alpha is detected (no colour value above
/// its alpha anywhere) and undone, which is what compositors hand out.
#[cfg_attr(not(feature = "pipewire"), allow(dead_code))]
pub fn cursor_to_rgba(src: &[u8], stride: usize, width: usize, height: usize, ch: Channels) -> Option<Vec<u8>> {
    let row = width * 4;
    if width == 0 || height == 0 || stride < row || src.len() < stride * (height - 1) + row {
        return None;
    }
    let mut out = Vec::with_capacity(row * height);
    for s in src.chunks(stride).take(height) {
        for p in s[..row].chunks_exact(4) {
            out.extend_from_slice(&[p[ch.r], p[ch.g], p[ch.b], ch.a.map_or(255, |a| p[a])]);
        }
    }
    unpremultiply_if_premultiplied(&mut out);
    Some(out)
}

/// XFixes cursor pixels (`0xAARRGGBB` words, premultiplied) to straight RGBA.
pub fn argb32_to_rgba(pixels: &[u32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(pixels.len() * 4);
    for &p in pixels {
        out.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, p as u8, (p >> 24) as u8]);
    }
    unpremultiply_if_premultiplied(&mut out);
    out
}

/// Undo premultiplied alpha in place, if the image looks premultiplied.
pub fn unpremultiply_if_premultiplied(rgba: &mut [u8]) {
    let premultiplied = rgba.chunks_exact(4).all(|p| p[0] <= p[3] && p[1] <= p[3] && p[2] <= p[3]);
    if !premultiplied {
        return;
    }
    for p in rgba.chunks_exact_mut(4) {
        let a = p[3] as u32;
        if a != 0 && a != 255 {
            for c in &mut p[..3] {
                *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bgrx_rows_are_copied_without_padding() {
        // 2×2 image with 4 bytes of row padding.
        let src = [1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 9, 10, 11, 12, 13, 14, 15, 16, 0, 0, 0, 0];
        let mut dst = Vec::new();
        assert!(to_bgrx(&src, 12, 2, 2, Channels::BGRX, &mut dst));
        assert_eq!(dst, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
    }

    #[test]
    fn rgb_orders_are_swizzled() {
        let px = |ch: Channels| {
            // A pixel with R=0x10, G=0x20, B=0x30, A/X=0x40 in the given layout.
            let mut p = [0x40u8; 4];
            p[ch.r] = 0x10;
            p[ch.g] = 0x20;
            p[ch.b] = 0x30;
            let mut dst = Vec::new();
            assert!(to_bgrx(&p, 4, 1, 1, ch, &mut dst));
            dst
        };
        for ch in [Channels::RGBX, Channels::RGBA, Channels::XRGB, Channels::ARGB, Channels::XBGR, Channels::ABGR] {
            assert_eq!(px(ch), [0x30, 0x20, 0x10, 255], "{ch:?}");
        }
        assert_eq!(px(Channels::BGRA), [0x30, 0x20, 0x10, 0x40]);
    }

    #[test]
    fn short_sources_are_rejected() {
        let mut dst = vec![7];
        assert!(!to_bgrx(&[0; 15], 8, 2, 2, Channels::BGRX, &mut dst));
        assert!(!to_bgrx(&[0; 16], 4, 2, 2, Channels::BGRX, &mut dst), "stride shorter than a row");
        assert_eq!(dst, [7]);
        // The last row needs no padding.
        assert!(to_bgrx(&[0; 20], 12, 2, 2, Channels::BGRX, &mut dst));
    }

    #[test]
    fn premultiplied_cursor_is_unpremultiplied() {
        // Half-transparent white (premultiplied 128,128,128,128) and opaque red.
        let src = [128, 128, 128, 128, 255, 0, 0, 255];
        let rgba = cursor_to_rgba(&src, 8, 2, 1, Channels::RGBA).unwrap();
        assert_eq!(rgba, [255, 255, 255, 128, 255, 0, 0, 255]);
    }

    #[test]
    fn straight_cursor_is_left_alone() {
        // Colour above alpha: cannot be premultiplied.
        let src = [200, 100, 50, 128];
        assert_eq!(cursor_to_rgba(&src, 4, 1, 1, Channels::RGBA).unwrap(), src);
    }

    #[test]
    fn bgra_cursor_and_xfixes_argb() {
        let src = [0x30, 0x20, 0x10, 0xff];
        assert_eq!(cursor_to_rgba(&src, 4, 1, 1, Channels::BGRA).unwrap(), [0x10, 0x20, 0x30, 0xff]);
        // Opaque blue, fully transparent, and 50% black.
        let px = [0xff00_00ff, 0x0000_0000, 0x8000_0000];
        assert_eq!(argb32_to_rgba(&px), [0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 128]);
    }
}
