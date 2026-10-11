//! Software compositing into the window buffer (`0x00RRGGBB` pixels):
//! frame scaling, cursor, banner, state messages, menu.

use anyhow::Context;
use fast_image_resize::images::{Image, ImageRef};
use fast_image_resize::{FilterType, PixelType, ResizeAlg, ResizeOptions, Resizer};

use crate::font::{self, CELL_H, CELL_W};
use crate::geom::{IRect, Layout};
use crate::menu::{Item, Kind, MenuLayout};
use crate::net::FrameBuf;

pub const BG: u32 = 0x0014_1519;
const PANEL: u32 = 0x001e_2127;
const PANEL_BORDER: u32 = 0x004b_5263;
const TEXT: u32 = 0x00d7_dae0;
const TEXT_DIM: u32 = 0x007f_8aa3;
const TEXT_DISABLED: u32 = 0x005c_6370;
const SELECTED: u32 = 0x002c_5282;

pub struct Canvas<'a> {
    pub buf: &'a mut [u32],
    pub w: u32,
    pub h: u32,
}

impl<'a> Canvas<'a> {
    pub fn new(buf: &'a mut [u32], w: u32, h: u32) -> Self {
        debug_assert!(buf.len() >= (w * h) as usize);
        Canvas { buf, w, h }
    }

    fn clip(&self, r: IRect) -> Option<(usize, usize, usize, usize)> {
        let x0 = r.x.max(0) as i64;
        let y0 = r.y.max(0) as i64;
        let x1 = (r.right() as i64).min(self.w as i64);
        let y1 = (r.bottom() as i64).min(self.h as i64);
        (x1 > x0 && y1 > y0).then_some((x0 as usize, y0 as usize, x1 as usize, y1 as usize))
    }

    pub fn fill_rect(&mut self, r: IRect, color: u32) {
        if let Some((x0, y0, x1, y1)) = self.clip(r) {
            for y in y0..y1 {
                let row = y * self.w as usize;
                self.buf[row + x0..row + x1].fill(color);
            }
        }
    }

    /// Fill everything outside `inner` (the letterbox bars).
    pub fn fill_outside(&mut self, inner: IRect, color: u32) {
        let (w, h) = (self.w, self.h);
        if inner.w == 0 || inner.h == 0 {
            self.fill_rect(IRect::new(0, 0, w, h), color);
            return;
        }
        self.fill_rect(IRect::new(0, 0, w, inner.y.max(0) as u32), color);
        self.fill_rect(IRect::new(0, inner.bottom(), w, h.saturating_sub(inner.bottom().max(0) as u32)), color);
        self.fill_rect(IRect::new(0, inner.y, inner.x.max(0) as u32, inner.h), color);
        self.fill_rect(
            IRect::new(inner.right(), inner.y, w.saturating_sub(inner.right().max(0) as u32), inner.h),
            color,
        );
    }

    pub fn stroke_rect(&mut self, r: IRect, color: u32) {
        self.fill_rect(IRect::new(r.x, r.y, r.w, 1), color);
        self.fill_rect(IRect::new(r.x, r.bottom() - 1, r.w, 1), color);
        self.fill_rect(IRect::new(r.x, r.y, 1, r.h), color);
        self.fill_rect(IRect::new(r.right() - 1, r.y, 1, r.h), color);
    }

    /// Darken a region to half brightness.
    pub fn dim_rect(&mut self, r: IRect) {
        if let Some((x0, y0, x1, y1)) = self.clip(r) {
            for y in y0..y1 {
                let row = y * self.w as usize;
                for p in &mut self.buf[row + x0..row + x1] {
                    *p = (*p >> 1) & 0x007f_7f7f;
                }
            }
        }
    }

    /// Draw `text` with its top-left at `(x, y)`; returns the x after the last glyph.
    pub fn draw_text(&mut self, x: i32, y: i32, text: &str, color: u32, scale: i32) -> i32 {
        let mut cx = x;
        for c in font::sanitize(text).chars() {
            let g = font::glyph(c);
            for (row, bits) in g.iter().enumerate() {
                if *bits == 0 {
                    continue;
                }
                for bit in 0..8 {
                    if bits & (0x80 >> bit) != 0 {
                        self.fill_rect(
                            IRect::new(cx + bit * scale, y + (row as i32 + 1) * scale, scale as u32, scale as u32),
                            color,
                        );
                    }
                }
            }
            cx += CELL_W * scale;
        }
        cx
    }

