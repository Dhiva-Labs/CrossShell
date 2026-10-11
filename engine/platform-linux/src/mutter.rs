//! GNOME on Wayland, straight through Mutter: `org.gnome.Mutter.RemoteDesktop`
//! + `org.gnome.Mutter.ScreenCast`, the API gnome-remote-desktop uses.
//!
//! Unlike the portal this shows no consent dialog — the agent already runs
//! as the logged-in user and was started over SSH authenticated with the
//! pairing key, so this gives unattended access. GNOME still shows its
//! "screen is being shared" indicator while a session is active.
//!
//! One RemoteDesktop session per backend, with a linked ScreenCast session
//! that records every logical monitor up front (an unconsumed stream costs
//! Mutter nothing). Stream coordinates for absolute pointer motion are the
//! stream's buffer pixels — Mutter divides by the monitor scale itself.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context};
use crossshell_platform::{Backend, Capturer, DisplayInfo, Injector};
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::dbus::{self, Signals};
use crate::input::{Geometry, RemoteInput, SharedGeometry, StreamInjector};
use crate::pw::{PwCapturer, PwSource};

const RD_DEST: &str = "org.gnome.Mutter.RemoteDesktop";
const RD_PATH: &str = "/org/gnome/Mutter/RemoteDesktop";
const RD_SESSION: &str = "org.gnome.Mutter.RemoteDesktop.Session";
const SC_DEST: &str = "org.gnome.Mutter.ScreenCast";
const SC_PATH: &str = "/org/gnome/Mutter/ScreenCast";
const SC_SESSION: &str = "org.gnome.Mutter.ScreenCast.Session";
const SC_STREAM: &str = "org.gnome.Mutter.ScreenCast.Stream";
const DC_DEST: &str = "org.gnome.Mutter.DisplayConfig";
const DC_PATH: &str = "/org/gnome/Mutter/DisplayConfig";

/// ScreenCast `cursor-mode` values.
const CURSOR_EMBEDDED: u32 = 1;
const CURSOR_METADATA: u32 = 2;

const STREAM_TIMEOUT: Duration = Duration::from_secs(5);

/// Are Mutter's remote-desktop interfaces on the bus?
pub fn available(conn: &Connection) -> bool {
    dbus::has_owner(conn, RD_DEST) && dbus::has_owner(conn, SC_DEST)
}

/// The RemoteDesktop session; stopped when the last user drops it.
struct Session {
    conn: Connection,
    path: OwnedObjectPath,
}

impl Session {
    fn proxy(&self) -> anyhow::Result<Proxy<'static>> {
        dbus::proxy(&self.conn, RD_DEST, self.path.clone().into_inner(), RD_SESSION)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        log::info!("mutter: stopping remote desktop session {}", self.path.as_str());
        if let Ok(p) = self.proxy() {
            let _ = p.call::<_, _, ()>("Stop", &());
        }
    }
}

struct Stream {
    info: DisplayInfo,
    path: String,
    node_id: u32,
    geometry: SharedGeometry,
}

pub struct MutterBackend {
    session: Arc<Session>,
    streams: Vec<Stream>,
}

/// A physical monitor from `DisplayConfig.GetCurrentState`.
#[derive(Debug, Clone)]
pub(crate) struct PhysMonitor {
    pub connector: String,
    pub display_name: String,
    /// Current mode size in pixels.
    pub mode: Option<(u32, u32)>,
}

/// A logical monitor (one desktop region; mirrored monitors share one).
#[derive(Debug, Clone)]
pub(crate) struct LogicalMonitor {
    pub x: i32,
    pub y: i32,
    pub transform: u32,
    pub primary: bool,
    pub connectors: Vec<String>,
}

