# CrossShell — plan and specs

CrossShell makes two machines on the same LAN — typically a Linux daily
driver and a Windows build box — behave like one desk:

- **SSH both ways**, set up for you: the OS's own OpenSSH server is enabled,
  keys are exchanged by a pairing ceremony, and `~/.ssh/config` gets an entry,
  so plain `ssh`, VS Code Remote-SSH, rsync and git work too.
- **Terminal, files and port forwards** in the app, over that SSH.
- **Remote desktop** (TeamViewer-style view + control), our own engine,
  tunneled through SSH — no extra open ports, no third-party servers.

Everything works in both directions: Linux→Windows and Windows→Linux (and
Linux↔Linux, Windows↔Windows for free).

## Principles

1. **SSH is the only trust boundary.** Remote desktop, token fetch and agent
   start all ride on SSH authenticated with the pairing key. Nothing but sshd
   and the pairing/discovery port listen on the LAN.
2. **Use the OS's OpenSSH**, never a bundled sshd. Users keep their tools.
3. **Pin host keys at pairing.** No trust-on-first-use, ever.
4. **Language by fit.** Flutter for the UI, Rust for the capture/encode/input
   engine. Components talk over processes, stdin/stdout JSON lines and files.
5. **Be honest about platform limits** in the UI and docs (see Limits).

## Repo layout

| Path | What |
|---|---|
| `app/` | Flutter desktop app (Linux + Windows), package `cross_shell` |
| `engine/` | Rust workspace |
| `engine/crossshell-proto/` | Remote-desktop wire protocol + tile codec + keymaps (lib) |
| `engine/crossshell-host/` | Screen-share agent (bin `crossshell-host`) |
| `engine/crossshell-view/` | Viewer window (bin `crossshell-view`) |
| `scripts/` | Elevated setup scripts (`windows-setup.ps1`, `linux-setup.sh`) — also bundled as app assets |
| `docs/` | User + design docs |

## Ports

| Port | Proto | Bind | Purpose |
|---|---|---|---|
| 22 (configurable) | TCP | LAN | OS sshd |
| 47820 | UDP | LAN | Discovery beacons (broadcast) |
| 47820 | TCP | LAN | Pairing ceremony only |
| 47821 | TCP | **127.0.0.1 only** | Screen-share agent; reached via SSH local forward |

## Identity and files

Per machine, in the app support dir (`~/.local/share/cross_shell` on Linux,
`%APPDATA%\com.dhivalabs\cross_shell` on Windows via path_provider):

- `device.json` — `{id: uuid-v4, name: hostname}`
- `peers.json` — paired peers (see Peer record)

SSH material (shared with the system `ssh` client), all under `~/.ssh/crossshell/`:

- `id_ed25519{,.pub}` — this machine's client key, made with
  `ssh-keygen -t ed25519 -N "" -C crossshell@<hostname>`.
- `known_hosts` — pinned host keys, one line per key:
  `crossshell-<peer-id> <keytype> <base64>`.
- `config` — one managed block per peer, wholly owned by CrossShell:

```
# >>> crossshell peer <peer-id> >>>
Host <alias>
  HostName <last-seen-ip>
  Port <ssh-port>
  User <ssh-user>
  IdentityFile ~/.ssh/crossshell/id_ed25519
  IdentitiesOnly yes
  HostKeyAlias crossshell-<peer-id>
  UserKnownHostsFile ~/.ssh/crossshell/known_hosts
  StrictHostKeyChecking yes
  ServerAliveInterval 15
# <<< crossshell peer <peer-id> <<<
```

`~/.ssh/config` gets a single `Include crossshell/config` line at the very
top (an Include inside a Host block would only apply to that host), so
`ssh <alias>`, VS Code Remote-SSH, rsync and git all work. The app's own
system-ssh calls use `-F ~/.ssh/crossshell/config` so the user's config
can't redirect them.

Authorized keys get the peer's client key with a marker comment
`crossshell:<peer-id>` so unpairing can remove exactly that line:

