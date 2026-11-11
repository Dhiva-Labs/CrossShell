# Publishing CrossShell to the Microsoft Store

What is ready, the steps only the account owner can do, and what has not
been tested. The listing text and questionnaire answers are in
`listing.md`, the privacy policy in `PRIVACY.md`, and the notes for
Microsoft's testers in `CERTIFICATION_NOTES.md`.

## What is ready

- `msix_config` in `app/pubspec.yaml` and `msix` in its `dev_dependencies`.
  Display name CrossShell, publisher display name Dhiva-Labs, version
  `0.2.0.0`, logo `app/linux/crossshell-512.png`, capabilities
  `internetClient` and `privateNetworkClientServer`, `store: true`,
  `build_windows: false` (the engine binaries are copied into the Flutter
  build first, see below). `allowElevation` and `unvirtualizedResources` are
  not declared: the one admin prompt runs the system `powershell.exe`, not a
  program from the package.
- **`identity_name` and `publisher` are placeholders**
  (`REPLACE-WITH-PARTNER-CENTER-IDENTITY-NAME`,
  `CN=REPLACE-WITH-PARTNER-CENTER-PUBLISHER`). The name has not been
  reserved yet. Do not upload a package built with them.
- App changes for a packaged (full-trust MSIX) build: state files in
  `%USERPROFILE%\.crossshell` (not the per-package AppData), the elevated
  setup's result file there too, screen sharing off until the user turns it
  on, `--no-notify` ignored by a packaged agent, firewall rules for Private
  and Domain networks only, and *Remove CrossShell changes from this PC* on
  the *This machine* page.

## Build the package (on Windows, x64)

From the repository root:

```powershell
# 1. Engine (crossshell-host.exe, crossshell-view.exe)
cd engine
cargo build --release -p crossshell-host -p crossshell-view
cd ..

# 2. Flutter app
cd app
flutter build windows --release
cd ..

# 3. Put both engine binaries next to cross_shell.exe, where the app looks
#    for them. scripts\package-windows.ps1 does this copy (and also writes
#    the release zip); by hand:
Copy-Item engine\target\release\crossshell-host.exe, engine\target\release\crossshell-view.exe `
  app\build\windows\x64\runner\Release\

# 4. The package (needs the real identity values in pubspec.yaml first)
cd app
dart run msix:create --store
```

The `.msix` is written to `app\build\windows\x64\runner\Release\`. Check
that it contains both engine binaries before uploading, for example by
opening a copy renamed to `.zip`: `crossshell-host.exe` and
`crossshell-view.exe` must sit next to `cross_shell.exe`. Without them the
app runs but screen sharing does not.

`dart run msix:create` writes `AppxManifest.xml`, `Images\`,
`resources.pri` and the VC runtime DLLs into the Release folder and
deletes them again after packing, but the `.msix` itself stays there. Move
it out before making the release zip with `scripts\package-windows.ps1`,
which zips the whole Release folder.

For arm64, build on an arm64 machine and add `architecture: arm64` to
`msix_config` (or pass `--architecture arm64`); the Flutter output is then
under `build\windows\arm64\runner\Release`.

## Partner Center (yours to do)

1. Sign in to Partner Center (https://partner.microsoft.com/dashboard) with
   the Dhiva-Labs developer account and reserve the app name "CrossShell".
2. On the app's *Product identity* page, copy `Package/Identity/Name` into
   `identity_name` and `Package/Identity/Publisher` (starts with `CN=`) into
   `publisher` in `app/pubspec.yaml`. Check that `publisher_display_name`
   matches `Package/Properties/PublisherDisplayName` exactly. The Store
   rejects a package whose values differ.
3. Build the package as above.
4. Publish `PRIVACY.md` at a public URL (for example on the project website
   or as a page in the GitHub repository) and enter that URL as the privacy
   policy, or paste its text into Partner Center's "Provide privacy policy
   text" box. Its contact line points to the contact details at
   dhivalabs.com, as Circuit Lab's policy does.
5. Create a submission:
   - *Pricing and availability*: free.
   - *Properties*: category Developer tools. The app does not need a
     Microsoft account and has no in-app purchases.
   - *Age ratings*: answer the IARC questionnaire with the answers in
     `listing.md`.
   - *Packages*: upload the `.msix`.
   - *Store listings* (English): description, short description, What's
     new, search terms from `listing.md`; screenshots of the main window,
     the *This machine* page, a terminal and a remote desktop window (none
     are in the repository yet).
   - *Submission options*, *Notes for certification*: paste
     `CERTIFICATION_NOTES.md` and add the demo video link.
   - Partner Center will ask why the package uses `runFullTrust` (added by
     the msix tool for every Win32 app): CrossShell is a desktop app that
     runs OpenSSH tools, PowerShell and its own screen-sharing agent.

## Not tested

Nothing below has been run as an installed MSIX package. The package has
not been built with real identity values, installed or submitted.

- **Remote start of the agent from a packaged install.** A peer starts the
  agent with a `CrossShellHost` scheduled task pointing at the path in
  `agent-path`. In a packaged install that path is inside
  `C:\Program Files\WindowsApps\<package folder>\`, which changes with
  every update (the app rewrites `agent-path` each time it starts with
  screen sharing on, so a stale path only matters until then). Whether Task
  Scheduler may start an executable directly from the WindowsApps folder,
  and whether it then runs with or without the package identity, is not
  verified. While CrossShell is open on that PC with screen sharing on, the
  agent is already running (started by the app) and no task is needed.
- Whether the agent started by the app keeps running after the packaged
  app closes.
- The elevated setup and the removal from a packaged install (they use the
  system `powershell.exe` and `%USERPROFILE%\.crossshell\tmp`, which are
  outside the package, so they are expected to behave like the zip build).
- Interoperation with an older CrossShell on the other PC in both
  directions (the code reads and mirrors the old
  `%LOCALAPPDATA%\CrossShell` location for that; not tried between two
  machines).
- The Store's handling of the persistent system changes (OpenSSH Server
  feature, firewall rules, scheduled task, DefaultShell registry value). The
  listing states them, and the app can remove all but the OpenSSH feature.

Possible later improvements, not done: an execution alias for
`crossshell-host.exe` (a stable path for the scheduled task) and
`desktop2:FirewallRules` in the manifest. The msix tool has no option for
either (`execution_alias` only aliases the main executable); they would need
`dart run msix:build`, a hand edit of `AppxManifest.xml`, then
`dart run msix:pack`.

## Before each release

- Bump `version:` in `app/pubspec.yaml`, `msix_version` (four numbers; the
  last one must stay 0 for the Store), `appVersion` in
  `app/lib/src/core/app_controller.dart` and `version` in
  `engine/Cargo.toml`.
- Run the tests (`flutter test` in `app/`, `cargo test` in `engine/`).
- Update What's new in `listing.md`.
