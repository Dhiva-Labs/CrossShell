// Connecting to a paired peer: in-app (dartssh2) and via the system ssh.

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../pairing/pairing_crypto.dart' show constantTimeEquals;
import '../peers/peer.dart';
import '../platform/local_system.dart';
import 'public_key.dart';
import 'ssh_files.dart';

class ConnectError implements Exception {
  ConnectError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Open an authenticated dartssh2 client to [peer], accepting only the host
/// keys pinned at pairing.
Future<SSHClient> connectToPeer(Peer peer, SshFiles files) async {
  if (!peer.canConnect) {
    throw ConnectError('${peer.name} had no SSH server when you paired. Enable it there, then pair again.');
  }
  final pinned = <String>{};
  for (final k in peer.hostKeys) {
    pinned.add(await PublicKey.parse(k).sha256Fingerprint());
  }
  final identities = SSHKeyPair.fromPem(await files.readPrivateKeyPem());

  final SSHSocket socket;
  try {
    socket = await SSHSocket.connect(peer.lastIp, peer.sshPort, timeout: const Duration(seconds: 8));
  } on SocketException catch (e) {
    throw ConnectError(
      'Cannot reach ${peer.name} at ${peer.lastIp}:${peer.sshPort} '
      '(${e.osError?.message ?? e.message}). Is it on and on this network?',
    );
  } on TimeoutException {
    throw ConnectError('Timed out reaching ${peer.name} at ${peer.lastIp}:${peer.sshPort}.');
  }

  var hostKeyMismatch = false;
  final client = SSHClient(
    socket,
    username: peer.sshUser,
    identities: identities,
    onVerifyHostKey: (type, fingerprint) {
      final fp = String.fromCharCodes(fingerprint);
      final ok = pinned.any((p) => constantTimeEquals(p.codeUnits, fp.codeUnits));
      hostKeyMismatch = !ok;
      return ok;
    },
  );
  try {
    await client.authenticated;
  } catch (e) {
    client.close();
    if (hostKeyMismatch) {
      throw ConnectError(
        'The machine at ${peer.lastIp} is not ${peer.name}: its SSH host key does not match the '
        'one pinned at pairing. If ${peer.name} was reinstalled, unpair and pair again.',
      );
    }
    if (e is SSHAuthFailError) {
      throw ConnectError(
        '${peer.name} refused this machine\'s key. Re-pair, or check that '
        '${peer.isWindows ? r'C:\ProgramData\ssh\administrators_authorized_keys' : '~/.ssh/authorized_keys'} '
        'on ${peer.name} still contains the CrossShell key.',
      );
    }
    throw ConnectError('SSH to ${peer.name} failed: $e');
  }
  return client;
}

/// Arguments for the system ssh using only CrossShell's config (`-F`), so
/// the user's own ~/.ssh/config can't change what we connect to.
List<String> systemSshArgs(SshLayout layout, Peer peer, {List<String> extra = const []}) => [
      '-F',
      layout.config,
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=8',
      ...extra,
      peer.alias,
    ];

/// Run [command] on [peer] via the system ssh; returns stdout.
Future<String> runOnPeer(
  SshLayout layout,
  Peer peer,
  String command, {
  Duration timeout = const Duration(seconds: 30),
}) =>
    runTool(LocalSystem.sshTool('ssh'), [...systemSshArgs(layout, peer), command], timeout: timeout);
