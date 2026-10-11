//! Window ↔ remote-frame geometry: scale-to-fit with letterboxing, 1:1 mode
//! with panning, and the pointer coordinate mapping built on both.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct IRect {
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

impl IRect {
    pub const fn new(x: i32, y: i32, w: u32, h: u32) -> Self {
        IRect { x, y, w, h }
    }

    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x as f64
            && py >= self.y as f64
            && px < (self.x + self.w as i32) as f64
            && py < (self.y + self.h as i32) as f64
    }

    pub fn right(&self) -> i32 {
        self.x + self.w as i32
    }

    pub fn bottom(&self) -> i32 {
        self.y + self.h as i32
    }
}

/// Where the remote frame lands in the window.
///
/// `src` is the part of the frame on show (all of it when fitting, a
/// window-sized crop in 1:1 mode); `dst` is where it is drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Layout {
    pub frame_w: u32,
    pub frame_h: u32,
    pub src: IRect,
    pub dst: IRect,
}

impl Layout {
    /// `fit`: scale the whole frame into the window (aspect kept, centered).
    /// Otherwise show it 1:1, cropped to the window around `pan` (the frame
    /// pixel at the window's top-left corner when the frame is larger).
    pub fn compute(win_w: u32, win_h: u32, frame_w: u32, frame_h: u32, fit: bool, pan: (i32, i32)) -> Layout {
        if win_w == 0 || win_h == 0 || frame_w == 0 || frame_h == 0 {
            return Layout { frame_w, frame_h, ..Default::default() };
        }
        let (dw, dh, src) = if fit {
            let s = (win_w as f64 / frame_w as f64).min(win_h as f64 / frame_h as f64);
            let dw = ((frame_w as f64 * s).round() as u32).clamp(1, win_w);
            let dh = ((frame_h as f64 * s).round() as u32).clamp(1, win_h);
            (dw, dh, IRect::new(0, 0, frame_w, frame_h))
        } else {
            let dw = frame_w.min(win_w);
            let dh = frame_h.min(win_h);
            let px = pan.0.clamp(0, (frame_w - dw) as i32);
            let py = pan.1.clamp(0, (frame_h - dh) as i32);
            (dw, dh, IRect::new(px, py, dw, dh))
        };
        let dst = IRect::new(((win_w - dw) / 2) as i32, ((win_h - dh) / 2) as i32, dw, dh);
        Layout { frame_w, frame_h, src, dst }
    }

    pub fn is_empty(&self) -> bool {
        self.dst.w == 0 || self.dst.h == 0
    }

    /// Scale factor from frame pixels to window pixels.
    pub fn scale(&self) -> f64 {
        if self.src.w == 0 {
            1.0
        } else {
            self.dst.w as f64 / self.src.w as f64
        }
    }

    /// Window position → frame pixel. `None` in the letterbox.
    pub fn to_frame(self, wx: f64, wy: f64) -> Option<(i32, i32)> {
        if self.is_empty() || !self.dst.contains(wx, wy) {
            return None;
        }
        Some(self.to_frame_clamped(wx, wy))
    }

    /// Like [`to_frame`](Self::to_frame) but a position outside the image
    /// snaps to its nearest edge (used while a button is held, so a drag that
    /// leaves the image keeps working and the release lands).
    pub fn to_frame_clamped(self, wx: f64, wy: f64) -> (i32, i32) {
        if self.is_empty() {
            return (0, 0);
        }
        let fx = self.src.x as f64 + (wx - self.dst.x as f64) * self.src.w as f64 / self.dst.w as f64;
        let fy = self.src.y as f64 + (wy - self.dst.y as f64) * self.src.h as f64 / self.dst.h as f64;
        (
            (fx.floor() as i64).clamp(0, self.frame_w as i64 - 1) as i32,
            (fy.floor() as i64).clamp(0, self.frame_h as i64 - 1) as i32,
        )
    }

    /// Frame pixel → window position (top-left of that pixel).
    pub fn to_window(self, fx: f64, fy: f64) -> (f64, f64) {
        let s = self.scale();
        (self.dst.x as f64 + (fx - self.src.x as f64) * s, self.dst.y as f64 + (fy - self.src.y as f64) * s)
    }
}

