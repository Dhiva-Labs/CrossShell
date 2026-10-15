# Building crossshell-platform-linux

The crate links `libpipewire-0.3` and generates its bindings with bindgen, so
it needs the PipeWire/SPA headers and libclang at build time. D-Bus (zbus) and
X11 (x11rb) are pure Rust and need nothing extra.

## CI / machines with root

```sh
sudo apt install libpipewire-0.3-dev libclang-dev pkg-config clang
cargo build -p crossshell-host
```

## Without root (dev machines)

The PipeWire runtime library is already installed with any desktop; only the
headers are missing. Unpack the -dev packages into a private prefix and point
pkg-config at it:

```sh
ROOT=$HOME/.cache/crossshell-devroot
mkdir -p "$ROOT/debs" && cd "$ROOT/debs"
apt-get download libpipewire-0.3-dev libspa-0.2-dev
for d in *.deb; do dpkg -x "$d" "$ROOT"; done

LIB=$ROOT/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)   # x86_64-linux-gnu or aarch64-linux-gnu
# The .pc files say prefix=/usr; make them point into the private prefix.
sed -i "s|^prefix=.*|prefix=$ROOT/usr|" "$LIB"/pkgconfig/libpipewire-0.3.pc "$LIB"/pkgconfig/libspa-0.2.pc
# The -dev symlink libpipewire-0.3.so -> libpipewire-0.3.so.0 dangles inside
# the prefix; aim it at the installed runtime library.
ln -sfn "/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/libpipewire-0.3.so.0" "$LIB/libpipewire-0.3.so"

export PKG_CONFIG_PATH=$LIB/pkgconfig
cargo build -p crossshell-host
```

Use the same versions as the installed runtime (`dpkg -l libpipewire-0.3-0t64`);
`apt-get download` picks the candidate version, which matches after an update.

bindgen finds libclang on its own when `clang` is installed (it ships
`libclang-NN.so.1` and the builtin headers). If it does not, point it there:

```sh
export LIBCLANG_PATH=/usr/lib/llvm-21/lib
export BINDGEN_EXTRA_CLANG_ARGS="-I$ROOT/usr/include/spa-0.2 -I$ROOT/usr/include/pipewire-0.3"
```

## Testing without touching your desktop

`examples/probe.rs` drives the backend directly (`--display N --seconds S
--ppm out.ppm`, plus `--move X,Y` / `--input` for input). Never point it, or
`crossshell-host`, at the desktop you are using. Build every test environment
from scratch with `env -i` so nothing is inherited from your session — an
unset `DBUS_SESSION_BUS_ADDRESS` silently falls back to your live bus, and
your `XDG_RUNTIME_DIR` holds your live Wayland and PipeWire sockets.

A fully private headless GNOME session (own runtime dir, D-Bus, PipeWire,
WirePlumber and gnome-shell; the runtime dir must be short, sockets are
limited to 108 bytes):

```sh
T=$HOME/.cache/crossshell-test; RT=/tmp/csrt-$(id -u)
mkdir -p -m 700 "$RT" "$T"/{config/wireplumber/wireplumber.conf.d,cache,data,state}
# A WirePlumber profile that touches no audio, Bluetooth or camera devices.
cat > "$T/config/wireplumber/wireplumber.conf.d/90-test.conf" <<'CONF'
wireplumber.profiles = { crossshell-test = { inherits = [ main ]
  hardware.audio = disabled, hardware.bluetooth = disabled,
  hardware.video-capture = disabled, support.reserve-device = disabled,
  support.logind = disabled } }
CONF
env -i HOME="$HOME" PATH="$PATH" LANG=C.UTF-8 XDG_RUNTIME_DIR="$RT" \
  XDG_CONFIG_HOME="$T/config" XDG_CACHE_HOME="$T/cache" XDG_DATA_HOME="$T/data" \
  XDG_STATE_HOME="$T/state" GSETTINGS_BACKEND=memory XDG_SESSION_TYPE=wayland \
  XDG_CURRENT_DESKTOP=GNOME dbus-run-session -- sh -c '
    pipewire & sleep 0.5; wireplumber -p crossshell-test &
    echo "$DBUS_SESSION_BUS_ADDRESS" > "$XDG_STATE_HOME/bus"
    gnome-shell --headless --wayland --no-x11 --wayland-display=cs-test-0 \
      --virtual-monitor 1280x720; kill $(jobs -p)' &
```

Then run every test command with the same `env -i ...` prefix plus
`DBUS_SESSION_BUS_ADDRESS=$(cat $T/state/bus) WAYLAND_DISPLAY=cs-test-0`. Add
more `--virtual-monitor` options for multi-monitor tests; scale can be changed
temporarily with `org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig`
(method 1). The session runs its own xdg-desktop-portal, so the portal backend
can be tested too (`CROSSSHELL_LINUX_BACKEND=portal`; the consent dialog shows
inside the headless shell).

`--input` (clicks, keys, scroll) and `--move` refuse to run unless
`CROSSSHELL_PROBE_INPUT_OK=1` is set and `DBUS_SESSION_BUS_ADDRESS` names a bus
other than your default one. For X11, run `Xvfb :99 -screen 0 1280x720x24`
and use `env -i HOME="$HOME" PATH="$PATH" DISPLAY=:99
DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent CROSSSHELL_LINUX_BACKEND=x11 ...`.

## Runtime switches

- `CROSSSHELL_LINUX_BACKEND=mutter|portal|x11` forces one backend (the host
  honours it too).
- `CROSSSHELL_CURSOR=metadata|embedded` overrides the cursor mode on GNOME.
  The default is metadata (cursor sent to the viewer separately) with one
  monitor and embedded (drawn into frames) with several: with two monitors,
  Mutter 50 never delivers full frames for the first monitor's stream in
  metadata mode (cursor-only frames triggered by the other monitor keep its
  frame-rate limiter shut). Seen on headless GNOME with virtual monitors.
