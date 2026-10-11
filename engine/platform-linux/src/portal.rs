//! xdg-desktop-portal RemoteDesktop + ScreenCast: works on KDE Plasma and
//! GNOME (and any desktop whose portal backend implements both).
//!
//! The first session shows the desktop's consent dialog. Devices are
//! selected with `persist_mode = 2`, and the restore token the portal hands
//! back is kept in `~/.local/state/crossshell/portal-token` (0600), so later
//! sessions start without asking. Tokens are single-use: each session
//! stores the new one.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context};
use crossshell_platform::{Backend, Capturer, DisplayInfo, Injector};
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{self, OwnedObjectPath, OwnedValue, Value};

use crate::dbus::{self, Dict, Signals};
use crate::input::{Geometry, RemoteInput, SharedGeometry, StreamInjector};
use crate::pw::{PwCapturer, PwSource};

const DEST: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const RD: &str = "org.freedesktop.portal.RemoteDesktop";
const SC: &str = "org.freedesktop.portal.ScreenCast";
const REQUEST: &str = "org.freedesktop.portal.Request";
const SESSION: &str = "org.freedesktop.portal.Session";

/// Device types: keyboard | pointer.
const DEVICES: u32 = 1 | 2;
/// Source types: monitor.
const SOURCE_MONITOR: u32 = 1;
const CURSOR_EMBEDDED: u32 = 2;
const CURSOR_METADATA: u32 = 4;
/// Keep the permission until revoked.
const PERSIST_UNTIL_REVOKED: u32 = 2;

/// Time for a non-interactive request.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// Time the user has to answer the consent dialog.
const CONSENT_TIMEOUT: Duration = Duration::from_secs(120);
/// Time to wait for a stream's first format when sizing displays.
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);

pub fn available(conn: &Connection) -> bool {
    dbus::available(conn, DEST)
}

/// Where the restore token lives (`$XDG_STATE_HOME`, else `~/.local/state`).
pub fn token_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
    Some(base.join("crossshell").join("portal-token"))
}

fn load_token() -> Option<String> {
    let t = std::fs::read_to_string(token_path()?).ok()?;
    let t = t.trim();
    (!t.is_empty()).then(|| t.to_owned())
}

/// Write the token atomically: dir 0700, file 0600.
fn save_token(token: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    let path = token_path().ok_or_else(|| std::io::Error::other("no HOME"))?;
    let dir = path.parent().unwrap();
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    let tmp = path.with_extension("tmp");
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
    f.write_all(token.as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, &path)
}

