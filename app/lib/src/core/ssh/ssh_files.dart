// The SSH files CrossShell manages, shared with the system `ssh` client:
//
//   ~/.ssh/config                  gets one `Include crossshell/config` line at the top
//   ~/.ssh/crossshell/config       one Host block per paired peer (ours entirely)
//   ~/.ssh/crossshell/known_hosts  pinned host keys, `crossshell-<peer-id> <type> <b64>`
//   ~/.ssh/crossshell/id_ed25519   this machine's client key
//   ~/.ssh/authorized_keys         peer client keys, comment `crossshell:<peer-id>`
//
// The text transforms are pure functions so they can be tested without
// touching the real files.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/local_system.dart';
import 'public_key.dart';

const includeLine = 'Include crossshell/config';
const _includeMarker = '# Added by CrossShell: paired machines (ssh <name>)';

class SshLayout {
  SshLayout(this.sshDir);

  factory SshLayout.forUser() => SshLayout(LocalSystem.sshDir);

  final String sshDir;

  String get dir => p.join(sshDir, 'crossshell');
  String get userConfig => p.join(sshDir, 'config');
  String get config => p.join(dir, 'config');
  String get knownHosts => p.join(dir, 'known_hosts');
  String get privateKey => p.join(dir, 'id_ed25519');
  String get publicKey => '$privateKey.pub';
  String get authorizedKeys => p.join(sshDir, 'authorized_keys');

  /// Paths as written into ssh config (`~`-relative works on both OSes).
  static const configIdentityFile = '~/.ssh/crossshell/id_ed25519';
  static const configKnownHosts = '~/.ssh/crossshell/known_hosts';
}

String hostKeyAlias(String peerId) => 'crossshell-$peerId';
String authorizedKeyMarker(String peerId) => 'crossshell:$peerId';

/// What the config needs to know about a peer.
class PeerSshEntry {
  PeerSshEntry({
    required this.peerId,
    required this.alias,
    required this.host,
    required this.port,
    required this.user,
  });
  final String peerId;
  final String alias;
  final String host;
  final int port;
  final String user;
}

String _blockStart(String id) => '# >>> crossshell peer $id >>>';
String _blockEnd(String id) => '# <<< crossshell peer $id <<<';

String renderPeerBlock(PeerSshEntry e) {
  final user = e.user.contains(' ') ? '"${e.user}"' : e.user;
  return [
    _blockStart(e.peerId),
    'Host ${e.alias}',
    '  HostName ${e.host}',
    '  Port ${e.port}',
    '  User $user',
    '  IdentityFile ${SshLayout.configIdentityFile}',
    '  IdentitiesOnly yes',
    '  HostKeyAlias ${hostKeyAlias(e.peerId)}',
    '  UserKnownHostsFile ${SshLayout.configKnownHosts}',
    '  StrictHostKeyChecking yes',
    '  ServerAliveInterval 15',
    _blockEnd(e.peerId),
  ].join('\n');
}

/// Insert or replace the block for [e] in our config file.
String upsertPeerBlock(String config, PeerSshEntry e) {
  final without = removePeerBlock(config, e.peerId).trimRight();
  final block = renderPeerBlock(e);
  return without.isEmpty ? '$block\n' : '$without\n\n$block\n';
}

