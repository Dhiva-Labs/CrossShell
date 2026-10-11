//! Windows backend: DXGI Desktop Duplication capture, SendInput injection.
#![cfg(windows)]

use crossshell_platform::Backend;

/// Process-wide setup; called once at host start (DPI awareness etc.).
pub fn init() {}

pub fn start_backend() -> anyhow::Result<Box<dyn Backend>> {
    anyhow::bail!("Windows capture backend not implemented yet")
}
