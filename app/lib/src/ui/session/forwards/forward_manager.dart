import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../session_controller.dart';
import 'forward_models.dart';
import 'forward_store.dart';

enum ForwardState { stopped, starting, running, error }

/// Live state of one rule. Mutable; the manager notifies after changes.
class ForwardRuntime {
  ForwardRuntime(this.rule);

  ForwardRule rule;
  ForwardState state = ForwardState.stopped;

  /// Why the forward failed to start or what went wrong on the last
  /// connection.
  String? message;
  int liveConnections = 0;
  int totalConnections = 0;
  int bytesUp = 0;
  int bytesDown = 0;

  /// The port actually bound (differs from the rule only if it asked for 0).
  int? boundPort;

  /// Restart this forward when the connection comes back.
  bool resumeOnReconnect = false;

  ServerSocket? _server;
  SSHRemoteForward? _remote;
  SSHClient? _remoteClient;
  StreamSubscription<dynamic>? _accepts;
  final Set<_Pipe> _pipes = {};
  var _epoch = 0;

  bool get isActive =>
      state == ForwardState.running || state == ForwardState.starting;
}

class _Pipe {
  _Pipe(this.socket, this.channel);
  final Socket socket;
  final SSHSocket channel;

  void destroy() {
    try {
      socket.destroy();
    } catch (_) {}
    try {
      channel.destroy();
    } catch (_) {}
  }
}

/// Runs a peer's forwards over the session's shared SSH connection and keeps
/// the saved presets in sync with disk.
class ForwardManager extends ChangeNotifier {
  ForwardManager({
    required this.peerId,
    required this.session,
    required this.store,
    this.connectTimeout = const Duration(seconds: 8),
  }) {
    session.addListener(_onSessionChanged);
    _lastGeneration = session.generation;
  }

  final String peerId;
  final SessionController session;
  final ForwardStore store;
  final Duration connectTimeout;

  final List<ForwardRuntime> _items = [];
  List<ForwardRuntime> get items => List.unmodifiable(_items);

  /// Problems reading or writing the preset file, for the banner.
  String? storeError;

  var _loaded = false;
  bool get loaded => _loaded;
  var _disposed = false;
  late int _lastGeneration;
  Timer? _tick;

  Future<void> load() async {
    final result = await store.load(peerId);
    if (_disposed) return;
    _items
      ..clear()
      ..addAll(result.rules.map(ForwardRuntime.new));
    storeError = result.error;
    _loaded = true;
    _notify();
  }

  ForwardRuntime? byId(String id) {
    for (final rt in _items) {
      if (rt.rule.id == id) return rt;
    }
    return null;
  }

  Future<void> _persist() async {
    try {
      await store.save(peerId, [for (final rt in _items) rt.rule]);
      storeError = null;
    } catch (e) {
      storeError = 'Could not save forwards: $e';
    }
    _notify();
  }

  /// Adds a rule; with [start] also starts it. A rule with the same route as
  /// an existing one is not added twice.
  Future<ForwardRuntime> add(ForwardRule rule, {bool start = false}) async {
    final existing = _items.where((rt) => rt.rule.sameRoute(rule));
    final ForwardRuntime rt;
    if (existing.isNotEmpty) {
      rt = existing.first;
    } else {
      rt = ForwardRuntime(rule);
      _items.add(rt);
      _notify();
      await _persist();
    }
    if (start && !rt.isActive) await this.start(rt.rule.id);
    return rt;
  }

  /// Replaces the rule with [updated] (same id). A running forward is
  /// restarted so the new route takes effect.
  Future<void> update(ForwardRule updated) async {
    final rt = byId(updated.id);
    if (rt == null) return;
    final wasActive = rt.isActive;
    if (wasActive) await stop(rt.rule.id);
    rt.rule = updated;
    rt.message = null;
    _notify();
    await _persist();
    if (wasActive) await start(updated.id);
  }

  Future<void> remove(String id) async {
    final rt = byId(id);
    if (rt == null) return;
    await stop(id);
    _items.remove(rt);
    _notify();
    await _persist();
  }

  Future<void> toggle(String id) async {
    final rt = byId(id);
    if (rt == null) return;
    if (rt.isActive) {
      await stop(id);
    } else {
      await start(id);
    }
  }

  Future<void> start(String id) async {
    final rt = byId(id);
    if (rt == null || rt.isActive) return;
    final problem = rt.rule.validate();
    if (problem != null) {
      rt
        ..state = ForwardState.error
        ..message = problem;
      _notify();
      return;
    }
    if (!session.isConnected) {
      rt
        ..state = ForwardState.error
        ..message = 'Not connected to the peer.'
        ..resumeOnReconnect = true;
      _notify();
      return;
    }
    final epoch = ++rt._epoch;
    rt
      ..state = ForwardState.starting
      ..message = null
      ..resumeOnReconnect = false;
    _notify();
    try {
      final client = session.client;
      switch (rt.rule.kind) {
        case ForwardKind.local:
          await _startLocal(rt, client, epoch);
        case ForwardKind.remote:
          await _startRemote(rt, client, epoch);
      }
      if (rt._epoch != epoch) return;
      rt.state = ForwardState.running;
      _ensureTick();
    } catch (e) {
      if (rt._epoch != epoch) return;
      await _teardown(rt);
      rt
        ..state = ForwardState.error
        ..message = e is _ForwardFailure ? e.message : e.toString();
    }
    _notify();
  }

