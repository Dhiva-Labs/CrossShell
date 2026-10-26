//! Linux capture and input for the CrossShell host.
//!
//! [`start_backend`] tries, in order:
//! 1. **Mutter direct** (GNOME): `org.gnome.Mutter.RemoteDesktop` +
//!    `ScreenCast`, no consent dialog. Frames from PipeWire.
//! 2. **xdg-desktop-portal** RemoteDesktop + ScreenCast (KDE, GNOME, …):
//!    consent dialog on first use, then a restore token. Frames from PipeWire.
//! 3. **X11** (no Wayland): MIT-SHM `GetImage`, XFixes cursor, XTest input.
//!
//! On an X11 session X11 is tried before the portal. Set
//! `CROSSSHELL_LINUX_BACKEND=mutter|portal|x11` to force one.
//!
//! Mutter and the portal need the `pipewire` feature (on by default). A
//! build without it has the X11 backend only and links no C library.
#![cfg(target_os = "linux")]

mod convert;
mod dbus;
mod input;
#[cfg(feature = "pipewire")]
mod mutter;
pub mod notify;
#[cfg(feature = "pipewire")]
mod portal;
#[cfg(feature = "pipewire")]
mod pw;
mod x11;

use crossshell_platform::Backend;

/// Does this build have the Mutter and portal backends?
pub const HAS_PIPEWIRE: bool = cfg!(feature = "pipewire");

/// Process-wide setup; called once at host start.
pub fn init() {
    #[cfg(feature = "pipewire")]
    pipewire::init();
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Mutter,
    Portal,
    X11,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Mutter => "mutter",
            Kind::Portal => "portal",
            Kind::X11 => "x11",
        }
    }

    fn parse(s: &str) -> Option<Kind> {
        [Kind::Mutter, Kind::Portal, Kind::X11].into_iter().find(|k| k.name() == s)
    }

    /// Is this backend part of the build?
    fn compiled(self) -> bool {
        HAS_PIPEWIRE || self == Kind::X11
    }

    fn start(self) -> anyhow::Result<Box<dyn Backend>> {
        Ok(match self {
            #[cfg(feature = "pipewire")]
            Kind::Mutter => Box::new(mutter::MutterBackend::start()?),
            #[cfg(feature = "pipewire")]
            Kind::Portal => Box::new(portal::PortalBackend::start()?),
            #[cfg(not(feature = "pipewire"))]
            Kind::Mutter | Kind::Portal => anyhow::bail!("not in this build (X11 only)"),
            Kind::X11 => Box::new(x11::X11Backend::start()?),
        })
    }
}

/// `order` without the backends this build lacks.
fn usable(order: Vec<Kind>, forced: bool) -> anyhow::Result<Vec<Kind>> {
    let usable: Vec<Kind> = order.iter().copied().filter(|k| k.compiled()).collect();
    if usable.is_empty() {
        let names: Vec<&str> = order.iter().map(|k| k.name()).collect();
        anyhow::bail!(
            "this build has the X11 backend only, and {} needs {} (use the full build, which has PipeWire)",
            if forced { "CROSSSHELL_LINUX_BACKEND" } else { "this session" },
            names.join(" or ")
        );
    }
    Ok(usable)
}

/// Backends to try, best first.
fn order(forced: Option<&str>, wayland: bool, x11: bool) -> anyhow::Result<Vec<Kind>> {
    if let Some(f) = forced.filter(|f| !f.is_empty()) {
        let k = Kind::parse(f).ok_or_else(|| anyhow::anyhow!("CROSSSHELL_LINUX_BACKEND={f:?}: expected mutter, portal or x11"))?;
        return Ok(vec![k]);
    }
    Ok(if wayland {
        // X11 under Wayland would only see Xwayland windows.
        vec![Kind::Mutter, Kind::Portal]
    } else if x11 {
        // Direct X11 needs no consent; Mutter still wins on GNOME/Xorg.
        vec![Kind::Mutter, Kind::X11, Kind::Portal]
    } else {
        vec![Kind::Mutter, Kind::Portal]
    })
}

fn is_wayland() -> bool {
    let set = |k: &str| std::env::var_os(k).is_some_and(|v| !v.is_empty());
    set("WAYLAND_DISPLAY") || std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t == "wayland")
}

pub fn start_backend() -> anyhow::Result<Box<dyn Backend>> {
    init();
    let forced = std::env::var("CROSSSHELL_LINUX_BACKEND").ok();
    let has_x11 = std::env::var_os("DISPLAY").is_some_and(|v| !v.is_empty());
    let forced_set = forced.as_deref().is_some_and(|f| !f.is_empty());
    let order = usable(order(forced.as_deref(), is_wayland(), has_x11)?, forced_set)?;
    let mut errors = Vec::new();
    for kind in order {
        match kind.start() {
            Ok(b) => {
                log::info!("capture backend: {}", kind.name());
                return Ok(b);
            }
            Err(e) => {
                log::info!("{} backend unavailable: {e:#}", kind.name());
                errors.push(format!("{}: {e:#}", kind.name()));
            }
        }
    }
    anyhow::bail!("no usable capture backend ({})", errors.join("; "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_order() {
        use Kind::*;
        assert_eq!(order(None, true, true).unwrap(), [Mutter, Portal]);
        assert_eq!(order(None, false, true).unwrap(), [Mutter, X11, Portal]);
        assert_eq!(order(None, false, false).unwrap(), [Mutter, Portal]);
        assert_eq!(order(Some("x11"), true, true).unwrap(), [X11]);
        assert_eq!(order(Some(""), true, false).unwrap(), [Mutter, Portal]);
        assert!(order(Some("vnc"), true, true).is_err());
    }

    #[test]
    #[cfg(feature = "pipewire")]
    fn full_build_keeps_every_backend() {
        use Kind::*;
        assert_eq!(usable(vec![Mutter, X11, Portal], false).unwrap(), [Mutter, X11, Portal]);
        assert_eq!(usable(vec![Portal], true).unwrap(), [Portal]);
    }

    #[test]
    #[cfg(not(feature = "pipewire"))]
    fn x11_only_build_drops_pipewire_backends() {
        use Kind::*;
        assert_eq!(usable(vec![Mutter, X11, Portal], false).unwrap(), [X11]);
        let e = usable(vec![Mutter, Portal], false).unwrap_err().to_string();
        assert!(e.contains("X11 backend only") && e.contains("mutter or portal"), "{e}");
        assert!(usable(vec![Mutter], true).unwrap_err().to_string().contains("CROSSSHELL_LINUX_BACKEND"));
    }
}
