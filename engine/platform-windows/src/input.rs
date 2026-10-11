//! Input injection with `SendInput`.

use std::time::{Duration, Instant};

use crossshell_platform::Injector;
use crossshell_proto::keymap::{evdev_to_windows, WinKey};
use crossshell_proto::msg::button;
use windows::core::BOOL;
use windows::Win32::Foundation::{LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    MapVirtualKeyW, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, MAPVK_VK_TO_VSC, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL,
    MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, MOUSEINPUT, MOUSE_EVENT_FLAGS, VIRTUAL_KEY, VK_NUMLOCK,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, XBUTTON1, XBUTTON2,
};

use crate::displays::wide_to_string;

/// How long a looked-up display rectangle is trusted (displays can be
/// rearranged or change resolution mid-session).
const RECT_TTL: Duration = Duration::from_secs(1);

pub(crate) struct SendInputInjector {
    device: String,
    rect: RECT,
    rect_at: Instant,
    /// Consecutive `SendInput` failures; only the first of a run is logged
    /// (on the secure desktop every pointer move fails).
    failures: u32,
}

impl SendInputInjector {
    pub fn new(device: String, rect: RECT) -> Self {
        SendInputInjector { device, rect, rect_at: Instant::now(), failures: 0 }
    }

    /// The display's desktop rectangle, refreshed every [`RECT_TTL`].
    fn rect(&mut self) -> RECT {
        if self.rect_at.elapsed() >= RECT_TTL {
            self.rect_at = Instant::now();
            match monitor_rect(&self.device) {
                Some(r) => self.rect = r,
                None => log::debug!("display {} not found; keeping its last position", self.device),
            }
        }
        self.rect
    }

    fn send(&mut self, inputs: &[INPUT]) {
        let n = unsafe { SendInput(inputs, size_of::<INPUT>() as i32) };
        if n as usize == inputs.len() {
            if self.failures > 0 {
                log::info!("input injection works again after {} failed attempts", self.failures);
            }
            self.failures = 0;
        } else {
            if self.failures == 0 {
                // UIPI (elevated window, agent not elevated) or the secure desktop.
                log::warn!("SendInput rejected input: {}", windows::core::Error::from_thread());
            }
            self.failures += 1;
        }
    }

    fn mouse(&mut self, flags: MOUSE_EVENT_FLAGS, data: u32, dx: i32, dy: i32) {
        let mi = MOUSEINPUT { dx, dy, mouseData: data, dwFlags: flags, time: 0, dwExtraInfo: 0 };
        self.send(&[INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi } }]);
    }

    fn keyboard(&mut self, vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) {
        let ki = KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 };
        self.send(&[INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki } }]);
    }
}

/// Map a virtual-desktop pixel to `SendInput`'s 0..=65535 absolute range.
///
/// Windows maps back with `pixel = floor(n * extent / 65536)`, so the
/// smallest `n` for a pixel is `ceil(p * 65536 / extent)`; that lands on
/// the exact pixel for every extent (checked against `GetCursorPos`).
pub(crate) fn normalize(p: i32, extent: i32) -> i32 {
    if extent <= 0 {
        return 0;
    }
    let p = i64::from(p.clamp(0, extent - 1));
    let e = i64::from(extent);
    ((p * 65536 + e - 1) / e).min(65535) as i32
}

