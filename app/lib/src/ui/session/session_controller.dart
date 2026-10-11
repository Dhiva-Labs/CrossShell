import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'session_types.dart';

enum ConnectionPhase { connecting, connected, lost, failed }

/// Owns the one SSH connection every tab shares: terminals open shell
/// channels on it, the file manager opens SFTP channels, forwards open
/// forwarding channels. When it drops, [generation] changes on the next
/// successful [reconnect] so each tab can rebuild what it had.
class SessionController extends ChangeNotifier {
  SessionController({required this.connect, required this.os});

  final Future<SSHClient> Function() connect;
  final RemoteOs os;

  ConnectionPhase _phase = ConnectionPhase.connecting;
  ConnectionPhase get phase => _phase;

  SSHClient? _client;

  /// Increases on every successful (re)connect.
  int _generation = 0;
  int get generation => _generation;

  /// Why the last attempt failed or the connection ended.
  String? _message;
  String? get message => _message;

  /// The directory the file manager is showing on the peer, for "Open in VS
  /// Code". Null until the Files tab has loaded.
  String? remoteDir;

  Future<void>? _connecting;
  var _disposed = false;

  bool get isConnected =>
      _phase == ConnectionPhase.connected && _client != null;

  /// The live client. Throws when not connected, which callers treat as "show
  /// the reconnect banner" rather than crash.
  SSHClient get client {
    final c = _client;
    if (c == null || _phase != ConnectionPhase.connected) {
      throw StateError('Not connected to the peer.');
    }
    return c;
  }

  /// Connects, or does nothing if an attempt is already running. Never
  /// throws: failure becomes [ConnectionPhase.failed] with [message].
  Future<void> reconnect() => _connecting ??= _connectNow().whenComplete(() {
    _connecting = null;
  });

  Future<void> _connectNow() async {
    final previous = _client;
    _client = null;
    _phase = ConnectionPhase.connecting;
    _message = null;
    _notify();
    previous?.close();

    final SSHClient fresh;
    try {
      fresh = await connect();
      await fresh.authenticated;
    } catch (e) {
      if (_disposed) return;
      _phase = ConnectionPhase.failed;
      _message = describeConnectionError(e);
      _notify();
      return;
    }
    if (_disposed) {
      fresh.close();
      return;
    }
    _client = fresh;
    _generation++;
    _phase = ConnectionPhase.connected;
    _notify();

    unawaited(
      fresh.done.then(
        (_) => _handleClosed(fresh, 'The peer closed the connection.'),
        onError: (Object e, StackTrace _) =>
            _handleClosed(fresh, describeConnectionError(e)),
      ),
    );
  }

  void _handleClosed(SSHClient closed, String reason) {
    // A client we replaced may finish dying late; it no longer speaks for us.
    if (_disposed || !identical(closed, _client)) return;
    _client = null;
    _phase = ConnectionPhase.lost;
    _message = reason;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    _client = null;
    super.dispose();
  }
}

/// A sentence for the user out of whatever the connect callback threw.
String describeConnectionError(Object error) {
  if (error is SSHAuthFailError) {
    return 'Authentication failed. The peer rejected this machine\'s key.';
  }
  if (error is SSHHostkeyError) {
    return 'The peer\'s host key does not match the pinned one. '
        'Refusing to connect.';
  }
  final text = error.toString();
  return text.isEmpty ? 'Connection failed.' : text;
}