/// Pan that puts frame point `(fx, fy)` at the center of a `win_w`×`win_h`
/// window in 1:1 mode (clamping happens in [`Layout::compute`]).
pub fn pan_centered_on(fx: i32, fy: i32, win_w: u32, win_h: u32) -> (i32, i32) {
    (fx - (win_w / 2) as i32, fy - (win_h / 2) as i32)
}

/// Which way the 1:1 view should scroll for a pointer at `(px, py)`: -1/0/1
/// per axis, non-zero within `margin` pixels of a window edge.
pub fn edge_pan_dir(px: f64, py: f64, win_w: u32, win_h: u32, margin: f64) -> (i32, i32) {
    let axis = |p: f64, len: u32| {
        if p < margin {
            -1
        } else if p >= len as f64 - margin {
            1
        } else {
            0
        }
    };
    (axis(px, win_w), axis(py, win_h))
}

/// Window size (physical pixels) for a first frame of `frame_w`×`frame_h`
/// on a monitor of `mon_w`×`mon_h`: the frame at 1:1 if it fits in 85 % of
/// the monitor, otherwise scaled down to that.
pub fn initial_window_size(frame_w: u32, frame_h: u32, mon_w: u32, mon_h: u32) -> (u32, u32) {
    if frame_w == 0 || frame_h == 0 || mon_w == 0 || mon_h == 0 {
        return (frame_w.max(1), frame_h.max(1));
    }
    let s = (mon_w as f64 * 0.85 / frame_w as f64).min(mon_h as f64 * 0.85 / frame_h as f64).min(1.0);
    (((frame_w as f64 * s).round() as u32).max(1), ((frame_h as f64 * s).round() as u32).max(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fit_letterboxes_wide_window() {
        // 1920x1080 frame in a 1600x600 window: height-limited, pillarboxed.
        let l = Layout::compute(1600, 600, 1920, 1080, true, (0, 0));
        assert_eq!(l.dst.h, 600);
        assert_eq!(l.dst.w, 1067); // 1920 * 600/1080
        assert_eq!(l.dst.y, 0);
        assert_eq!(l.dst.x, (1600 - 1067) / 2);
        assert_eq!(l.src, IRect::new(0, 0, 1920, 1080));
    }

    #[test]
    fn fit_letterboxes_tall_window() {
        let l = Layout::compute(800, 800, 1600, 900, true, (0, 0));
        assert_eq!((l.dst.w, l.dst.h), (800, 450));
        assert_eq!((l.dst.x, l.dst.y), (0, 175));
    }

    #[test]
    fn fit_upscales_small_frames() {
        let l = Layout::compute(1000, 1000, 100, 50, true, (0, 0));
        assert_eq!((l.dst.w, l.dst.h), (1000, 500));
        assert!((l.scale() - 10.0).abs() < 1e-9);
    }

    #[test]
    fn pointer_mapping_inside_and_outside() {
        let l = Layout::compute(1600, 600, 1920, 1080, true, (0, 0));
        // Letterbox: nothing.
        assert_eq!(l.to_frame(10.0, 300.0), None);
        assert_eq!(l.to_frame(1590.0, 300.0), None);
        // Top-left and bottom-right pixel of the image.
        assert_eq!(l.to_frame(l.dst.x as f64 + 0.5, 0.5), Some((0, 0)));
        let (fx, fy) = l.to_frame((l.dst.right() - 1) as f64 + 0.5, 599.5).unwrap();
        assert_eq!((fx, fy), (1919, 1079));
        // Center.
        let (cx, cy) = l.to_frame(800.0, 300.0).unwrap();
        assert!((cx - 960).abs() <= 2 && (cy - 540).abs() <= 2, "{cx},{cy}");
    }

    #[test]
    fn clamped_mapping_snaps_to_edges() {
        let l = Layout::compute(1600, 600, 1920, 1080, true, (0, 0));
        assert_eq!(l.to_frame_clamped(-50.0, -50.0), (0, 0));
        assert_eq!(l.to_frame_clamped(5000.0, 5000.0), (1919, 1079));
    }

    #[test]
    fn mapping_round_trips_through_the_window() {
        let l = Layout::compute(1280, 720, 1920, 1080, true, (0, 0));
        for (fx, fy) in [(0, 0), (1, 1), (960, 540), (1919, 1079), (333, 777)] {
            let (wx, wy) = l.to_window(fx as f64, fy as f64);
            // Aim at the middle of the destination pixel the frame pixel covers.
            let s = l.scale();
            let (bx, by) = l.to_frame(wx + s / 2.0, wy + s / 2.0).unwrap();
            assert_eq!((bx, by), (fx, fy));
        }
    }

    #[test]
    fn actual_size_centers_small_frames() {
        let l = Layout::compute(1000, 800, 640, 480, false, (0, 0));
        assert_eq!(l.dst, IRect::new(180, 160, 640, 480));
        assert_eq!(l.src, IRect::new(0, 0, 640, 480));
        assert_eq!(l.to_frame(180.0, 160.0), Some((0, 0)));
        assert_eq!(l.to_frame(179.0, 160.0), None);
        assert_eq!(l.to_frame(819.5, 639.5), Some((639, 479)));
    }

    #[test]
    fn actual_size_crops_and_pans_large_frames() {
        let l = Layout::compute(800, 600, 1920, 1080, false, (100, 50));
        assert_eq!(l.dst, IRect::new(0, 0, 800, 600));
        assert_eq!(l.src, IRect::new(100, 50, 800, 600));
        assert_eq!(l.to_frame(0.0, 0.0), Some((100, 50)));
        assert_eq!(l.to_frame(10.5, 20.5), Some((110, 70)));
        // Pan is clamped to the frame.
        let l = Layout::compute(800, 600, 1920, 1080, false, (5000, -20));
        assert_eq!(l.src, IRect::new(1120, 0, 800, 600));
        let l = Layout::compute(800, 600, 1920, 1080, false, (-9, 9999));
        assert_eq!(l.src, IRect::new(0, 480, 800, 600));
    }

    #[test]
    fn degenerate_sizes_do_not_panic() {
        let l = Layout::compute(0, 100, 10, 10, true, (0, 0));
        assert!(l.is_empty());
        assert_eq!(l.to_frame(1.0, 1.0), None);
        let l = Layout::compute(100, 100, 0, 0, true, (0, 0));
        assert!(l.is_empty());
        assert_eq!(l.to_frame_clamped(5.0, 5.0), (0, 0));
        let l = Layout::compute(1, 1, 4000, 3000, true, (0, 0));
        assert_eq!((l.dst.w, l.dst.h), (1, 1));
    }

    #[test]
    fn initial_size_fits_85_percent_of_monitor() {
        // 4K remote on a 1080p monitor: scaled to 85 %.
        assert_eq!(initial_window_size(3840, 2160, 1920, 1080), (1632, 918));
        // Small remote: shown 1:1.
        assert_eq!(initial_window_size(800, 600, 1920, 1080), (800, 600));
        // Fits exactly 85 % of the width.
        let (w, h) = initial_window_size(1920, 1080, 1920, 1200);
        assert_eq!((w, h), (1632, 918));
        assert_eq!(initial_window_size(10, 10, 0, 0), (10, 10));
    }

    #[test]
    fn edge_pan_directions() {
        assert_eq!(edge_pan_dir(2.0, 300.0, 800, 600, 8.0), (-1, 0));
        assert_eq!(edge_pan_dir(799.0, 599.0, 800, 600, 8.0), (1, 1));
        assert_eq!(edge_pan_dir(400.0, 300.0, 800, 600, 8.0), (0, 0));
        assert_eq!(edge_pan_dir(400.0, 0.0, 800, 600, 8.0), (0, -1));
    }

    #[test]
    fn centering_pan() {
        assert_eq!(pan_centered_on(960, 540, 800, 600), (560, 240));
        let l = Layout::compute(800, 600, 1920, 1080, false, pan_centered_on(0, 0, 800, 600));
        assert_eq!(l.src.x, 0); // clamped
    }
}