/// Displays in the order offered to viewers (primary first, then left to
/// right), each with the connector to record. Sizes are the stream size
/// Mutter will produce: the current mode, rotated by the transform.
pub(crate) fn layout(phys: &[PhysMonitor], logical: &[LogicalMonitor]) -> Vec<(String, DisplayInfo)> {
    let mut lms: Vec<&LogicalMonitor> = logical.iter().collect();
    lms.sort_by_key(|l| (!l.primary, l.x, l.y));
    let mut out = Vec::new();
    for l in lms {
        let Some(pm) = l.connectors.iter().find_map(|c| phys.iter().find(|p| &p.connector == c)) else { continue };
        let Some((mut w, mut h)) = pm.mode else { continue };
        // Odd transforms (90°, 270°, and their flipped variants) swap axes.
        if l.transform % 2 == 1 {
            std::mem::swap(&mut w, &mut h);
        }
        let name = if pm.display_name.is_empty() || pm.display_name == pm.connector {
            pm.connector.clone()
        } else {
            format!("{} ({})", pm.display_name, pm.connector)
        };
        let index = out.len() as u8;
        out.push((pm.connector.clone(), DisplayInfo { index, name, x: l.x, y: l.y, width: w, height: h, primary: l.primary }));
    }
    out
}

type MonitorSpec = (String, String, String, String);
type Mode = (String, i32, i32, f64, f64, Vec<f64>, HashMap<String, OwnedValue>);
type Monitor = (MonitorSpec, Vec<Mode>, HashMap<String, OwnedValue>);
type Logical = (i32, i32, f64, u32, bool, Vec<MonitorSpec>, HashMap<String, OwnedValue>);
type CurrentState = (u32, Vec<Monitor>, Vec<Logical>, HashMap<String, OwnedValue>);

fn current_layout(conn: &Connection) -> anyhow::Result<Vec<(String, DisplayInfo)>> {
    let dc = dbus::proxy(conn, DC_DEST, DC_PATH, DC_DEST)?;
    let (_serial, monitors, logical, _props): CurrentState =
        dc.call("GetCurrentState", &()).context("DisplayConfig.GetCurrentState")?;
    let phys: Vec<PhysMonitor> = monitors
        .into_iter()
        .map(|((connector, ..), modes, props)| PhysMonitor {
            display_name: dbus::get::<String>(&props, "display-name").unwrap_or_default(),
            mode: modes
                .iter()
                .find(|m| dbus::get::<bool>(&m.6, "is-current").unwrap_or(false))
                .map(|m| (m.1.max(0) as u32, m.2.max(0) as u32)),
            connector,
        })
        .collect();
    let logical: Vec<LogicalMonitor> = logical
        .into_iter()
        .map(|(x, y, _scale, transform, primary, specs, _)| LogicalMonitor {
            x,
            y,
            transform,
            primary,
            connectors: specs.into_iter().map(|s| s.0).collect(),
        })
        .collect();
    Ok(layout(&phys, &logical))
}

/// Cursor as stream metadata (sent to the viewer separately) or drawn into
/// the frames. Metadata is better, but with more than one monitor Mutter 50
/// starves a monitor's stream: repaints of the other monitor record
/// cursor-only frames that keep its frame-rate limiter shut, and no full
/// frame ever arrives (seen on headless GNOME with two virtual monitors).
/// `CROSSSHELL_CURSOR=metadata|embedded` overrides.
pub(crate) fn want_cursor_metadata(monitors: usize) -> bool {
    cursor_metadata_for(std::env::var("CROSSSHELL_CURSOR").ok().as_deref(), monitors)
}

fn cursor_metadata_for(setting: Option<&str>, monitors: usize) -> bool {
    match setting {
        Some("metadata") => true,
        Some("embedded") => false,
        _ => monitors <= 1,
    }
}

/// Number of active monitors when Mutter is running (GNOME), else `None`.
pub(crate) fn monitor_count(conn: &Connection) -> Option<usize> {
    if !dbus::has_owner(conn, DC_DEST) {
        return None;
    }
    current_layout(conn).ok().map(|l| l.len())
}

