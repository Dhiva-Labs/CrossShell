#!/usr/bin/env bash
# Build the standalone crossshell-host agents that other apps (SecureShell
# Go) upload to a remote machine and run for one session, into dist/agents/:
#
#   crossshell-host-linux-x86_64        Mutter, portal and X11; glibc >= 2.31,
#                                       needs libpipewire-0.3 on the remote
#   crossshell-host-linux-x86_64-x11    X11 only; static musl, runs anywhere
#   crossshell-host-linux-aarch64       as linux-x86_64, for arm64
#   crossshell-host-linux-aarch64-x11   as linux-x86_64-x11, for arm64
#   crossshell-host-windows-x64.exe
#   crossshell-host-windows-arm64.exe
#
# plus SHA256SUMS for what was built. Everything is cross-built with
# cargo-zigbuild. What cannot be built on this machine is skipped and
# listed at the end; --strict turns a skip into a failure.
#
#   scripts/build-agents.sh [--strict] [FLAVOUR...]   e.g. linux-aarch64
#
# Needs: zig and cargo-zigbuild (`pip install cargo-zigbuild` brings both;
# or ZIG=/path/to/zig), the rustup target of each flavour, and for the full
# Linux flavours the PipeWire headers and library of that architecture
# (engine/platform-linux/BUILDING.md). Those are only looked up for the
# machine's own architecture, so linux-aarch64 is built on an aarch64
# machine (CI's arm runner) and linux-x86_64 on an x86_64 one.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/dist/agents"
glibc=${CROSSSHELL_GLIBC:-2.31}
strict=0
only=()
for a in "$@"; do
  case "$a" in
    --strict) strict=1 ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option $a" >&2; exit 2 ;;
    *) only+=("$a") ;;
  esac
done

if [ -n "${ZIG:-}" ]; then
  export PATH="$(dirname "$ZIG"):$PATH"
fi

# name | rust target | zigbuild target | cargo feature flags | kind
flavours=(
  "linux-x86_64|x86_64-unknown-linux-gnu|x86_64-unknown-linux-gnu.$glibc||full"
  "linux-x86_64-x11|x86_64-unknown-linux-musl|x86_64-unknown-linux-musl|--no-default-features|static"
  "linux-aarch64|aarch64-unknown-linux-gnu|aarch64-unknown-linux-gnu.$glibc||full"
  "linux-aarch64-x11|aarch64-unknown-linux-musl|aarch64-unknown-linux-musl|--no-default-features|static"
  "windows-x64|x86_64-pc-windows-gnu|x86_64-pc-windows-gnu||windows"
  "windows-arm64|aarch64-pc-windows-gnullvm|aarch64-pc-windows-gnullvm||windows"
)

case "$(uname -m)" in
  x86_64) host_arch=x86_64 ;;
  aarch64 | arm64) host_arch=aarch64 ;;
  *) host_arch=$(uname -m) ;;
esac

built=()
skipped=()
skip() { skipped+=("$1: $2"); echo "skip $1: $2"; }

installed_targets=$(rustup target list --installed 2> /dev/null || true)
have_zigbuild=1
if ! command -v zig > /dev/null && ! python3 -c 'import ziglang' 2> /dev/null; then
  have_zigbuild=0 why_no_zigbuild="zig not found (put it on PATH, set ZIG=/path/to/zig, or pip install cargo-zigbuild)"
elif ! cargo zigbuild --help > /dev/null 2>&1; then
  have_zigbuild=0 why_no_zigbuild="cargo-zigbuild not installed (cargo install cargo-zigbuild)"
fi

# PKG_CONFIG_PATH for libpipewire-0.3 of this machine's architecture, or
# fails. Dev machines without root use the unpacked headers (BUILDING.md).
pipewire_pkgconfig() {
  local triplet=$1 devroot="$HOME/.cache/crossshell-devroot/usr/lib/$1/pkgconfig"
  if pkg-config --exists libpipewire-0.3 2> /dev/null; then
    echo "${PKG_CONFIG_PATH:-}"
  elif [ -f "$devroot/libpipewire-0.3.pc" ]; then
    echo "$devroot${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  else
    return 1
  fi
}

