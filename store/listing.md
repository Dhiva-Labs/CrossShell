# CrossShell store listing (Microsoft Store)

Text to paste into Partner Center. Character limits are noted where the
Store has one.

| | |
| --- | --- |
| App name | CrossShell |
| Publisher | Dhiva-Labs |
| Category | Developer tools |
| Price | Free, no ads, no in-app purchases |
| Version | 0.2.0 |
| Website / source | https://github.com/Dhiva-Labs/CrossShell |
| Privacy policy | `PRIVACY.md`, published at a public URL (see README.md) |

## Short description

80 characters max:

> SSH, files, port forwards and screen sharing between your own PCs on a LAN.

## Description

Requires a second PC running CrossShell on the same network. Can install Windows' OpenSSH Server feature (admin prompt).

CrossShell connects your own computers on the same local network: Windows to Windows, or Windows to Linux. Pair two PCs once, by checking that both screens show the same 6-digit code, and each can then reach the other over SSH.

WHAT YOU CAN DO

• SSH both ways: a terminal on the other PC, in tabs, and "ssh <name>" from any terminal, VS Code Remote-SSH, git or rsync
• Files: a two-pane file manager to copy, rename and delete files on either PC (SFTP)
• Port forwards: reach a port on the other PC from this one, or the other way round
• Remote view and control: see the other PC's screen and use its mouse and keyboard, or view only, with clipboard text shared both ways

UNATTENDED ACCESS, ONLY FOR PAIRED PCs

Screen sharing is off until you turn it on under This machine. When it is on, a PC you have paired with can view and control this screen without anyone at this PC accepting each time. While someone is viewing, this PC shows a notification ("Your screen is being viewed and controlled from ..."), and CrossShell shows a banner with a button to disconnect them. Turning screen sharing off stops it at once.

WHAT IT CHANGES ON YOUR PC

Setting up the SSH server takes one administrator prompt and:
• installs and starts Windows' OpenSSH Server optional feature (the sshd service, set to start automatically)
• adds three firewall rules, "CrossShell SSH", "CrossShell Discovery" and "CrossShell Pairing", for the local subnet on Private and work networks only
• can set OpenSSH's default shell to PowerShell, if no default shell was set
Pairing adds the other PC's key to your SSH authorized keys (for administrators, to Windows' administrators_authorized_keys, with an administrator prompt) and adds an Include line and a crossshell folder to your ~/.ssh. Starting screen sharing from the other PC creates a scheduled task, "CrossShellHost", that runs the sharing agent in your desktop session.

"Remove CrossShell changes from this PC" on the This machine page undoes all of this before you uninstall: it unpairs every PC, deletes the scheduled task, the firewall rules and the keys CrossShell added, removes CrossShell's SSH files and settings lines, and puts the default shell back if CrossShell set it. It leaves the OpenSSH Server feature installed, as you may use it for other things; you can remove it in Settings, System, Optional features.

PRIVATE BY DESIGN

• Local network only. No account, no cloud service, no telemetry. To connect across the internet, put both PCs on a VPN and pair by address.
• Everything between paired PCs (terminal, files, screen, keyboard, mouse, clipboard) goes through SSH, with keys exchanged when you pair.
• While open, CrossShell announces itself on the local network every 3 seconds so your other PCs can find it: the computer name, user name and a random ID, unencrypted, readable by other devices on that network.

LIMITS

• Windows' secure desktop (UAC prompts, the lock screen, the sign-in screen) can't be shown or controlled remotely; the viewer says so until it goes away.
• Windows that run as administrator can only be controlled when the sharing agent itself runs with administrator rights.
• Pairing and discovery need both PCs on the same network, set to Private (not Public) on Windows.
• The built-in terminal does not support input methods (IME) or dead keys; use "Open in system terminal" for those.

## What's new (0.2.0)

First Microsoft Store release.
• Screen sharing is now off until you turn it on, with a plain explanation of what it allows.
• New "Remove CrossShell changes from this PC" action.
• Firewall rules now apply to Private and work networks only, and CrossShell tells you when your network is set to Public.
• A notification on the shared PC while it is being viewed.

## Search terms

Microsoft Store (7 terms max): ssh, sftp, file transfer, port forwarding, terminal, screen sharing, remote access

## Screenshots

None in the repository yet. Needed: the main window with a paired PC, the
This machine page (showing the screen sharing switch and its explanation),
a terminal tab, the file manager, and a remote desktop window.

## Store questionnaires

Answers that are true of the app as built.

**Microsoft Store age rating (IARC)**:
- Type of app: utility / productivity tool (not a game, not a browser).
- Violence, sexual content, nudity, crude language, drugs, alcohol, tobacco: none.
- Gambling or simulated gambling: none.
- Purchases (in-app or of digital goods): none.
- Shares the user's location with other users: no.
- Users can interact or exchange content: **yes**. Paired PCs exchange
  files, terminal sessions, clipboard text and screen images with each
  other, directly over the local network (no server in between, nothing
  public).
- Unrestricted internet / web browser: no.
- Shares personal information with third parties: no.

**Capabilities**:
- `internetClient`: outgoing connections (SSH to a paired PC, which may be
  reached through a VPN address).
- `privateNetworkClientServer`: the local-network discovery broadcasts
  (UDP 47820), the pairing listener (TCP 47820) and SSH to and from PCs on
  the home or work network.
- `runFullTrust`: added by the packaging tool; CrossShell is a Win32
  desktop app.
