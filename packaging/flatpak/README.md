# Flatpak

`com.dhivalabs.cross_shell.yml` packages the same files as the `.rpm`, the
Arch package and the AppImage: the installed tree that
`packaging/linux-distros/tree.sh` lays out from the release tarball (the
Flutter app with `crossshell-host` and `crossshell-view` next to it). It does
not rebuild CrossShell inside the sandbox. The one thing built from source is
OpenSSH's client (`ssh`, `ssh-keygen`, `ssh-keyscan`), because the GNOME
runtime has none and the app runs those tools itself.

## How CI builds it

The `flatpak` job in `.github/workflows/ci.yml` runs on x86_64 and aarch64
in the `ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image. It
unpacks the tree the `distros` job made into `packaging/flatpak/tree/`
(git-ignored), builds the manifest and the bundle
`crossshell-<version>-<arch>.flatpak`, installs it, checks every ELF file
with `ldd` inside the sandbox, and runs `scripts/smoke-flatpak.sh`: the
bundled ssh tools (ssh-keygen writes a key into the home folder), the engine
streaming its synthetic screen from `crossshell-host` to `crossshell-view`
inside the sandbox, and the app rendering a picture of its window.

Install a bundle with (the GNOME 51 runtime comes from Flathub):

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./crossshell-<version>-x86_64.flatpak
flatpak run com.dhivalabs.cross_shell
```

The bundles are not signed and do not update themselves.

## What works in the sandbox

The Flatpak gets the network, the display, the GPU and the home folder
(`--filesystem=home`, as the snap's `home` plug: the local side of the file
manager browses it, and CrossShell keeps its key, config and known_hosts in
`~/.ssh/crossshell/`, adds an Include line to `~/.ssh/config` and paired
machines' keys to `~/.ssh/authorized_keys`).

Works:

- pairing with another machine (discovery and pairing on port 47820) and
  `ssh <name>` from any terminal afterwards, since the keys and config are in
  the real `~/.ssh`;
- terminal tabs, the SFTP file manager and port forwards, through the bundled
  OpenSSH client;
- remote desktop to another machine: the viewer and its SSH tunnel run in the
  sandbox.

Does not work, use the `.rpm`, Arch package, AppImage or tarball where you
need it:

- **Setting up this machine's SSH server and firewall.** The app does that
  with `pkexec` and the distribution's package manager, which are not in the
  sandbox. Install and start the server yourself (for example
  `sudo dnf install openssh-server && sudo systemctl enable --now sshd`) and
  allow SSH and port 47820 through the firewall; then other machines can sign
  in with the keys pairing added.
- **Other machines viewing or controlling this screen.** A paired machine
  starts and finds this machine's screen-share agent through
  `~/.local/state/crossshell/agent-path` and `$XDG_RUNTIME_DIR/crossshell/`.
  A Flatpak gets its own state and runtime directories, so the agent the app
  starts inside the sandbox cannot be found from outside it.
- **Open in system terminal** and **Open in VS Code**: those are programs on
  the host, which the sandbox cannot start.
- Paths outside the home folder in the file manager (add them with
  `flatpak override --user --filesystem=/path com.dhivalabs.cross_shell`).

## Submitting to Flathub

Flathub builds from a manifest in its own repository and from published
sources only, so a submission differs from this file in one place: the
`crossshell` module's `tree` directory source becomes the release tarballs
(`type: archive`, one per architecture with `only-arches`, URL and sha256
from the release's `SHA256SUMS`) plus `app/linux/com.dhivalabs.cross_shell.desktop`,
the two icons and the metainfo file as `type: file` sources, and the
build commands do what `tree.sh` does (rename the desktop file's `Exec=` and
`Icon=`, remove `lib/libdartjni.so`). The OpenSSH module stays as it is.
Reviewers will look at `--filesystem=home` (the file manager browses local
folders itself) and expect `<screenshots>` in the metainfo file, which has
none yet. The submission itself (a PR to `flathub/flathub`) needs a Flathub
account and is not automated here.
