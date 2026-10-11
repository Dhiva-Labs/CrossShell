// Facts about SSH servers: is one listening, what host keys does it serve.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../platform/local_system.dart';
import 'public_key.dart';

/// Connect to [host]:[port] and read the SSH banner. Returns the banner
/// (`SSH-2.0-OpenSSH_9.5`) or null if nothing SSH-like answered.
Future<String?> probeSshBanner(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  Socket? s;
  try {
    s = await Socket.connect(host, port, timeout: timeout);
    final line = await s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.startsWith('SSH-'), orElse: () => '')
        .timeout(timeout);
    return line.isEmpty ? null : line.trim();
  } catch (_) {
    return null;
  } finally {
    s?.destroy();
  }
}

/// This machine's sshd host keys, as served (ssh-keyscan works unelevated;
/// on Windows the .pub files are admin-only readable).
Future<List<PublicKey>> localHostKeys(int port) async {
  final out = await runTool(
    LocalSystem.sshTool('ssh-keyscan'),
    ['-T', '5', '-p', '$port', '-t', 'ed25519,ecdsa,rsa', '127.0.0.1'],
    timeout: const Duration(seconds: 15),
  ).catchError((Object e) => e is ToolError ? (e.stdout ?? '') : throw e);
  return parseKeyscan(out);
}

/// Parse `ssh-keyscan` output lines (`host type b64`), skipping comments.
List<PublicKey> parseKeyscan(String out) {
  final keys = <PublicKey>[];
  for (final l in const LineSplitter().convert(out)) {
    if (l.startsWith('#')) continue;
    final parts = l.trim().split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    try {
      final k = PublicKey.parse('${parts[1]} ${parts[2]}');
      if (!keys.contains(k)) keys.add(k);
    } on FormatException {
      // ignore unknown key types
    }
  }
  // Strongest first: that's what clients will negotiate anyway.
  const order = ['ssh-ed25519', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521', 'ssh-rsa'];
  keys.sort((a, b) => order.indexOf(a.type).compareTo(order.indexOf(b.type)));
  return keys;
}
