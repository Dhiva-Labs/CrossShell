#!/usr/bin/env bash
# Lays out the installed file tree that the .rpm, Arch package, AppImage and
# Flatpak are built from. CrossShell ships no .deb, so the tree comes from the
# Linux release tarball (scripts/build-linux.sh), which holds the Flutter
# bundle with the engine binaries next to the app:
#
#   /usr/lib/crossshell/      cross_shell, crossshell-host, crossshell-view,
#                             lib/, data/ (the bundle as it is)
#   /usr/bin/crossshell       -> ../lib/crossshell/cross_shell
#   /usr/share/applications/com.dhivalabs.cross_shell.desktop
#   /usr/share/icons/hicolor/{256x256,512x512}/apps/com.dhivalabs.cross_shell.png
#   /usr/share/metainfo/com.dhivalabs.cross_shell.metainfo.xml
#
# The app finds the engine binaries next to its resolved executable, so the
# /usr/bin symlink keeps remote desktop working.
#
# usage: tree.sh <crossshell-<ver>-linux-<arch>.tar.gz> <root>
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 <tarball> <root>" >&2; exit 2; }
tarball="$1"
root="$2"
id=com.dhivalabs.cross_shell

umask 022
mkdir -p "$root/usr/lib/crossshell" "$root/usr/bin"
tar -xzf "$tarball" -C "$root/usr/lib/crossshell" --strip-components=1 --no-same-owner
for f in cross_shell crossshell-host crossshell-view lib/libapp.so lib/libflutter_linux_gtk.so data/icudtl.dat; do
  [ -f "$root/usr/lib/crossshell/$f" ] || { echo "$f is not in $tarball" >&2; exit 1; }
done
ln -s ../lib/crossshell/cross_shell "$root/usr/bin/crossshell"

# The desktop file the app's own Linux build carries, started through the
# /usr/bin name and with the icon named after the application ID (what
# Flatpak and the Wayland app ID expect).
install -d "$root/usr/share/applications"
sed -e 's/^Exec=.*/Exec=crossshell/' -e "s/^Icon=.*/Icon=$id/" \
  "$repo/app/linux/$id.desktop" > "$root/usr/share/applications/$id.desktop"
for size in 256 512; do
  install -Dm644 "$repo/app/linux/crossshell-$size.png" \
    "$root/usr/share/icons/hicolor/${size}x${size}/apps/$id.png"
done
install -Dm644 "$repo/packaging/flatpak/$id.metainfo.xml" "$root/usr/share/metainfo/$id.metainfo.xml"
