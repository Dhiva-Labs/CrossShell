//! Windows backend: DXGI Desktop Duplication capture, SendInput injection.
#![cfg(windows)]

mod capture;
mod cursor;
mod desktop;
mod displays;
mod input;

use std::sync::Once;

use anyhow::anyhow;
use crossshell_platform::{Backend, Capturer, DisplayInfo, Injector};
use windows::Win32::Foundation::RECT;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};

static INIT: Once = Once::new();

/// Process-wide setup; called once at host start. Makes the process
/// per-monitor DPI aware so DXGI desktop coordinates, `GetSystemMetrics`
/// and `SendInput` all speak physical pixels (and `DuplicateOutput1`
/// requires it).
pub fn init() {
    INIT.call_once(|| {
        if let Err(e) = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) } {
            // Access denied = already set, e.g. by a manifest.
            log::debug!("SetProcessDpiAwarenessContext: {e}");
        }
    });
}

pub fn start_backend() -> anyhow::Result<Box<dyn Backend>> {
    init();
    Ok(Box::new(WinBackend { outputs: Vec::new() }))
}

struct WinBackend {
    /// The list last handed to the core; indices refer to it.
    outputs: Vec<displays::Output>,
}

impl WinBackend {
    fn output(&mut self, display: u8) -> anyhow::Result<displays::Output> {
        if self.outputs.is_empty() {
            self.outputs = displays::enumerate()?;
        }
        self.outputs.iter().find(|o| o.info.index == display).cloned().ok_or_else(|| anyhow!("no display {display}"))
    }
}

impl Backend for WinBackend {
    fn displays(&mut self) -> anyhow::Result<Vec<DisplayInfo>> {
        self.outputs = displays::enumerate()?;
        for o in &self.outputs {
            let i = &o.info;
            log::info!(
                "display {}: {:?} ({}) {}x{} at {},{}{}",
                i.index,
                i.name,
                o.device,
                i.width,
                i.height,
                i.x,
                i.y,
                if i.primary { " primary" } else { "" }
            );
        }
        Ok(self.outputs.iter().map(|o| o.info.clone()).collect())
    }

    fn capturer(&mut self, display: u8) -> anyhow::Result<Box<dyn Capturer>> {
        let o = self.output(display)?;
        Ok(Box::new(capture::DuplCapturer::new(o.device)?))
    }

    fn injector(&mut self, display: u8) -> anyhow::Result<Box<dyn Injector>> {
        let o = self.output(display)?;
        let i = &o.info;
        let rect = RECT { left: i.x, top: i.y, right: i.x + i.width as i32, bottom: i.y + i.height as i32 };
        Ok(Box::new(input::SendInputInjector::new(o.device, rect)))
    }
}
