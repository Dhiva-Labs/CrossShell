# Changelog

## 0.1.2

### Added

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

### Changed

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
