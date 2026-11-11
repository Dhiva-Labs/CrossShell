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

/// Which capture backends this build has, for `--version`.
pub fn flavour() -> &'static str {
    #[cfg(target_os = "linux")]
    {
        if crossshell_platform_linux::HAS_PIPEWIRE {
            "mutter, portal, x11"
        } else {
            "x11 only"
        }
    }
    #[cfg(windows)]
    {
        "dxgi"
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        "none"
    }
}

/// True when `exe` is inside an MSIX package install (a `WindowsApps`
/// folder, e.g. `C:\Program Files\WindowsApps\<package>\crossshell-host.exe`).
/// A packaged (Microsoft Store) agent always shows the "your screen is being
/// viewed" notice: Store policy forbids an option to hide that activity.
pub fn is_packaged_exe(exe: &std::path::Path) -> bool {
    // Split on both separators so the check is the same on every host OS.
    exe.to_string_lossy().split(['\\', '/']).any(|c| c.eq_ignore_ascii_case("WindowsApps"))
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

#[cfg(test)]
mod tests {
    use super::is_packaged_exe;
    use std::path::Path;

    #[test]
    fn packaged_exe_paths() {
        for packaged in [
            r"C:\Program Files\WindowsApps\Dhiva-Labs.CrossShell_0.2.0.0_x64__abc\crossshell-host.exe",
            r"C:\Program Files\windowsapps\X_1.0.0.0_arm64__y\crossshell-host.exe",
            r"C:\Users\alex\AppData\Local\Microsoft\WindowsApps\crossshell-host.exe",
            r"D:\WindowsApps\pkg\crossshell-host.exe",
        ] {
            assert!(is_packaged_exe(Path::new(packaged)), "{packaged}");
        }
        for unpackaged in [
            r"C:\Users\alex\Downloads\crossshell-0.2.0-windows-x64\crossshell-host.exe",
            r"C:\Program Files\CrossShell\crossshell-host.exe",
            r"C:\tools\MyWindowsAppsBackup\crossshell-host.exe",
            r"C:\Users\alex\WindowsApps.old\crossshell-host.exe",
            "/usr/lib/crossshell/crossshell-host",
            "/snap/crossshell/current/crossshell-host",
        ] {
            assert!(!is_packaged_exe(Path::new(unpackaged)), "{unpackaged}");
        }
    }
}
