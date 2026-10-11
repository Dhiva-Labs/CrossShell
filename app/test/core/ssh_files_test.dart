import 'dart:io';

import 'package:cross_shell/src/core/peers/peer.dart';
import 'package:cross_shell/src/core/remote_desktop/remote_desktop.dart';
import 'package:cross_shell/src/core/ssh/public_key.dart';
import 'package:cross_shell/src/core/ssh/setup_scripts.dart';
import 'package:cross_shell/src/core/ssh/ssh_files.dart';
import 'package:cross_shell/src/core/ssh/sshd.dart';
import 'package:flutter_test/flutter_test.dart';

const ed =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKKkY2WKzNp7LwHoUGCJxBB8MQrtp5MT5TMJtJ0xR0AU';
const id1 = 'aaaaaaaa-1111-4111-8111-111111111111';
const id2 = 'bbbbbbbb-2222-4222-8222-222222222222';

PeerSshEntry entry(String id, String alias, {String user = 'dhiva'}) =>
    PeerSshEntry(
      peerId: id,
      alias: alias,
      host: '192.168.0.129',
      port: 22,
      user: user,
    );

void main() {
  group('ssh config', () {
    test('blocks upsert, replace and remove without touching other text', () {
      var c = upsertPeerBlock('', entry(id1, 'lenovo'));
      expect(c, contains('Host lenovo\n'));
      expect(c, contains('HostKeyAlias crossshell-$id1'));
      expect(c, contains('StrictHostKeyChecking yes'));
      c = upsertPeerBlock(c, entry(id2, 'desk'));
      c = upsertPeerBlock(c, entry(id1, 'lenovo', user: 'John Smith'));
      expect('Host lenovo'.allMatches(c), hasLength(1));
      expect(c, contains('User "John Smith"'));
      c = removePeerBlock(c, id1);
      expect(c, isNot(contains('lenovo')));
      expect(c, contains('Host desk'));
    });

    test('include goes at the top once and can be removed', () {
      const user = 'Host *\n  ServerAliveInterval 30\n';
      final withInc = ensureInclude(user);
      expect(withInc.indexOf(includeLine), lessThan(withInc.indexOf('Host *')));
      expect(ensureInclude(withInc), withInc);
      expect(removeInclude(withInc), user);
      expect(ensureInclude(''), contains(includeLine));
    });
  });

  group('known hosts', () {
    test('pins per peer and reads back', () {
      final k = PublicKey.parse(ed);
      var kh = upsertKnownHosts('', id1, [k]);
      kh = upsertKnownHosts(kh, id2, [k]);
      expect(knownHostsFor(kh, id1), [k]);
      kh = upsertKnownHosts(kh, id1, const []);
      expect(knownHostsFor(kh, id1), isEmpty);
      expect(knownHostsFor(kh, id2), [k]);
    });
  });

  group('authorized keys', () {
    test('marker-based upsert/remove keeps unrelated keys', () {
      const mine = 'ssh-rsa AAAAB3NzaC1yc2E= me@laptop';
      final k = PublicKey.parse(ed);
      var a = upsertAuthorizedKey('$mine\n', id1, k);
      expect(a, '$mine\n$ed crossshell:$id1\n');
      a = upsertAuthorizedKey(a, id1, k);
      expect('crossshell:$id1'.allMatches(a), hasLength(1));
      expect(removeAuthorizedKey(a, id1), '$mine\n');
      // A similar-looking id must not match.
      expect(removeAuthorizedKey(a, id1.substring(0, 20)), a);
    });
  });

  group('public keys', () {
    test('parses and fingerprints like OpenSSH', () async {
      final k = PublicKey.parse('$ed some comment');
      expect(k.line, ed);
      final fp = await k.sha256Fingerprint();
      expect(fp, startsWith('SHA256:'));
      if (await _hasSshKeygen()) {
        final dir = await Directory.systemTemp.createTemp();
        final f = File('${dir.path}/k.pub')..writeAsStringSync(ed);
        final r = await Process.run('ssh-keygen', ['-lf', f.path]);
        expect(r.stdout as String, contains(fp));
        await dir.delete(recursive: true);
      }
    });

    test('rejects options, other types and mismatched blobs', () {
      for (final bad in [
        'from="1.2.3.4" $ed',
        'ssh-dss AAAAB3NzaC1kc3M=',
        'ssh-rsa ${ed.split(' ')[1]}',
        'ssh-ed25519 !!!',
        '$ed\nssh-ed25519 x',
        '',
      ]) {
        expect(isValidPublicKey(bad), isFalse, reason: bad);
      }
    });

    test('keyscan output parses, strongest first', () {
      final keys = parseKeyscan(
        '# 127.0.0.1:22 SSH-2.0-OpenSSH_9.5\n'
        '127.0.0.1 ssh-rsa AAAAB3NzaC1yc2E=\n'
        '127.0.0.1 $ed\n'
        '[127.0.0.1]:2222 $ed\n',
      );
      expect(keys.map((k) => k.type), ['ssh-ed25519', 'ssh-rsa']);
    });
  });

  group('aliases', () {
    test('are ssh-friendly and unique', () {
      expect(makeAlias('LENOVO', []), 'lenovo');
      expect(makeAlias('My PC!', []), 'my-pc');
      expect(makeAlias('lenovo', ['lenovo', 'lenovo-2']), 'lenovo-3');
      expect(makeAlias('***', []), 'peer');
    });
  });

  group('setup scripts', () {
    test('windows script validates and quotes', () {
      final s = buildWindowsScript([
        InstallSshServer(),
        OpenFirewall(22),
        AuthorizeAdminKey(id1, PublicKey.parse(ed)),
        RevokeAdminKey(id2),
      ], r"C:\Users\o'brien\AppData\Local\Temp\r.json");
      expect(
        s,
        contains("'C:\\Users\\o''brien\\AppData\\Local\\Temp\\r.json'"),
      );
      expect(s, contains('crossshell:$id1'));
      expect(
        () => buildWindowsScript([RevokeAdminKey('x; rm')], 'r'),
        throwsA(isA<SetupError>()),
      );
      expect(
        () => buildWindowsScript([OpenFirewall(0)], 'r'),
        throwsA(isA<SetupError>()),
      );
    });

    test('encoded command is base64 utf-16le', () {
      expect(encodePowerShell('ab'), 'YQBiAA==');
    });

    test('shell quoting', () {
      expect(shQuote("it's"), "'it'\\''s'");
    });
  });

  test('host info parsing is strict', () {
    expect(
      HostInfo.tryParse(
        '{"v":1,"port":47821,"token":"${'ab' * 32}","pid":1,"ver":"0.1.0"}',
      )?.port,
      47821,
    );
    expect(HostInfo.tryParse(''), isNull);
    expect(HostInfo.tryParse('{"port":0,"token":"${'ab' * 32}"}'), isNull);
    expect(HostInfo.tryParse('{"port":1,"token":"zz"}'), isNull);
  });
}

Future<bool> _hasSshKeygen() async {
  try {
    await Process.run('ssh-keygen', ['-?']);
    return true;
  } catch (_) {
    return false;
  }
}
