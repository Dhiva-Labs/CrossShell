import 'dart:convert';
import 'dart:io';

import 'package:cross_shell/src/ui/session/forwards/forward_manager.dart';
import 'package:cross_shell/src/ui/session/forwards/forward_models.dart';
import 'package:cross_shell/src/ui/session/forwards/forward_store.dart';
import 'package:cross_shell/src/ui/session/session_controller.dart';
import 'package:cross_shell/src/ui/session/session_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_session.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cs_forwards_'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('ForwardRule', () {
    test(
      'defaults: local listens on loopback, remote on the peer\'s localhost',
      () {
        final l = ForwardRule.devPort(3000, ForwardKind.local);
        expect(l.bindHost, '127.0.0.1');
        expect(l.bindPort, 3000);
        expect(l.targetHost, 'localhost');
        expect(l.targetPort, 3000);
        final r = ForwardRule.devPort(8080, ForwardKind.remote);
        expect(r.bindHost, 'localhost');
        expect(r.title, 'Port 8080 (reverse)');
      },
    );

    test('json round trip', () {
      final rule = ForwardRule.create(
        kind: ForwardKind.remote,
        bindPort: 9000,
        targetPort: 3000,
        targetHost: '192.168.0.5',
        label: 'api',
      );
      final back = ForwardRule.fromJson(jsonDecode(jsonEncode(rule.toJson())))!;
      expect(back.id, rule.id);
      expect(back.kind, ForwardKind.remote);
      expect(back.bindPort, 9000);
      expect(back.targetHost, '192.168.0.5');
      expect(back.label, 'api');
    });

    test('invalid entries are rejected rather than crashing', () {
      expect(ForwardRule.fromJson('nope'), isNull);
      expect(ForwardRule.fromJson({'id': 'x'}), isNull);
      expect(
        ForwardRule.fromJson({
          'id': 'x',
          'kind': 'local',
          'bindHost': '127.0.0.1',
          'bindPort': 70000,
          'targetHost': 'h',
          'targetPort': 1,
        }),
        isNull,
      );
      expect(
        ForwardRule.fromJson({
          'id': 'x',
          'kind': 'sideways',
          'bindHost': 'h',
          'bindPort': 1,
          'targetHost': 'h',
          'targetPort': 1,
        }),
        isNull,
      );
    });

    test('port parsing', () {
      expect(parsePort('8080'), 8080);
      expect(parsePort(' 22 '), 22);
      expect(parsePort('0'), isNull);
      expect(parsePort('65536'), isNull);
      expect(parsePort('abc'), isNull);
      expect(parsePort(''), isNull);
    });

    test('presets cover the common dev ports', () {
      expect(
        commonDevPorts.map((p) => p.port),
        containsAll([3000, 5173, 8000, 8080]),
      );
    });
  });

  group('ForwardStore', () {
    test('missing file loads empty with no error', () async {
      final r = await ForwardStore(dir).load('peer-1');
      expect(r.rules, isEmpty);
      expect(r.error, isNull);
    });

    test('save then load keeps order and ids, per peer', () async {
      final store = ForwardStore(dir);
      final a = ForwardRule.devPort(3000, ForwardKind.local);
      final b = ForwardRule.devPort(5173, ForwardKind.remote, label: 'vite');
      await store.save('peer-1', [a, b]);
      await store.save('peer-2', [ForwardRule.devPort(22, ForwardKind.local)]);
      final r1 = await store.load('peer-1');
      expect(r1.rules.map((r) => r.id), [a.id, b.id]);
      expect(r1.rules.last.label, 'vite');
      expect((await store.load('peer-2')).rules.length, 1);
      expect(File('${dir.path}/forwards/peer-1.json').existsSync(), isTrue);
    });

    test('peer ids cannot escape the directory', () async {
      final store = ForwardStore(dir);
      await store.save('../../evil', [
        ForwardRule.devPort(1, ForwardKind.local),
      ]);
      expect(store.fileFor('../../evil').path.startsWith(dir.path), isTrue);
      expect(File(store.fileFor('../../evil').path).existsSync(), isTrue);
      expect(ForwardStore.fileSafe('a/b\\c'), 'a_b_c');
    });

    test(
      'a corrupt file is reported, kept as .bad, and does not crash',
      () async {
        final store = ForwardStore(dir);
        final file = store.fileFor('p');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('{ not json');
        final r = await store.load('p');
        expect(r.rules, isEmpty);
        expect(r.error, contains('could not be read'));
        expect(File('${file.path}.bad').existsSync(), isTrue);
        // The next save starts clean.
        await store.save('p', [ForwardRule.devPort(3000, ForwardKind.local)]);
        expect((await store.load('p')).rules.length, 1);
      },
    );

    test('one bad entry does not lose the good ones', () async {
      final store = ForwardStore(dir);
      final good = ForwardRule.devPort(3000, ForwardKind.local);
      final file = store.fileFor('p');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'v': 1,
          'rules': [
            good.toJson(),
            {'id': 'broken'},
          ],
        }),
      );
      final r = await store.load('p');
      expect(r.rules.single.id, good.id);
      expect(r.error, contains('1 saved forward'));
    });

    test('a failed save leaves the previous file intact', () async {
      final store = ForwardStore(dir);
      await store.save('p', [ForwardRule.devPort(3000, ForwardKind.local)]);
      final before = store.fileFor('p').readAsStringSync();
      // Make the temp path a directory so the write fails.
      Directory('${store.fileFor('p').path}.tmp').createSync();
      await expectLater(store.save('p', []), throwsA(anything));
      expect(store.fileFor('p').readAsStringSync(), before);
    });
  });

  group('ForwardManager', () {
    SessionController offline() => SessionController(
      connect: () async => throw StateError('offline'),
      os: RemoteOs.linux,
    );

    test('presets persist across manager instances', () async {
      final session = offline();
      final store = ForwardStore(dir);
      final m1 = ForwardManager(peerId: 'peer', session: session, store: store);
      await m1.load();
      await m1.add(ForwardRule.devPort(3000, ForwardKind.local));
      await m1.add(ForwardRule.devPort(8000, ForwardKind.remote));
      m1.dispose();

      final m2 = ForwardManager(peerId: 'peer', session: session, store: store);
      await m2.load();
      expect(m2.items.map((i) => i.rule.bindPort), [3000, 8000]);
      expect(m2.items.map((i) => i.rule.kind), [
        ForwardKind.local,
        ForwardKind.remote,
      ]);
      m2.dispose();
      session.dispose();
    });

    test('adding the same route twice does not duplicate', () async {
      final session = offline();
      final m = ForwardManager(
        peerId: 'p',
        session: session,
        store: ForwardStore(dir),
      );
      await m.load();
      await m.add(ForwardRule.devPort(3000, ForwardKind.local));
      await m.add(ForwardRule.devPort(3000, ForwardKind.local));
      expect(m.items.length, 1);
      m.dispose();
      session.dispose();
    });

    test('update and remove are persisted', () async {
      final session = offline();
      final store = ForwardStore(dir);
      final m = ForwardManager(peerId: 'p', session: session, store: store);
      await m.load();
      final rt = await m.add(ForwardRule.devPort(3000, ForwardKind.local));
      await m.update(rt.rule.copyWith(label: 'web', targetPort: 3001));
      var saved = (await store.load('p')).rules.single;
      expect(saved.label, 'web');
      expect(saved.targetPort, 3001);
      await m.remove(rt.rule.id);
      saved = (await store.load('p')).rules.firstOrNull ?? saved;
      expect((await store.load('p')).rules, isEmpty);
      m.dispose();
      session.dispose();
    });

    test('starting while offline says so instead of hanging', () async {
      final session = offline();
      final m = ForwardManager(
        peerId: 'p',
        session: session,
        store: ForwardStore(dir),
      );
      await m.load();
      final rt = await m.add(
        ForwardRule.devPort(3000, ForwardKind.local),
        start: true,
      );
      expect(rt.state, ForwardState.error);
      expect(rt.message, contains('Not connected'));
      m.dispose();
      session.dispose();
    });

    test('a save failure is surfaced, not swallowed', () async {
      final session = offline();
      // A file where the directory should be makes every save fail.
      final blocker = File('${dir.path}/forwards')..writeAsStringSync('x');
      expect(blocker.existsSync(), isTrue);
      final m = ForwardManager(
        peerId: 'p',
        session: session,
        store: ForwardStore(dir),
      );
      await m.load();
      await m.add(ForwardRule.devPort(3000, ForwardKind.local));
      expect(m.storeError, contains('Could not save'));
      m.dispose();
      session.dispose();
    });
  });

  group('ForwardManager and the connection', () {
    test(
      'running forwards stop when the connection drops and restart when it returns',
      () async {
        final session = FakeSession();
        final m = ForwardManager(
          peerId: 'p',
          session: session,
          store: ForwardStore(dir),
        );
        await m.load();
        final probe = await ServerSocket.bind('127.0.0.1', 0);
        final port = probe.port;
        await probe.close();
        final rt = await m.add(
          ForwardRule.create(
            kind: ForwardKind.local,
            bindPort: port,
            targetPort: 22,
          ),
          start: true,
        );
        expect(rt.state, ForwardState.running, reason: rt.message);
        // The listener is up.
        (await Socket.connect('127.0.0.1', port)).destroy();

        session.set(ConnectionPhase.lost, 'wifi dropped');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(rt.state, ForwardState.error);
        expect(rt.message, contains('Connection lost'));
        expect(rt.resumeOnReconnect, isTrue);
        await expectLater(
          Socket.connect('127.0.0.1', port),
          throwsA(isA<SocketException>()),
          reason: 'a dead tunnel must not leave a listener behind',
        );

        session.reconnected();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(rt.state, ForwardState.running, reason: rt.message);
        (await Socket.connect('127.0.0.1', port)).destroy();

        // A forward the user stopped does not come back by itself.
        await m.stop(rt.rule.id);
        session.set(ConnectionPhase.lost);
        session.reconnected();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(rt.state, ForwardState.stopped);
        m.dispose();
        session.dispose();
      },
    );
  });

  group('describeBindError', () {
    test('port in use / privileged / bad address', () {
      String msg(int code, String text, int port) => describeBindError(
        SocketException('bind failed', osError: OSError(text, code)),
        '127.0.0.1',
        port,
      );
      expect(
        msg(98, 'Address already in use', 3000),
        contains('already in use'),
      );
      expect(msg(10048, 'Only one usage', 3000), contains('already in use'));
      expect(msg(13, 'Permission denied', 80), contains('privileged'));
      expect(msg(13, 'Permission denied', 8080), isNot(contains('privileged')));
      expect(
        msg(99, 'Cannot assign requested address', 3000),
        contains('127.0.0.1 always works'),
      );
    });
  });
}
