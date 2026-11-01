#!/usr/bin/env bash
# Smoke test of the installed Flatpak, from outside the sandbox, on the
# machine it was built for. The same ground as scripts/smoke-linux.sh where
# the sandbox allows it:
#
#   1. the bundled OpenSSH client: ssh -V, ssh-keyscan loads, and ssh-keygen
#      writes a key into the home folder (the --filesystem=home grant that
#      ~/.ssh relies on).
#   2. engine, synthetic backend: crossshell-host --synthetic serves its test
#      pattern inside the sandbox, crossshell-view --snapshot connects,
#      decodes and saves a 1280x720 PNG.
#   3. app: cross_shell starts, renders and saves a picture of its own window
#      (CROSSSHELL_SHOT), then exits.
#
# The X11 capture step of smoke-linux.sh is left out: it needs tkinter and
# Pillow, which the Flatpak builder image does not have.
#
# Needs a display and a session bus:
#   xvfb-run -a dbus-run-session -- scripts/smoke-flatpak.sh com.dhivalabs.cross_shell
set -euo pipefail

app="${1:?usage: smoke-flatpak.sh <app-id>}"
# Visible inside the sandbox at the same path.
out="$HOME/.var/app/$app/cache/smoke"
rm -rf "$out"
mkdir -p "$out"

png_size() { # <file>: prints WIDTHxHEIGHT of a PNG, fails on anything else
  python3 - "$1" << 'PY'
import struct, sys
data = open(sys.argv[1], "rb").read(24)
assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
print("%dx%d" % struct.unpack(">II", data[16:24]))
PY
}

echo "== 1. bundled OpenSSH client"
flatpak run --command=ssh "$app" -V
# Outside the app's own data folder, so this needs the home grant.
keys="$HOME/crossshell-flatpak-smoke"
rm -rf "$keys"
mkdir -p "$keys"
flatpak run --command=ssh-keygen "$app" -q -t ed25519 -N '' -C crossshell-smoke -f "$keys/key"
flatpak run --command=ssh-keygen "$app" -l -f "$keys/key.pub"
# Without arguments ssh-keyscan prints its usage and exits 1; seeing the
# usage proves the binary loads.
if flatpak run --command=ssh-keyscan "$app" > "$out/keyscan.log" 2>&1; then :; fi
grep -q 'usage: ssh-keyscan' "$out/keyscan.log" || { cat "$out/keyscan.log"; exit 1; }

echo "== 2. synthetic backend inside the sandbox: host -> view --snapshot"
flatpak run --command=bash "$app" -c '
  set -euo pipefail
  d=/app/lib/crossshell
  "$d/crossshell-host" --version
  "$d/crossshell-view" --version
  "$d/crossshell-host" --synthetic --no-clipboard --port 47831 > "$1/host.log" 2>&1 &
  host=$!
  info="$XDG_RUNTIME_DIR/crossshell/host.json"
  for _ in $(seq 1 100); do [ -s "$info" ] && break; sleep 0.2; done
  [ -s "$info" ] || { echo "no $info"; cat "$1/host.log"; exit 1; }
  sed -n "s/.*\"token\" *: *\"\\([^\"]*\\)\".*/\\1/p" "$info" \
    | "$d/crossshell-view" --port 47831 --snapshot "$1/synthetic.png" --frames 30 | tee "$1/view.log"
  kill "$host"
  grep -q " 1280x720 " "$1/view.log"
' smoke "$out"
[ "$(png_size "$out/synthetic.png")" = 1280x720 ]

echo "== 3. app: render a picture of its window"
flatpak run --env=CROSSSHELL_SHOT="$out/app.png" --env=CROSSSHELL_SHOT_DELAY=8 \
  --env=GDK_BACKEND=x11 --env=LIBGL_ALWAYS_SOFTWARE=1 "$app" > "$out/app.log" 2>&1 &
pid=$!
for ((i = 0; i < 120; i++)); do
  kill -0 "$pid" 2> /dev/null || break
  sleep 1
done
if kill -0 "$pid" 2> /dev/null; then
  echo "the app is still running after 120 s" >&2
  cat "$out/app.log"
  kill "$pid"
  exit 1
fi
wait "$pid" || { echo "the app exited with status $?" >&2; cat "$out/app.log"; exit 1; }
cat "$out/app.log"
[ -s "$out/app.png" ] || { echo "the app saved no picture" >&2; exit 1; }
echo "app picture: $(png_size "$out/app.png")"
echo "flatpak smoke test passed"
