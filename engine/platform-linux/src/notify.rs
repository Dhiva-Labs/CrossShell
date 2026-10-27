//! Desktop notifications over `org.freedesktop.Notifications` (any
//! notification daemon: GNOME Shell, KDE, mako, dunst, …), used to tell the
//! person at the machine that a viewer is connected.
//!
//! Best effort: no session bus or no notification daemon (a headless
//! server, an Xvfb virtual desktop) just means no notification.

use std::collections::HashMap;
use std::sync::mpsc::Receiver;
use std::time::Duration;

use zbus::blocking::Connection;
use zbus::zvariant::Value;

use crate::dbus;

const NAME: &str = "org.freedesktop.Notifications";
const PATH: &str = "/org/freedesktop/Notifications";
/// A daemon that does not answer within this is treated as absent.
const TIMEOUT: Duration = Duration::from_secs(3);
const APP_NAME: &str = "CrossShell";
const ICON: &str = "preferences-desktop-remote-desktop";

/// Urgency hint values from the notification spec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Urgency {
    Normal = 1,
    /// Stays on screen until dismissed (GNOME also shows it in Do Not Disturb).
    Critical = 2,
}

/// A notification on screen. Closed when dropped.
pub struct Notification {
    conn: Connection,
    id: u32,
}

impl Notification {
    /// Show `summary` (plain text, never markup) on the session bus.
    pub fn show(summary: &str, urgency: Urgency) -> anyhow::Result<Notification> {
        let conn = zbus::blocking::connection::Builder::session()?.method_timeout(TIMEOUT).build()?;
        Self::show_on(conn, summary, urgency)
    }

    fn show_on(conn: Connection, summary: &str, urgency: Urgency) -> anyhow::Result<Notification> {
        let p = dbus::proxy(&conn, NAME, PATH, NAME)?;
        let mut hints: HashMap<&str, Value> = HashMap::new();
        hints.insert("urgency", Value::U8(urgency as u8));
        // The body may be interpreted as markup by some daemons, so the
        // viewer-supplied text only goes into the summary.
        let id: u32 = p.call(
            "Notify",
            &(APP_NAME, 0u32, ICON, summary, "", Vec::<&str>::new(), hints, 0i32 /* never expire */),
        )?;
        Ok(Notification { conn, id })
    }
}

impl Drop for Notification {
    fn drop(&mut self) {
        let closed = dbus::proxy(&self.conn, NAME, PATH, NAME)
            .and_then(|p| Ok(p.call::<_, _, ()>("CloseNotification", &(self.id,))?));
        if let Err(e) = closed {
            log::debug!("closing notification {}: {e:#}", self.id);
        }
    }
}

/// Show `summary` until `stop` fires (or its sender is dropped), then close
/// it. Runs on the caller's thread; failures are logged at debug level only.
pub fn show_until(summary: &str, urgency: Urgency, stop: &Receiver<()>) {
    let shown = match Notification::show(summary, urgency) {
        Ok(n) => Some(n),
        Err(e) => {
            log::debug!("no desktop notification: {e:#}");
            None
        }
    };
    let _ = stop.recv();
    drop(shown);
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixStream;
    use std::sync::{Arc, Mutex};

    use zbus::zvariant::OwnedValue;

    use super::*;

    #[derive(Debug, Clone, PartialEq)]
    enum Call {
        Notify { app: String, icon: String, summary: String, body: String, urgency: Option<u8>, expire: i32 },
        Close(u32),
    }

    struct FakeDaemon(Arc<Mutex<Vec<Call>>>);

    #[zbus::interface(name = "org.freedesktop.Notifications")]
    impl FakeDaemon {
        #[allow(clippy::too_many_arguments)]
        fn notify(
            &self,
            app_name: String,
            _replaces_id: u32,
            app_icon: String,
            summary: String,
            body: String,
            _actions: Vec<String>,
            hints: HashMap<String, OwnedValue>,
            expire_timeout: i32,
        ) -> u32 {
            let urgency = hints.get("urgency").and_then(|v| u8::try_from(v).ok());
            self.0.lock().unwrap().push(Call::Notify {
                app: app_name,
                icon: app_icon,
                summary,
                body,
                urgency,
                expire: expire_timeout,
            });
            42
        }

        fn close_notification(&self, id: u32) {
            self.0.lock().unwrap().push(Call::Close(id));
        }
    }

    /// A peer-to-peer connection to a fake daemon: no bus, nothing from the
    /// user's session is touched.
    fn fake_daemon() -> (Connection, Connection, Arc<Mutex<Vec<Call>>>) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let (a, b) = UnixStream::pair().unwrap();
        let daemon = FakeDaemon(calls.clone());
        let server = std::thread::spawn(move || {
            zbus::blocking::connection::Builder::async_io_unix_stream(a)
                .server(zbus::Guid::generate())
                .unwrap()
                .p2p()
                .serve_at(PATH, daemon)
                .unwrap()
                .build()
                .unwrap()
        });
        let client = zbus::blocking::connection::Builder::async_io_unix_stream(b).p2p().build().unwrap();
        (client, server.join().unwrap(), calls)
    }

    #[test]
    fn notify_then_close_on_drop() {
        let (client, _server, calls) = fake_daemon();
        let n = Notification::show_on(client, "Your screen is being viewed from <b>pc</b>", Urgency::Critical).unwrap();
        assert_eq!(n.id, 42);
        drop(n);
        assert_eq!(
            *calls.lock().unwrap(),
            vec![
                Call::Notify {
                    app: "CrossShell".into(),
                    icon: ICON.into(),
                    summary: "Your screen is being viewed from <b>pc</b>".into(),
                    body: String::new(),
                    urgency: Some(2),
                    expire: 0,
                },
                Call::Close(42),
            ]
        );
    }

    #[test]
    fn a_missing_daemon_is_an_error_not_a_hang() {
        // A peer with objects, but none at the notifications path.
        let (a, b) = UnixStream::pair().unwrap();
        let server = std::thread::spawn(move || {
            zbus::blocking::connection::Builder::async_io_unix_stream(a)
                .server(zbus::Guid::generate())
                .unwrap()
                .p2p()
                .serve_at("/elsewhere", FakeDaemon(Arc::default()))
                .unwrap()
                .build()
                .unwrap()
        });
        let client = zbus::blocking::connection::Builder::async_io_unix_stream(b)
            .p2p()
            .method_timeout(TIMEOUT)
            .build()
            .unwrap();
        let _server = server.join().unwrap();
        let t = std::time::Instant::now();
        assert!(Notification::show_on(client, "x", Urgency::Normal).is_err());
        assert!(t.elapsed() < TIMEOUT, "took {:?}", t.elapsed());
    }
}
