# Notes for certification

Paste into Partner Center, *Submission options*, *Notes for certification*
("Additional testing information").

---

CrossShell connects two of the user's own computers on the same local
network (SSH terminal, file transfer, port forwards, remote view and
control). It does nothing useful on a single PC: testing needs **two Windows
PCs on the same local network**, each with CrossShell installed (the second
one can also run the free build from https://github.com/Dhiva-Labs/CrossShell/releases,
or Linux). The network must be set to **Private** on both (Settings >
Network & internet > the connection > Network profile type); CrossShell's
firewall rules do not apply to Public networks, and its "This machine" page
says so when a network is Public. No account, sign-in or test credentials
are needed. Use a Windows account that is an administrator, or have
administrator credentials ready for the prompts.

Demo video: <demo video URL>

## Steps

1. Open CrossShell on both PCs (PC A and PC B).
2. On each PC, click the gear icon (**This machine**). If "SSH server" is red,
   click **Set up OpenSSH Server (admin prompt)** and accept the Windows
   administrator prompt. This prompt runs one PowerShell script that:
   - installs Windows' optional feature "OpenSSH Server" if it is not
     installed, sets the sshd service to start automatically and starts it;
   - adds three inbound firewall rules, "CrossShell SSH" (TCP 22),
     "CrossShell Pairing" (TCP 47820) and "CrossShell Discovery"
     (UDP 47820), limited to the local subnet and to Private and Domain
     networks;
   - if the box "Use PowerShell as the SSH shell" is ticked and no default
     shell is set, sets `HKLM\SOFTWARE\OpenSSH\DefaultShell` to Windows
     PowerShell, and records under `HKLM\SOFTWARE\CrossShell` that it did,
     so the removal can undo it.
   Press **Re-check**; everything should be green.
3. On PC A, PC B appears under **Nearby** within a few seconds. Click
   **Pair**. Both PCs show the same 6-digit code; confirm on both. If the
   Windows account is an administrator, each PC shows one more
   administrator prompt: it adds the other PC's key (marked
   `crossshell:<id>`) to `C:\ProgramData\ssh\administrators_authorized_keys`,
   which is where Windows' sshd reads administrators' keys. (For other
   accounts the key goes into `%USERPROFILE%\.ssh\authorized_keys`, with no
   prompt.)
4. On PC A, use PC B's card: **Terminal** (a shell on PC B: PowerShell if
   it was chosen in step 2, otherwise cmd),
   **Files** (copy a file both ways), and under *More*, **Port forwards**.
5. Remote view and control: on PC B, in **This machine**, turn on **Let
   paired PCs view and control this screen** (off by default; the text under
   it explains what it allows). Keep CrossShell open on PC B. On PC A, click
   **Remote desktop** on PC B's card. A window shows PC B's screen; mouse and
   keyboard control PC B. On PC B, Windows shows a notification "Your screen
   is being viewed and controlled from <PC A's name>" and CrossShell shows a
   banner with **Disconnect them**. Turning the switch off on PC B ends the
   session. (If CrossShell is not running on PC B, PC A starts PC B's
   sharing agent through SSH with a scheduled task named "CrossShellHost"
   in the signed-in user's session.)

## Undo

On each PC, open **This machine**, click **Remove…** next to "Remove
CrossShell changes from this PC" and confirm (one administrator prompt).
It unpairs all PCs, stops the sharing agent, deletes the "CrossShellHost"
scheduled task, the three firewall rules and every `crossshell:` key it
added, unsets OpenSSH's DefaultShell only if CrossShell set it, and removes
the `Include crossshell/config` line from `~/.ssh/config`, the
`~/.ssh/crossshell` folder and `%USERPROFILE%\.crossshell`. It deliberately
leaves the OpenSSH Server feature installed and running, because the user
may use it for other things; remove it in Settings > System > Optional
features > OpenSSH Server if wanted. Then uninstall CrossShell.

## Privacy and network use

No telemetry, analytics, ads or accounts, and no connection to any server
of ours or anyone else's. Traffic stays between the two PCs: UDP broadcasts
on port 47820 for discovery (every 3 seconds while the app is open),
TCP 47820 for pairing, and SSH (TCP 22) for everything else, including the
screen images. The sharing agent listens on 127.0.0.1 only and is reached
through the SSH connection.

Source code (MIT licence): https://github.com/Dhiva-Labs/CrossShell
