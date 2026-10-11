// Exercises the real code paths against a real peer. Skipped unless
// CS_DEV_HOST is set:
//
//   CS_DEV_HOST=192.168.0.129 CS_DEV_USER=dhiva \
//     CS_DEV_KEY=~/.ssh/id_ed25519 CS_DEV_OS=windows \
//     flutter test test/ui/live_peer_test.dart
//
// Everything it creates lives under CS_DEV_SCRATCH (a folder on the peer, in
// SFTP form, default /C:/dev/crossshell/uitest) and is removed afterwards.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cross_shell/src/ui/session/files/fs_backend.dart';
import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:cross_shell/src/ui/session/files/sftp_backend.dart';
import 'package:cross_shell/src/ui/session/files/transfer_engine.dart';
import 'package:cross_shell/src/ui/session/files/transfer_queue.dart';
import 'package:cross_shell/src/ui/session/forwards/forward_manager.dart';
import 'package:cross_shell/src/ui/session/forwards/forward_models.dart';
import 'package:cross_shell/src/ui/session/forwards/forward_store.dart';
import 'package:cross_shell/src/ui/session/session_controller.dart';
import 'package:cross_shell/src/ui/session/session_types.dart';
import 'package:cross_shell/src/core/ssh/ssh_algorithms.dart';
import 'package:cross_shell/src/ui/session/terminal/terminal_shell.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

final env = Platform.environment;
final host = env['CS_DEV_HOST'];
final live = (host ?? '').isNotEmpty;

String expandHome(String p) =>
    p.startsWith('~') ? '${env['HOME']}${p.substring(1)}' : p;

Future<SSHClient> connect() async {
  final socket = await SSHSocket.connect(
    host!,
    int.parse(env['CS_DEV_PORT'] ?? '22'),
  );
  final key = File(
    expandHome(env['CS_DEV_KEY'] ?? '~/.ssh/id_ed25519'),
  ).readAsStringSync();
  final client = SSHClient(
    socket,
    username: env['CS_DEV_USER'] ?? 'dhiva',
    identities: SSHKeyPair.fromPem(key),
    algorithms: fastSshAlgorithms,
    // Test only: the real app pins host keys at pairing.
    onVerifyHostKey: (_, _) => true,
  );
  await client.authenticated;
  return client;
}

Future<TransferTask> runTask(
  TransferQueue q,
  TaskKind kind,
  TaskRunner r,
) async {
  final t = q.enqueue(kind: kind, title: 't', subtitle: '', runner: r);
  while (t.status.isActive) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return t;
}

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

