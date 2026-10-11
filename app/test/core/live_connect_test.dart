// Live check of the in-app SSH path against a real paired peer.
// Runs only with CS_LIVE_PEERS=<path to peers.json> (e.g. after pairing
// with the profile build): `CS_LIVE_PEERS=… flutter test test/core/live_connect_test.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:cross_shell/src/core/peers/peer.dart';
import 'package:cross_shell/src/core/ssh/ssh_connect.dart';
import 'package:cross_shell/src/core/ssh/ssh_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final path = Platform.environment['CS_LIVE_PEERS'];
  final skip = path == null ? 'set CS_LIVE_PEERS to run' : null;

  List<Peer> load() => [
    for (final m in jsonDecode(File(path!).readAsStringSync()) as List)
      Peer.fromJson(m as Map<String, dynamic>),
  ];

  test(
    'connects with pinned host keys and runs a command',
    () async {
      final files = SshFiles(SshLayout.forUser());
      for (final peer in load().where((p) => p.canConnect)) {
        final client = await connectToPeer(peer, files);
        final out = utf8
            .decode(await client.run(peer.isWindows ? 'whoami' : 'id -un'))
            .trim();
        client.close();
        expect(out.toLowerCase(), contains(peer.sshUser.toLowerCase()));
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'refuses a host whose key differs from the pinned one',
    () async {
      final files = SshFiles(SshLayout.forUser());
      final peer = load().firstWhere((p) => p.canConnect);
      // Pin someone else's key: the real host must now be rejected.
      final impostor = Peer.fromJson({
        ...peer.toJson(),
        'hostKeys': [
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILGgJ19ugqnNH/jujnX9q/Xw1FzEAFi0hmISmyY/L9UF',
        ],
      });
      await expectLater(
        connectToPeer(impostor, files),
        throwsA(
          isA<ConnectError>().having(
            (e) => e.message,
            'message',
            contains('host key does not match'),
          ),
        ),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
