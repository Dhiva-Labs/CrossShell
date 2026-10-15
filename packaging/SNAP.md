# Publishing CrossShell to the Snap Store

Snap name: `crossshell`. Packaging is in `snap/snapcraft.yaml`, and the confinement is **strict**.

## Current state

- **2026-10-12:** revision 1 (0.1.1) was uploaded with `--release=stable`. It is in **manual review** because of the `ssh-dir` personal-files plug, so post the store request below.
- **After approval:** run `snapcraft release crossshell 1 stable` if the store didn't release it automatically. A revision in review blocks later releases, so don't upload another revision expecting it to go out first.
- **arm64:** `snapcraft.yaml` lists `amd64` and `arm64`. CI builds both natively (the `Snap amd64` and `Snap arm64` jobs on `ubuntu-24.04` and `ubuntu-24.04-arm`), checks the architecture of the binaries and the expanded PipeWire paths in `meta/snap.yaml`, and keeps each `.snap` as a workflow artifact. It never uploads to the store. Upload the arm64 snap by hand (`snapcraft upload --release=stable crossshell_<ver>_arm64.snap`) only after revision 1 has left review, since a revision in review blocks later releases.

## What works under strict confinement

| What the app does | How | Strictly confined? |
| --- | --- | --- |
| Client key `~/.ssh/crossshell/id_ed25519` | bundled `ssh-keygen` | Yes, with `ssh-dir` (personal-files, write `$HOME/.ssh`) |
| Managed `~/.ssh/crossshell/{config,known_hosts}`, one `Include` line in `~/.ssh/config` | Dart file I/O | Yes, with `ssh-dir` |
| Paired machines' keys in `~/.ssh/authorized_keys` (marked `crossshell:<id>`) | Dart file I/O | Yes, with `ssh-dir` |
| This machine's sshd host keys | bundled `ssh-keyscan 127.0.0.1` | Yes |
| Discovery (UDP broadcast, 47820) and pairing (TCP 47820) | Dart sockets | Yes: `network`, `network-bind` |
| Terminal, SFTP and port forwards | dartssh2 | Yes: `network`, `network-bind` |
| Local file pane | Dart file I/O | Yes: `home`, `removable-media` |
| Remote desktop tunnel and remote commands | bundled `ssh` (`openssh-client` is staged) | Yes |
| Screen-share agent: loopback listener | Rust | Yes: `network-bind` |
| Screen capture and input on Wayland | xdg-desktop-portal RemoteDesktop and ScreenCast, frames over PipeWire (staged client library and SPA plugins) | Yes: `desktop`. It asks once, and a restore token avoids the prompt after that |
| Screen capture and input on X11 | XShm/GetImage and XTest | Yes: `x11` |
| Prompt-free capture on GNOME | Mutter's private `org.gnome.Mutter.RemoteDesktop` D-Bus API | **No.** No interface grants it, so the agent falls back to the portal |
| Install and enable openssh-server, open the firewall | `pkexec` | **No.** The app shows the commands to run instead |
| "Open in system terminal" and "Open in VS Code" | run host programs | **No.** The actions are hidden in the snap |
| Started remotely by a paired machine | `systemd-run --user /snap/bin/crossshell.host` | Yes. The remote command falls back to `/snap/bin/crossshell.host` when no `agent-path` was published |
| `host.json` and `status.json` | `$XDG_RUNTIME_DIR` is `/run/user/<uid>/snap.crossshell` | Yes. Remote readers look in both runtime dirs |

The app detects the snap from `SNAP_NAME` (`LocalSystem.inSnap`). It takes `~/.ssh` from `SNAP_REAL_HOME` and leaves `HOME` as the snap's own, so GTK caches and the portal restore token stay private to the snap.

### Why not classic

The store grants classic only to listed kinds of software (IDEs, compilers, terminals and the like), and CrossShell is not one of them. Classic would only add three optional conveniences: pkexec setup, launching the terminal and VS Code, and the prompt-free GNOME API. A classic upload would also wait in review and block every later release. The GitHub tarball keeps all features for people who want them.

## Plugs

