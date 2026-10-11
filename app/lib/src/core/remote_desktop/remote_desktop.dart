// Remote desktop orchestration (PLAN.md "Process model"):
// read the peer's host.json over SSH (starting its agent if needed), open a
// system-ssh local forward to the agent's loopback port, and run the
// crossshell-view window against it with the token on stdin.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../peers/peer.dart';
import '../platform/local_system.dart';
import '../ssh/ssh_connect.dart';
import '../ssh/ssh_files.dart';
import 'remote_commands.dart';

class RemoteDesktopError implements Exception {
  RemoteDesktopError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Locates the Rust engine binaries.
class EnginePaths {
  EnginePaths._();

  static String get _ext => Platform.isWindows ? '.exe' : '';

  static String? find(String name) {
    final candidates = <String>[
      // Installed: next to the app executable.
      p.join(File(Platform.resolvedExecutable).parent.path, '$name$_ext'),
      // Development override.
      if (Platform.environment['CROSSSHELL_ENGINE_DIR'] case final d?)
        p.join(d, '$name$_ext'),
    ];
    // Development checkout: walk up to the repo and use the cargo output.
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 10; i++) {
      candidates.add(
        p.join(dir.path, 'engine', 'target', 'release', '$name$_ext'),
      );
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static String? get host => find('crossshell-host');
  static String? get view => find('crossshell-view');
}

class HostInfo {
  HostInfo(this.port, this.token);
  final int port;
  final String token;

  static HostInfo? tryParse(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    try {
      final m = jsonDecode(t) as Map<String, dynamic>;
      final port = m['port'];
      final token = m['token'];
      if (port is int &&
          port > 0 &&
          port < 65536 &&
          token is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
        return HostInfo(port, token);
      }
    } catch (_) {}
    return null;
  }
}

/// A viewer event (JSON line from crossshell-view's stdout).
class ViewerEvent {
  ViewerEvent(this.kind, this.data);
  final String
  kind; // connecting, waiting, connected, notice, closed, exited, status
  final Map<String, dynamic> data;
  String? get message =>
      (data['msg'] ?? data['text'] ?? data['reason']) as String?;
}

class RemoteDesktopSession {
  RemoteDesktopSession._(this.peer, this._tunnel, this._viewer, this._events);

  final Peer peer;
  final Process _tunnel;
  final Process _viewer;
  final StreamController<ViewerEvent> _events;

  Stream<ViewerEvent> get events => _events.stream;

  /// Ends when the viewer window closes.
  Future<int> get done => _viewer.exitCode;

  void close() {
    _viewer.kill();
    _tunnel.kill();
  }

  static Future<RemoteDesktopSession> start(
    Peer peer,
    SshLayout layout, {
    bool viewOnly = false,
    void Function(String status)? onStatus,
  }) async {
    final viewExe = EnginePaths.view;
    if (viewExe == null) {
      throw RemoteDesktopError(
        'crossshell-view is missing from this installation',
      );
    }

    onStatus?.call('Checking ${peer.name}…');
    var info = await _fetchInfo(layout, peer);
    if (info == null) {
      onStatus?.call('Starting screen sharing on ${peer.name}…');
      try {
        await runOnPeer(
          layout,
          peer,
          startAgentCommand(windows: peer.isWindows),
        );
      } on ToolError catch (e) {
        throw RemoteDesktopError(
          'Could not start screen sharing on ${peer.name}: ${_clean(e.message)}',
        );
      }
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (info == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        info = await _fetchInfo(layout, peer);
      }
      if (info == null) {
        if (peer.isWindows) {
          final code = int.tryParse(
            (await runOnPeer(
              layout,
              peer,
              agentLastResultCommand(),
            ).catchError((Object _) => '')).trim(),
          );
          final why = code == null ? null : explainTaskResult(code);
          if (why != null) {
            throw RemoteDesktopError(
              'Screen sharing could not start on ${peer.name}: $why',
            );
          }
        }
        throw RemoteDesktopError(
          'Screen sharing did not come up on ${peer.name}. Someone has to be signed in to its desktop '
          '(a locked screen is fine on Windows).',
        );
      }
    }

    onStatus?.call('Opening a secure tunnel…');
    final localPort = await _freePort();
    final tunnel = await Process.start(
      LocalSystem.sshTool('ssh'),
      systemSshArgs(
        layout,
        peer,
        extra: [
          '-N',
          '-o',
          'ExitOnForwardFailure=yes',
          '-o',
          'ServerAliveInterval=5',
          '-L',
          '127.0.0.1:$localPort:127.0.0.1:${info.port}',
        ],
      ),
    );
    final tunnelErr = StringBuffer();
    tunnel.stderr.transform(utf8.decoder).listen(tunnelErr.write);
    tunnel.stdout.drain<void>();
    if (!await _waitForPort(localPort, tunnel)) {
      tunnel.kill();
      throw RemoteDesktopError(
        'SSH tunnel to ${peer.name} failed: ${_clean(tunnelErr.toString())}',
      );
    }

    final viewer = await Process.start(viewExe, [
      '--port',
      '$localPort',
      '--title',
      peer.name,
      if (viewOnly) '--view-only',
    ]);
    viewer.stdin.writeln(info.token);
    await viewer.stdin.flush();
    await viewer.stdin.close();

    final events = StreamController<ViewerEvent>.broadcast();
    viewer.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final m = jsonDecode(line) as Map<String, dynamic>;
            events.add(ViewerEvent(m['ev'] as String? ?? 'unknown', m));
          } catch (_) {}
        });
    viewer.stderr.drain<void>();
    unawaited(
      viewer.exitCode.then((code) {
        tunnel.kill();
        events.add(ViewerEvent('exited', {'code': code}));
        events.close();
      }),
    );
    unawaited(tunnel.exitCode.then((_) => viewer.kill()));
    return RemoteDesktopSession._(peer, tunnel, viewer, events);
  }

  static Future<HostInfo?> _fetchInfo(SshLayout layout, Peer peer) async {
    try {
      return HostInfo.tryParse(
        await runOnPeer(
          layout,
          peer,
          readHostInfoCommand(windows: peer.isWindows),
        ),
      );
    } on ToolError catch (e) {
      throw RemoteDesktopError(
        'Cannot reach ${peer.name} over SSH: ${_clean(e.message)}',
      );
    }
  }
}

String _clean(String s) => s
    .split('\n')
    .where(
      (l) =>
          !l.contains('post-quantum') &&
          !l.contains('store now, decrypt later') &&
          !l.contains('openssh.com/pq'),
    )
    .join('\n')
    .trim();

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<bool> _waitForPort(int port, Process tunnel) async {
  var exited = false;
  unawaited(tunnel.exitCode.then((_) => exited = true));
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline) && !exited) {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      s.destroy();
      return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }
  return false;
}
