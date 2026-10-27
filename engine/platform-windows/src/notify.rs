//! "Your screen is being viewed" notice: a notification-area icon with an
//! info balloon, which Windows 10/11 shows as a toast. The icon stays in the
//! notification area (tooltip = the same text) until the viewer leaves.
//!
//! The icon belongs to a hidden message-only window on a thread of its own
//! that pumps messages while the notice is up. Best effort: when there is no
//! shell (no interactive desktop) nothing is shown.

use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use anyhow::Context;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, LoadIconW, PeekMessageW, RegisterClassW,
    TranslateMessage, HWND_MESSAGE, IDI_INFORMATION, MSG, PM_REMOVE, WINDOW_EX_STYLE, WINDOW_STYLE, WNDCLASSW,
};

const CLASS: PCWSTR = w!("CrossShellNotice");
const ICON_ID: u32 = 1;
/// How often the window's queue is drained while waiting for `stop`.
const PUMP_INTERVAL: Duration = Duration::from_millis(100);

/// Show `title` / `text` until `stop` fires (or its sender is dropped), then
/// remove the icon. Runs on the caller's thread; failures are logged at
/// debug level only.
pub fn show_until(title: &str, text: &str, stop: &Receiver<()>) {
    match Notice::show(title, text) {
        Ok(notice) => {
            loop {
                notice.pump();
                match stop.recv_timeout(PUMP_INTERVAL) {
                    Err(RecvTimeoutError::Timeout) => continue,
                    _ => break,
                }
            }
            drop(notice);
        }
        Err(e) => {
            log::debug!("no notification balloon: {e:#}");
            let _ = stop.recv();
        }
    }
}

struct Notice {
    hwnd: HWND,
    data: NOTIFYICONDATAW,
}

impl Notice {
    fn show(title: &str, text: &str) -> anyhow::Result<Notice> {
        unsafe {
            let inst = GetModuleHandleW(None).context("GetModuleHandleW")?;
            let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), hInstance: inst.into(), lpszClassName: CLASS, ..Default::default() };
            // Fails harmlessly when an earlier session registered it already.
            RegisterClassW(&wc);
            let hwnd = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                CLASS,
                w!("CrossShell"),
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                Some(HWND_MESSAGE),
                None,
                Some(inst.into()),
                None,
            )
            .context("CreateWindowExW")?;
            let mut data = NOTIFYICONDATAW {
                cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
                hWnd: hwnd,
                uID: ICON_ID,
                uFlags: NIF_ICON | NIF_TIP | NIF_INFO,
                hIcon: LoadIconW(None, IDI_INFORMATION).unwrap_or_default(),
                dwInfoFlags: NIIF_INFO,
                ..Default::default()
            };
            copy_wide(&mut data.szTip, text);
            copy_wide(&mut data.szInfoTitle, title);
            copy_wide(&mut data.szInfo, text);
            if !Shell_NotifyIconW(NIM_ADD, &data).as_bool() {
                let _ = DestroyWindow(hwnd);
                anyhow::bail!("Shell_NotifyIconW(NIM_ADD) failed (no shell in this session?)");
            }
            Ok(Notice { hwnd, data })
        }
    }

    fn pump(&self) {
        let mut msg = MSG::default();
        unsafe {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
}

impl Drop for Notice {
    fn drop(&mut self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.data);
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
}

/// Copy `s` into a fixed, NUL-terminated UTF-16 field, truncating on a
/// character boundary.
fn copy_wide(dst: &mut [u16], s: &str) {
    let mut n = 0;
    for c in s.chars() {
        let mut buf = [0u16; 2];
        let units = c.encode_utf16(&mut buf);
        if n + units.len() >= dst.len() {
            break;
        }
        dst[n..n + units.len()].copy_from_slice(units);
        n += units.len();
    }
    dst[n] = 0;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_wide_truncates_and_terminates() {
        let mut b = [0xffffu16; 6];
        copy_wide(&mut b, "ab");
        assert_eq!(b[..3], [b'a' as u16, b'b' as u16, 0]);
        copy_wide(&mut b, "abcdefgh");
        assert_eq!(b, [97, 98, 99, 100, 101, 0]);
        // A surrogate pair never gets split.
        copy_wide(&mut b, "abcd😀");
        assert_eq!(b[..5], [97, 98, 99, 100, 0]);
    }
}