# file(1) description of $1 must match the flavour.
check_binary() {
  local f=$1 kind=$2 arch=$3 desc
  desc=$(file -b "$f")
  echo "  $desc"
  case "$kind" in
    static)
      case "$desc" in *"statically linked"* | *"static-pie linked"*) ;; *) echo "error: $f is not static" >&2; return 1 ;; esac
      if ldd "$f" > /dev/null 2>&1; then echo "error: ldd sees dependencies in $f" >&2; return 1; fi
      ;;
    full)
      case "$desc" in *"dynamically linked"*) ;; *) echo "error: $f is not a dynamic executable" >&2; return 1 ;; esac
      if command -v objdump > /dev/null; then
        local newest
        newest=$(objdump -T "$f" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
        echo "  newest glibc symbol: $newest (baseline $glibc)"
        if [ "$(printf '%s\n%s\n' "$newest" "$glibc" | sort -V | tail -1)" != "$glibc" ]; then
          echo "error: $f needs glibc $newest, above the $glibc baseline" >&2
          return 1
        fi
      fi
      ;;
    windows)
      case "$desc" in PE32+*) ;; *) echo "error: $f is not a PE32+ executable" >&2; return 1 ;; esac
      ;;
  esac
  case "$arch" in
    x86_64) [[ "$desc" == *x86-64* ]] ;;
    aarch64) [[ "$desc" == *aarch64* || "$desc" == *ARM64* || "$desc" == *Aarch64* ]] ;;
  esac || { echo "error: $f is not $arch" >&2; return 1; }
}

mkdir -p "$out"
rm -f "$out"/crossshell-host-* "$out/SHA256SUMS"

for spec in "${flavours[@]}"; do
  IFS='|' read -r name target zig_target features kind <<< "$spec"
  if [ ${#only[@]} -gt 0 ] && [[ ! " ${only[*]} " == *" $name "* ]]; then
    continue
  fi
  arch=${target%%-*}
  file="crossshell-host-$name"
  [ "$kind" = windows ] && file="$file.exe"

  if [ "$kind" = full ] && [ "$arch" != "$host_arch" ]; then
    skip "$name" "links $arch libpipewire-0.3; build it on an $arch machine (CI's arm runner)"
    continue
  fi
  if [ "$have_zigbuild" = 0 ]; then skip "$name" "$why_no_zigbuild"; continue; fi
  if ! grep -qx "$target" <<< "$installed_targets"; then
    skip "$name" "rust target $target not installed (rustup target add $target)"
    continue
  fi

  env_vars=()
  if [ "$kind" = full ]; then
    if ! pc=$(pipewire_pkgconfig "$arch-linux-gnu"); then
      skip "$name" "libpipewire-0.3 headers not found (see engine/platform-linux/BUILDING.md)"
      continue
    fi
    # zig links against its own glibc stubs and searches no system folder,
    # so a libpipewire in /usr/lib/<arch> (CI's, from apt) is not found.
    # Pointing it at that whole folder would also offer the newer system
    # libc; a folder holding only the one link is enough.
    pwdir=$(PKG_CONFIG_PATH=$pc pkg-config --variable=libdir libpipewire-0.3)
    pwlink="$root/engine/target/pipewire-link/$arch"
    mkdir -p "$pwlink"
    ln -sfn "$pwdir/libpipewire-0.3.so" "$pwlink/libpipewire-0.3.so"
    # The build machine's libpipewire was linked against a newer glibc than
    # the baseline; its own symbols are resolved on the remote at load time.
    tvar="CARGO_TARGET_$(echo "$target" | tr 'a-z-' 'A-Z_')_RUSTFLAGS"
    env_vars+=("PKG_CONFIG_PATH=$pc" "$tvar=${!tvar:+${!tvar} }-L native=$pwlink -C link-arg=-Wl,--allow-shlib-undefined")
  fi

  echo "== $name ($zig_target${features:+, $features})"
  # shellcheck disable=SC2086 # $features is empty or one flag
  (cd "$root/engine" && env ${env_vars[@]+"${env_vars[@]}"} cargo zigbuild --release --locked --target "$zig_target" -p crossshell-host $features)
  bin="$root/engine/target/$target/release/crossshell-host"
  [ "$kind" = windows ] && bin="$bin.exe"
  install -m755 "$bin" "$out/$file"
  check_binary "$out/$file" "$kind" "$arch"
  built+=("$file")
done

if [ ${#built[@]} -gt 0 ]; then
  (cd "$out" && sha256sum "${built[@]}" > SHA256SUMS)
fi

echo
echo "built in $out:"
for f in "${built[@]}"; do
  printf '  %-36s %8s KiB\n' "$f" "$(($(stat -c %s "$out/$f") / 1024))"
done
[ ${#built[@]} -gt 0 ] || echo "  (nothing)"
if [ ${#skipped[@]} -gt 0 ]; then
  echo "skipped:"
  printf '  %s\n' "${skipped[@]}"
  [ "$strict" = 0 ] || { echo "error: --strict and ${#skipped[@]} flavour(s) skipped" >&2; exit 1; }
fi
