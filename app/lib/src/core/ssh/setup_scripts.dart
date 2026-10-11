// Privileged setup, run through UAC (Windows) or polkit (Linux).
//
// The scripts are passed inline (PowerShell -EncodedCommand, `sh -c`) rather
// than written to a temp file first: a file the unelevated app wrote could
// be swapped by another process before the elevated interpreter reads it.
// Values are validated here AND again inside the scripts.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/local_system.dart';
import 'public_key.dart';
import 'ssh_files.dart';

class SetupError implements Exception {
  SetupError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Quote for a PowerShell single-quoted string literal.
String psQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// Quote for a POSIX shell single-quoted word.
String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// One privileged Windows step.
sealed class WindowsStep {}

class InstallSshServer extends WindowsStep {}

class OpenFirewall extends WindowsStep {
  OpenFirewall(this.sshPort);
  final int sshPort;
}

class PowerShellDefaultShell extends WindowsStep {}

class AuthorizeAdminKey extends WindowsStep {
  AuthorizeAdminKey(this.peerId, this.key);
  final String peerId;
  final PublicKey key;
}

class RevokeAdminKey extends WindowsStep {
  RevokeAdminKey(this.peerId);
  final String peerId;
}

final _peerIdRe = RegExp(r'^[A-Za-z0-9-]{8,64}$');

const _psPrelude = r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$result = [ordered]@{ ok = $true; steps = @() }
function Step([string]$name, [scriptblock]$body) {
  try { & $body; $script:result.steps += [ordered]@{ name = $name; ok = $true } }
  catch { $script:result.ok = $false; $script:result.steps += [ordered]@{ name = $name; ok = $false; error = "$_" } }
}
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
function Write-AdminKeys([string[]]$lines) {
  $dir = Split-Path $adminKeys
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -LiteralPath $adminKeys -Value $lines -Encoding ascii
  # sshd ignores the file unless only Administrators and SYSTEM can touch it.
  icacls.exe $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
}
function Read-AdminKeys([string]$marker) {
  if (-not (Test-Path $adminKeys)) { return @() }
  return @(Get-Content -LiteralPath $adminKeys | Where-Object { $_ -and -not $_.TrimEnd().EndsWith(" $marker") })
}
''';

String _psStep(WindowsStep s) {
  switch (s) {
    case InstallSshServer():
      return r'''
Step 'install-sshd' {
  $cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
  if (-not $cap) { throw 'The OpenSSH Server feature is not available on this Windows edition' }
  if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
}
Step 'start-sshd' {
  Set-Service -Name sshd -StartupType Automatic
  Start-Service -Name sshd
}
''';
    case OpenFirewall(:final sshPort):
      if (sshPort < 1 || sshPort > 65535) throw SetupError('bad port $sshPort');
      return '''
Step 'firewall' {
  foreach (\$r in @(
      @{ Name = 'CrossShell-SSH'; Display = 'CrossShell SSH'; Proto = 'TCP'; Port = $sshPort },
      @{ Name = 'CrossShell-Pairing'; Display = 'CrossShell Pairing'; Proto = 'TCP'; Port = 47820 },
      @{ Name = 'CrossShell-Discovery'; Display = 'CrossShell Discovery'; Proto = 'UDP'; Port = 47820 })) {
    Remove-NetFirewallRule -Name \$r.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name \$r.Name -DisplayName \$r.Display -Direction Inbound -Action Allow ``
      -Protocol \$r.Proto -LocalPort \$r.Port -RemoteAddress LocalSubnet -Profile Any | Out-Null
  }
}
''';
    case PowerShellDefaultShell():
      return r'''
Step 'default-shell' {
  $k = 'HKLM:\SOFTWARE\OpenSSH'
  if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
  $cur = (Get-ItemProperty -Path $k -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
  if (-not $cur) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    New-ItemProperty -Path $k -Name DefaultShell -Value $ps -PropertyType String -Force | Out-Null
  }
}
''';
    case AuthorizeAdminKey(:final peerId, :final key):
      if (!_peerIdRe.hasMatch(peerId)) throw SetupError('bad peer id');
      final line = '${key.line} ${authorizedKeyMarker(peerId)}';
      return '''
Step 'authorize-key' {
  \$line = ${psQuote(line)}
  if (\$line -notmatch '^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+ crossshell:[A-Za-z0-9-]+\$') { throw 'refusing a malformed key line' }
  \$marker = \$line.Split(' ')[2]
  Write-AdminKeys (@(Read-AdminKeys \$marker) + \$line)
}
''';
    case RevokeAdminKey(:final peerId):
      if (!_peerIdRe.hasMatch(peerId)) throw SetupError('bad peer id');
      return '''
Step 'revoke-key' {
  if (Test-Path \$adminKeys) { Write-AdminKeys @(Read-AdminKeys ${psQuote(authorizedKeyMarker(peerId))}) }
}
''';
  }
}

/// Build the elevated PowerShell script; result JSON goes to [resultFile].
String buildWindowsScript(List<WindowsStep> steps, String resultFile) {
  final b = StringBuffer(_psPrelude);
  for (final s in steps) {
    b.write(_psStep(s));
  }
  b.write('''
\$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ${psQuote(resultFile)} -Encoding utf8
if (-not \$result.ok) { exit 1 }
''');
  return b.toString();
}

/// PowerShell -EncodedCommand payload (base64 of UTF-16LE).
String encodePowerShell(String script) {
  final units = script.codeUnits;
  final bytes = <int>[];
  for (final u in units) {
    bytes
      ..add(u & 0xff)
      ..add(u >> 8);
  }
  return base64.encode(bytes);
}

class StepResult {
  StepResult(this.name, this.ok, this.error);
  final String name;
  final bool ok;
  final String? error;
}

/// Run [steps] elevated (one UAC prompt). Throws [SetupError] if the user
/// declines or any step fails.
Future<List<StepResult>> runWindowsElevated(List<WindowsStep> steps) async {
  if (!Platform.isWindows) throw SetupError('not on Windows');
  final tmp = await Directory.systemTemp.createTemp('crossshell-setup');
  final resultFile = p.join(tmp.path, 'result.json');
  try {
    final inner = encodePowerShell(buildWindowsScript(steps, resultFile));
    // The outer (unelevated) PowerShell asks for elevation and waits. It is
    // one line so it can travel as a plain -Command argument; the inner
    // script is base64 and never needs quoting.
    final outer =
        "try { \$p = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru "
        "-WindowStyle Hidden -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',"
        "'-EncodedCommand','$inner'); exit \$p.ExitCode } "
        "catch { [Console]::Error.WriteLine(\$_.Exception.Message); exit 1223 }";
    final r = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      outer,
    ]);
    final f = File(resultFile);
    if (!await f.exists()) {
      final err = (r.stderr as String).trim();
      if (r.exitCode == 1223 || err.toLowerCase().contains('cancel')) {
        throw SetupError('Administrator permission was declined');
      }
      throw SetupError(
        'elevated setup did not run: ${err.isEmpty ? 'exit ${r.exitCode}' : err}',
      );
    }
    var text = await f.readAsString();
    if (text.startsWith('﻿')) text = text.substring(1);
    final json = jsonDecode(text) as Map<String, dynamic>;
    final rawSteps = json['steps'];
    final list = rawSteps is List ? rawSteps : [rawSteps];
    final results = [
      for (final s in list.whereType<Map<String, dynamic>>())
        StepResult(
          s['name'] as String? ?? '?',
          s['ok'] == true,
          s['error'] as String?,
        ),
    ];
    final failed = results.where((s) => !s.ok).toList();
    if (failed.isNotEmpty) {
      throw SetupError(failed.map((s) => '${s.name}: ${s.error}').join('; '));
    }
    return results;
  } finally {
    await tmp.delete(recursive: true).catchError((_) => tmp);
  }
}

// ------------------------------------------------------------------ Linux

const linuxSetupScript = r'''
set -eu
action="$1"
case "$action" in
  install-server)
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y openssh-server
    elif command -v pacman >/dev/null 2>&1; then
      pacman -S --noconfirm --needed openssh
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive install openssh-server
    else
      echo "no supported package manager (apt, dnf, pacman, zypper)" >&2; exit 3
    fi
    for unit in ssh.socket ssh.service sshd.service; do
      if systemctl cat "$unit" >/dev/null 2>&1; then
        systemctl enable --now "$unit"
        exit 0
      fi
    done
    echo "openssh-server installed but no ssh/sshd systemd unit found" >&2; exit 4
    ;;
  firewall)
    port="$2"
    case "$port" in ''|*[!0-9]*) echo "bad port" >&2; exit 2;; esac
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      # Allow from each directly attached IPv4 subnet only.
      for cidr in $(ip -o -f inet addr show scope global | awk '{print $4}'); do
        net=$(echo "$cidr" | awk -F/ '{
          split($1, o, "."); bits = $2;
          ip = ((o[1]*256 + o[2])*256 + o[3])*256 + o[4];
          size = 2 ^ (32 - bits); net = ip - (ip % size);
          printf "%d.%d.%d.%d/%d", int(net/16777216)%256, int(net/65536)%256, int(net/256)%256, net%256, bits }')
        ufw allow proto tcp from "$net" to any port "$port" comment "CrossShell SSH"
        ufw allow proto tcp from "$net" to any port 47820 comment "CrossShell pairing"
        ufw allow proto udp from "$net" to any port 47820 comment "CrossShell discovery"
      done
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="$port/tcp" --add-port=47820/tcp --add-port=47820/udp
      firewall-cmd --reload
    fi
    ;;
  *)
    echo "unknown action $action" >&2; exit 2
    ;;
esac
''';

/// Run a Linux setup action as root via polkit (password dialog).
Future<void> runLinuxPrivileged(
  String action, [
  List<String> args = const [],
]) async {
  if (!Platform.isLinux) throw SetupError('not on Linux');
  final r = await Process.run('pkexec', [
    '/bin/sh',
    '-c',
    linuxSetupScript,
    'crossshell-setup',
    action,
    ...args,
  ]);
  if (r.exitCode == 126 || r.exitCode == 127) {
    throw SetupError('Administrator permission was declined');
  }
  if (r.exitCode != 0) {
    final err = '${r.stderr}'.trim();
    throw SetupError(err.isEmpty ? '$action failed (exit ${r.exitCode})' : err);
  }
}

/// True when [LocalSystem] would need elevation to authorize a key
/// (Windows admins: sshd reads ProgramData\ssh\administrators_authorized_keys).
Future<bool> authorizationNeedsElevation() => LocalSystem.isWindowsAdmin();