impl MutterBackend {
    pub fn start() -> anyhow::Result<Self> {
        let conn = dbus::session()?;
        if !available(&conn) {
            bail!("org.gnome.Mutter.RemoteDesktop/ScreenCast not on the session bus");
        }
        let monitors = current_layout(&conn)?;
        if monitors.is_empty() {
            bail!("Mutter reports no active monitors");
        }

        let rd = dbus::proxy(&conn, RD_DEST, RD_PATH, RD_DEST)?;
        let path: OwnedObjectPath = rd.call("CreateSession", &()).context("RemoteDesktop.CreateSession")?;
        let session = Arc::new(Session { conn: conn.clone(), path });
        let rd_session = session.proxy()?;
        let session_id: String = rd_session.get_property("SessionId").context("reading SessionId")?;

        let sc = dbus::proxy(&conn, SC_DEST, SC_PATH, SC_DEST)?;
        let props = HashMap::from([("remote-desktop-session-id", Value::from(session_id.as_str()))]);
        let sc_path: OwnedObjectPath = sc.call("CreateSession", &(props,)).context("ScreenCast.CreateSession")?;
        let sc_session = dbus::proxy(&conn, SC_DEST, sc_path.as_str(), SC_SESSION)?;

        let mut cursor_metadata = want_cursor_metadata(monitors.len());
        let mut pending = Vec::new();
        for (connector, info) in monitors {
            let record = |mode: u32| -> zbus::Result<OwnedObjectPath> {
                let props = HashMap::from([("cursor-mode", Value::from(mode))]);
                sc_session.call("RecordMonitor", &(connector.as_str(), props))
            };
            let stream_path = match record(if cursor_metadata { CURSOR_METADATA } else { CURSOR_EMBEDDED }) {
                Ok(p) => p,
                Err(e) if cursor_metadata => {
                    log::info!("mutter: cursor metadata refused ({e}); embedding the cursor instead");
                    cursor_metadata = false;
                    record(CURSOR_EMBEDDED)?
                }
                Err(e) => return Err(e).context(format!("RecordMonitor({connector})")),
            };
            let sp = dbus::proxy(&conn, SC_DEST, stream_path.as_str(), SC_STREAM)?;
            let added = Signals::subscribe(&sp, "PipeWireStreamAdded")?;
            pending.push((info, stream_path.as_str().to_owned(), added));
        }

        rd_session.call::<_, _, ()>("Start", &()).context("RemoteDesktop.Session.Start")?;

        let mut streams = Vec::new();
        for (info, path, mut added) in pending {
            let msg = added.next(STREAM_TIMEOUT).ok_or_else(|| anyhow!("no PipeWire stream for {}", info.name))?;
            let (node_id,): (u32,) = msg.body().deserialize()?;
            log::info!(
                "mutter: display {} {:?} {}x{} at {},{} → PipeWire node {node_id}",
                info.index,
                info.name,
                info.width,
                info.height,
                info.x,
                info.y
            );
            let geometry = Arc::new(Mutex::new(Geometry { buffer: (info.width, info.height), ..Default::default() }));
            streams.push(Stream { info, path, node_id, geometry });
        }
        log::info!("mutter: cursor {}", if cursor_metadata { "sent as metadata" } else { "drawn into frames" });
        Ok(MutterBackend { session, streams })
    }

    fn stream(&self, display: u8) -> anyhow::Result<&Stream> {
        self.streams.iter().find(|s| s.info.index == display).ok_or_else(|| anyhow!("no display {display}"))
    }
}

impl Backend for MutterBackend {
    fn displays(&mut self) -> anyhow::Result<Vec<DisplayInfo>> {
        Ok(self.streams.iter().map(|s| s.info.clone()).collect())
    }

    fn capturer(&mut self, display: u8) -> anyhow::Result<Box<dyn Capturer>> {
        let s = self.stream(display)?;
        let src = PwSource { remote: None, node_id: s.node_id };
        let cap = PwCapturer::start(src, s.geometry.clone(), self.session.clone())?;
        Ok(Box::new(cap))
    }

    fn injector(&mut self, display: u8) -> anyhow::Result<Box<dyn Injector>> {
        let s = self.stream(display)?;
        let input = MutterInput { proxy: self.session.proxy()?, stream: s.path.clone(), _session: self.session.clone() };
        Ok(Box::new(StreamInjector::new(input, s.geometry.clone())))
    }
}