  Future<void> _startLocal(
    ForwardRuntime rt,
    SSHClient client,
    int epoch,
  ) async {
    final rule = rt.rule;
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(rule.bindHost, rule.bindPort);
    } on SocketException catch (e) {
      throw _ForwardFailure(describeBindError(e, rule.bindHost, rule.bindPort));
    }
    if (rt._epoch != epoch) {
      await server.close();
      return;
    }
    rt._server = server;
    rt.boundPort = server.port;
    rt._accepts = server.listen(
      (socket) => unawaited(_acceptLocal(rt, client, socket, epoch)),
      onError: (Object e) => _noteFailure(rt, epoch, 'Listener: $e'),
    );
  }

  Future<void> _acceptLocal(
    ForwardRuntime rt,
    SSHClient client,
    Socket socket,
    int epoch,
  ) async {
    final rule = rt.rule;
    final SSHForwardChannel channel;
    try {
      // The originator address is informational (sshd logs it).
      channel = await client.forwardLocal(
        rule.targetHost,
        rule.targetPort,
        localHost: socket.remoteAddress.address,
        localPort: socket.remotePort,
      );
    } catch (e) {
      socket.destroy();
      _noteFailure(
        rt,
        epoch,
        'The peer could not reach ${rule.targetHost}:${rule.targetPort} ($e)',
      );
      return;
    }
    _pump(rt, epoch, socket, channel);
  }

  Future<void> _startRemote(
    ForwardRuntime rt,
    SSHClient client,
    int epoch,
  ) async {
    final rule = rt.rule;
    final forward = await client.forwardRemote(
      host: rule.bindHost,
      port: rule.bindPort,
    );
    if (forward == null) {
      throw _ForwardFailure(
        'The peer refused to listen on ${rule.bindHost}:${rule.bindPort}. '
        'The port may already be in use there, or the peer\'s sshd has '
        'AllowTcpForwarding disabled.',
      );
    }
    if (rt._epoch != epoch) {
      forward.close();
      return;
    }
    rt._remote = forward;
    rt._remoteClient = client;
    rt.boundPort = forward.port;
    rt._accepts = forward.connections.listen(
      (channel) => unawaited(_acceptRemote(rt, channel, epoch)),
      onError: (Object e) => _noteFailure(rt, epoch, 'Listener: $e'),
    );
  }

  Future<void> _acceptRemote(
    ForwardRuntime rt,
    SSHForwardChannel channel,
    int epoch,
  ) async {
    final rule = rt.rule;
    final Socket socket;
    try {
      socket = await Socket.connect(
        rule.targetHost,
        rule.targetPort,
        timeout: connectTimeout,
      );
    } catch (e) {
      channel.destroy();
      _noteFailure(
        rt,
        epoch,
        'Nothing answered on ${rule.targetHost}:${rule.targetPort} on this computer ($e)',
      );
      return;
    }
    _pump(rt, epoch, socket, channel);
  }

  /// Joins a local socket and a channel, moving bytes both ways until each
  /// direction ends. Each direction half-closes independently: a client that
  /// shuts down its write side and then waits for the reply (HTTP/1.0, nc -N,
  /// git) must still receive it.
  void _pump(ForwardRuntime rt, int epoch, Socket socket, SSHSocket channel) {
    if (rt._epoch != epoch || !rt.isActive) {
      socket.destroy();
      channel.destroy();
      return;
    }
    final pipe = _Pipe(socket, channel);
    rt._pipes.add(pipe);
    rt.liveConnections++;
    rt.totalConnections++;
    _notify();

    Future<void> relay(
      Stream<List<int>> from,
      StreamConsumer<List<int>> to,
      Future<void> Function() closeTo,
      void Function(int) count,
    ) async {
      try {
        await to.addStream(
          from.map((chunk) {
            count(chunk.length);
            return chunk;
          }),
        );
      } catch (_) {
        // A reset or a torn-down channel ends this one connection only.
      }
      try {
        await closeTo();
      } catch (_) {}
    }

    unawaited(
      Future.wait([
        relay(socket, channel.sink, () => channel.sink.close(), (n) {
          rt.bytesUp += n;
          _dirty = true;
        }),
        relay(channel.stream, socket, () => socket.close(), (n) {
          rt.bytesDown += n;
          _dirty = true;
        }),
      ]).whenComplete(() {
        pipe.destroy();
        rt._pipes.remove(pipe);
        if (rt.liveConnections > 0) rt.liveConnections--;
        _notify();
      }),
    );
  }

  var _dirty = false;

  void _ensureTick() {
    _tick ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_dirty) {
        _dirty = false;
        _notify();
      }
      if (!_items.any((rt) => rt.isActive)) {
        _tick?.cancel();
        _tick = null;
      }
    });
  }

  void _noteFailure(ForwardRuntime rt, int epoch, String message) {
    if (rt._epoch != epoch || rt.state != ForwardState.running) return;
    // The listener is fine and the next connection may work, so this is a
    // note on the row, not an error state.
    rt.message = 'Last connection failed: $message';
    _notify();
  }

  Future<void> stop(String id) async {
    final rt = byId(id);
    if (rt == null) return;
    rt._epoch++;
    rt.resumeOnReconnect = false;
    await _teardown(rt);
    rt
      ..state = ForwardState.stopped
      ..message = null
      ..liveConnections = 0;
    _notify();
  }

  Future<void> stopAll() async {
    for (final rt in List.of(_items)) {
      if (rt.isActive) await stop(rt.rule.id);
    }
  }

  Future<void> _teardown(ForwardRuntime rt) async {
    final accepts = rt._accepts;
    final server = rt._server;
    final remote = rt._remote;
    final remoteClient = rt._remoteClient;
    rt._accepts = null;
    rt._server = null;
    rt._remote = null;
    rt._remoteClient = null;
    for (final pipe in rt._pipes.toList()) {
      pipe.destroy();
    }
    rt._pipes.clear();
    rt.boundPort = null;
    if (remote != null) {
      // SSHRemoteForward.close() fires cancelForwardRemote without awaiting
      // it, so when the connection is already gone its failure escapes as an
      // unhandled async error. Cancel it ourselves where it can be caught;
      // close() afterwards then finds nothing left to cancel.
      try {
        await remoteClient?.cancelForwardRemote(remote);
      } catch (_) {
        // The connection is gone, which cancels the forward anyway.
      }
      try {
        remote.close();
      } catch (_) {}
    }
    await accepts?.cancel();
    try {
      await server?.close();
    } catch (_) {}
  }

  void _onSessionChanged() {
    if (_disposed) return;
    if (session.phase == ConnectionPhase.lost ||
        session.phase == ConnectionPhase.failed) {
      for (final rt in _items) {
        if (!rt.isActive) continue;
        rt._epoch++;
        unawaited(_teardown(rt));
        rt
          ..state = ForwardState.error
          ..message =
              'Connection lost. It restarts when the connection returns.'
          ..resumeOnReconnect = true
          ..liveConnections = 0;
      }
      _notify();
    } else if (session.phase == ConnectionPhase.connected &&
        session.generation != _lastGeneration) {
      _lastGeneration = session.generation;
      for (final rt in _items.where((r) => r.resumeOnReconnect).toList()) {
        rt.state = ForwardState.stopped;
        unawaited(start(rt.rule.id));
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_onSessionChanged);
    _tick?.cancel();
    for (final rt in _items) {
      rt._epoch++;
      unawaited(_teardown(rt));
    }
    super.dispose();
  }
}

