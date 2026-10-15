#!/usr/bin/env bash
# Build the Linux release bundle: Rust engine + Flutter app, with the engine
# binaries placed next to the app executable (where EnginePaths looks).
# Builds natively for the machine it runs on: x64 (x86_64) or arm64 (aarch64).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# CROSSSHELL_BUILD_MODE=profile keeps the end-to-end test hooks (lib/dev/).
mode=${CROSSSHELL_BUILD_MODE:-release}
ver=$(grep -m1 '^version' "$root/engine/Cargo.toml" | sed 's/.*"\(.*\)"/\1/')

case "$(uname -m)" in
  x86_64) arch=x64 triplet=x86_64-linux-gnu ;;
  aarch64 | arm64) arch=arm64 triplet=aarch64-linux-gnu ;;
  *) echo "error: unsupported machine '$(uname -m)' (x86_64 or aarch64)" >&2; exit 1 ;;
esac

# Dev machines without root can use unpacked PipeWire headers (see
# engine/platform-linux/BUILDING.md).
devroot="$HOME/.cache/crossshell-devroot/usr/lib/$triplet/pkgconfig"
if ! pkg-config --exists libpipewire-0.3 && [ -d "$devroot" ]; then
  export PKG_CONFIG_PATH="$devroot${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
(cd "$root/engine" && cargo build --release -p crossshell-host -p crossshell-view)
(cd "$root/app" && flutter build linux "--$mode")

bundle="$root/app/build/linux/$arch/$mode/bundle"
install -m755 "$root/engine/target/release/crossshell-host" "$root/engine/target/release/crossshell-view" "$bundle/"

mkdir -p "$root/dist"
name="crossshell-$ver-linux-$arch"
[ "$mode" = release ] || name="$name-$mode"
tar -C "$(dirname "$bundle")" --owner=0 --group=0 --numeric-owner -czf "$root/dist/$name.tar.gz" --transform "s|^bundle|$name|" bundle
echo "built $root/dist/$name.tar.gz"
