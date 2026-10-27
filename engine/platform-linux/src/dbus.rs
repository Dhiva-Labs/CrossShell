//! Small zbus helpers: a private session-bus connection, name checks, and
//! waiting for a signal with a timeout.
//!
//! Mostly for the PipeWire backends; an X11-only build uses just [`proxy`]
//! (for notifications).
#![cfg_attr(not(feature = "pipewire"), allow(dead_code))]

use std::collections::HashMap;
use std::time::Duration;

use anyhow::Context;
use futures_lite::StreamExt;
use zbus::blocking::{Connection, Proxy};
use zbus::proxy::CacheProperties;
use zbus::zvariant::{OwnedValue, Value};

/// Default reply timeout for method calls (the consent dialog is waited
/// for through a signal, not a reply).
const METHOD_TIMEOUT: Duration = Duration::from_secs(15);

pub type Dict = HashMap<String, OwnedValue>;

/// A connection of our own to the session bus. Compositor sessions are tied
/// to it: when it closes, they close too.
pub fn session() -> anyhow::Result<Connection> {
    zbus::blocking::connection::Builder::session()?
        .method_timeout(METHOD_TIMEOUT)
        .build()
        .context("connecting to the D-Bus session bus")
}

pub fn proxy<'a, P>(conn: &Connection, dest: &'a str, path: P, iface: &'a str) -> anyhow::Result<Proxy<'a>>
where
    P: TryInto<zbus::zvariant::ObjectPath<'a>>,
    P::Error: Into<zbus::Error>,
{
    Ok(zbus::blocking::proxy::Builder::new(conn)
        .destination(dest)?
        .path(path)?
        .interface(iface)?
        .cache_properties(CacheProperties::No)
        .build()?)
}

/// Is `name` currently owned on the bus?
pub fn has_owner(conn: &Connection, name: &str) -> bool {
    let Ok(p) = proxy(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus") else {
        return false;
    };
    p.call::<_, _, bool>("NameHasOwner", &(name,)).unwrap_or(false)
}

/// Is `name` owned now or startable by D-Bus activation?
pub fn available(conn: &Connection, name: &str) -> bool {
    if has_owner(conn, name) {
        return true;
    }
    let Ok(p) = proxy(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus") else {
        return false;
    };
    p.call::<_, _, Vec<String>>("ListActivatableNames", &()).is_ok_and(|names| names.iter().any(|n| n == name))
}

/// A signal subscription that can be waited on with a timeout. Subscribe
/// before triggering the signal so it cannot be missed.
pub struct Signals(zbus::proxy::SignalStream<'static>);

impl Signals {
    pub fn subscribe(proxy: &Proxy<'_>, name: &'static str) -> anyhow::Result<Self> {
        Ok(Signals(async_io::block_on(proxy.inner().receive_signal(name))?))
    }

    /// The next signal, or `None` after `timeout`.
    pub fn next(&mut self, timeout: Duration) -> Option<zbus::Message> {
        async_io::block_on(futures_lite::future::or(self.0.next(), async {
            async_io::Timer::after(timeout).await;
            None
        }))
    }
}

/// Typed value from an `a{sv}` dictionary.
pub fn get<T>(d: &Dict, key: &str) -> Option<T>
where
    T: TryFrom<OwnedValue>,
{
    d.get(key).and_then(|v| v.try_clone().ok()).and_then(|v| T::try_from(v).ok())
}

/// `(ii)` value from an `a{sv}` dictionary.
pub fn get_pair(d: &Dict, key: &str) -> Option<(i32, i32)> {
    let mut v: &Value = d.get(key)?;
    while let Value::Value(inner) = v {
        v = inner;
    }
    match v {
        Value::Structure(s) => match s.fields() {
            [Value::I32(a), Value::I32(b)] => Some((*a, *b)),
            _ => None,
        },
        _ => None,
    }
}
