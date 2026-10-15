# CrossShell

[![ARM64 builds](https://github.com/Dhiva-Labs/CrossShell/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/CrossShell/actions/workflows/ci.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Windows x64 | arm64](https://img.shields.io/badge/Windows-x64%20%7C%20arm64-informational?logo=windows&logoColor=white)

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

## Install

Download from the [releases page](https://github.com/Dhiva-Labs/CrossShell/releases):

- **Linux (x64):** `crossshell-<ver>-linux-x64.tar.gz`. Extract it and run
  `./cross_shell`. You need the OpenSSH client (`ssh`, `ssh-keygen`) and
  GTK 3. Screen sharing uses PipeWire, which any current desktop has.
- **Linux (arm64):** `crossshell-<ver>-linux-arm64.tar.gz`, the same bundle
  built natively for aarch64. It has the same requirements and is used the
  same way.
- **Windows 10/11 (x64):** `crossshell-<ver>-windows-x64.zip`. Extract it
  and run `cross_shell.exe`. The OpenSSH client ships with Windows; the app
  can install OpenSSH Server for you.
- **Windows 11 on ARM (arm64):** `crossshell-<ver>-windows-arm64.zip`, a
  native ARM64 build with the same contents and steps as the x64 zip. It
  needs the Microsoft Visual C++ Redistributable for ARM64, like the x64
  build needs the x64 one. Remote desktop uses the same Windows APIs as on
  x64 (Desktop Duplication for capture, `SendInput` for input); CI exercises
  the capture on a Windows 11 ARM runner.

Pick the file that matches the machine: `uname -m` prints `aarch64` on
arm64 Linux, and Windows shows the processor type under *Settings, System,
About*. A machine pair can mix architectures, for example a Linux arm64
box and an x64 Windows PC.

> **The builds are not code-signed yet.** On Windows, SmartScreen will warn
> on first launch. If **Smart App Control** is on, it may block
> `cross_shell.exe` or the screen-share agent `crossshell-host.exe`. The
> app tells you when that happens. Signed releases are planned.

Verify downloads with `SHA256SUMS` (it lists the x64 and arm64 files).

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
ssh winbox
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
- **Terminal input:** the built-in terminal takes keys directly from the
  keyboard, so input methods (IME) and dead-key compose sequences don't
  reach it. Use *Open in system terminal* for those.
- **LAN only:** across the internet, put both machines on a VPN (Tailscale,
  WireGuard) and use *Pair by address*.

## Build

```bash
scripts/build-linux.sh                     # dist/crossshell-<ver>-linux-<x64|arm64>.tar.gz
scripts/build-windows.sh user@winbox       # dist/crossshell-<ver>-windows-x64.zip
```

`build-linux.sh` builds natively for the machine it runs on, so run it on an
aarch64 machine for the arm64 bundle. Flutter cannot cross-compile Windows,
so `build-windows.sh` produces the x64 zip (engine cross-built here, app
built on the Windows machine). The arm64 builds happen on native runners in
CI (`.github/workflows/ci.yml`): `ubuntu-24.04-arm` and `windows-11-arm`. On
a Windows machine, after `cargo build --release -p crossshell-host -p
crossshell-view` in `engine/` and `flutter build windows --release` in
`app/`, `scripts\package-windows.ps1` writes the zip for that machine's
architecture.

Every CI run builds and tests both architectures, checks that each binary
in the packages is the right architecture (ELF `aarch64` / PE `0xAA64`) and
smoke-runs the packaged engine and app (`scripts/smoke-linux.sh`,
`scripts/smoke-windows.ps1`). When a release is published, the workflow
attaches the tarballs and zips for x64 and arm64 that the release does not
have yet, and `SHA256SUMS` if it has none. It never replaces a file, so
anything uploaded by hand stays as it was. The CI also builds the Snap on
amd64 and arm64 (see [packaging/SNAP.md](packaging/SNAP.md)).

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