| Plug | Interface | Purpose | Auto-connected? |
| --- | --- | --- | --- |
| `ssh-dir` | personal-files, write `$HOME/.ssh` | everything SSH (see above); the stock `ssh-keys` interface is read-only | No. It needs a store declaration (request below) |
| `network`, `network-bind` | | discovery, pairing, SSH, agent listener | Yes |
| `home`, `removable-media` | | local pane of the file manager | `home` yes, `removable-media` no |
| `desktop`, `wayland`, `x11`, `opengl`, … | gnome extension | GUI, portal, clipboard | Yes |

After installing, until auto-connect is granted:

```bash
sudo snap connect crossshell:ssh-dir
```

## Build and test

```bash
snapcraft pack                      # crossshell_<ver>_<amd64|arm64>.snap, for the machine's own architecture
```

`apps.*.environment` uses `$CRAFT_ARCH_TRIPLET_BUILD_FOR` for the PipeWire plugin directories, which snapcraft expands to `x86_64-linux-gnu` or `aarch64-linux-gnu` when it writes `meta/snap.yaml`.

Test confined in the `snaptest` LXD VM before every upload (see the Dhiva Labs snap notes for the VM recipe). `app/tool/headless_peer.dart` is a headless pairing peer: it answers one pairing request, confirms the code and trusts the other side the same way the app does. That lets you test pairing, SSH in both directions and the agent's remote start against the snap without a second desktop:

```bash
cd app && dart compile exe tool/headless_peer.dart -o build/headless_peer
```

The app's test hooks only work in profile builds; a release snap ignores them, so the release snap is driven through its real UI with `xdotool` on a private Xvfb display inside the VM.

### Verified for 0.1.0 (strict, `ssh-dir` connected, Ubuntu 24.04 VM)

The partner was `headless_peer` running in a separate LXD container on the same bridge.

- The app launches confined and renders on Xvfb.
- The health check finds the VM's sshd.
- The client key is created in the real `~/.ssh/crossshell/`.
- The agent starts and writes `host.json` to `/run/user/1000/snap.crossshell/crossshell/`.
- Pairing, using *Pair by address* and *Codes match* in the UI:
  - both sides showed the same code;
  - the snap wrote `~/.ssh/crossshell/config`, the pinned `known_hosts`, the `Include` line and the peer's `authorized_keys` entry.
- SSH both ways:
  - the snap's bundled `ssh` (confined) works with the app's config;
  - plain `ssh peerbox` works through the `Include`;
  - the peer can sign in to the VM.
- The in-app terminal (dartssh2 with pinned keys) runs commands on the peer.
- From the peer over SSH:
  - the `host.json` read finds the snap's agent;
  - after the agent was stopped, the remote start brought it back through `systemd-run --user /snap/bin/crossshell.host`, running confined as `snap.crossshell.host (enforce)`.
- Remote desktop capture (X11 backend on Xvfb) with the snap's viewer decoded the screen.
- No CrossShell AppArmor denials were logged.

Not verified in the snap: the xdg-portal capture path on a real GNOME/KDE Wayland session (the VM has no desktop session). That path was tested unconfined in a headless GNOME session.

## Store request

The first upload is held for manual review because of `ssh-dir`. A revision in review blocks every later release, so post this in the forum's **store-requests** category (<https://forum.snapcraft.io/c/store-requests>) when uploading:

> **crossshell: personal-files `ssh-dir` (write `$HOME/.ssh`) + auto-connect**
>
> CrossShell (<https://github.com/Dhiva-Labs/CrossShell>, MIT) sets up SSH between a user's own machines on their LAN, for example a Linux desktop and a Windows build box. Two machines pair by comparing a 6-digit code. Each then trusts the other through standard OpenSSH files, so `ssh <name>`, VS Code Remote-SSH, rsync and git work afterwards.
>
> Writing `~/.ssh` is the app's core function, and the snap can't work without it:
> - it creates its own client key in `~/.ssh/crossshell/id_ed25519` (with ssh-keygen);
> - it keeps `~/.ssh/crossshell/config` and `~/.ssh/crossshell/known_hosts`, with host keys pinned at pairing;
> - it adds a single `Include crossshell/config` line at the top of `~/.ssh/config`;
> - it adds a paired machine's public key to `~/.ssh/authorized_keys`, marked `crossshell:<peer-id>`, and removes exactly that line when the user unpairs.
>
> It never reads or changes the user's other keys. The read-only `ssh-keys` interface isn't enough, because pairing must write these files. We request the `ssh-dir` personal-files plug (write `$HOME/.ssh`) and auto-connect, so pairing works right after install.
