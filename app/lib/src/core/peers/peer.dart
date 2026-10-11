// A paired machine and the store that remembers them.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../platform/local_system.dart';

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.os,
    required this.alias,
    required this.sshUser,
    required this.sshPort,
    required this.hostKeys,
    required this.clientKey,
    required this.lastIp,
    required this.pairedAt,
  });

  final String id;
  final String name;

  /// `linux` / `windows` / `macos` / `other`.
  final String os;

  /// `Host` alias in ~/.ssh/crossshell/config — `ssh <alias>` works.
  final String alias;
  final String sshUser;
  final int sshPort;

  /// Pinned sshd host keys; empty = the peer runs no SSH server (one-way).
  final List<String> hostKeys;

  /// The peer's client key we authorized.
  final String clientKey;
  final String lastIp;
  final DateTime pairedAt;

  bool get canConnect => hostKeys.isNotEmpty;
  bool get isWindows => os == 'windows';

  Peer copyWith({String? lastIp, String? name}) => Peer(
        id: id,
        name: name ?? this.name,
        os: os,
        alias: alias,
        sshUser: sshUser,
        sshPort: sshPort,
        hostKeys: hostKeys,
        clientKey: clientKey,
        lastIp: lastIp ?? this.lastIp,
        pairedAt: pairedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'os': os,
        'alias': alias,
        'sshUser': sshUser,
        'sshPort': sshPort,
        'hostKeys': hostKeys,
        'clientKey': clientKey,
        'lastIp': lastIp,
        'pairedAt': pairedAt.toUtc().toIso8601String(),
      };

  factory Peer.fromJson(Map<String, dynamic> m) => Peer(
        id: m['id'] as String,
        name: m['name'] as String,
        os: m['os'] as String? ?? 'other',
        alias: m['alias'] as String,
        sshUser: m['sshUser'] as String,
        sshPort: m['sshPort'] as int? ?? 22,
        hostKeys: (m['hostKeys'] as List? ?? const []).cast<String>(),
        clientKey: m['clientKey'] as String? ?? '',
        lastIp: m['lastIp'] as String? ?? '',
        pairedAt: DateTime.tryParse(m['pairedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Turn a machine name into a short, ssh-friendly alias unique among [taken].
String makeAlias(String name, Iterable<String> taken) {
  var base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) base = 'peer';
  if (base.length > 32) base = base.substring(0, 32);
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  for (var i = 2;; i++) {
    final c = '$base-$i';
    if (!used.contains(c)) return c;
  }
}

class PeerStore {
  PeerStore(this.file);
  final File file;

  Future<List<Peer>> load() async {
    if (!await file.exists()) return [];
    try {
      final list = jsonDecode(await file.readAsString()) as List;
      return [for (final m in list) Peer.fromJson(m as Map<String, dynamic>)];
    } catch (e) {
      // Keep the unreadable file for inspection rather than overwrite it.
      await file.copy('${file.path}.corrupt');
      return [];
    }
  }

  Future<void> save(List<Peer> peers) =>
      writePrivateFile(file.path, const JsonEncoder.withIndent('  ').convert([for (final p in peers) p.toJson()]));
}

/// This machine's identity: a random id kept forever plus the hostname.
class DeviceIdentity {
  DeviceIdentity(this.id, this.name);
  final String id;
  final String name;

  static Future<DeviceIdentity> load(String appDir) async {
    final f = File(p.join(appDir, 'device.json'));
    if (await f.exists()) {
      try {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final id = m['id'] as String;
        if (RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(id)) return DeviceIdentity(id, LocalSystem.hostname);
      } catch (_) {}
    }
    final id = _uuidV4();
    await writePrivateFile(f.path, jsonEncode({'id': id}));
    return DeviceIdentity(id, LocalSystem.hostname);
  }
}

String _uuidV4() {
  final r = List<int>.generate(16, (_) => _rng.nextInt(256));
  r[6] = (r[6] & 0x0f) | 0x40;
  r[8] = (r[8] & 0x3f) | 0x80;
  String h(int i) => r[i].toRadixString(16).padLeft(2, '0');
  final s = List.generate(16, h).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

final _rng = Random.secure();
