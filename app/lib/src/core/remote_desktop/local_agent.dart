// This machine as a screen-share host: tell peers where our agent lives,
// keep it running while sharing is allowed, and report who is watching.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/local_system.dart';
import 'remote_desktop.dart';

class WatchStatus {
  WatchStatus(this.viewer, this.since, this.viewOnly);
  final String viewer;
  final DateTime since;
  final bool viewOnly;
}

class LocalAgent {
  LocalAgent();

  Timer? _poll;
  final _status = StreamController<WatchStatus?>.broadcast();
  WatchStatus? current;

  /// Who is viewing this screen right now (null = nobody).
  Stream<WatchStatus?> get status => _status.stream;

  String? get agentPath => EnginePaths.host;

  /// Record the agent path where peers look for it over SSH
  /// (`agent-path` in the state dir) — a peer never takes a path from the
  /// network, only from this file, read through an authenticated SSH session.
  Future<void> publishPath() async {
    final exe = agentPath;
    if (exe == null) return;
    await Directory(LocalSystem.stateDir).create(recursive: true);
    await File(p.join(LocalSystem.stateDir, 'agent-path')).writeAsString(exe);
  }

  /// Start the agent detached so it outlives the app window. It is
  /// single-instance, so starting it twice is harmless.
  Future<void> ensureRunning() async {
    final exe = agentPath;
    if (exe == null) return;
    await Process.start(exe, const [], mode: ProcessStartMode.detached);
  }

  void startWatching() {
    _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  Future<void> _check() async {
    final f = File(p.join(LocalSystem.agentRuntimeDir, 'status.json'));
    WatchStatus? s;
    try {
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        s = WatchStatus(
          m['viewer'] as String? ?? 'someone',
          DateTime.fromMillisecondsSinceEpoch(((m['since'] as int?) ?? 0) * 1000),
          m['viewOnly'] == true,
        );
      }
    } catch (_) {}
    if ((s == null) != (current == null) || s?.viewer != current?.viewer) {
      current = s;
      _status.add(s);
    }
  }

  /// Stop sharing: kill the agent (ends any session immediately).
  Future<void> stop() async {
    final f = File(p.join(LocalSystem.agentRuntimeDir, 'host.json'));
    try {
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final pid = m['pid'];
      if (pid is int && await _isAgent(pid)) Process.killPid(pid);
    } catch (_) {}
  }

  /// host.json can outlive its process; never kill a recycled pid.
  Future<bool> _isAgent(int pid) async {
    if (Platform.isLinux) {
      try {
        return p.basename(await Link('/proc/$pid/exe').target()).startsWith('crossshell-host');
      } catch (_) {
        return false;
      }
    }
    if (Platform.isWindows) {
      final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
      return (r.stdout as String).toLowerCase().contains('crossshell-host.exe');
    }
    return false;
  }

  void dispose() {
    _poll?.cancel();
    _status.close();
  }
}