/// Unique token for request and session handles (`[A-Za-z0-9_]`).
fn handle_token() -> String {
    static N: AtomicU32 = AtomicU32::new(0);
    format!("crossshell{}_{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed))
}

/// Run one portal request: subscribe to its `Response` before calling, so
/// the answer cannot be missed, then wait for it.
fn request<F>(conn: &Connection, timeout: Duration, what: &str, call: F) -> anyhow::Result<Dict>
where
    F: FnOnce(&str) -> zbus::Result<OwnedObjectPath>,
{
    let token = handle_token();
    let sender = conn.unique_name().ok_or_else(|| anyhow!("no unique bus name"))?;
    let sender = sender.as_str().trim_start_matches(':').replace('.', "_");
    let expected = format!("{PATH}/request/{sender}/{token}");
    let req = dbus::proxy(conn, DEST, expected.as_str(), REQUEST)?;
    let mut responses = Signals::subscribe(&req, "Response")?;
    let handle = call(&token).with_context(|| format!("portal {what}"))?;
    if handle.as_str() != expected {
        // Portals older than 0.9 pick their own path; listen there instead.
        let req = dbus::proxy(conn, DEST, handle.as_str(), REQUEST)?;
        responses = Signals::subscribe(&req, "Response")?;
    }
    let Some(msg) = responses.next(timeout) else {
        if let Ok(p) = dbus::proxy(conn, DEST, handle.as_str(), REQUEST) {
            let _ = p.call::<_, _, ()>("Close", &());
        }
        bail!("portal {what}: no answer within {timeout:?}");
    };
    let (code, results): (u32, Dict) = msg.body().deserialize()?;
    match code {
        0 => Ok(results),
        1 => bail!("portal {what}: cancelled (the screen-sharing request was declined)"),
        _ => bail!("portal {what}: failed (response {code})"),
    }
}

fn opts(pairs: Vec<(&'static str, Value<'static>)>) -> HashMap<&'static str, Value<'static>> {
    pairs.into_iter().collect()
}

/// A stream from `Start`.
#[derive(Debug, Clone, PartialEq)]
struct PortalStream {
    node_id: u32,
    position: Option<(i32, i32)>,
    size: Option<(i32, i32)>,
}

fn parse_streams(v: &Value) -> Vec<PortalStream> {
    let Value::Array(a) = v else { return Vec::new() };
    a.iter()
        .filter_map(|item| {
            let Value::Structure(s) = item else { return None };
            let [Value::U32(node_id), Value::Dict(props)] = s.fields() else { return None };
            let props: HashMap<String, OwnedValue> = HashMap::try_from(props.try_clone().ok()?).ok()?;
            Some(PortalStream {
                node_id: *node_id,
                position: dbus::get_pair(&props, "position"),
                size: dbus::get_pair(&props, "size"),
            })
        })
        .collect()
}

/// The portal session; closed when the last user drops it.
struct Session {
    conn: Connection,
    handle: OwnedObjectPath,
}

impl Drop for Session {
    fn drop(&mut self) {
        log::info!("portal: closing session {}", self.handle.as_str());
        if let Ok(p) = dbus::proxy(&self.conn, DEST, self.handle.as_str(), SESSION) {
            let _ = p.call::<_, _, ()>("Close", &());
        }
    }
}

struct Stream {
    info: DisplayInfo,
    node_id: u32,
    geometry: SharedGeometry,
}

pub struct PortalBackend {
    session: Arc<Session>,
    streams: Vec<Stream>,
    /// Capturers opened while sizing the displays, reused for the first
    /// `capturer()` call.
    probed: HashMap<u8, PwCapturer>,
}

impl PortalBackend {
    pub fn start() -> anyhow::Result<Self> {
        let conn = dbus::session()?;
        if !available(&conn) {
            bail!("xdg-desktop-portal is not available");
        }
        let rd = dbus::proxy(&conn, DEST, PATH, RD)?;
        let sc = dbus::proxy(&conn, DEST, PATH, SC)?;
        let rd_version: u32 = rd.get_property("version").context("no RemoteDesktop portal")?;
        let cursor_modes: u32 = sc.get_property("AvailableCursorModes").unwrap_or(CURSOR_EMBEDDED);
        log::info!("portal: RemoteDesktop v{rd_version}, cursor modes {cursor_modes:#x}");

        let results = request(&conn, REQUEST_TIMEOUT, "CreateSession", |t| {
            rd.call(
                "CreateSession",
                &(opts(vec![("handle_token", t.to_owned().into()), ("session_handle_token", handle_token().into())]),),
            )
        })?;
        let handle: String = dbus::get(&results, "session_handle").ok_or_else(|| anyhow!("portal gave no session"))?;
        let session = Arc::new(Session { conn: conn.clone(), handle: OwnedObjectPath::try_from(handle)? });
        let sh = &session.handle;

        let restore = load_token();
        request(&conn, REQUEST_TIMEOUT, "SelectDevices", |t| {
            let mut o = opts(vec![("handle_token", t.to_owned().into()), ("types", DEVICES.into())]);
            if rd_version >= 2 {
                o.insert("persist_mode", PERSIST_UNTIL_REVOKED.into());
                if let Some(tok) = &restore {
                    o.insert("restore_token", tok.clone().into());
                }
            }
            rd.call("SelectDevices", &(sh, o))
        })?;

        // On GNOME the portal is backed by Mutter, with the same multi-monitor
        // limitation (see `mutter::want_cursor_metadata`).
        let metadata_ok = crate::mutter::want_cursor_metadata(crate::mutter::monitor_count(&conn).unwrap_or(1));
        let cursor_mode =
            if cursor_modes & CURSOR_METADATA != 0 && metadata_ok { CURSOR_METADATA } else { CURSOR_EMBEDDED };
        request(&conn, REQUEST_TIMEOUT, "SelectSources", |t| {
            let o = opts(vec![
                ("handle_token", t.to_owned().into()),
                ("types", SOURCE_MONITOR.into()),
                ("multiple", true.into()),
                ("cursor_mode", cursor_mode.into()),
            ]);
            sc.call("SelectSources", &(sh, o))
        })?;

        if restore.is_none() {
            log::info!("portal: waiting for the user to allow screen sharing on this desktop");
        }
        let results = request(&conn, CONSENT_TIMEOUT, "Start", |t| {
            rd.call("Start", &(sh, "", opts(vec![("handle_token", t.to_owned().into())])))
        })?;

        let devices: u32 = dbus::get(&results, "devices").unwrap_or(0);
        if devices & DEVICES != DEVICES {
            log::warn!("portal: only granted devices {devices:#x}; input may not work");
        }
        if let Some(tok) = dbus::get::<String>(&results, "restore_token") {
            match save_token(&tok) {
                Ok(()) => log::info!("portal: saved restore token"),
                Err(e) => log::warn!("portal: cannot save restore token: {e}"),
            }
        }
        let streams = results.get("streams").map(|v| parse_streams(v)).unwrap_or_default();
        if streams.is_empty() {
            bail!("portal shared no screens");
        }

        // GNOME's portal passes pointer coordinates straight to Mutter, which
        // wants buffer pixels; other portals (KDE) want the logical size
        // they report for the stream.
        let pixel_coords = dbus::has_owner(&conn, "org.gnome.Mutter.ScreenCast");
        let mut me = PortalBackend { session, streams: Vec::new(), probed: HashMap::new() };
        for (i, s) in streams.into_iter().enumerate() {
            let index = i as u8;
            let logical = s.size.filter(|_| !pixel_coords).map(|(w, h)| (w as f64, h as f64));
            let geometry = Arc::new(Mutex::new(Geometry { logical, ..Default::default() }));
            // The viewer needs frame-pixel sizes up front; only the stream
            // knows them (HiDPI makes them differ from the logical size).
            let cap = PwCapturer::start(me.source(s.node_id)?, geometry.clone(), me.session.clone())?;
            let (w, h) = cap.wait_format(PROBE_TIMEOUT).with_context(|| format!("sizing screen {}", i + 1))?;
            me.probed.insert(index, cap);
            let (x, y) = s.position.unwrap_or_default();
            let info = DisplayInfo { index, name: format!("Screen {}", i + 1), x, y, width: w, height: h, primary: i == 0 };
            log::info!("portal: display {index} {w}x{h} at {x},{y} (logical {:?}) → PipeWire node {}", s.size, s.node_id);
            me.streams.push(Stream { info, node_id: s.node_id, geometry });
        }
        Ok(me)
    }

    /// A fresh PipeWire connection for this session's streams.
    fn source(&self, node_id: u32) -> anyhow::Result<PwSource> {
        let sc = dbus::proxy(&self.session.conn, DEST, PATH, SC)?;
        let fd: zvariant::OwnedFd = sc
            .call("OpenPipeWireRemote", &(self.session.handle.as_ref(), HashMap::<&str, Value>::new()))
            .context("portal OpenPipeWireRemote")?;
        Ok(PwSource { remote: Some(fd.into()), node_id })
    }

    fn stream(&self, display: u8) -> anyhow::Result<&Stream> {
        self.streams.iter().find(|s| s.info.index == display).ok_or_else(|| anyhow!("no display {display}"))
    }
}

impl Backend for PortalBackend {
    fn displays(&mut self) -> anyhow::Result<Vec<DisplayInfo>> {
        Ok(self.streams.iter().map(|s| s.info.clone()).collect())
    }

    fn capturer(&mut self, display: u8) -> anyhow::Result<Box<dyn Capturer>> {
        let cap = self.probed.remove(&display);
        // The other probes would only keep copying frames nobody reads.
        self.probed.clear();
        if let Some(cap) = cap {
            return Ok(Box::new(cap));
        }
        let s = self.stream(display)?;
        let src = self.source(s.node_id)?;
        Ok(Box::new(PwCapturer::start(src, s.geometry.clone(), self.session.clone())?))
    }

    fn injector(&mut self, display: u8) -> anyhow::Result<Box<dyn Injector>> {
        let s = self.stream(display)?;
        let input = PortalInput {
            rd: dbus::proxy(&self.session.conn, DEST, PATH, RD)?,
            node_id: s.node_id,
            session: self.session.clone(),
        };
        Ok(Box::new(StreamInjector::new(input, s.geometry.clone())))
    }
}

struct PortalInput {
    rd: Proxy<'static>,
    node_id: u32,
    session: Arc<Session>,
}

fn no_opts() -> HashMap<&'static str, Value<'static>> {
    HashMap::new()
}

impl RemoteInput for PortalInput {
    fn motion_absolute(&mut self, x: f64, y: f64, wait: bool) -> anyhow::Result<()> {
        let body = (self.session.handle.as_ref(), no_opts(), self.node_id, x, y);
        if wait {
            self.rd.call::<_, _, ()>("NotifyPointerMotionAbsolute", &body)?;
        } else {
            self.rd.call_noreply("NotifyPointerMotionAbsolute", &body)?;
        }
        Ok(())
    }

    fn button(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
        let body = (self.session.handle.as_ref(), no_opts(), code as i32, down as u32);
        Ok(self.rd.call::<_, _, ()>("NotifyPointerButton", &body)?)
    }

    fn axis_discrete(&mut self, axis: u32, steps: i32) -> anyhow::Result<()> {
        let body = (self.session.handle.as_ref(), no_opts(), axis, steps);
        Ok(self.rd.call::<_, _, ()>("NotifyPointerAxisDiscrete", &body)?)
    }

    fn key(&mut self, code: u16, down: bool) -> anyhow::Result<()> {
        let body = (self.session.handle.as_ref(), no_opts(), code as i32, down as u32);
        Ok(self.rd.call::<_, _, ()>("NotifyKeyboardKeycode", &body)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::{Array, Dict as ZDict, Signature, StructureBuilder};

    #[test]
    fn streams_are_parsed_from_start_results() {
        let mut props = ZDict::new(&Signature::Str, &Signature::Variant);
        props.append(Value::from("position"), Value::new(Value::from(StructureBuilder::new().add_field(1920i32).add_field(0i32).build().unwrap()))).unwrap();
        props.append(Value::from("size"), Value::new(Value::from(StructureBuilder::new().add_field(1280i32).add_field(720i32).build().unwrap()))).unwrap();
        props.append(Value::from("source_type"), Value::new(Value::from(1u32))).unwrap();
        let item = Value::from(StructureBuilder::new().add_field(57u32).append_field(Value::Dict(props)).build().unwrap());
        let sig = item.value_signature().clone();
        let mut arr = Array::new(&sig);
        arr.append(item).unwrap();
        let v = Value::Array(arr);
        assert_eq!(parse_streams(&v), [PortalStream { node_id: 57, position: Some((1920, 0)), size: Some((1280, 720)) }]);
        assert!(parse_streams(&Value::from(3u32)).is_empty());
    }

    #[test]
    fn handle_tokens_are_unique_and_path_safe() {
        let (a, b) = (handle_token(), handle_token());
        assert_ne!(a, b);
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
    }
}