class _ForwardFailure implements Exception {
  _ForwardFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns a failed [ServerSocket.bind] into something worth reading. The OS
/// error code is checked next to the text because Windows localises the text.
String describeBindError(SocketException error, String host, int port) {
  final code = error.osError?.errorCode;
  final text = (error.osError?.message ?? error.message).toLowerCase();

  // EADDRINUSE: 98 Linux, 48 macOS, 10048 Windows. dart:io also reports an
  // in-process collision as an API misuse with no OSError, hence the phrases.
  if (code == 98 ||
      code == 48 ||
      code == 10048 ||
      text.contains('address already in use') ||
      text.contains('shared flag') ||
      text.contains('normally permitted')) {
    return 'Port $port is already in use on $host. Something else is '
        'listening there: pick another port or stop whatever has it.';
  }
  // EACCES: 13 everywhere but Windows (10013).
  if (code == 13 || code == 10013 || text.contains('permission denied')) {
    return port < 1024
        ? 'Port $port is privileged: ports below 1024 need administrator '
              'rights to listen on. Pick a port above that.'
        : 'This computer refused to let the app listen on $host:$port.';
  }
  // EADDRNOTAVAIL: 99 Linux, 49 macOS, 10049 Windows.
  if (code == 99 ||
      code == 49 ||
      code == 10049 ||
      text.contains('cannot assign requested address')) {
    return 'No network interface here has the address $host, so nothing can '
        'listen there. 127.0.0.1 always works.';
  }
  return 'Could not listen on $host:$port. ${error.osError?.message ?? error.message}';
}