struct MutterInput {
    proxy: Proxy<'static>,
    stream: String,
    _session: Arc<Session>,
}

impl RemoteInput for MutterInput {
    fn motion_absolute(&mut self, x: f64, y: f64, wait: bool) -> anyhow::Result<()> {
        let args = (self.stream.as_str(), x, y);
        if wait {
            self.proxy.call::<_, _, ()>("NotifyPointerMotionAbsolute", &args)?;
        } else {
            self.proxy.call_noreply("NotifyPointerMotionAbsolute", &args)?;
        }
        Ok(())
    }

    fn button(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
        Ok(self.proxy.call::<_, _, ()>("NotifyPointerButton", &(code as i32, down))?)
    }

    fn axis_discrete(&mut self, axis: u32, steps: i32) -> anyhow::Result<()> {
        Ok(self.proxy.call::<_, _, ()>("NotifyPointerAxisDiscrete", &(axis, steps))?)
    }

    fn key(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
        Ok(self.proxy.call::<_, _, ()>("NotifyKeyboardKeycode", &(code as u32, down))?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn phys(c: &str, name: &str, mode: (u32, u32)) -> PhysMonitor {
        PhysMonitor { connector: c.into(), display_name: name.into(), mode: Some(mode) }
    }

    fn logical(x: i32, y: i32, transform: u32, primary: bool, c: &[&str]) -> LogicalMonitor {
        LogicalMonitor { x, y, transform, primary, connectors: c.iter().map(|s| s.to_string()).collect() }
    }

    #[test]
    fn primary_first_then_left_to_right() {
        let p = [phys("DP-1", "Dell", (2560, 1440)), phys("eDP-1", "Built-in display", (2880, 1800)), phys("HDMI-1", "", (1920, 1080))];
        // Laptop panel at 2× scale (1440 logical wide) left of the primary DP-1.
        let l = [logical(1440, 0, 0, true, &["DP-1"]), logical(0, 0, 0, false, &["eDP-1"]), logical(4000, 0, 0, false, &["HDMI-1"])];
        let d = layout(&p, &l);
        let names: Vec<_> = d.iter().map(|(_, i)| (i.index, i.name.as_str(), i.width, i.height, i.x, i.primary)).collect();
        assert_eq!(
            names,
            [
                (0, "Dell (DP-1)", 2560, 1440, 1440, true),
                (1, "Built-in display (eDP-1)", 2880, 1800, 0, false),
                (2, "HDMI-1", 1920, 1080, 4000, false),
            ]
        );
        assert_eq!(d[1].0, "eDP-1");
    }

    #[test]
    fn rotated_monitors_swap_axes_and_mirrors_record_one_connector() {
        let p = [phys("DP-1", "A", (1920, 1080)), phys("DP-2", "B", (1920, 1080))];
        let d = layout(&p, &[logical(0, 0, 1, true, &["DP-1", "DP-2"])]);
        assert_eq!(d.len(), 1);
        assert_eq!((d[0].1.width, d[0].1.height), (1080, 1920));
        let d = layout(&p, &[logical(0, 0, 6, true, &["DP-2"])]); // flipped-180
        assert_eq!((d[0].0.as_str(), d[0].1.width, d[0].1.height), ("DP-2", 1920, 1080));
    }

    #[test]
    fn cursor_is_metadata_only_on_a_single_monitor_unless_overridden() {
        assert!(cursor_metadata_for(None, 1));
        assert!(!cursor_metadata_for(None, 2));
        assert!(cursor_metadata_for(Some("metadata"), 3));
        assert!(!cursor_metadata_for(Some("embedded"), 1));
        assert!(!cursor_metadata_for(Some("bogus"), 2));
    }

    #[test]
    fn monitors_without_a_mode_are_skipped() {
        let p = [PhysMonitor { connector: "DP-1".into(), display_name: "X".into(), mode: None }];
        assert!(layout(&p, &[logical(0, 0, 0, true, &["DP-1"])]).is_empty());
        assert!(layout(&[], &[logical(0, 0, 0, true, &["DP-9"])]).is_empty());
    }
}