- Linux, or Windows non-admin: `~/.ssh/authorized_keys` (0600, dir 0700).
- Windows admin (member of S-1-5-32-544): `C:\ProgramData\ssh\administrators_authorized_keys`
  via the elevated script (UAC), ACL = Administrators + SYSTEM only. sshd's
  stock `Match Group administrators` block ignores the per-user file.

Own host key: `ssh-keyscan -t ed25519,ecdsa,rsa -p <port> 127.0.0.1`
(the Windows `.pub` files are admin-only readable, keyscan works unelevated).

### Peer record

```json
{"id":"…","name":"winbox","os":"windows","alias":"winbox",
 "sshUser":"alex","sshPort":22,"hostKeys":["ssh-ed25519 AAAA…"],
 "clientKey":"ssh-ed25519 AAAA… crossshell:<id>","lastIp":"192.168.1.20",
 "pairedAt":"2026-10-11T12:00:00Z","hostAgent":{"path":"…"}}
```

## Discovery (UDP 47820)

Every 3 s (and immediately on start / network change) each running app
broadcasts to 255.255.255.255 and each interface's directed broadcast:

```json
{"cs":1,"id":"<uuid>","name":"winbox","os":"windows","user":"alex",
 "sshPort":22,"pairPort":47820,"ver":"0.1.0"}
```

Receivers ignore their own id, keep a "seen" table (expires after 10 s), and
update `lastIp` + the ssh config `HostName` of paired peers. Manual "add by
IP" sends a unicast beacon request (`{"cs":1,"q":1}`) the peer answers with
its beacon.

## Pairing (TCP 47820) — numeric comparison with commitment

Frames: 4-byte big-endian length + UTF-8 JSON. Max frame 64 KiB.
Initiator I connects to responder R. All hashes SHA-256, keys X25519.

1. I→R `{"t":"hello","v":1,"id","name","os","commit":b64(H("cs-commit"‖pkI‖nI))}`
   where pkI is a fresh X25519 public key, nI 32 random bytes.
2. R shows nothing yet; R→I `{"t":"key","id","name","os","pk":b64(pkR)}`
3. I→R `{"t":"reveal","pk":b64(pkI),"nonce":b64(nI)}`. R checks the commit.
4. Both compute `ss = X25519`, `th = H("cs-pair-v1"‖pkI‖pkR‖nI‖lp(idI)‖lp(idR))`
   (`lp` = u16 big-endian length prefix, so ids can't be re-split),
   `SAS = (first 4 bytes of H("cs-sas"‖th) as u32 BE) mod 10^6`, shown as `123 456`.
   The commitment stops a MITM from grinding the SAS: I is bound to pkI
   before it sees pkR, and R reveals pkR before it sees pkI.
5. Each user confirms the code matches the other screen. On confirm, a side
   sends `{"t":"confirm"}`; on reject `{"t":"abort","reason"}` and closes.
6. Once a side has **both** sent and received confirm, it sends its sealed
   payload: `{"t":"payload","box":b64(nonce12‖ChaCha20-Poly1305(k, json))}`
   with `k = HKDF-SHA256(ss, salt=th, info="cs-pair-key-I"|"cs-pair-key-R")`
   (direction-specific keys, nonce random). Payload JSON:
   `{"sshUser","sshPort","hostKeys":[…],"clientKey","name","os","ip"}`.
7. Each side applies the other's payload (authorize key, pin host keys, write
   config block, save peer) and sends `{"t":"done","ok":true|false,"err"}`.

Timeouts: 120 s for user confirmation, 10 s per protocol step. R accepts
pairing connections only while the app is open; an incoming hello pops a
dialog. One pairing at a time; a second concurrent hello gets `busy`.

## SSH server setup ("Doctor")

Checks (all non-elevated): sshd banner on 127.0.0.1:<port>; client key
exists; peer reachable (TCP connect + banner) ; key auth works
(`ssh -o BatchMode=yes <alias> echo ok`).

