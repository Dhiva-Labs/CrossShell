#!/usr/bin/env bash
# Build the Windows release from Linux: the Rust engine is cross-compiled
# here (cargo-zigbuild), the Flutter app is built on a Windows machine over
# SSH (Flutter can't cross-compile Windows), then everything is zipped and
# copied back to dist/.
#
#   scripts/build-windows.sh user@windows-host [C:/dev/apps]
#
# Needs: zig + cargo-zigbuild here; Flutter (C:\dev\flutter) and Visual
# Studio Build Tools on the Windows machine.
set -euo pipefail
target=${1:?usage: build-windows.sh user@windows-host [remote-work-dir]}
work=${2:-C:/dev/apps}
root=$(cd "$(dirname "$0")/.." && pwd)
ver=$(grep -m1 '^version' "$root/engine/Cargo.toml" | sed 's/.*"\(.*\)"/\1/')
flutter_bat=${FLUTTER_WIN:-'C:\dev\flutter\bin\flutter.bat'}
wwork=${work//\//\\}
quiet() { grep -v -i -e 'post-quantum' -e 'store now, decrypt later' -e 'openssh.com/pq' -e 'may need to be upgraded' || true; }

(cd "$root/engine" && cargo zigbuild --release --target x86_64-pc-windows-gnu -p crossshell-host -p crossshell-view)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -C "$root" --exclude=app/build --exclude=app/.dart_tool -czf "$tmp/src.tgz" app
scp -q "$tmp/src.tgz" "$target:$work/cross_shell-src.tgz" 2>&1 | quiet
ssh "$target" "cd /d $wwork && (if exist cross_shell rmdir /s /q cross_shell) & mkdir cross_shell && tar -xzf cross_shell-src.tgz -C cross_shell && del cross_shell-src.tgz" 2>&1 | quiet
ssh "$target" "cd /d $wwork\\cross_shell\\app && $flutter_bat build windows --release" 2>&1 | quiet

rel="$work/cross_shell/app/build/windows/x64/runner/Release"
scp -q "$root/engine/target/x86_64-pc-windows-gnu/release/crossshell-host.exe" \
       "$root/engine/target/x86_64-pc-windows-gnu/release/crossshell-view.exe" "$target:$rel/" 2>&1 | quiet
name="crossshell-$ver-windows-x64"
ssh "$target" "powershell -NoProfile -Command \"\$ProgressPreference='SilentlyContinue'; Compress-Archive -Force -Path '${rel//\//\\}\\*' -DestinationPath '$wwork\\$name.zip'\"" 2>&1 | quiet
mkdir -p "$root/dist"
scp -q "$target:$work/$name.zip" "$root/dist/" 2>&1 | quiet
echo "built $root/dist/$name.zip"
