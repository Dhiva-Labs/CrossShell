// Pairing wire format: 4-byte big-endian length + UTF-8 JSON, ≤ 64 KiB.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../ssh/public_key.dart';

const pairingProtocolVersion = 1;
const maxPairingFrame = 64 * 1024;

class PairingError implements Exception {
  PairingError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a peer says about itself in hello/key messages (unauthenticated
/// until the code is confirmed).
class PeerIdentity {
  PeerIdentity({required this.id, required this.name, required this.os});
  final String id;
  final String name;
  final String os;

  static final _idRe = RegExp(r'^[A-Za-z0-9-]{8,64}$');

  factory PeerIdentity.fromJson(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is! String || !_idRe.hasMatch(id)) {
      throw PairingError('peer sent an invalid id');
    }
    return PeerIdentity(
      id: id,
      name: sanitizeName(m['name']),
      os: sanitizeOs(m['os']),
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'os': os};
}

String sanitizeName(Object? v) {
  final s = (v is String ? v : '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .trim();
  if (s.isEmpty) return 'unknown';
  return s.length > 64 ? s.substring(0, 64) : s;
}

String sanitizeOs(Object? v) => switch (v) {
  'linux' || 'windows' || 'macos' => v as String,
  _ => 'other',
};

/// What each side hands the other once both users confirmed the code.
class PairingPayload {
  PairingPayload({
    required this.sshUser,
    required this.sshPort,
    required this.hostKeys,
    required this.clientKey,
    required this.name,
    required this.os,
  });

  /// Login name on this machine's sshd.
  final String sshUser;
  final int sshPort;

  /// This machine's sshd host keys (`<type> <b64>`); empty when this
  /// machine doesn't run an SSH server (one-way pairing).
  final List<String> hostKeys;

  /// This machine's CrossShell client key (`<type> <b64>`).
  final String clientKey;
  final String name;
  final String os;

  Map<String, dynamic> toJson() => {
    'sshUser': sshUser,
    'sshPort': sshPort,
    'hostKeys': hostKeys,
    'clientKey': clientKey,
    'name': name,
    'os': os,
  };

  /// Strictly validated: everything here ends up in SSH config files.
  factory PairingPayload.fromJson(Map<String, dynamic> m) {
    final user = m['sshUser'];
    if (user is! String ||
        user.isEmpty ||
        user.length > 104 ||
        RegExp(r'[\x00-\x1f\x7f"]').hasMatch(user)) {
      throw PairingError('peer sent an invalid user name');
    }
    final port = m['sshPort'];
    if (port is! int || port < 1 || port > 65535) {
      throw PairingError('peer sent an invalid SSH port');
    }
    final rawHostKeys = m['hostKeys'];
    if (rawHostKeys is! List || rawHostKeys.length > 8) {
      throw PairingError('peer sent invalid host keys');
    }
    final hostKeys = <String>[];
    for (final k in rawHostKeys) {
      if (k is! String) throw PairingError('peer sent invalid host keys');
      try {
        hostKeys.add(PublicKey.parse(k).line);
      } on FormatException catch (e) {
        throw PairingError('peer sent an invalid host key: ${e.message}');
      }
    }
    final ck = m['clientKey'];
    final String clientKey;
    try {
      clientKey = PublicKey.parse(ck is String ? ck : '').line;
    } on FormatException catch (e) {
      throw PairingError('peer sent an invalid client key: ${e.message}');
    }
    return PairingPayload(
      sshUser: user,
      sshPort: port,
      hostKeys: hostKeys,
      clientKey: clientKey,
      name: sanitizeName(m['name']),
      os: sanitizeOs(m['os']),
    );
  }
}

/// Length-prefixed JSON frames over a socket.
class FrameChannel {
  FrameChannel(this.socket) {
    _sub = socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder(copy: false);
  final _frames = <Map<String, dynamic>>[];
  final _waiters = <Completer<Map<String, dynamic>>>[];
  Object? _error;
  bool _closed = false;

  void _onData(Uint8List data) {
    _buf.add(data);
    var bytes = _buf.takeBytes();
    while (bytes.length >= 4) {
      final len = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (len > maxPairingFrame) {
        _fail(PairingError('pairing frame too large'));
        return;
      }
      if (bytes.length < 4 + len) break;
      final Map<String, dynamic> msg;
      try {
        final decoded = jsonDecode(utf8.decode(bytes.sublist(4, 4 + len)));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('not an object');
        }
        msg = decoded;
      } on FormatException {
        _fail(PairingError('malformed pairing message'));
        return;
      }
      bytes = bytes.sublist(4 + len);
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(msg);
      } else {
        _frames.add(msg);
      }
    }
    _buf.add(bytes);
  }

  void _fail(Object e) {
    _error ??= e;
    for (final w in _waiters) {
      w.completeError(e);
    }
    _waiters.clear();
    close();
  }

  void _onError(Object e) => _fail(PairingError('connection error: $e'));
  void _onDone() =>
      _fail(PairingError('the other device closed the connection'));

  /// Next message, or throws [PairingError] on timeout/close.
  Future<Map<String, dynamic>> next(Duration timeout) {
    if (_frames.isNotEmpty) return Future.value(_frames.removeAt(0));
    if (_error != null) return Future.error(_error!);
    final c = Completer<Map<String, dynamic>>();
    _waiters.add(c);
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(c);
        throw PairingError('timed out waiting for the other device');
      },
    );
  }

  /// Next message, which must be of type [t] (an `abort` becomes an error).
  Future<Map<String, dynamic>> expect(String t, Duration timeout) async {
    final m = await next(timeout);
    final type = m['t'];
    if (type == 'abort') {
      throw PairingError(
        'the other device cancelled: ${sanitizeName(m['reason'])}',
      );
    }
    if (type == 'busy') {
      throw PairingError('the other device is already pairing');
    }
    if (type != t) {
      throw PairingError('unexpected pairing message "$type" (expected "$t")');
    }
    return m;
  }

  void send(Map<String, dynamic> msg) {
    if (_closed) return;
    final body = utf8.encode(jsonEncode(msg));
    final head = ByteData(4)..setUint32(0, body.length);
    socket.add([...head.buffer.asUint8List(), ...body]);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await socket.flush();
    } catch (_) {}
    await _sub.cancel();
    socket.destroy();
  }
}