Fixes:
- Linux (pkexec `scripts/linux-setup.sh`): install `openssh-server` via
  apt/dnf/pacman/zypper, `systemctl enable --now ssh.socket|ssh|sshd`, if
  `ufw` is active allow 22/tcp + 47820 udp/tcp from local subnet.
- Windows (UAC `scripts/windows-setup.ps1`): `Add-WindowsCapability
  OpenSSH.Server~~~~0.0.1.0`, `sshd` Automatic + started; firewall rules
  `CrossShell SSH` (TCP 22), `CrossShell Discovery` (UDP 47820), `CrossShell
  Pairing` (TCP 47820), all `-Profile Any -RemoteAddress LocalSubnet`;
  optional `DefaultShell` = PowerShell (only if unset); `-AuthorizeKey` /
  `-RevokeKey` for administrators_authorized_keys.

## Terminal, files, forwards

dartssh2 with the pairing key and pinned host keys (code lineage:
SecureShellGo). Terminal = xterm widget, multiple tabs. Files = SFTP
two-pane browser with upload/download/mkdir/rename/delete. Forwards = local
(`-L`) and remote (`-R`) TCP forwards with presets. "Open in system
terminal" runs `ssh <alias>` in the OS terminal; "Open in VS Code" runs
`code --remote ssh-remote+<alias> <path>`.

## Remote desktop

### Process model

```
viewer machine                                   host machine
┌───────────────┐   ssh -N -L p:127.0.0.1:47821  ┌──────────────────────┐
│ Flutter app   │ ─────────── (system ssh) ────► │ sshd                  │
│  spawns ──► crossshell-view ── tcp 127.0.0.1:p ─┼─► crossshell-host     │
└───────────────┘                                │  (user's GUI session)│
                                                 └──────────────────────┘
```

1. Viewer app runs `ssh <alias> <read-host-json>` to fetch the host's
   `host.json`. If it's missing or stale it starts the agent remotely, waits,
   and retries:
   - Windows: `schtasks /Create /F /TN CrossShellHost /SC ONCE /ST 00:00 /IT /TR "<path>"`
     then `schtasks /Run /TN CrossShellHost` (SSH sessions are session 0;
     `/IT` lands the agent in the interactive desktop).
   - Linux: `systemd-run --user --collect --unit=crossshell-host <path>`
     (inherits WAYLAND_DISPLAY/DISPLAY/DBUS from the user manager).
2. Viewer app opens `ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:<p>:127.0.0.1:<host-port> <alias>`.
3. Viewer app spawns `crossshell-view --port <p> --title "<peer>" [--view-only]`
   and writes the token (hex) + newline to its stdin (never argv).
4. Viewer prints JSON lines on stdout (`{"ev":"connected"}`, `{"ev":"closed","reason":…}`).

#### Remote-launched agents

Other apps (SecureShell Go) upload a standalone `crossshell-host` over SFTP
and run it for one session. These flags exist for them; without them the
agent behaves as above.

| Flag | Effect |
|---|---|
| `--runtime-dir DIR` | `host.json`, `host.lock`, `status.json` and `host.log` live in `DIR` (created 0700; `host.json` 0600 on unix) instead of the per-user default, so a per-session agent never collides with an installed one. `--info` honours it. |
| `--exit-when-idle SECS` | Exit when no authenticated viewer connected within `SECS` of start, or `SECS` after the last one left (a dead SSH link ends the session after the 15 s idle timeout, then this applies). Removes `host.json` and `status.json` on the way out. Failed logins do not count as a viewer. |
| `--no-notify` | No desktop notification while a viewer is connected (see below). |

**Connect notification.** While a viewer is connected the host shows
"Your screen is being viewed from <viewer_name>" ("viewed and controlled"
unless the session is view-only); the name loses control and bidi-override
characters and is cut to 64 characters. Linux: `org.freedesktop.Notifications`
on the session bus (summary only, never markup; urgency critical when
controlled), closed with `CloseNotification` when the session ends.
Windows: a notification-area icon with an info balloon (Windows 10/11 show it
as a toast), removed when the session ends. A missing notification service
is ignored.

