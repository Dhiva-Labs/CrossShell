//! CrossShell host agent library (the binary is a thin CLI around it).

pub mod clipboard;
pub mod logger;
pub mod notify;
pub mod runtime;
pub mod session;

use crossshell_platform::Backend;

/// Which capture backend sessions use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    /// The real desktop of this OS.
    Native,
    /// The animated test pattern (tests, CI, demos).
    Synthetic,
}

/// Process-wide platform setup (Windows: DPI awareness).
pub fn platform_init() {
    #[cfg(windows)]
    crossshell_platform_windows::init();
    #[cfg(target_os = "linux")]
    crossshell_platform_linux::init();
}

pub fn start_backend(kind: BackendKind) -> anyhow::Result<Box<dyn Backend>> {
    match kind {
        BackendKind::Synthetic => Ok(Box::new(crossshell_platform::SyntheticBackend::new())),
        BackendKind::Native => native_backend(),
    }
}

#[cfg(windows)]
fn native_backend() -> anyhow::Result<Box<dyn Backend>> {
    crossshell_platform_windows::start_backend()
}

#[cfg(target_os = "linux")]
fn native_backend() -> anyhow::Result<Box<dyn Backend>> {
    crossshell_platform_linux::start_backend()
}

#[cfg(not(any(windows, target_os = "linux")))]
fn native_backend() -> anyhow::Result<Box<dyn Backend>> {
    anyhow::bail!("screen sharing is not supported on this OS yet")
}