void main() {
  late SSHClient client;
  late SftpFsBackend remote;
  late LocalFsBackend local;
  late Directory tmp;
  late String scratch;
  final created = <String>[];
  final queue = TransferQueue(progressInterval: Duration.zero);

  setUpAll(() async {
    if (!live) return;
    client = await connect();
    final sftp = await client.sftp();
    final home = await sftp.absolute('.');
    final style = PathStyle.remote(
      RemoteOs.values.asNameMap()[env['CS_DEV_OS']] ?? RemoteOs.other,
      home: home,
    );
    remote = SftpFsBackend(sftp, style: style, label: 'peer');
    local = LocalFsBackend(style: const PosixPathStyle());
    tmp = Directory.systemTemp.createTempSync('cs_live_');
    scratch = style.normalize(
      env['CS_DEV_SCRATCH'] ?? '/C:/dev/crossshell/uitest',
    );
    // Create the scratch chain, remembering what we made so only that is removed.
    var cur = style.root;
    for (final crumb in style.breadcrumbs(scratch).skip(1)) {
      cur = crumb.path;
      if (await remote.stat(cur) == null) {
        await remote.mkdir(cur);
        created.add(cur);
      }
    }
  });

  tearDownAll(() async {
    if (!live) return;
    // Scratch contents first, then only the directories we created.
    final leftovers = await remote.list(scratch);
    if (leftovers.isNotEmpty) {
      await runTask(
        queue,
        TaskKind.delete,
        TransferEngine.delete(fs: remote, items: leftovers),
      );
    }
    for (final dir in created.reversed) {
      await remote.deleteEmptyDirectory(dir);
    }
    expect(await remote.stat(scratch), created.isEmpty ? isNotNull : isNull);
    tmp.deleteSync(recursive: true);
    queue.dispose();
    client.close();
  });

  group(
    'SFTP on the live peer',
    () {
      test('home and listing follow the server path grammar', () async {
        final home = await remote.home();
        // ignore: avoid_print
        print('home=$home style=${remote.style.runtimeType}');
        if (remote.style is SftpWindowsPathStyle) {
          expect(home, matches(RegExp(r'^/[A-Z]:/Users/')));
          final drives = await remote.list('/');
          expect(drives.map((e) => e.name), contains('C:'));
          expect(drives.first.path, matches(RegExp(r'^/[A-Z]:/$')));
          final c = await remote.list('/C:/');
          expect(c.map((e) => e.name), contains('Users'));
        }
        final entries = await remote.list(home);
        expect(entries, isNotEmpty);
        expect(entries.where((e) => e.isDirectory), isNotEmpty);
      });

      test('a missing path reports not-found', () async {
        expect(await remote.stat('$scratch/does-not-exist'), isNull);
        await expectLater(
          remote.list('$scratch/does-not-exist'),
          throwsA(
            isA<FsException>().having(
              (e) => e.kind,
              'kind',
              FsErrorKind.notFound,
            ),
          ),
        );
      });

      test('mkdir / rename / delete round trip', () async {
        final dir = remote.style.join(scratch, 'ops');
        await remote.mkdir(dir);
        expect(await remote.stat(dir), isNotNull);
        await expectLater(remote.mkdir(dir), throwsA(isA<FsException>()));
        final renamed = remote.style.join(scratch, 'ops2');
        await remote.rename(dir, renamed);
        expect(await remote.stat(dir), isNull);
        expect((await remote.stat(renamed))!.isDirectory, isTrue);
        // A case-only rename is not a conflict on a case-insensitive peer, and
        // must not destroy the folder (Win32-OpenSSH's posix-rename would).
        final recased = remote.style.join(scratch, 'OPS2');
        if (remote.style.isWindows) {
          await remote.mkdir(remote.style.join(renamed, 'inner'));
          await remote.rename(renamed, recased);
          final names = (await remote.list(
            scratch,
          )).map((e) => e.name).toList();
          expect(names, contains('OPS2'));
          expect(names, isNot(contains('ops2')));
          expect((await remote.list(recased)).map((e) => e.name), ['inner']);
          await remote.deleteEmptyDirectory(
            remote.style.join(recased, 'inner'),
          );
          // And again with nothing inside, the case that used to vanish.
          await remote.rename(recased, renamed);
          expect(await remote.stat(renamed), isNotNull);
          await remote.rename(renamed, recased);
          expect((await remote.stat(recased))?.isDirectory, isTrue);
        }
        final last = remote.style.isWindows ? recased : renamed;
        await remote.deleteEmptyDirectory(last);
        expect(await remote.stat(last), isNull);
      });

      test('upload then download a small file is byte-identical', () async {
        final src = File('${tmp.path}/small.txt')
          ..writeAsStringSync('héllo wörld \u2192 日本語\nline two\n');
        final srcEntry = (await local.stat(src.path))!;
        var t = await runTask(
          queue,
          TaskKind.upload,
          TransferEngine.copy(
            from: local,
            to: remote,
            items: [CopyItem(srcEntry)],
            destDir: scratch,
          ),
        );
        expect(t.status, TaskStatus.completed, reason: t.error);
        final remotePath = remote.style.join(scratch, 'small.txt');
        expect((await remote.stat(remotePath))!.size, src.lengthSync());

        final back = Directory('${tmp.path}/back')..createSync();
        t = await runTask(
          queue,
          TaskKind.download,
          TransferEngine.copy(
            from: remote,
            to: local,
            items: [CopyItem((await remote.stat(remotePath))!)],
            destDir: back.path,
          ),
        );
        expect(t.status, TaskStatus.completed, reason: t.error);
        expect(
          File('${back.path}/small.txt').readAsBytesSync(),
          src.readAsBytesSync(),
        );
      });

      test(
        'a 24 MB file streams both ways with progress and matches',
        () async {
          final data = randomBytes(24 * 1024 * 1024, 7);
          final src = File('${tmp.path}/big.bin')..writeAsBytesSync(data);
          final srcEntry = (await local.stat(src.path))!;
          final sw = Stopwatch()..start();
          var t = await runTask(
            queue,
            TaskKind.upload,
            TransferEngine.copy(
              from: local,
              to: remote,
              items: [CopyItem(srcEntry)],
              destDir: scratch,
            ),
          );
          final upSecs = sw.elapsedMilliseconds / 1000;
          expect(t.status, TaskStatus.completed, reason: t.error);
          expect(t.doneBytes, data.length);
          final remotePath = remote.style.join(scratch, 'big.bin');
          expect((await remote.stat(remotePath))!.size, data.length);

          final back = Directory('${tmp.path}/back_big')..createSync();
          sw
            ..reset()
            ..start();
          t = await runTask(
            queue,
            TaskKind.download,
            TransferEngine.copy(
              from: remote,
              to: local,
              items: [CopyItem((await remote.stat(remotePath))!)],
              destDir: back.path,
            ),
          );
          final downSecs = sw.elapsedMilliseconds / 1000;
          expect(t.status, TaskStatus.completed, reason: t.error);
          final got = File('${back.path}/big.bin').readAsBytesSync();
          expect(got.length, data.length);
          expect(got, data);
          // ignore: avoid_print
          print(
            '24 MB up ${(24 / upSecs).toStringAsFixed(1)} MB/s, '
            'down ${(24 / downSecs).toStringAsFixed(1)} MB/s',
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );

      test(
        'a folder tree round-trips recursively (nested, empty dir, unicode names)',
        () async {
          final root = Directory('${tmp.path}/tree')..createSync();
          File('${root.path}/a.txt').writeAsStringSync('A');
          Directory('${root.path}/sub/deeper').createSync(recursive: true);
          File(
            '${root.path}/sub/b.bin',
          ).writeAsBytesSync(randomBytes(300000, 1));
          File(
            '${root.path}/sub/deeper/c d.txt',
          ).writeAsStringSync('spaces in name');
          File('${root.path}/ünï.txt').writeAsStringSync('unicode');
          Directory('${root.path}/empty').createSync();
          final entry = (await local.stat(root.path))!;
          var t = await runTask(
            queue,
            TaskKind.upload,
            TransferEngine.copy(
              from: local,
              to: remote,
              items: [CopyItem(entry)],
              destDir: scratch,
            ),
          );
          expect(t.status, TaskStatus.completed, reason: t.error);
          expect(t.filesTotal, 4);
          final rtree = remote.style.join(scratch, 'tree');
          expect(
            (await remote.list(rtree)).map((e) => e.name),
            containsAll(['a.txt', 'sub', 'ünï.txt', 'empty']),
          );

          final back = Directory('${tmp.path}/back_tree')..createSync();
          t = await runTask(
            queue,
            TaskKind.download,
            TransferEngine.copy(
              from: remote,
              to: local,
              items: [CopyItem((await remote.stat(rtree))!)],
              destDir: back.path,
            ),
          );
          expect(t.status, TaskStatus.completed, reason: t.error);
          expect(File('${back.path}/tree/a.txt').readAsStringSync(), 'A');
          expect(
            File('${back.path}/tree/sub/deeper/c d.txt').readAsStringSync(),
            'spaces in name',
          );
          expect(
            File('${back.path}/tree/sub/b.bin').readAsBytesSync(),
            File('${root.path}/sub/b.bin').readAsBytesSync(),
          );
          expect(Directory('${back.path}/tree/empty').existsSync(), isTrue);
          expect(
            File('${back.path}/tree/ünï.txt').readAsStringSync(),
            'unicode',
          );

          // Recursive delete on the peer.
          t = await runTask(
            queue,
            TaskKind.delete,
            TransferEngine.delete(
              fs: remote,
              items: [(await remote.stat(rtree))!],
            ),
          );
          expect(t.status, TaskStatus.completed, reason: t.error);
          expect(await remote.stat(rtree), isNull);
        },
      );

      test(
        'cancelling a big upload leaves no partial file',
        () async {
          final src = File('${tmp.path}/cancel.bin')
            ..writeAsBytesSync(randomBytes(40 * 1024 * 1024, 3));
          final entry = (await local.stat(src.path))!;
          final t = queue.enqueue(
            kind: TaskKind.upload,
            title: 'c',
            subtitle: '',
            runner: TransferEngine.copy(
              from: local,
              to: remote,
              items: [CopyItem(entry)],
              destDir: scratch,
            ),
          );
          while (t.doneBytes < 1024 * 1024 && t.status.isActive) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          queue.cancel(t.id);
          await Future<void>.delayed(const Duration(seconds: 2));
          expect(t.status, TaskStatus.cancelled);
          expect(
            await remote.stat(remote.style.join(scratch, 'cancel.bin')),
            isNull,
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
    skip: live ? false : 'set CS_DEV_HOST to run against a real peer',
  );

  group(
    'terminal on the live peer',
    () {
      test(
        'echo, resize and exit behave',
        () async {
          final shell = TerminalShell(number: 1);
          addTearDown(shell.dispose);
          final raw = StringBuffer();
          shell.onRawOutput = raw.write;
          shell.terminal.resize(100, 30);
          await shell.start(client);
          expect(shell.state, ShellState.running);

          String screen() => shell.terminal.buffer.getText();
          Future<void> waitFor(bool Function() test, String what) async {
            final end = DateTime.now().add(const Duration(seconds: 20));
            while (!test()) {
              if (DateTime.now().isAfter(end)) {
                fail(
                  'timed out waiting for $what.\n--- screen ---\n${screen()}\n--- raw ---\n${raw.toString().replaceAll('\x1b', '<ESC>')}',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }

          // Wait for a prompt, then type like a user would.
          await waitFor(
            () => screen().contains('>') || screen().contains(r'$'),
            'a prompt',
          );
          shell.terminal.textInput('echo hello-from-crossshell\r');
          await waitFor(
            () => RegExp(
              r'^hello-from-crossshell',
              multiLine: true,
            ).hasMatch(screen()),
            'echo output',
          );

          // Resize reaches the PTY (cmd.exe: mode con prints the columns).
          if (env['CS_DEV_OS'] == 'windows') {
            shell.terminal.resize(120, 40);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            shell.terminal.textInput('mode con | findstr Columns\r');
            await waitFor(
              () => RegExp(r'Columns:\s+120').hasMatch(screen()),
              'resized columns',
            );
          } else {
            shell.terminal.resize(120, 40);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            shell.terminal.textInput('echo size:\$(stty size)\r');
            await waitFor(
              () => screen().contains('size:40 120'),
              'resized size',
            );
          }

          // TERM is advertised as xterm-256color in the PTY request. A POSIX
          // shell shows it; on Windows, cmd.exe has no TERM variable at all
          // (ConPTY ignores the type), so only the PTY behaviour matters.
          if (env['CS_DEV_OS'] != 'windows') {
            shell.terminal.textInput('echo term:\$TERM\r');
            await waitFor(
              () => screen().contains('term:xterm-256color'),
              'TERM',
            );
          } else {
            shell.terminal.textInput('echo term=[%TERM%]\r');
            await Future<void>.delayed(const Duration(milliseconds: 600));
            // ignore: avoid_print
            print(
              'cmd.exe reports: '
              '${RegExp(r'^term=.*', multiLine: true).allMatches(screen()).map((m) => m[0]).toList()}',
            );
          }

          shell.terminal.textInput('exit\r');
          await waitFor(() => shell.state == ShellState.exited, 'shell exit');
          expect(shell.detail, anyOf(contains('status'), contains('closed')));
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
    skip: live ? false : 'set CS_DEV_HOST to run against a real peer',
  );

  group(
    'forwards on the live peer',
    () {
      test(
        'local forward reaches sshd; remote forward comes back to us',
        () async {
          final session = SessionController(
            connect: connect,
            os: RemoteOs.other,
          );
          await session.reconnect();
          expect(session.isConnected, isTrue, reason: session.message);
          final dir = Directory.systemTemp.createTempSync('cs_fwd_');
          final manager = ForwardManager(
            peerId: 'live',
            session: session,
            store: ForwardStore(dir),
          );
          addTearDown(() {
            manager.dispose();
            session.dispose();
            dir.deleteSync(recursive: true);
          });
          await manager.load();

          // 1. Local forward: 127.0.0.1:<free> -> the peer's own sshd.
          final probe = await ServerSocket.bind('127.0.0.1', 0);
          final localPort = probe.port;
          await probe.close();
          final local = await manager.add(
            ForwardRule.create(
              kind: ForwardKind.local,
              bindPort: localPort,
              targetPort: int.parse(env['CS_DEV_PORT'] ?? '22'),
              targetHost: '127.0.0.1',
            ),
            start: true,
          );
          expect(local.state, ForwardState.running, reason: local.message);
          final sock = await Socket.connect('127.0.0.1', localPort);
          final banner = await utf8.decoder
              .bind(sock)
              .first
              .timeout(const Duration(seconds: 10));
          sock.destroy();
          expect(banner, startsWith('SSH-2.0-'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(local.totalConnections, 1);
          expect(local.bytesDown, greaterThan(0));

          // 2. Remote forward: the peer listens on P and sends to our echo server.
          final echo = await ServerSocket.bind('127.0.0.1', 0);
          echo.listen((s) => s.listen((d) => s.add(d), onDone: s.close));
          final peerPort = 47931 + Random().nextInt(300);
          final remoteRule = await manager.add(
            ForwardRule.create(
              kind: ForwardKind.remote,
              bindHost: '127.0.0.1',
              bindPort: peerPort,
              targetHost: '127.0.0.1',
              targetPort: echo.port,
            ),
            start: true,
          );
          expect(
            remoteRule.state,
            ForwardState.running,
            reason: remoteRule.message,
          );

          // 3. Go around: a local forward whose target is the peer's listener, so
          //    the bytes travel us -> peer -> back to us -> echo -> back again.
          final probe2 = await ServerSocket.bind('127.0.0.1', 0);
          final loopPort = probe2.port;
          await probe2.close();
          final loop = await manager.add(
            ForwardRule.create(
              kind: ForwardKind.local,
              bindPort: loopPort,
              targetPort: peerPort,
              targetHost: '127.0.0.1',
            ),
            start: true,
          );
          expect(loop.state, ForwardState.running, reason: loop.message);
          final s2 = await Socket.connect('127.0.0.1', loopPort);
          final reply = Completer<String>();
          final got = StringBuffer();
          s2.listen((d) {
            got.write(utf8.decode(d));
            if (got.length >= 'ping through two tunnels'.length &&
                !reply.isCompleted) {
              reply.complete(got.toString());
            }
          });
          s2.write('ping through two tunnels');
          expect(
            await reply.future.timeout(const Duration(seconds: 15)),
            'ping through two tunnels',
          );
          s2.destroy();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(remoteRule.totalConnections, 1);
          expect(remoteRule.bytesUp, greaterThan(0));
          expect(loop.bytesUp, greaterThan(0));

          // 4. Stopping really closes the listener.
          await manager.stop(local.rule.id);
          expect(local.state, ForwardState.stopped);
          await expectLater(
            Socket.connect('127.0.0.1', localPort),
            throwsA(isA<SocketException>()),
          );
          await echo.close();
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'a local port that is taken is reported with the real reason',
        () async {
          final session = SessionController(
            connect: connect,
            os: RemoteOs.other,
          );
          await session.reconnect();
          final dir = Directory.systemTemp.createTempSync('cs_fwd2_');
          final manager = ForwardManager(
            peerId: 'live2',
            session: session,
            store: ForwardStore(dir),
          );
          addTearDown(() {
            manager.dispose();
            session.dispose();
            dir.deleteSync(recursive: true);
          });
          await manager.load();
          final taken = await ServerSocket.bind('127.0.0.1', 0);
          addTearDown(taken.close);
          final rt = await manager.add(
            ForwardRule.create(
              kind: ForwardKind.local,
              bindPort: taken.port,
              targetPort: 22,
            ),
            start: true,
          );
          expect(rt.state, ForwardState.error);
          expect(rt.message, contains('already in use'));
        },
      );
    },
    skip: live ? false : 'set CS_DEV_HOST to run against a real peer',
  );

  group(
    'reconnect on the live peer',
    () {
      test(
        'a dropped connection brings the shell and the forward back',
        () async {
          final session = SessionController(
            connect: connect,
            os: RemoteOs.other,
          );
          await session.reconnect();
          expect(session.isConnected, isTrue, reason: session.message);
          final dir = Directory.systemTemp.createTempSync('cs_reconnect_');
          final tabs = TerminalTabs(session: session);
          final manager = ForwardManager(
            peerId: 'rc',
            session: session,
            store: ForwardStore(dir),
          );
          addTearDown(() {
            manager.dispose();
            tabs.dispose();
            session.dispose();
            dir.deleteSync(recursive: true);
          });
          await manager.load();

          Future<void> until(bool Function() test, String what) async {
            final end = DateTime.now().add(const Duration(seconds: 25));
            while (!test()) {
              if (DateTime.now().isAfter(end)) {
                fail('timed out waiting for $what');
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }

          final shell = tabs.add();
          await until(() => shell.state == ShellState.running, 'the shell');
          String screen() => shell.terminal.buffer.getText();
          await until(
            () => screen().contains('>') || screen().contains(r'$'),
            'a prompt',
          );
          shell.terminal.textInput('echo before-drop\r');
          await until(
            () => RegExp(r'^before-drop', multiLine: true).hasMatch(screen()),
            'first echo',
          );

          final probe = await ServerSocket.bind('127.0.0.1', 0);
          final port = probe.port;
          await probe.close();
          final fwd = await manager.add(
            ForwardRule.create(
              kind: ForwardKind.local,
              bindPort: port,
              targetPort: int.parse(env['CS_DEV_PORT'] ?? '22'),
              targetHost: '127.0.0.1',
            ),
            start: true,
          );
          expect(fwd.state, ForwardState.running, reason: fwd.message);

          // The connection dies under everything.
          final generation = session.generation;
          session.client.close();
          await until(
            () => session.phase == ConnectionPhase.lost,
            'the drop to be noticed',
          );
          await until(
            () => shell.state == ShellState.dropped,
            'the shell to notice',
          );
          expect(fwd.state, ForwardState.error);
          expect(fwd.resumeOnReconnect, isTrue);

          // One call reconnects; the dropped shell and the forward come back alone.
          await session.reconnect();
          expect(session.isConnected, isTrue, reason: session.message);
          expect(session.generation, greaterThan(generation));
          await until(
            () => shell.state == ShellState.running,
            'the shell to restart',
          );
          await until(
            () => fwd.state == ForwardState.running,
            'the forward to restart',
          );
          await until(
            () => screen().contains('reconnected'),
            'the reconnect rule in the scrollback',
          );
          shell.terminal.textInput('echo after-drop\r');
          await until(
            () => RegExp(r'^after-drop', multiLine: true).hasMatch(screen()),
            'second echo',
          );
          expect(
            screen(),
            contains('before-drop'),
            reason: 'scrollback survives the reconnect',
          );

          final sock = await Socket.connect('127.0.0.1', port);
          final banner = await utf8.decoder
              .bind(sock)
              .first
              .timeout(const Duration(seconds: 10));
          sock.destroy();
          expect(banner, startsWith('SSH-2.0-'));
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    },
    skip: live ? false : 'set CS_DEV_HOST to run against a real peer',
  );
}
