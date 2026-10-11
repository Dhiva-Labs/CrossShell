import 'dart:async';
import 'dart:typed_data';

import 'package:cross_shell/src/ui/session/session_controller.dart';
import 'package:cross_shell/src/ui/session/session_types.dart';
import 'package:dartssh2/dartssh2.dart';

/// A socket that never carries anything: enough to construct a real
/// [SSHClient] object without a network.
class NullSocket implements SSHSocket {
  final _in = StreamController<Uint8List>();
  final _out = StreamController<List<int>>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _in.stream;
  @override
  StreamSink<List<int>> get sink => _out.sink;
  @override
  Future<void> get done => _done.future;
  @override
  Future<void> close() async {}
  @override
  void destroy() {}
  @override
  Future<void> flush() async {}
}

/// A session whose connection state the test controls.
class FakeSession extends SessionController {
  FakeSession({
    this.initial = ConnectionPhase.connected,
    super.os = RemoteOs.windows,
  }) : super(connect: () async => throw StateError('unused'));

  final ConnectionPhase initial;
  late ConnectionPhase _phase = initial;
  int _generation = 1;
  String? _message;
  int reconnects = 0;
  final SSHClient _fakeClient = SSHClient(NullSocket(), username: 'test');

  void set(ConnectionPhase phase, [String? message]) {
    _phase = phase;
    _message = message;
    notifyListeners();
  }

  @override
  ConnectionPhase get phase => _phase;
  @override
  bool get isConnected => _phase == ConnectionPhase.connected;
  @override
  String? get message => _message;
  @override
  int get generation => _generation;

  /// A successful reconnect: new generation, connected again.
  void reconnected() {
    _generation++;
    set(ConnectionPhase.connected);
  }

  @override
  SSHClient get client => _fakeClient;

  @override
  Future<void> reconnect() async {
    reconnects++;
  }

  @override
  void dispose() {
    _fakeClient.close();
    super.dispose();
  }
}
