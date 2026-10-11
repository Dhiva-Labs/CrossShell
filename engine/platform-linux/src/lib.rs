//! Linux backends: xdg-desktop-portal + PipeWire on Wayland, XShm + XTest on X11.
#![cfg(target_os = "linux")]

use crossshell_platform::Backend;

/// Process-wide setup; called once at host start.
pub fn init() {}

pub fn start_backend() -> anyhow::Result<Box<dyn Backend>> {
    anyhow::bail!("Linux capture backend not implemented yet")
}
