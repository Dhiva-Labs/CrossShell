#!/usr/bin/env bash
# Build the Linux release bundle: Rust engine + Flutter app, with the engine
# binaries placed next to the app executable (where EnginePaths looks).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
ver=$(grep -m1 '^version' "$root/engine/Cargo.toml" | sed 's/.*"\(.*\)"/\1/')

# Dev machines without root can use unpacked PipeWire headers (see
# engine/platform-linux/BUILDING.md).
devroot="$HOME/.cache/crossshell-devroot/usr/lib/x86_64-linux-gnu/pkgconfig"
if ! pkg-config --exists libpipewire-0.3 && [ -d "$devroot" ]; then
  export PKG_CONFIG_PATH="$devroot${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
(cd "$root/engine" && cargo build --release -p crossshell-host -p crossshell-view)
(cd "$root/app" && flutter build linux --release)

bundle="$root/app/build/linux/x64/release/bundle"
install -m755 "$root/engine/target/release/crossshell-host" "$root/engine/target/release/crossshell-view" "$bundle/"

mkdir -p "$root/dist"
name="crossshell-$ver-linux-x64"
tar -C "$(dirname "$bundle")" -czf "$root/dist/$name.tar.gz" --transform "s|^bundle|$name|" bundle
echo "built $root/dist/$name.tar.gz"