**Agent binaries** (`scripts/build-agents.sh` → `dist/agents/`, plus
`SHA256SUMS`):

| File | Backends | Linking |
|---|---|---|
| `crossshell-host-linux-x86_64` | Mutter, portal, X11 | glibc ≥ 2.31, needs `libpipewire-0.3.so.0` |
| `crossshell-host-linux-x86_64-x11` | X11 only (`--no-default-features`) | static musl |
| `crossshell-host-linux-aarch64` | Mutter, portal, X11 | glibc ≥ 2.31, needs `libpipewire-0.3.so.0` |
| `crossshell-host-linux-aarch64-x11` | X11 only | static musl |
| `crossshell-host-windows-x64.exe` | DXGI | system DLLs only |
| `crossshell-host-windows-arm64.exe` | DXGI | system DLLs only |

The full Linux build fails to start where libpipewire is missing (minimal
servers); the `-x11` build runs anywhere and is what Xvfb virtual desktops
use. On an Xvfb display, run the full build with
`CROSSSHELL_LINUX_BACKEND=x11`: otherwise it tries Mutter first, on whatever
session bus it can reach. `crossshell-host --version` names the backends a
build has.

### host.json

Linux `${XDG_RUNTIME_DIR:-$HOME/.cache}/crossshell/host.json` (dir 0700, file 0600);
Windows `%LOCALAPPDATA%\CrossShell\host.json`. Contents:
`{"v":1,"port":47821,"token":"<64 hex>","pid":1234,"ver":"0.1.0"}`.
`--runtime-dir DIR` moves it (and the lock, status and log) to `DIR`.
Token: 32 random bytes, new per agent start. Read over SSH only if the pid
in it is alive (see `remote_commands.dart`). Remote commands are
`sh -c '…'` on Linux (any login shell, even fish) and `powershell
-EncodedCommand …` on Windows (works whether the SSH default shell is cmd or
PowerShell, no quoting pitfalls).