    /// Alpha-blend a straight-alpha RGBA bitmap with its top-left at `(x, y)`.
    pub fn blit_rgba(&mut self, x: i32, y: i32, w: u32, h: u32, rgba: &[u8]) {
        if rgba.len() < (w * h * 4) as usize {
            return;
        }
        for row in 0..h as i32 {
            let py = y + row;
            if py < 0 || py >= self.h as i32 {
                continue;
            }
            for col in 0..w as i32 {
                let px = x + col;
                if px < 0 || px >= self.w as i32 {
                    continue;
                }
                let i = ((row as u32 * w + col as u32) * 4) as usize;
                let a = rgba[i + 3] as u32;
                if a == 0 {
                    continue;
                }
                let dst = &mut self.buf[py as usize * self.w as usize + px as usize];
                if a == 255 {
                    *dst = (rgba[i] as u32) << 16 | (rgba[i + 1] as u32) << 8 | rgba[i + 2] as u32;
                } else {
                    let mix = |s: u8, d: u32| (s as u32 * a + d * (255 - a) + 127) / 255;
                    let r = mix(rgba[i], (*dst >> 16) & 0xff);
                    let g = mix(rgba[i + 1], (*dst >> 8) & 0xff);
                    let b = mix(rgba[i + 2], *dst & 0xff);
                    *dst = r << 16 | g << 8 | b;
                }
            }
        }
    }
}

/// Owns the resizer (and its scratch buffers) between redraws.
pub struct Renderer {
    resizer: Resizer,
    scratch: Vec<u32>,
}

impl Renderer {
    pub fn new() -> Self {
        Renderer { resizer: Resizer::new(), scratch: Vec::new() }
    }

    /// Draw the frame per `lay`, letterbox in [`BG`].
    pub fn draw_frame(&mut self, canvas: &mut Canvas, fb: &FrameBuf, lay: &Layout) -> anyhow::Result<()> {
        canvas.fill_outside(lay.dst, BG);
        let have = !fb.pixels.is_empty() && fb.pixels.len() == (fb.width * fb.height) as usize;
        if lay.is_empty() || !have || lay.frame_w != fb.width || lay.frame_h != fb.height {
            canvas.fill_rect(lay.dst, BG);
            return Ok(());
        }
        if lay.src.w == lay.dst.w && lay.src.h == lay.dst.h {
            // 1:1 (or fit that happens to be exact): plain row copies.
            blit_rows(canvas, lay.dst, &fb.pixels, fb.width as usize, lay.src.x as usize, lay.src.y as usize);
            return Ok(());
        }
        let n = (lay.dst.w * lay.dst.h) as usize;
        self.scratch.resize(n, 0);
        let src = ImageRef::new(fb.width, fb.height, bytemuck::cast_slice(&fb.pixels), PixelType::U8x4)
            .context("wrapping the frame for scaling")?;
        let mut dst = Image::from_slice_u8(
            lay.dst.w,
            lay.dst.h,
            bytemuck::cast_slice_mut(&mut self.scratch[..n]),
            PixelType::U8x4,
        )
        .context("wrapping the scaling target")?;
        // Pixels are BGRX: there is no alpha, so don't let the resizer
        // premultiply by the (zero) fourth byte.
        let opts = ResizeOptions::new().resize_alg(ResizeAlg::Convolution(FilterType::Bilinear)).use_alpha(false);
        self.resizer.resize(&src, &mut dst, &opts).context("scaling the frame")?;
        blit_rows(canvas, lay.dst, &self.scratch[..n], lay.dst.w as usize, 0, 0);
        Ok(())
    }
}

