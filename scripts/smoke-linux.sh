#!/usr/bin/env bash
# Smoke test of an extracted Linux bundle (the unpacked release tarball) on the
# machine it was built for. Nothing here touches a real desktop session: every
# step runs on a private Xvfb display with its own HOME/XDG directories and no
# session bus.
#
#   scripts/smoke-linux.sh <extracted-bundle-dir>
#
# Needs: Xvfb, python3 with tkinter and PIL (python3-tk, python3-pil), file, and
# dbus-run-session.
#
#   1. engine, synthetic backend: crossshell-host --synthetic serves its test
#      pattern, crossshell-view --snapshot connects, decodes and saves a PNG.
#   2. engine, native X11 backend: the same against the Xvfb screen (XShm
#      capture), checking a pixel of the saved picture.
#   3. app: cross_shell starts, renders, saves a picture of its own window
#      (CROSSSHELL_SHOT) and has started the bundled crossshell-host. A release
#      build must also ignore the end-to-end test hooks (CROSSSHELL_TEST_*).
set -euo pipefail

bundle=$(cd "${1:?usage: smoke-linux.sh <extracted-bundle-dir>}" && pwd)
tmp=$(mktemp -d)
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

wait_for() { # <file> <seconds>
  local i
  for ((i = 0; i < $2 * 5; i++)); do
    { [ -s "$1" ] || [ -S "$1" ]; } && return 0
    sleep 0.2
  done
  echo "timed out after $2 s waiting for $1" >&2
  return 1
}

# Environment for one step: a fresh home and runtime dir, no session bus.
fresh_env() { # <name>
  export HOME="$tmp/$1/home" XDG_RUNTIME_DIR="$tmp/$1/run" XDG_STATE_HOME="$tmp/$1/state"
  export XDG_DATA_HOME="$tmp/$1/data" XDG_CONFIG_HOME="$tmp/$1/config" XDG_CACHE_HOME="$tmp/$1/cache"
  mkdir -p -m 700 "$XDG_RUNTIME_DIR" "$HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
}

token_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$1"; }

echo "== versions"
"$bundle/crossshell-host" --version
"$bundle/crossshell-view" --version

echo "== 1. synthetic backend: host -> view --snapshot"
(
  fresh_env synthetic
  "$bundle/crossshell-host" --synthetic --no-clipboard --port 47831 > "$tmp/synthetic-host.log" 2>&1 &
  host=$!
  trap 'kill $host 2> /dev/null || true' EXIT
  wait_for "$XDG_RUNTIME_DIR/crossshell/host.json" 20
  token_of "$XDG_RUNTIME_DIR/crossshell/host.json" \
    | "$bundle/crossshell-view" --port 47831 --snapshot "$tmp/synthetic.png" --frames 30 | tee "$tmp/synthetic-view.log"
  grep -q ' 1280x720 ' "$tmp/synthetic-view.log"
  file "$tmp/synthetic.png"
  file "$tmp/synthetic.png" | grep -q 'PNG image data, 1280 x 720'
)

echo "== 2. native X11 backend on Xvfb: host -> view --snapshot"
export DISPLAY=:99
Xvfb "$DISPLAY" -screen 0 1280x720x24 -nolisten tcp > "$tmp/xvfb.log" 2>&1 &
pids+=($!)
wait_for /tmp/.X11-unix/X99 20
# A borderless 1280x720 window in a known colour (there is no window manager
# on this display) for the capture to find.
cat > "$tmp/paint.py" << 'PY'
import sys
import tkinter as tk

root = tk.Tk()
root.overrideredirect(True)
root.geometry("1280x720+0+0")
root.configure(bg="#336699")
root.update()
open(sys.argv[1], "w").write("painted\n")
root.mainloop()
PY
python3 "$tmp/paint.py" "$tmp/painted" &
pids+=($!)
wait_for "$tmp/painted" 20
sleep 1
(
  fresh_env x11
  CROSSSHELL_LINUX_BACKEND=x11 "$bundle/crossshell-host" --no-clipboard --port 47832 > "$tmp/x11-host.log" 2>&1 &
  host=$!
  trap 'kill $host 2> /dev/null || true' EXIT
  wait_for "$XDG_RUNTIME_DIR/crossshell/host.json" 20
  token_of "$XDG_RUNTIME_DIR/crossshell/host.json" \
    | "$bundle/crossshell-view" --port 47832 --snapshot "$tmp/x11.png" --frames 5 | tee "$tmp/x11-view.log" \
    || { cat "$tmp/x11-host.log"; exit 1; }
  cat "$tmp/x11-host.log"
  file "$tmp/x11.png"
  python3 - "$tmp/x11.png" << 'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
px = im.getpixel((640, 360))
print("size", im.size, "pixel(640,360)", px)
assert im.size == (1280, 720), im.size
assert px == (0x33, 0x66, 0x99), px
PY
)

echo "== 3. app: render a frame and start the bundled agent"
(
  fresh_env app
  export CROSSSHELL_SHOT="$tmp/app.png" CROSSSHELL_SHOT_DELAY=8 GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1
  export CROSSSHELL_TEST_LOG="$tmp/hooks.log" CROSSSHELL_TEST_AUTOCONFIRM=1
  # The app starts crossshell-host (next to it) when it opens, and exits by
  # itself once it has saved the picture.
  dbus-run-session -- "$bundle/cross_shell" > "$tmp/app.log" 2>&1 &
  app=$!
  for ((i = 0; i < 120; i++)); do
    kill -0 "$app" 2> /dev/null || break
    sleep 1
  done
  if kill -0 "$app" 2> /dev/null; then
    echo "the app is still running after 120 s" >&2
    cat "$tmp/app.log"
    echo "--- files the app wrote"
    find "$HOME" "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$tmp/app.png" 2> /dev/null || true
    echo "--- processes"
    ps -eo pid,ppid,stat,etime,args | grep -E 'cross_shell|crossshell|dbus' | grep -v grep || true
    kill "$app" 2> /dev/null || true
    exit 1
  fi
  wait "$app" || { echo "the app exited with status $?" >&2; cat "$tmp/app.log"; exit 1; }
  cat "$tmp/app.log"
  [ -s "$CROSSSHELL_SHOT" ] || { echo "the app saved no picture" >&2; exit 1; }
  file "$CROSSSHELL_SHOT"
  file "$CROSSSHELL_SHOT" | grep -q 'PNG image data'
  if [ "${CROSSSHELL_BUILD_MODE:-release}" = release ] && [ -e "$CROSSSHELL_TEST_LOG" ]; then
    echo "this release build honoured the end-to-end test hooks:" >&2
    cat "$CROSSSHELL_TEST_LOG" >&2
    exit 1
  fi
  info="$XDG_RUNTIME_DIR/crossshell/host.json"
  [ -s "$info" ] || { echo "the app did not start crossshell-host" >&2; exit 1; }
  python3 -c 'import json,sys; m=json.load(sys.stdin); print("agent started by the app: pid", m["pid"], "port", m["port"], "ver", m["ver"])' < "$info"
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$info")
  kill "$pid" 2> /dev/null || true
)
echo "smoke test passed"