String removePeerBlock(String config, String peerId) {
  final lines = config.split('\n');
  final out = <String>[];
  var skipping = false;
  for (final l in lines) {
    if (l.trim() == _blockStart(peerId)) {
      skipping = true;
      continue;
    }
    if (skipping) {
      if (l.trim() == _blockEnd(peerId)) skipping = false;
      continue;
    }
    out.add(l);
  }
  // Collapse the blank lines a removed block leaves behind.
  return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

/// Ensure the user's ~/.ssh/config includes ours, at the very top (Include
/// inside a Host block would only apply to that host).
String ensureInclude(String userConfig) {
  final has = userConfig
      .split('\n')
      .any((l) => l.trim().toLowerCase() == includeLine.toLowerCase());
  if (has) return userConfig;
  final head = '$_includeMarker\n$includeLine\n';
  return userConfig.isEmpty ? head : '$head\n$userConfig';
}

String removeInclude(String userConfig) => userConfig
    .split('\n')
    .where((l) => l.trim() != includeLine && l.trim() != _includeMarker)
    .join('\n')
    .replaceFirst(RegExp(r'^\n+'), '');

/// Replace all pinned keys for [peerId].
String upsertKnownHosts(String contents, String peerId, List<PublicKey> keys) {
  final alias = hostKeyAlias(peerId);
  final kept = contents
      .split('\n')
      .where((l) => l.trim().isNotEmpty && l.split(' ').first != alias)
      .toList();
  kept.addAll(keys.map((k) => '$alias ${k.line}'));
  return kept.isEmpty ? '' : '${kept.join('\n')}\n';
}

/// Pinned keys for [peerId] (malformed lines are skipped).
List<PublicKey> knownHostsFor(String contents, String peerId) {
  final alias = hostKeyAlias(peerId);
  final out = <PublicKey>[];
  for (final l in contents.split('\n')) {
    final parts = l.trim().split(RegExp(r'\s+'));
    if (parts.length >= 3 && parts[0] == alias) {
      try {
        out.add(PublicKey.parse('${parts[1]} ${parts[2]}'));
      } on FormatException {
        // ignore
      }
    }
  }
  return out;
}

/// Add (or replace) the authorized key for [peerId].
String upsertAuthorizedKey(String contents, String peerId, PublicKey key) {
  final marker = authorizedKeyMarker(peerId);
  final lines = contents
      .split('\n')
      .where((l) => l.isNotEmpty && !_hasMarker(l, marker))
      .toList();
  lines.add('${key.line} $marker');
  return '${lines.join('\n')}\n';
}

String removeAuthorizedKey(String contents, String peerId) {
  final marker = authorizedKeyMarker(peerId);
  final lines = contents
      .split('\n')
      .where((l) => l.isNotEmpty && !_hasMarker(l, marker))
      .toList();
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

bool _hasMarker(String line, String marker) =>
    line.trimRight().endsWith(' $marker');

// ------------------------------------------------------------------ file IO

class SshFiles {
  SshFiles(this.layout);
  final SshLayout layout;

  Future<String> _read(String path) async {
    final f = File(path);
    return await f.exists() ? await f.readAsString() : '';
  }

  /// Create the client key if needed; returns its public key.
  Future<PublicKey> ensureClientKey() async {
    await ensurePrivateDir(layout.sshDir);
    await ensurePrivateDir(layout.dir);
    if (!await File(layout.privateKey).exists()) {
      await runTool(LocalSystem.sshTool('ssh-keygen'), [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-C',
        'crossshell@${LocalSystem.hostname}',
        '-f',
        layout.privateKey,
      ]);
    }
    return PublicKey.parse(await File(layout.publicKey).readAsString());
  }

  Future<String> readPrivateKeyPem() => File(layout.privateKey).readAsString();

  Future<void> writePeerConfig(PeerSshEntry e) async {
    await ensurePrivateDir(layout.dir);
    await writePrivateFile(
      layout.config,
      upsertPeerBlock(await _read(layout.config), e),
    );
    final user = await _read(layout.userConfig);
    final withInclude = ensureInclude(user);
    if (withInclude != user) {
      await writePrivateFile(layout.userConfig, withInclude);
    }
  }

  Future<void> removePeerConfig(String peerId) async {
    final c = await _read(layout.config);
    if (c.isNotEmpty) {
      await writePrivateFile(layout.config, removePeerBlock(c, peerId));
    }
  }

  Future<void> pinHostKeys(String peerId, List<PublicKey> keys) async {
    await ensurePrivateDir(layout.dir);
    await writePrivateFile(
      layout.knownHosts,
      upsertKnownHosts(await _read(layout.knownHosts), peerId, keys),
    );
  }

  Future<List<PublicKey>> pinnedHostKeys(String peerId) async =>
      knownHostsFor(await _read(layout.knownHosts), peerId);

  /// Per-user authorized_keys (Linux, and non-admin Windows users).
  Future<void> authorizeInUserFile(String peerId, PublicKey key) async {
    await ensurePrivateDir(layout.sshDir);
    await writePrivateFile(
      layout.authorizedKeys,
      upsertAuthorizedKey(await _read(layout.authorizedKeys), peerId, key),
    );
  }

  Future<void> revokeInUserFile(String peerId) async {
    final c = await _read(layout.authorizedKeys);
    if (c.isNotEmpty) {
      await writePrivateFile(
        layout.authorizedKeys,
        removeAuthorizedKey(c, peerId),
      );
    }
  }
}
