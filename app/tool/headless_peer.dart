// A headless CrossShell peer for testing: answers one pairing request,
// confirms the code automatically, trusts the other side exactly like the
// app does (authorized_keys, pinned host keys, ssh config) and exits.
//
//   dart compile exe tool/headless_peer.dart -o build/headless_peer
//   headless_peer [--port 47830] [--name NAME] [--ssh-port 22]
//
// Prints one JSON line per event. Used to test packaged builds (e.g. the
// snap) end to end without a second desktop.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cross_shell/src/core/pairing/pairing_messages.dart';
import 'package:cross_shell/src/core/pairing/pairing_session.dart';
import 'package:cross_shell/src/core/peers/peer.dart';
import 'package:cross_shell/src/core/platform/local_system.dart';
import 'package:cross_shell/src/core/ssh/public_key.dart';
import 'package:cross_shell/src/core/ssh/ssh_files.dart';
import 'package:cross_shell/src/core/ssh/sshd.dart';

void emit(Map<String, Object?> m) => stdout.writeln(jsonEncode(m));

Future<void> main(List<String> args) async {
  var port = 47830;
  var sshPort = 22;
  var name = '${LocalSystem.hostname}-headless';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
        port = int.parse(args[++i]);
      case '--ssh-port':
        sshPort = int.parse(args[++i]);
      case '--name':
        name = args[++i];
    }
  }
  final r = Random.secure();
  String hex(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  final me = PeerIdentity(
    id: '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}',
    name: name,
    os: 'linux',
  );
  final files = SshFiles(SshLayout.forUser());
  final clientKey = await files.ensureClientKey();
  final hostKeys = await probeSshBanner('127.0.0.1', sshPort) == null
      ? <PublicKey>[]
      : await localHostKeys(sshPort);
  final payload = PairingPayload(
    sshUser: LocalSystem.userName,
    sshPort: sshPort,
    hostKeys: [for (final k in hostKeys) k.line],
    clientKey: clientKey.line,
    name: name,
    os: 'linux',
  );

  final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  emit({'ev': 'listening', 'port': port, 'id': me.id});
  final socket = await server.first;
  try {
    final outcome = await respondToPairing(
      socket: socket,
      me: me,
      myPayload: payload,
      confirm: (p) async {
        emit({'ev': 'code', 'code': p.code, 'peer': p.peer.name});
        return true;
      },
      apply: (peer, pl, address) async {
        await files.authorizeInUserFile(peer.id, PublicKey.parse(pl.clientKey));
        if (pl.hostKeys.isNotEmpty) {
          await files.pinHostKeys(peer.id, [
            for (final k in pl.hostKeys) PublicKey.parse(k),
          ]);
          await files.writePeerConfig(
            PeerSshEntry(
              peerId: peer.id,
              alias: makeAlias(pl.name, const []),
              host: address,
              port: pl.sshPort,
              user: pl.sshUser,
            ),
          );
        }
      },
    );
    emit({
      'ev': 'paired',
      'peer': outcome.peer.name,
      'alias': makeAlias(outcome.payload.name, const []),
    });
  } catch (e) {
    emit({'ev': 'failed', 'error': '$e'});
    exitCode = 1;
  } finally {
    await server.close();
  }
}
