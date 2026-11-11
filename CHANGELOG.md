# Changelog

## 0.2.0

### Engine

- **Protocol: `CAP_DEFLATE`** (caps bit 0) and tile encoding 4, **Deflate**:
  a zlib stream (RFC 1950) of the same BGRX bytes a Zstd tile carries. A
  viewer that sets the bit in `Hello.caps` gets lossless tiles as Deflate
  instead of Zstd; the host answers `Welcome.caps = Hello.caps & host caps`.
  Viewers sending 0, CrossShell's own included, get exactly what they got
  before. The reserved CopyPrev encoding moves to 5.
- **Host flags for remote-launched agents** (SecureShell Go):
  - `--runtime-dir DIR`: `host.json`, the instance lock, `status.json` and
    the log go in `DIR` (created 0700, `host.json` 0600).
  - `--exit-when-idle SECS`: exit when no viewer connected within `SECS` of
    start, or `SECS` after the last viewer left.
  - `--no-notify`: see below.
- **Connect notification**: while a viewer is connected the host shows
  "Your screen is being viewed (and controlled) from <viewer>": a desktop
  notification on Linux, a notification-area balloon (toast) on Windows.
- **Linux build flavours**: PipeWire is now a default cargo feature. Without
  it the agent has the X11 backend only, links no C library and builds as a
  fully static musl binary. `--version` names the backends of the build.
- `scripts/build-agents.sh` builds the standalone agents (Linux x86_64 and
  aarch64, full and X11-only; Windows x64 and arm64) into `dist/agents/`
  with `SHA256SUMS`.
- `crossshell-proto` example `ssgo_fixtures` writes golden fixtures (encoded
  frames, expected pixels, every message type) for other implementations of
  the protocol.

### Microsoft Store preparation

- **Windows state files moved** from `%LOCALAPPDATA%\CrossShell` to
  `%USERPROFILE%\.crossshell` (`agent-path`, `host.json`, `status.json`,
  `host.log`, `host.lock`): an MSIX-packaged app's AppData writes are private
  to the package, so a peer reading them over SSH would see nothing. The old
  location is still read, and `agent-path` and `host.json` are mirrored there,
  so older CrossShell builds keep working with this one in both directions.
- The elevated setup's result file goes under `%USERPROFILE%\.crossshell\tmp`
  instead of `%TEMP%`.
- **Screen sharing is opt-in**: off unless turned on under *This machine*
  (a settings file already saved with it on keeps it on). While it is off the
  agent path is not published, so paired machines can't start the agent
  (except with the Snap, see PLAN.md).
- **Remove CrossShell changes from this PC** (*This machine*): unpairs all
  machines, stops the agent and, with one admin prompt on Windows, deletes the
  `CrossShellHost` scheduled task, the CrossShell firewall rules and
  CrossShell's admin keys, and reverts OpenSSH's `DefaultShell` if CrossShell
  set it (recorded from now on); removes the `Include` line and
  `~/.ssh/crossshell`. sshd and the OpenSSH Server feature are left alone.
- Windows firewall rules are created for the Domain and Private profiles
  only (were Any). *This machine* flags networks set to Public.
- Fixed: the Windows firewall step of the elevated setup never worked: a
  doubled backtick in the generated PowerShell is not a line continuation, so
  `New-NetFirewallRule` was split in two.
- `crossshell-host --no-notify` is ignored when the agent runs from an MSIX
  package (`WindowsApps`); the viewing notice always shows there.
- Turning screen sharing off (or *Disconnect them*) now also stops an agent
  that a peer started elevated: the app leaves a `stop` file in the runtime
  dir, which the agent checks every 250 ms (Windows does not let an
  unelevated process terminate an elevated one).
- `store/`: Microsoft Store packaging notes, listing, privacy policy and
  certification notes; `msix_config` in `app/pubspec.yaml` (identity values
  are placeholders until the name is reserved in Partner Center).

### Arm64 (prepared as 0.1.2, first released here)

#### Added

- Linux arm64 (aarch64) and Windows 11 on ARM (arm64) builds:
  `crossshell-<version>-linux-arm64.tar.gz` and
  `crossshell-<version>-windows-arm64.zip`, built natively next to the x64
  ones. The application is unchanged.
- The snap builds for arm64 as well as amd64.
- CI builds, tests and smoke-runs the engine and the app on native runners of
  each architecture, checks that every binary in the packages is the right
  architecture, and attaches the tarballs and zips of both architectures, with
  `SHA256SUMS`, to a published release without replacing any file that is
  already on it.

#### Changed

- `scripts/build-linux.sh` builds for the architecture of the machine it runs
  on, and `scripts/package-windows.ps1` packs the Windows zip for the
  architecture of the machine it runs on.
- The snap's PipeWire plugin paths follow the architecture the snap is built
  for.

## 0.1.1

### Fixed

- Terminal: typing fast (about 50 ms per key or faster) could insert a
  character twice. The terminal now takes keys directly from the keyboard, so
  input methods (IME) and dead-key compose sequences don't reach the built-in
  terminal; use *Open in system terminal* for those.

### Added

- Snap packaging (`crossshell`, strictly confined; see `packaging/SNAP.md`).
- Remote start of a snap-installed agent on a paired machine.
- An app icon on Linux and in the Windows executable.

## 0.1.0

First release: SSH both ways with pairing and key exchange, terminal tabs, a
two-pane SFTP file manager, port forwards and remote desktop between Linux and
Windows machines.