/// Copy `dst.w`×`dst.h` pixels from `src` (row length `src_stride`, starting
/// at `(sx, sy)`) to `dst` on the canvas, clipped.
fn blit_rows(canvas: &mut Canvas, dst: IRect, src: &[u32], src_stride: usize, sx: usize, sy: usize) {
    for row in 0..dst.h as usize {
        let y = dst.y + row as i32;
        if y < 0 || y >= canvas.h as i32 {
            continue;
        }
        let x0 = dst.x.max(0) as usize;
        let x1 = ((dst.x + dst.w as i32) as usize).min(canvas.w as usize);
        if x1 <= x0 {
            continue;
        }
        let s = (sy + row) * src_stride + sx + (x0 as i32 - dst.x) as usize;
        let len = x1 - x0;
        let d = y as usize * canvas.w as usize + x0;
        canvas.buf[d..d + len].copy_from_slice(&src[s..s + len]);
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BannerLevel {
    Info,
    Warn,
    Error,
}

impl BannerLevel {
    pub fn from_wire(level: u8) -> Self {
        match level {
            0 => BannerLevel::Info,
            1 => BannerLevel::Warn,
            _ => BannerLevel::Error,
        }
    }
}

/// Notice banner across the top. Returns its height.
pub fn draw_banner(canvas: &mut Canvas, level: BannerLevel, text: &str, scale: i32) -> i32 {
    let bg = match level {
        BannerLevel::Info => 0x001f_4e79,
        BannerLevel::Warn => 0x008a_5a00,
        BannerLevel::Error => 0x008b_1e1e,
    };
    let pad = 6 * scale;
    let h = CELL_H * scale + 2 * pad;
    canvas.fill_rect(IRect::new(0, 0, canvas.w, h as u32), bg);
    let max_chars = ((canvas.w as i32 - 2 * pad) / (CELL_W * scale)).max(1) as usize;
    canvas.draw_text(pad, pad, &font::truncate(&font::sanitize(text), max_chars), 0x00ff_ffff, scale);
    h
}

/// Centered message box: a bold-ish first line and dimmer detail lines.
pub fn draw_message(canvas: &mut Canvas, title: &str, detail: &str, scale: i32) {
    let pad = 14 * scale;
    let max_chars = (((canvas.w as i32 - 4 * pad) / (CELL_W * scale)).max(10) as usize).min(72);
    let mut lines: Vec<(String, u32)> =
        font::wrap(&font::sanitize(title), max_chars).into_iter().map(|l| (l, 0x00ff_ffff)).collect();
    if !detail.is_empty() {
        lines.push((String::new(), TEXT));
        lines.extend(font::wrap(&font::sanitize(detail), max_chars).into_iter().map(|l| (l, TEXT_DIM)));
    }
    let widest = lines.iter().map(|(l, _)| l.chars().count()).max().unwrap_or(0) as i32;
    let w = widest * CELL_W * scale + 2 * pad;
    let line_h = (CELL_H + 2) * scale;
    let h = lines.len() as i32 * line_h + 2 * pad;
    let x = (canvas.w as i32 - w) / 2;
    let y = (canvas.h as i32 - h) / 2;
    let r = IRect::new(x, y, w.max(0) as u32, h.max(0) as u32);
    canvas.fill_rect(r, PANEL);
    canvas.stroke_rect(r, PANEL_BORDER);
    for (i, (l, c)) in lines.iter().enumerate() {
        let lw = l.chars().count() as i32 * CELL_W * scale;
        let first = i == 0;
        let tx = x + (w - lw) / 2;
        let ty = y + pad + i as i32 * line_h;
        canvas.draw_text(tx, ty, l, *c, scale);
        if first {
            canvas.draw_text(tx + 1, ty, l, *c, scale); // cheap bold
        }
    }
}

/// The overlay menu. `selected` is the highlighted item index.
pub fn draw_menu(
    canvas: &mut Canvas,
    items: &[Item],
    lay: &MenuLayout,
    selected: Option<usize>,
    title: &str,
    footer: &str,
    scale: i32,
) {
    canvas.fill_rect(lay.rect, PANEL);
    canvas.stroke_rect(lay.rect, PANEL_BORDER);
    let pad = lay.pad;
    canvas.draw_text(lay.rect.x + pad, lay.title_y, title, 0x00ff_ffff, scale);
    canvas.draw_text(lay.rect.x + pad + 1, lay.title_y, title, 0x00ff_ffff, scale);
    for (i, (item, row)) in items.iter().zip(&lay.rows).enumerate() {
        if selected == Some(i) && item.selectable() {
            canvas.fill_rect(IRect::new(row.x, row.y, row.w, row.h), SELECTED);
        }
        let text_y = row.y + (row.h as i32 - CELL_H * scale) / 2;
        let (prefix, color) = match item.kind {
            Kind::Header => ("", TEXT_DIM),
            Kind::Radio(on) => (if on { "(*) " } else { "( ) " }, if item.enabled { TEXT } else { TEXT_DISABLED }),
            Kind::Check(on) => (if on { "[x] " } else { "[ ] " }, if item.enabled { TEXT } else { TEXT_DISABLED }),
            Kind::Button => ("    ", if item.enabled { TEXT } else { TEXT_DISABLED }),
        };
        let indent = if matches!(item.kind, Kind::Header) { 0 } else { CELL_W * scale };
        canvas.draw_text(row.x + pad + indent, text_y, &format!("{prefix}{}", item.label), color, scale);
    }
    canvas.draw_text(lay.rect.x + pad, lay.footer_y, footer, TEXT_DIM, scale);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geom::Layout;

    fn frame(w: u32, h: u32, f: impl Fn(u32, u32) -> u32) -> FrameBuf {
        let mut pixels = Vec::new();
        for y in 0..h {
            for x in 0..w {
                pixels.push(f(x, y));
            }
        }
        FrameBuf { width: w, height: h, pixels, generation: 1 }
    }

    #[test]
    fn fit_scales_letterboxes_and_keeps_colors() {
        // A solid mid-orange frame: scaling must not shift or darken it
        // (guards the alpha-premultiply trap with the unused X byte).
        let orange = 0x00e0_8030;
        let fb = frame(200, 100, |_, _| orange);
        let (ww, wh) = (150u32, 150u32);
        let lay = Layout::compute(ww, wh, 200, 100, true, (0, 0));
        assert_eq!((lay.dst.w, lay.dst.h), (150, 75));
        let mut buf = vec![0xdead_beefu32; (ww * wh) as usize];
        let mut canvas = Canvas::new(&mut buf, ww, wh);
        Renderer::new().draw_frame(&mut canvas, &fb, &lay).unwrap();
        // Letterbox bars are background, the middle is the frame colour.
        assert_eq!(buf[0], BG);
        assert_eq!(buf[(149 * ww) as usize], BG);
        assert_eq!(buf[(75 * ww + 75) as usize], orange);
        assert_eq!(buf[(40 * ww + 5) as usize], orange);
        // Row 36 is just above the image (dst.y = 37), row 37 is its first.
        assert_eq!(buf[(36 * ww + 75) as usize], BG);
        assert_eq!(buf[(37 * ww + 75) as usize], orange);
    }

    #[test]
    fn downscale_averages_a_checkerboard() {
        let fb = frame(64, 64, |x, y| if (x + y) % 2 == 0 { 0x00ff_ffff } else { 0 });
        let lay = Layout::compute(16, 16, 64, 64, true, (0, 0));
        let mut buf = vec![0u32; 256];
        let mut canvas = Canvas::new(&mut buf, 16, 16);
        Renderer::new().draw_frame(&mut canvas, &fb, &lay).unwrap();
        let mid = buf[8 * 16 + 8];
        let (r, g, b) = ((mid >> 16) & 0xff, (mid >> 8) & 0xff, mid & 0xff);
        for c in [r, g, b] {
            assert!((100..=156).contains(&c), "channel {c} not mid-grey in {mid:06x}");
        }
    }

    #[test]
    fn one_to_one_copies_exact_pixels_and_pans() {
        let fb = frame(40, 30, |x, y| (x << 8) | y);
        let lay = Layout::compute(20, 10, 40, 30, false, (5, 7));
        let mut buf = vec![0u32; 200];
        let mut canvas = Canvas::new(&mut buf, 20, 10);
        Renderer::new().draw_frame(&mut canvas, &fb, &lay).unwrap();
        assert_eq!(buf[0], (5 << 8) | 7);
        assert_eq!(buf[19], (24 << 8) | 7);
        assert_eq!(buf[9 * 20 + 3], (8 << 8) | 16);
    }

    #[test]
    fn small_frame_one_to_one_is_centered_on_background() {
        let fb = frame(4, 4, |_, _| 0x00aa_bbcc);
        let lay = Layout::compute(10, 10, 4, 4, false, (0, 0));
        let mut buf = vec![0u32; 100];
        let mut canvas = Canvas::new(&mut buf, 10, 10);
        Renderer::new().draw_frame(&mut canvas, &fb, &lay).unwrap();
        assert_eq!(buf[0], BG);
        assert_eq!(buf[3 * 10 + 3], 0x00aa_bbcc);
        assert_eq!(buf[6 * 10 + 6], 0x00aa_bbcc);
        assert_eq!(buf[7 * 10 + 7], BG);
    }

    #[test]
    fn missing_frame_paints_background() {
        let fb = FrameBuf::default();
        let lay = Layout::compute(8, 8, 0, 0, true, (0, 0));
        let mut buf = vec![1u32; 64];
        let mut canvas = Canvas::new(&mut buf, 8, 8);
        Renderer::new().draw_frame(&mut canvas, &fb, &lay).unwrap();
        assert!(buf.iter().all(|p| *p == BG));
    }

    #[test]
    fn text_draws_within_bounds_and_clips() {
        let mut buf = vec![0u32; 40 * 20];
        let mut canvas = Canvas::new(&mut buf, 40, 20);
        let end = canvas.draw_text(2, 2, "Hi", 0xffffff, 1);
        assert_eq!(end, 2 + 16);
        assert!(buf.contains(&0xffffff));
        // Off-canvas and negative origins must not panic.
        let mut canvas = Canvas::new(&mut buf, 40, 20);
        canvas.draw_text(-30, -5, "clipped text", 0xffffff, 2);
        canvas.draw_text(35, 15, "edge", 0xffffff, 3);
    }

    #[test]
    fn rgba_blit_blends_and_clips() {
        let mut buf = vec![0x0000_00ffu32; 16];
        let mut canvas = Canvas::new(&mut buf, 4, 4);
        // 2x1 bitmap: opaque red, half-transparent white.
        let bmp = [255, 0, 0, 255, 255, 255, 255, 128];
        canvas.blit_rgba(1, 1, 2, 1, &bmp);
        assert_eq!(buf[4 + 1], 0x00ff_0000);
        let blended = buf[4 + 2];
        let (r, b) = ((blended >> 16) & 0xff, blended & 0xff);
        assert!((127..=129).contains(&r), "{r}");
        assert!(b > 0xf0, "{b}"); // 50% white over blue stays bright blue
                                  // Partially off-canvas is clipped, fully transparent pixels skipped.
        let mut canvas = Canvas::new(&mut buf, 4, 4);
        canvas.blit_rgba(-1, 3, 2, 2, &[255; 16]);
        canvas.blit_rgba(3, 0, 2, 1, &[0; 8]);
    }

    #[test]
    fn dim_halves_brightness() {
        let mut buf = vec![0x00ff_8040u32; 4];
        let mut canvas = Canvas::new(&mut buf, 2, 2);
        canvas.dim_rect(IRect::new(0, 0, 2, 2));
        assert_eq!(buf[0], 0x007f_4020);
    }

    #[test]
    fn fill_outside_leaves_the_inside() {
        let mut buf = vec![0u32; 100];
        let mut canvas = Canvas::new(&mut buf, 10, 10);
        canvas.fill_outside(IRect::new(2, 3, 5, 4), 7);
        assert_eq!(buf[3 * 10 + 2], 0);
        assert_eq!(buf[6 * 10 + 6], 0);
        assert_eq!(buf[0], 7);
        assert_eq!(buf[3 * 10 + 1], 7);
        assert_eq!(buf[3 * 10 + 7], 7);
        assert_eq!(buf[7 * 10 + 4], 7);
    }
}
