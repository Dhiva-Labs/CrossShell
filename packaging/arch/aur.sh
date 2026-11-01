#!/usr/bin/env bash
# Renders the AUR PKGBUILD for one release and proves it builds.
#
# usage: aur.sh <linux-x64.tar.gz> <linux-arm64.tar.gz> <outdir>
#
# Fills PKGBUILD.in with the version, the release download URL and the
# sha256 of both release tarballs and of the files it takes from the tagged
# tree (LICENSE, desktop file, icons, metainfo; this checkout's copies), then,
# in an archlinux:latest container, generates .SRCINFO, runs makepkg on the
# x86_64 sources (all placed next to the PKGBUILD, so makepkg verifies their
# checksums without downloading), installs the result and runs ldd on every
# ELF file in it. Writes <name>-bin-<version>-aur.tar.gz holding PKGBUILD and
# .SRCINFO, ready to push to the AUR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
[ $# -eq 3 ] || { echo "usage: $0 <linux-x64.tar.gz> <linux-arm64.tar.gz> <outdir>" >&2; exit 2; }
tar_x64="$(readlink -f "$1")"; tar_arm64="$(readlink -f "$2")"
mkdir -p "$3"; out="$(cd "$3" && pwd)"
# shellcheck source=/dev/null
. "$here/../linux-distros/distro.conf"
: "${VERSION:?set VERSION}"
tag="${TAG_PREFIX-v}$VERSION"
[ "$(basename "$tar_x64")" = "$NAME-$VERSION-linux-x64.tar.gz" ] || { echo "unexpected $tar_x64" >&2; exit 1; }
[ "$(basename "$tar_arm64")" = "$NAME-$VERSION-linux-arm64.tar.gz" ] || { echo "unexpected $tar_arm64" >&2; exit 1; }

sha() { sha256sum "$1" | cut -d' ' -f1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
deps=""; for d in "${ARCH_DEPENDS[@]}"; do deps+="'$d' "; done
optdeps=""; for d in "${ARCH_OPTDEPENDS[@]}"; do optdeps+="'$d' "; done
sed -e "s|@NAME@|$NAME|g" -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SUMMARY@|${SUMMARY//\'/}|g" -e "s|@HOMEPAGE@|$HOMEPAGE|g" \
    -e "s|@LICENSE@|$LICENSE|g" -e "s|@ARCH_DEPENDS@|${deps% }|g" \
    -e "s|@ARCH_OPTDEPENDS@|${optdeps% }|g" \
    -e "s|@GITHUB_REPO@|$GITHUB_REPO|g" -e "s|@TAG@|$tag|g" \
    -e "s|@RELEASE_URL@|https://github.com/$GITHUB_REPO/releases/download/$tag|g" \
    -e "s|@SHA_LICENSE@|$(sha "$repo/LICENSE")|g" \
    -e "s|@SHA_DESKTOP@|$(sha "$repo/app/linux/com.dhivalabs.cross_shell.desktop")|g" \
    -e "s|@SHA_ICON256@|$(sha "$repo/app/linux/crossshell-256.png")|g" \
    -e "s|@SHA_ICON512@|$(sha "$repo/app/linux/crossshell-512.png")|g" \
    -e "s|@SHA_METAINFO@|$(sha "$repo/packaging/flatpak/com.dhivalabs.cross_shell.metainfo.xml")|g" \
    -e "s|@SHA_X64@|$(sha "$tar_x64")|g" -e "s|@SHA_ARM64@|$(sha "$tar_arm64")|g" \
    "$here/PKGBUILD.in" > "$work/PKGBUILD"
if grep -n '@[A-Z0-9_]*@' "$work/PKGBUILD"; then echo "unfilled placeholder" >&2; exit 1; fi
# The sources makepkg would download, placed where it looks first.
cp "$tar_x64" "$work/"
cp "$repo/LICENSE" "$work/LICENSE"
cp "$repo/app/linux/com.dhivalabs.cross_shell.desktop" "$repo/app/linux/crossshell-256.png" \
  "$repo/app/linux/crossshell-512.png" "$repo/packaging/flatpak/com.dhivalabs.cross_shell.metainfo.xml" "$work/"

docker run --rm -v "$work:/build" archlinux:latest bash -euo pipefail -c '
  pacman -Syu --noconfirm --needed -q base-devel namcap
  useradd -m builder
  chown -R builder /build
  cd /build
  su builder -c "makepkg --printsrcinfo > .SRCINFO"
  su builder -c "makepkg --noconfirm --nodeps -f"
  namcap PKGBUILD
  pacman -U --noconfirm ./*-x86_64.pkg.tar.zst
  pacman -Qlq crossshell-bin | grep -x /usr/lib/crossshell/crossshell-host
  [ ! -e /usr/lib/crossshell/lib/libdartjni.so ]
  # Every ELF file the package installed finds its libraries (the depends
  # are complete), as in verify.sh.
  missing=0
  for f in $(pacman -Qlq crossshell-bin); do
    [ -f "$f" ] && [ "$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] || continue
    if LD_LIBRARY_PATH=/usr/lib/crossshell/lib ldd "$f" | grep "not found"; then echo "in $f"; missing=1; fi
  done
  [ "$missing" = 0 ]
  /usr/lib/crossshell/crossshell-host --version
  cat .SRCINFO
'
tar -C "$work" -czf "$out/$NAME-bin-$VERSION-aur.tar.gz" PKGBUILD .SRCINFO
ls -l "$out/$NAME-bin-$VERSION-aur.tar.gz"
