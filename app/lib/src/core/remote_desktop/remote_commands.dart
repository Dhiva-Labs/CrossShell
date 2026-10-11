// Commands CrossShell runs on a peer over SSH. Windows peers may default to
// cmd.exe or PowerShell, so Windows commands are `powershell -EncodedCommand`
// (no quoting surprises in either shell). Linux peers may use any login
// shell (fish!), so Linux commands are wrapped in `sh -c '…'`.

import '../ssh/setup_scripts.dart' show encodePowerShell, shQuote;

// Progress records and errors would otherwise reach stderr as CLIXML over
// SSH; report errors as one plain line instead.
String _ps(String script) =>
    'powershell -NoProfile -NonInteractive -EncodedCommand '
    '${encodePowerShell(_psWrap(script))}';

String _psWrap(String script) =>
    """
\$ProgressPreference = 'SilentlyContinue'
try {
$script
} catch {
  [Console]::Error.WriteLine(\$_.Exception.Message)
  exit 1
}
""";
String _sh(String script) => 'sh -c ${shQuote(script)}';

/// Print host.json if the agent it describes is still running; print
/// nothing otherwise.
String readHostInfoCommand({required bool windows}) => windows
    ? _ps(r'''
$f = Join-Path $env:LOCALAPPDATA 'CrossShell\host.json'
if (Test-Path -LiteralPath $f) {
  $raw = Get-Content -LiteralPath $f -Raw
  $j = $raw | ConvertFrom-Json
  if (Get-Process -Id $j.pid -ErrorAction SilentlyContinue) { [Console]::Out.Write($raw) }
}
''')
    : _sh(r'''
rt="${XDG_RUNTIME_DIR:-$HOME/.cache}"
f="$rt/crossshell/host.json"
# The snap's agent lives in the snap's private runtime dir.
[ -f "$f" ] || f="$rt/snap.crossshell/crossshell/host.json"
[ -f "$f" ] || exit 0
pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f")
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && cat "$f"
exit 0
''');

/// Start the peer's agent inside its signed-in desktop session.
///
/// Windows: an SSH session lives in session 0 and can't see the desktop, so
/// the agent runs as an interactive scheduled task (highest privileges when
/// the user is an admin, so it can also drive elevated windows).
/// Linux: `systemd-run --user` inherits the graphical session's environment.
String startAgentCommand({required bool windows}) => windows
    ? _ps(r'''
$ErrorActionPreference = 'Stop'
$pathFile = Join-Path $env:LOCALAPPDATA 'CrossShell\agent-path'
if (-not (Test-Path -LiteralPath $pathFile)) { throw 'CrossShell has never been started on this machine' }
$exe = (Get-Content -LiteralPath $pathFile -Raw).Trim()
if (-not (Test-Path -LiteralPath $exe)) { throw "CrossShell agent not found at $exe (moved or uninstalled?)" }
# USERDOMAIN is unset in SSH sessions; the token knows the real account.
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $exe
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
try {
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName 'CrossShellHost' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
} catch {
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'CrossShellHost' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
}
Start-ScheduledTask -TaskName 'CrossShellHost'
''')
    : _sh(r'''
set -e
pf="${XDG_STATE_HOME:-$HOME/.local/state}/crossshell/agent-path"
if [ -f "$pf" ]; then
  exe=$(cat "$pf")
elif [ -x /snap/bin/crossshell.host ]; then
  exe=/snap/bin/crossshell.host
else
  echo "CrossShell has never been started on this machine" >&2; exit 3
fi
[ -x "$exe" ] || { echo "CrossShell agent not found at $exe (moved or uninstalled?)" >&2; exit 4; }
systemd-run --user --collect --quiet --unit="crossshell-host-$(date +%s)" "$exe"
''');

/// Why the agent didn't come up on a Windows peer: prints the scheduled
/// task's last result code (decimal), or nothing.
String agentLastResultCommand() => _ps(r'''
$i = Get-ScheduledTaskInfo -TaskName 'CrossShellHost' -ErrorAction SilentlyContinue
if ($i) { [Console]::Out.Write($i.LastTaskResult) }
''');

/// Human explanation for a scheduled-task result code, if we know it.
String? explainTaskResult(int code) => switch (code & 0xffffffff) {
  // ERROR_SYSTEM_INTEGRITY_POLICY_VIOLATION
  0x800711C7 || 0x000011C7 =>
    'Windows Smart App Control blocked crossshell-host.exe on that machine because the build is not '
        'code-signed. Install a signed CrossShell release there.',
  0x80070002 || 0x00000002 =>
    'crossshell-host.exe was not found on that machine (moved or uninstalled?).',
  0x800710E0 =>
    'Windows refused to start it: nobody is signed in to that machine\'s desktop.',
  _ => null,
};

/// Remove this machine's key (marker `crossshell:<myId>`) from the peer's
/// authorized keys — used when unpairing so trust ends on both sides.
/// Windows admins: SSH key logons get a full (elevated) token, so the
/// ProgramData file is writable from the session.
String revokeSelfCommand({required bool windows, required String myId}) {
  if (!RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(myId)) {
    throw ArgumentError('bad id');
  }
  final marker = 'crossshell:$myId';
  return windows
      ? _ps('''
\$marker = ' $marker'
foreach (\$f in @((Join-Path \$env:ProgramData 'ssh\\administrators_authorized_keys'), (Join-Path \$env:USERPROFILE '.ssh\\authorized_keys'))) {
  if (Test-Path -LiteralPath \$f) {
    \$keep = @(Get-Content -LiteralPath \$f | Where-Object { \$_ -and -not \$_.TrimEnd().EndsWith(\$marker) })
    Set-Content -LiteralPath \$f -Value \$keep -Encoding ascii
  }
}
''')
      : _sh('''
f="\$HOME/.ssh/authorized_keys"
[ -f "\$f" ] || exit 0
tmp="\$f.crossshell.\$\$"
grep -v ' $marker\$' "\$f" > "\$tmp" || true
chmod 600 "\$tmp" && mv "\$tmp" "\$f"
''');
}