The agent path a peer starts remotely is read from `agent-path` in the
state dir (`~/.local/state/crossshell/`, `%LOCALAPPDATA%\CrossShell\`),
written by the local app at startup — never taken from the network.

The agent binds 127.0.0.1:47821 (falls back to any free port, recorded in
host.json). Single instance via the host.json pid check + bind.

### Wire protocol (crossshell-proto)

All integers little-endian. Message = `u8 type | u32 len | payload[len]`.
Max payload 64 MiB. Strings = `u16 len | utf8`.

Handshake (must complete within 10 s, else close):

| Dir | Type | Name | Payload |
|---|---|---|---|
| V→H | 0x01 | Hello | magic `CSRD`, u16 version=1, token[32], str viewer_name, u32 caps (bits the viewer supports) |
| H→V | 0x02 | Welcome | u16 version, u32 caps (`Hello.caps & host caps`), u8 n_displays, n × Display |
| H→V | 0x03 | Reject | str reason (bad token/version/busy) then close |
| V→H | 0x10 | Start | u8 display_index, u8 quality (0 lossless,1 balanced,2 speed), u8 max_fps, u8 flags (bit0 view_only) |

Display = `u8 index, str name, i32 x, i32 y, u32 width, u32 height, u8 primary`.

Capabilities (`caps` bits). Unknown bits are ignored and never echoed, so a
viewer can always offer more than a host knows; a viewer sending 0 gets the
protocol as it was before caps existed.

| Bit | Name | Meaning |
|---|---|---|
| 0 | `CAP_DEFLATE` | The viewer decodes encoding 4 (Deflate). The host then sends lossless tiles as Deflate instead of Zstd, for viewers without zstd (SecureShell Go's Dart viewer uses `dart:io` zlib). |

Session:

| Dir | Type | Name | Payload |
|---|---|---|---|
| H→V | 0x20 | Frame | u32 seq, u32 width, u32 height, u16 n_rects, n × Rect |
| V→H | 0x21 | FrameAck | u32 seq |
| H→V | 0x22 | CursorShape | u16 w, u16 h, u16 hot_x, u16 hot_y, rgba[w*h*4] (w=h=0 → hidden) |
| H→V | 0x23 | CursorPos | i32 x, i32 y (display coords) |
| H→V | 0x24 | DisplaysChanged | u8 n, n × Display |
| V→H | 0x30 | PointerMove | i32 x, i32 y (absolute, frame pixel coords) |
| V→H | 0x31 | PointerButton | u8 button (1 left,2 middle,3 right,4 back,5 forward), u8 down |
| V→H | 0x32 | Scroll | i16 dx, i16 dy (in 1/120 wheel-notch units, +y = up, +x = right) |
| V→H | 0x33 | Key | u16 evdev keycode, u8 down |
| V→H | 0x34 | ReleaseAll | — (focus lost) |
| both | 0x40 | ClipboardText | utf8 bytes (≤ 1 MiB) |
| both | 0x50 | Ping | u64 nanos |
| both | 0x51 | Pong | u64 nanos (echo) |
| V→H | 0x11 | SelectDisplay | u8 display_index, u8 quality, u8 max_fps |
| H→V | 0x60 | Notice | u8 level, str text (e.g. "screen locked"); empty text clears the notice |

Rect = `u16 x, u16 y, u16 w, u16 h, u8 encoding, u32 len, data[len]`:

| Enc | Name | Data |
|---|---|---|
| 0 | Raw | BGRX, w*h*4 bytes |
| 1 | Zstd | zstd(BGRX) |
| 2 | Jpeg | baseline JPEG (decoded to RGB → BGRX) |
| 3 | Fill | 4 bytes BGRX (X = 0) |
| 4 | Deflate | one zlib stream (RFC 1950: header, deflate data, Adler-32) of BGRX, w*h*4 bytes once inflated, nothing after it. Only sent after `CAP_DEFLATE`. |
| 5 | CopyPrev | u16 src_x, u16 src_y (scroll/move from previous frame) — reserved |

Raw, Zstd and Deflate carry the same bytes: the rect's pixels, rows top to
bottom, no padding. The X byte is whatever the capture produced; decoders
ignore it. A rect whose compressed form would not be smaller is sent Raw.

Pixel format in frames is BGRX (B,G,R,X bytes per pixel), which is
little-endian `0x00RRGGBB` as u32 — softbuffer's native layout.

### Flow control

Host keeps at most **2** unacked frames in flight; when the window is full it
keeps capturing but only diffs against the last *sent* frame, so the next
frame carries the union of changes. Bandwidth adapts with no tuning. A
`max_fps` cap (default 30) bounds CPU.

### Tile codec

Tiles are 64×64 (edge tiles smaller). Encoder keeps the last sent frame and
compares row slices to find dirty tiles. Per dirty tile:

1. Uniform → Fill.
2. Quality 0 → Zstd(level 1).
3. Count distinct colors on a sparse sample; ≤ 48 → Zstd (UI/text stays
   crisp), else Jpeg (quality 1: q=80, quality 2: q=60).

With `CAP_DEFLATE` negotiated, every Zstd above is Deflate (zlib level 1,
pure-Rust miniz_oxide) instead. Jpeg tiles that then stay unchanged for 3
encodes are re-sent losslessly (refinement, after ~250 ms of stillness), so
a still screen always ends up pixel-exact.

Horizontal runs of dirty tiles with the same encoding decision may be merged
into one rect. Tiles are encoded in parallel (rayon).

### Keyboard

The wire carries **Linux evdev keycodes** (physical keys, layout-independent;
the remote's keyboard layout applies). Tables in crossshell-proto:
`winit KeyCode → evdev` (viewer), `evdev → PS/2 set-1 scancode (+E0 flag)`
(Windows host, `SendInput` with `KEYEVENTF_SCANCODE`). Linux host passes
evdev straight to the portal (`NotifyKeyboardKeycode`) or XTest (`evdev + 8`).

### Host backends

- **Windows**: DXGI Desktop Duplication (`IDXGIOutput1::DuplicateOutput`),
  per-monitor DPI aware; `SendInput` for input; cursor via
  `GetCursorInfo`/`GetIconInfo`. Secure desktop (UAC, lock screen) → ACCESS_LOST
  → send Notice and retry every 500 ms.
- **Linux GNOME (Wayland or X11)**: Mutter's own `org.gnome.Mutter.RemoteDesktop`
  + `ScreenCast` D-Bus API (what gnome-remote-desktop uses): no consent
  dialog, so unattended access works; GNOME shows its "screen is being
  shared" indicator while connected. Frames from PipeWire, input via
  `NotifyPointerMotionAbsolute/Button/Axis/KeyboardKeycode`. Cursor as stream
  metadata on one monitor; drawn into frames with several monitors (Mutter
  starves a stream fed only cursor updates).
- **Linux other Wayland (KDE, wlroots…)**: xdg-desktop-portal RemoteDesktop
  + ScreenCast, `persist_mode = 2` with the restore token stored in
  `~/.local/state/crossshell/portal-token`; the first session shows the
  desktop's consent dialog once.
- **Linux X11**: XShm `GetImage` per RandR monitor (XDamage-driven) + XTest
  for input, XFixes cursor.
- Mutter and the portal need the `pipewire` cargo feature (default). Without
  it only X11 is built and the agent links no C library, so it can be a
  static musl binary.
- Overrides: `CROSSSHELL_LINUX_BACKEND=mutter|portal|x11`,
  `CROSSSHELL_CURSOR=metadata|embedded`.

Backend trait (crossshell-host `platform` module):

```rust
pub trait Capturer: Send {
    fn displays(&self) -> Vec<Display>;
    /// Blocks up to `timeout`. Ok(None) = no change.
    fn next_frame(&mut self, timeout: Duration) -> Result<Option<CapturedFrame<'_>>>;
    fn cursor(&mut self) -> Option<CursorUpdate>; // shape and/or position changes
}
pub trait Injector: Send {
    fn pointer_move(&mut self, x: i32, y: i32) -> Result<()>;
    fn pointer_button(&mut self, button: u8, down: bool) -> Result<()>;
    fn scroll(&mut self, dx: i16, dy: i16) -> Result<()>;
    fn key(&mut self, evdev: u16, down: bool) -> Result<()>;
}
```

### Viewer

winit + softbuffer window. Scales to fit (aspect preserved, letterboxed) with
fast_image_resize; 1:1 mode; fullscreen (F11 or Ctrl+Alt+Enter); view-only
toggle; display picker and quality picker in a tiny overlay menu
(Ctrl+Alt+M). Captures keys including Super/Alt+Tab where the OS allows.
Releases all keys on focus loss. Clipboard text synced both ways (arboard)
when the window gains/loses focus.

## Limits (say these in the UI)

- Windows secure desktop (UAC prompts, lock screen, sign-in) can't be
  captured by a user-session agent; the viewer shows a notice. (A SYSTEM
  service is a later milestone.)
- Windows: input into elevated windows needs the agent elevated (admin users:
  scheduled task runs with highest privileges).
- Linux: GNOME needs no prompt (Mutter API). Other Wayland desktops need
  one local click on the portal consent dialog the first time; the restore
  token avoids it afterwards. No lock-screen capture.
- Windows Home has no RDP server — that's why we have our own engine.
- LAN only in v0.x. Over the internet: put both machines on a VPN
  (Tailscale/WireGuard) — beacons won't cross, add by IP.

## Milestones

- **M1 — Pair + SSH**: device identity, discovery, pairing ceremony, Doctor
  + setup scripts, key/config/known_hosts management, terminal tab. Verified
  Linux↔Windows on real hardware.
- **M2 — Work**: SFTP files, port forwards, system terminal + VS Code
  launchers, tray + autostart, unpair.
- **M3 — Remote desktop**: proto + codec, Windows + Linux (portal, X11)
  hosts, viewer, app integration. Verified both directions.
- **M4 — Ship**: packaging (deb + tarball, Windows zip/installer), CI
  (Linux + Windows), docs, release.
