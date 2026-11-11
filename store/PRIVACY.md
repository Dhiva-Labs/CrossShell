# CrossShell privacy policy

Last updated: 2026-11-11

CrossShell is an app by Dhiva-Labs that connects your own computers on the
same local network: SSH terminal, file transfer, port forwards and remote
view and control of the screen. This policy describes what information the
app handles, where it goes and how you control it. It applies to CrossShell
on Windows (including the Microsoft Store version) and on Linux.

## Summary

- Dhiva-Labs does not collect any information from CrossShell. The app has no
  account, no analytics, no telemetry, no advertising and no crash
  reporting, and it does not contact any server run by Dhiva-Labs or anyone
  else.
- CrossShell only talks to devices on your local network (or other
  addresses you type in yourself), and exchanges data only with computers
  you have paired with.
- What it stores stays on your devices.

## Information the app processes

**On your local network, readable by other devices on it.** While CrossShell
is open, it announces itself every 3 seconds with an unencrypted UDP
broadcast on the local network, so your other computers can find it. Each
announcement contains:

- a random device ID that CrossShell creates once for this computer,
- the computer's name (hostname),
- your user name on this computer (the Windows or Linux account name),
- the operating system (Windows or Linux), the SSH and pairing port numbers
  and the CrossShell version.

Like any network packet, it also carries this computer's IP address. Any
device on the same network can receive these announcements, not only your
own computers. Close CrossShell to stop them.

**During pairing.** When you pair two computers, they first exchange the
device ID, computer name and operating system, unencrypted, so each screen
can show who is asking. Only after you confirm on both computers that they
show the same 6-digit code do they exchange, encrypted, the user name, SSH
port, the SSH host keys of the computer's SSH server and CrossShell's own
SSH public key.

**Between paired computers, only through SSH.** When you use a paired
computer, CrossShell sends what that feature needs, encrypted by SSH, directly
between the two computers:

- terminal input and output,
- files you copy, and file and folder names you browse,
- traffic of the port forwards you set up,
- for remote view and control: images of the screen, keyboard and mouse
  input, the mouse pointer, and clipboard text (in both directions).

None of this passes through any server and none of it is recorded by
CrossShell.

**Stored on your computer.** CrossShell keeps:

- this computer's random device ID and the list of paired computers (name,
  user name, operating system, last known IP address, SSH port and keys),
- the app settings,
- an SSH key pair for this computer and the paired computers' public keys,
  in your SSH folder (`~/.ssh/crossshell`, `~/.ssh/authorized_keys`, and on
  Windows for administrators `C:\ProgramData\ssh\administrators_authorized_keys`),
- for screen sharing, a small file with the sharing agent's local port and
  a random password that changes each time the agent starts, the name of
  the computer currently viewing
  the screen, and a log of technical events (for example when a viewer
  connected and disconnected, with that computer's name). On Windows these
  are in `%USERPROFILE%\.crossshell`; on Linux under `~/.local/state` and
  the session's runtime folder.

The SSH server of your operating system (OpenSSH) keeps its own logs
according to its settings; CrossShell does not change them.

## Viewing someone's screen: consent and notice

A computer can only view or control another computer's screen if:

1. the two computers were paired, which needs a person at each computer to
   confirm the same 6-digit code, and
2. screen sharing was turned on, on the computer being viewed. It is off
   until someone turns it on in CrossShell's "This machine" page.

Once both are true, the paired computer can connect without anyone at the
viewed computer accepting each time. While it is connected, the viewed
computer shows a notification that its screen is being viewed (and
controlled, unless view-only), naming the viewing computer, and CrossShell
shows a banner with a button to disconnect. Only use screen sharing on
computers you own or have permission to access.

## Your choices

- Turn screen sharing off at any time in "This machine". This also ends a
  session in progress.
- Unpair a computer to remove its key from this computer and, if it can be
  reached, this computer's key from it.
- "Remove CrossShell changes from this PC" unpairs every computer and
  removes CrossShell's keys, SSH settings, files, firewall rules and
  scheduled task.
- Uninstalling the Microsoft Store version removes the app with its settings
  and list of paired computers. Run the removal above first to also remove
  the changes outside the app.

## Retention

Everything listed above stays on your computers until you unpair, remove
CrossShell's changes or uninstall the app. The screen-sharing log is
replaced each time the sharing agent starts. Nothing is kept anywhere else.

## Third parties

CrossShell shares no information with Dhiva-Labs or any third party. It
uses your operating system's OpenSSH tools and SSH server, which work on
your computer.

## Children

CrossShell is a tool for managing your own computers and is not directed at
children.

## Changes

If this policy changes, the new version will be published at the same
address with a new date.

## Contact

Questions about this policy: <contact email>

Source code: https://github.com/Dhiva-Labs/CrossShell