impl Injector for SendInputInjector {
    fn pointer_move(&mut self, x: i32, y: i32) -> anyhow::Result<()> {
        let r = self.rect();
        let (vx, vy, vw, vh) = unsafe {
            (
                GetSystemMetrics(SM_XVIRTUALSCREEN),
                GetSystemMetrics(SM_YVIRTUALSCREEN),
                GetSystemMetrics(SM_CXVIRTUALSCREEN),
                GetSystemMetrics(SM_CYVIRTUALSCREEN),
            )
        };
        let nx = normalize(r.left + x - vx, vw);
        let ny = normalize(r.top + y - vy, vh);
        self.mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0, nx, ny);
        Ok(())
    }

    fn pointer_button(&mut self, b: u8, down: bool) -> anyhow::Result<()> {
        let (flags, data) = match (b, down) {
            (button::LEFT, true) => (MOUSEEVENTF_LEFTDOWN, 0),
            (button::LEFT, false) => (MOUSEEVENTF_LEFTUP, 0),
            (button::MIDDLE, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
            (button::MIDDLE, false) => (MOUSEEVENTF_MIDDLEUP, 0),
            (button::RIGHT, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
            (button::RIGHT, false) => (MOUSEEVENTF_RIGHTUP, 0),
            (button::BACK, true) => (MOUSEEVENTF_XDOWN, XBUTTON1),
            (button::BACK, false) => (MOUSEEVENTF_XUP, XBUTTON1),
            (button::FORWARD, true) => (MOUSEEVENTF_XDOWN, XBUTTON2),
            (button::FORWARD, false) => (MOUSEEVENTF_XUP, XBUTTON2),
            _ => {
                log::debug!("ignoring unknown pointer button {b}");
                return Ok(());
            }
        };
        self.mouse(flags, u32::from(data), 0, 0);
        Ok(())
    }

    fn scroll(&mut self, dx: i16, dy: i16) -> anyhow::Result<()> {
        // Both are already in WHEEL_DELTA (1/120 notch) units with the
        // Windows sign convention: +dy = wheel forward, +dx = right.
        if dy != 0 {
            self.mouse(MOUSEEVENTF_WHEEL, i32::from(dy) as u32, 0, 0);
        }
        if dx != 0 {
            self.mouse(MOUSEEVENTF_HWHEEL, i32::from(dx) as u32, 0, 0);
        }
        Ok(())
    }

    fn key(&mut self, evdev: u16, down: bool) -> anyhow::Result<()> {
        let up = if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP };
        match evdev_to_windows(evdev) {
            Some(WinKey::Scan { code, extended }) => {
                let ext = if extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
                self.keyboard(0, code, KEYEVENTF_SCANCODE | ext | up);
            }
            Some(WinKey::Vk(vk)) => {
                let scan = unsafe { MapVirtualKeyW(u32::from(vk), MAPVK_VK_TO_VSC) } as u16;
                // NumLock is an extended key in the keyboard layout tables
                // (KBDEXT); sent that way it toggles the lock, as in
                // Microsoft's keybd_event sample. Pause needs no flag.
                let ext = if vk == VK_NUMLOCK.0 { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
                self.keyboard(vk, scan, ext | up);
            }
            None => log::debug!("ignoring evdev key {evdev} (no Windows equivalent)"),
        }
        Ok(())
    }
}

/// Desktop rectangle of the monitor with this GDI device name.
pub(crate) fn monitor_rect(device: &str) -> Option<RECT> {
    struct Search<'a> {
        device: &'a str,
        found: Option<RECT>,
    }
    unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let s = unsafe { &mut *(data.0 as *mut Search) };
        let mut mi = MONITORINFOEXW::default();
        mi.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
        if unsafe { GetMonitorInfoW(m, &mut mi as *mut MONITORINFOEXW as *mut MONITORINFO) }.as_bool()
            && wide_to_string(&mi.szDevice) == s.device
        {
            s.found = Some(mi.monitorInfo.rcMonitor);
            return false.into();
        }
        true.into()
    }
    let mut s = Search { device, found: None };
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut s as *mut Search as isize));
    }
    s.found
}

#[cfg(test)]
mod tests {
    use super::normalize;

    /// Windows' inverse mapping (see `normalize`).
    fn to_pixel(n: i32, extent: i32) -> i32 {
        (i64::from(n) * i64::from(extent) / 65536) as i32
    }

    #[test]
    fn every_pixel_round_trips() {
        for extent in [1, 2, 640, 1366, 1920, 2560, 3000, 3840, 5120, 7680, 65535] {
            for p in 0..extent {
                let n = normalize(p, extent);
                assert!((0..=65535).contains(&n));
                assert_eq!(to_pixel(n, extent), p, "pixel {p} of {extent}");
            }
        }
    }

    #[test]
    fn out_of_range_is_clamped() {
        assert_eq!(normalize(-5, 1920), 0);
        assert_eq!(normalize(5000, 1920), normalize(1919, 1920));
        assert_eq!(normalize(3, 0), 0);
    }
}
