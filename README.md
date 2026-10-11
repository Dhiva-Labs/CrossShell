# CrossShell

Two machines, one desk. CrossShell links a Linux daily driver and a Windows
build box (or any mix of Linux and Windows machines) on the same network:

- **SSH both ways, set up for you.** CrossShell enables the OS's own
  OpenSSH server, pairs the machines with a 6-digit code, swaps keys and
  pins host keys. Afterwards `ssh <name>` works from any terminal — and so
  do VS Code Remote-SSH, rsync, scp and git.
- **Terminal, files and port forwards** in the app, over that SSH.
- **Remote desktop**, TeamViewer-style: view or control the other screen.
  It's CrossShell's own engine, tunneled through SSH, so it works on
  Windows Home (which has no RDP server) and on Wayland, opens no extra
  ports, and needs no third-party server.

## How it works

```
 Linux  ───────────── LAN ─────────────  Windows
 CrossShell app                           CrossShell app
   │  pairing (TCP 47820, once)  ◄────►     │
   │  discovery (UDP 47820)      ◄────►     │
   │                                        │
   ├─ ssh / sftp ─────────────────────────► sshd (OpenSSH Server)
   └─ ssh -L ── remote desktop ──────────►  └─ crossshell-host (127.0.0.1 only)
 sshd ◄────────────────────────────────── ssh / sftp / ssh -L
```

- **Pairing** uses an ephemeral X25519 exchange with a commitment and shows
  the same 6-digit code on both screens. If the codes match, each side
  sends its SSH user, its client key and its sshd host keys, sealed with a
  key only the two of them have. Nobody types passwords and nothing is
  trusted on first use.
- **Trust lives in standard files** in `~/.ssh/crossshell/` (`config`,
  `known_hosts`, `id_ed25519`), plus one `Include` line at the top of
  `~/.ssh/config`. Peer keys go into `authorized_keys`, or on Windows admin
  accounts into `C:\ProgramData\ssh\administrators_authorized_keys`. Each
  line carries a `crossshell:<peer-id>` marker so unpairing removes exactly
  that line.
- **Remote desktop:** the host agent listens on `127.0.0.1` only and writes
  a fresh random token to a file only its user can read. The viewer reads
  that file over SSH, opens an SSH tunnel and authenticates with the token.
  SSH is the only way in.

See [PLAN.md](PLAN.md) for the full design, wire protocol and pairing spec.

## Use it

1. Install and open CrossShell on both machines.
2. Open **This machine** (the gear icon) and fix anything red. Usually that
   means *Set up SSH server*, which takes one admin prompt (UAC on Windows,
   polkit on Linux).
3. The other machine appears under **Nearby**. Click **Pair** and check
   that both screens show the same code.
4. Use the machine card: **Terminal**, **Files**, **Remote desktop**, or
   *More* for view-only, port forwards, system terminal, VS Code and
   unpairing.

From any terminal afterwards:

```bash
ssh lenovo
```

## Limits (honest list)

- **Windows secure desktop:** UAC prompts, the lock screen and the sign-in
  screen can't be captured by an agent running in your session. The viewer
  shows a notice until they go away.
- **Windows elevated windows:** these can be driven when the agent runs with
  highest privileges. That is automatic for admin users when the session is
  started remotely.
- **Linux on GNOME:** sharing uses Mutter's remote-desktop API, with no
  prompt. On other Wayland desktops the xdg portal shows a consent dialog
  once, and a restore token avoids it afterwards. On X11 it uses XShm +
  XTest.
- **LAN only:** across the internet, put both machines on a VPN (Tailscale,
  WireGuard) and use *Pair by address*.

## Build

```bash
scripts/build-linux.sh                     # dist/crossshell-<ver>-linux-x64.tar.gz
scripts/build-windows.sh user@winbox       # dist/crossshell-<ver>-windows-x64.zip
```

Layout: `app/` is the Flutter UI (Linux + Windows) and `engine/` is the Rust
workspace:

- `crossshell-proto`: wire protocol and tile codec
- `crossshell-host`: agent
- `crossshell-view`: viewer
- `platform-*`: capture/input backends

Tests:

```bash
cd engine && cargo test --release
cd app && flutter test
```

## License

MIT
