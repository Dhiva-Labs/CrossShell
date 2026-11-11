// Microsoft Store compatibility: state outside AppData, opt-in screen
// sharing, the removal mode of the elevated script and the local cleanup.

import 'dart:convert';
import 'dart:io';

import 'package:cross_shell/src/core/app_controller.dart';
import 'package:cross_shell/src/core/platform/local_system.dart';
import 'package:cross_shell/src/core/remote_desktop/remote_commands.dart';
import 'package:cross_shell/src/core/ssh/public_key.dart';
import 'package:cross_shell/src/core/ssh/setup_scripts.dart';
import 'package:cross_shell/src/core/ssh/ssh_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const ed =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIZ/uAgXTIgSDXu5KtVkuyWBxnR2ae0aN4E/XCSDExpx';
const id1 = 'aaaaaaaa-1111-4111-8111-111111111111';
const id2 = 'bbbbbbbb-2222-4222-8222-222222222222';

/// The script inside a `powershell … -EncodedCommand <b64>` command line.
String decodePs(String command) {
  final b64 = command.split('-EncodedCommand ').last.trim();
  final bytes = base64.decode(b64);
  final units = [
    for (var i = 0; i + 1 < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ];
  return String.fromCharCodes(units);
}

void main() {
  group('Windows state dir', () {
    const env = {
      'USERPROFILE': r'C:\Users\alex',
      'LOCALAPPDATA': r'C:\Users\alex\AppData\Local',
    };

    test('is in the profile, not under AppData', () {
      expect(LocalSystem.windowsStateDir(env), r'C:\Users\alex\.crossshell');
      expect(
        LocalSystem.legacyWindowsStateDir(env),
        r'C:\Users\alex\AppData\Local\CrossShell',
      );
      expect(
        LocalSystem.legacyWindowsStateDir({'USERPROFILE': r'C:\Users\alex'}),
        r'C:\Users\alex\AppData\Local\CrossShell',
      );
    });

    test('elevated setup results go under it, not %TEMP%', () {
      expect(
        setupTempRoot({...env, 'TEMP': r'C:\Users\alex\AppData\Local\Temp'}),
        r'C:\Users\alex\.crossshell\tmp',
      );
    });

    test('peer commands read the new dir first, then the old one', () {
      for (final cmd in [
        readHostInfoCommand(windows: true),
        startAgentCommand(windows: true),
      ]) {
        final s = decodePs(cmd);
        final fresh = s.indexOf(r"Join-Path $env:USERPROFILE '.crossshell'");
        final legacy = s.indexOf(r"Join-Path $env:LOCALAPPDATA 'CrossShell'");
        expect(fresh, greaterThan(-1), reason: s);
        expect(legacy, greaterThan(fresh), reason: s);
      }
      expect(decodePs(readHostInfoCommand(windows: true)), contains('host.json'));
      expect(decodePs(startAgentCommand(windows: true)), contains('agent-path'));
      // Linux is unchanged.
      expect(
        readHostInfoCommand(windows: false),
        contains(r'${XDG_RUNTIME_DIR:-$HOME/.cache}'),
      );
      expect(
        startAgentCommand(windows: false),
        contains(r'${XDG_STATE_HOME:-$HOME/.local/state}/crossshell/agent-path'),
      );
    });
  });

  group('screen sharing setting', () {
    test('is off when missing, kept when saved', () {
      expect(AppSettings().allowScreenSharing, isFalse);
      expect(AppSettings.fromJson({}).allowScreenSharing, isFalse);
      expect(
        AppSettings.fromJson({'sshPort': 2222}).allowScreenSharing,
        isFalse,
      );
      expect(
        AppSettings.fromJson({'allowScreenSharing': true}).allowScreenSharing,
        isTrue,
      );
      final round = AppSettings.fromJson(
        AppSettings(sshPort: 2222, allowScreenSharing: true).toJson(),
      );
      expect(round.sshPort, 2222);
      expect(round.allowScreenSharing, isTrue);
    });
  });

  group('elevated script', () {
    test('firewall rules are Domain,Private and on one line', () {
      final s = buildWindowsScript([OpenFirewall(22)], 'r.json');
      expect(s, contains('-Profile Domain,Private'));
      expect(s, isNot(contains('-Profile Any')));
      // A doubled backtick is not a line continuation in PowerShell.
      expect(s, isNot(contains('``')));
      final line = s
          .split('\n')
          .firstWhere((l) => l.contains('New-NetFirewallRule'));
      expect(line, contains('-LocalPort'));
      expect(line, contains('-RemoteAddress LocalSubnet'));
    });

    test('setting the default shell is recorded for removal', () {
      final s = buildWindowsScript([PowerShellDefaultShell()], 'r.json');
      expect(s, contains(r'HKLM:\SOFTWARE\CrossShell'));
      expect(s, contains('SetOpenSshDefaultShell'));
      // Only when CrossShell set it: the record is inside `if (-not $cur)`.
      expect(
        s.indexOf('SetOpenSshDefaultShell'),
        greaterThan(s.indexOf(r'if (-not $cur)')),
      );
    });

    test('removal mode undoes CrossShell changes and leaves sshd alone', () {
      final s = buildWindowsScript(
        windowsRemovalSteps(
          agentExe: r"C:\Users\o'brien\CrossShell\crossshell-host.exe",
        ),
        r'C:\Users\alex\.crossshell\tmp\setup-1\result.json',
      );
      for (final rule in crossShellFirewallRules) {
        expect(s, contains("'$rule'"));
      }
      expect(s, contains('Remove-NetFirewallRule -Name'));
      expect(s, contains("Unregister-ScheduledTask -TaskName 'CrossShellHost'"));
      expect(s, contains("Stop-ScheduledTask -TaskName 'CrossShellHost'"));
      expect(s, contains(r"'C:\Users\o''brien\CrossShell\crossshell-host.exe'"));
      expect(s, contains('crossshell:[A-Za-z0-9-]{8,64}'));
      expect(s, contains('Write-AdminKeys'));
      // DefaultShell only when CrossShell recorded setting it, and unchanged.
      expect(s, contains('SetOpenSshDefaultShell'));
      expect(s, contains(r'if ($cur -eq $set)'));
      for (final forbidden in [
        'Stop-Service',
        'Set-Service',
        'Remove-WindowsCapability',
        'Add-WindowsCapability',
        'New-NetFirewallRule',
        'PasswordAuthentication',
      ]) {
        expect(s, isNot(contains(forbidden)), reason: forbidden);
      }
      expect(s, isNot(contains('``')));
    });

    test('removal without a known agent path skips the process stop', () {
      final s = buildWindowsScript(windowsRemovalSteps(), 'r.json');
      expect(s, isNot(contains('Stop-Process')));
      expect(s, contains('Unregister-ScheduledTask'));
    });

    test('a suspicious agent path is refused', () {
      for (final bad in [
        r'C:\Windows\System32\cmd.exe',
        "C:\\x\\crossshell-host.exe\nRemove-Item C:\\",
      ]) {
        expect(
          () => buildWindowsScript([RemoveAgentTask(bad)], 'r'),
          throwsA(isA<SetupError>()),
          reason: bad,
        );
      }
    });

    test('declining is a SetupError the removal can tell apart', () {
      final e = SetupDeclined();
      expect(e, isA<SetupError>());
      expect(e.message, contains('declined'));
    });
  });

  group('local cleanup', () {
    test('drops every CrossShell key and nothing else', () {
      const mine = 'ssh-rsa AAAAB3NzaC1yc2E= me@laptop';
      final k = PublicKey.parse(ed);
      var a = upsertAuthorizedKey('$mine\n', id1, k);
      a = upsertAuthorizedKey(a, id2, k);
      a = '$a# crossshell:not-a-marker comment line\n';
      expect(
        removeAllCrossShellKeys(a),
        '$mine\n# crossshell:not-a-marker comment line\n',
      );
      expect(removeAllCrossShellKeys('$ed crossshell:$id1\n'), '');
      expect(removeAllCrossShellKeys('$mine\r\n$ed crossshell:$id1\r\n'), '$mine\r\n');
    });

    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cs_remove_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('removes the Include line, our folder and our keys', () async {
      final layout = SshLayout(p.join(tmp.path, '.ssh'));
      final files = SshFiles(layout);
      Directory(layout.sshDir).createSync();
      const userConfig = 'Host *\n  ServerAliveInterval 30\n';
      File(layout.userConfig).writeAsStringSync(userConfig);
      const mine = 'ssh-rsa AAAAB3NzaC1yc2E= me@laptop\n';
      File(layout.authorizedKeys).writeAsStringSync(mine);
      File(p.join(layout.sshDir, 'id_ed25519')).writeAsStringSync('mine');

      await files.writePeerConfig(
        PeerSshEntry(
          peerId: id1,
          alias: 'winbox',
          host: '192.168.1.20',
          port: 22,
          user: 'alex',
        ),
      );
      await files.pinHostKeys(id1, [PublicKey.parse(ed)]);
      await files.authorizeInUserFile(id1, PublicKey.parse(ed));
      expect(File(layout.userConfig).readAsStringSync(), contains(includeLine));

      await files.removeAllCrossShellChanges();

      expect(File(layout.userConfig).readAsStringSync(), userConfig);
      expect(File(layout.authorizedKeys).readAsStringSync(), mine);
      expect(Directory(layout.dir).existsSync(), isFalse);
      // The user's own key next to ours is untouched.
      expect(File(p.join(layout.sshDir, 'id_ed25519')).existsSync(), isTrue);

      // Running it again is harmless.
      await files.removeAllCrossShellChanges();
      expect(File(layout.userConfig).readAsStringSync(), userConfig);
    });

    test('a config that only held our Include is deleted', () async {
      final layout = SshLayout(p.join(tmp.path, '.ssh'));
      final files = SshFiles(layout);
      await files.writePeerConfig(
        PeerSshEntry(
          peerId: id1,
          alias: 'winbox',
          host: '192.168.1.20',
          port: 22,
          user: 'alex',
        ),
      );
      await files.removeAllCrossShellChanges();
      expect(File(layout.userConfig).existsSync(), isFalse);
      expect(Directory(layout.dir).existsSync(), isFalse);
    });
  });

  test('the confirmation says sshd is kept and lists the changes', () {
    final w = removalDescription(windows: true);
    expect(w, contains('does not stop or uninstall the SSH server'));
    expect(w, contains('CrossShellHost scheduled task'));
    expect(w, contains('CrossShell SSH, CrossShell Discovery and CrossShell Pairing'));
    expect(w, contains('Include crossshell/config'));
    expect(w, contains('administrator permission once'));
    final l = removalDescription(windows: false);
    expect(l, contains('does not stop or uninstall the SSH server'));
    expect(l, isNot(contains('scheduled task')));
  });
}
