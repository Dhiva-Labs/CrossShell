import 'dart:convert';

import 'package:cross_shell/src/ui/session/files/fs_backend.dart';
import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:cross_shell/src/ui/session/files/transfer_engine.dart';
import 'package:cross_shell/src/ui/session/files/transfer_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_fs.dart';

Future<TransferTask> run(
  TransferQueue q,
  TaskRunner runner, {
  TaskKind kind = TaskKind.upload,
}) async {
  final t = q.enqueue(kind: kind, title: 't', subtitle: '', runner: runner);
  while (t.status.isActive) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  return t;
}

void main() {
  late TransferQueue q;
  setUp(() => q = TransferQueue(progressInterval: Duration.zero));
  tearDown(() => q.dispose());

  group('copy', () {
    test('a single file is streamed and counted', () async {
      final src = FakeFs(const PosixPathStyle())
        ..addFile('/home/a/hello.txt', 'hello world!');
      final dst = FakeFs(const SftpWindowsPathStyle())
        ..addDir('/C:/Users/dhiva');
      final item = (await src.stat('/home/a/hello.txt'))!;
      final t = await run(
        q,
        TransferEngine.copy(
          from: src,
          to: dst,
          items: [CopyItem(item)],
          destDir: '/C:/Users/dhiva',
        ),
      );
      expect(t.status, TaskStatus.completed, reason: t.error);
      expect(dst.text('/C:/Users/dhiva/hello.txt'), 'hello world!');
      expect(t.doneBytes, 12);
      expect(t.totalBytes, 12);
    });

    test(
      'a folder tree is recreated with every file, including empty folders',
      () async {
        final src = FakeFs(const PosixPathStyle())
          ..addFile('/p/proj/a.txt', 'A')
          ..addFile('/p/proj/src/b.txt', 'BB')
          ..addFile('/p/proj/src/deep/c.txt', 'CCC')
          ..addDir('/p/proj/empty');
        final dst = FakeFs(const SftpWindowsPathStyle())..addDir('/C:/dest');
        final item = (await src.stat('/p/proj'))!;
        final t = await run(
          q,
          TransferEngine.copy(
            from: src,
            to: dst,
            items: [CopyItem(item)],
            destDir: '/C:/dest',
          ),
        );
        expect(t.status, TaskStatus.completed, reason: t.error);
        expect(dst.text('/C:/dest/proj/a.txt'), 'A');
        expect(dst.text('/C:/dest/proj/src/b.txt'), 'BB');
        expect(dst.text('/C:/dest/proj/src/deep/c.txt'), 'CCC');
        expect(dst.exists('/C:/dest/proj/empty'), isTrue);
        expect(t.totalBytes, 6);
        expect(t.filesDone, 3);
        expect(t.filesTotal, 3);
      },
    );

    test('names illegal on the destination are sanitised', () async {
      final src = FakeFs(const PosixPathStyle())
        ..addFile('/p/what?.txt', 'x')
        ..addFile('/p/a:b', 'y');
      final dst = FakeFs(const SftpWindowsPathStyle())..addDir('/C:/d');
      final items = [
        for (final n in ['what?.txt', 'a:b'])
          CopyItem((await src.stat('/p/$n'))!),
      ];
      final t = await run(
        q,
        TransferEngine.copy(from: src, to: dst, items: items, destDir: '/C:/d'),
      );
      expect(t.status, TaskStatus.completed, reason: t.error);
      expect(dst.exists('/C:/d/what_.txt'), isTrue);
      expect(dst.exists('/C:/d/a_b'), isTrue);
    });

    test(
      'policy skip leaves existing files alone and still reaches 100%',
      () async {
        final src = FakeFs(const PosixPathStyle())
          ..addFile('/p/d/keep.txt', 'NEW')
          ..addFile('/p/d/fresh.txt', 'FRESH');
        final dst = FakeFs(const PosixPathStyle())
          ..addFile('/t/d/keep.txt', 'OLD')
          ..addDir('/t');
        final item = (await src.stat('/p/d'))!;
        final t = await run(
          q,
          TransferEngine.copy(
            from: src,
            to: dst,
            items: [CopyItem(item)],
            destDir: '/t',
            policy: ConflictPolicy.skip,
          ),
        );
        expect(t.status, TaskStatus.completed, reason: t.error);
        expect(dst.text('/t/d/keep.txt'), 'OLD');
        expect(dst.text('/t/d/fresh.txt'), 'FRESH');
        expect(t.doneBytes, t.totalBytes);
      },
    );

    test('policy overwrite replaces existing files', () async {
      final src = FakeFs(const PosixPathStyle())..addFile('/p/f.txt', 'NEW');
      final dst = FakeFs(const PosixPathStyle())
        ..addFile('/t/f.txt', 'OLD OLD OLD');
      final t = await run(
        q,
        TransferEngine.copy(
          from: src,
          to: dst,
          items: [CopyItem((await src.stat('/p/f.txt'))!)],
          destDir: '/t',
        ),
      );
      expect(t.status, TaskStatus.completed);
      expect(dst.text('/t/f.txt'), 'NEW');
    });

    test('keep-both naming comes from CopyItem.destName', () async {
      final src = FakeFs(const PosixPathStyle())..addFile('/p/f.txt', 'NEW');
      final dst = FakeFs(const PosixPathStyle())..addFile('/t/f.txt', 'OLD');
      final t = await run(
        q,
        TransferEngine.copy(
          from: src,
          to: dst,
          items: [CopyItem((await src.stat('/p/f.txt'))!, 'f (1).txt')],
          destDir: '/t',
        ),
      );
      expect(t.status, TaskStatus.completed);
      expect(dst.text('/t/f.txt'), 'OLD');
      expect(dst.text('/t/f (1).txt'), 'NEW');
    });

    test(
      'a file where a folder is needed fails with a clear message',
      () async {
        final src = FakeFs(const PosixPathStyle())..addFile('/p/d/x.txt', 'x');
        final dst = FakeFs(const PosixPathStyle())
          ..addFile('/t/d', 'i am a file');
        final t = await run(
          q,
          TransferEngine.copy(
            from: src,
            to: dst,
            items: [CopyItem((await src.stat('/p/d'))!)],
            destDir: '/t',
          ),
        );
        expect(t.status, TaskStatus.failed);
        expect(t.error, contains('not a folder'));
      },
    );

    test(
      'one unreadable file in a folder fails the task but the rest are copied',
      () async {
        final src = FakeFs(const PosixPathStyle())
          ..addFile('/p/d/good.txt', 'good')
          ..addFile('/p/d/bad.txt', 'bad')
          ..addFile('/p/d/also.txt', 'also')
          ..failReads.add('/p/d/bad.txt');
        final dst = FakeFs(const PosixPathStyle())..addDir('/t');
        final t = await run(
          q,
          TransferEngine.copy(
            from: src,
            to: dst,
            items: [CopyItem((await src.stat('/p/d'))!)],
            destDir: '/t',
          ),
        );
        expect(t.status, TaskStatus.failed);
        expect(t.error, contains('bad.txt'));
        expect(dst.text('/t/d/good.txt'), 'good');
        expect(dst.text('/t/d/also.txt'), 'also');
        expect(
          dst.exists('/t/d/bad.txt'),
          isFalse,
          reason: 'no truncated leftovers',
        );
      },
    );

    test('links to folders are skipped with a warning', () async {
      final src = FakeFs(const PosixPathStyle())
        ..addFile('/p/d/f.txt', 'f')
        ..addLink('/p/d/loop', toDirectory: true);
      final dst = FakeFs(const PosixPathStyle())..addDir('/t');
      final t = await run(
        q,
        TransferEngine.copy(
          from: src,
          to: dst,
          items: [CopyItem((await src.stat('/p/d'))!)],
          destDir: '/t',
        ),
      );
      expect(t.status, TaskStatus.completed, reason: t.error);
      expect(dst.exists('/t/d/loop'), isFalse);
      expect(t.warnings.single, contains('Skipped 1 link'));
    });

    test('a broken file link is a warning, not a failed transfer', () async {
      final src = FakeFs(const PosixPathStyle())
        ..addFile('/p/d/f.txt', 'f')
        ..addLink('/p/d/dangling');
      final dst = FakeFs(const PosixPathStyle())..addDir('/t');
      final t = await run(
        q,
        TransferEngine.copy(
          from: src,
          to: dst,
          items: [CopyItem((await src.stat('/p/d'))!)],
          destDir: '/t',
        ),
      );
      expect(t.status, TaskStatus.completed, reason: t.error);
      expect(dst.text('/t/d/f.txt'), 'f');
      expect(dst.exists('/t/d/dangling'), isFalse);
      expect(t.warnings.single, contains('dangling'));
    });

    test(
      'cancelling mid-file stops reading and removes the partial file',
      () async {
        final big = List.filled(400, 'x').join();
        final src = FakeFs(const PosixPathStyle(), chunk: 4)
          ..addFile('/p/big.bin', big);
        final dst = FakeFs(const PosixPathStyle())..addDir('/t');
        late TransferTask task;
        var chunks = 0;
        src.onChunk = (path, offset) async {
          chunks++;
          if (chunks == 5) q.cancel(task.id);
        };
        task = q.enqueue(
          kind: TaskKind.upload,
          title: 'big',
          subtitle: '',
          runner: TransferEngine.copy(
            from: src,
            to: dst,
            items: [CopyItem((await src.stat('/p/big.bin'))!)],
            destDir: '/t',
          ),
        );
        while (task.status.isActive) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(task.status, TaskStatus.cancelled);
        expect(
          chunks,
          lessThan(20),
          reason: 'reading must stop soon after cancel',
        );
        expect(dst.exists('/t/big.bin'), isFalse);
      },
    );

    test('bytes stream in chunks, never as one buffer', () async {
      final content = List.generate(
        1000,
        (i) => String.fromCharCode(97 + i % 26),
      ).join();
      final src = FakeFs(const PosixPathStyle(), chunk: 16)
        ..addFile('/p/f', content);
      final dst = FakeFs(const PosixPathStyle())..addDir('/t');
      var maxChunk = 0;
      final stream = src.read('/p/f');
      await for (final c in stream) {
        if (c.length > maxChunk) maxChunk = c.length;
      }
      expect(maxChunk, 16);
      final t = await run(
        q,
        TransferEngine.copy(
          from: src,
          to: dst,
          items: [CopyItem((await src.stat('/p/f'))!)],
          destDir: '/t',
        ),
      );
      expect(t.status, TaskStatus.completed);
      expect(dst.text('/t/f'), content);
    });

    test('parallel workers copy many small files correctly', () async {
      final src = FakeFs(const PosixPathStyle());
      for (var i = 0; i < 40; i++) {
        src.addFile('/p/d/f$i.txt', 'content $i');
      }
      final dst = FakeFs(const PosixPathStyle())..addDir('/t');
      final t = await run(
        q,
        TransferEngine.copy(
          from: src,
          to: dst,
          items: [CopyItem((await src.stat('/p/d'))!)],
          destDir: '/t',
        ),
      );
      expect(t.status, TaskStatus.completed, reason: t.error);
      for (var i = 0; i < 40; i++) {
        expect(dst.text('/t/d/f$i.txt'), 'content $i');
      }
      expect(t.filesDone, 40);
    });
  });

  group('delete', () {
    test(
      'removes folders bottom-up and links without following them',
      () async {
        final fs = FakeFs(const PosixPathStyle())
          ..addFile('/d/a.txt', 'a')
          ..addFile('/d/sub/b.txt', 'b')
          ..addLink('/d/link')
          ..addFile('/keep.txt', 'k');
        final item = (await fs.stat('/d'))!;
        final t = await run(
          q,
          TransferEngine.delete(fs: fs, items: [item]),
          kind: TaskKind.delete,
        );
        expect(t.status, TaskStatus.completed, reason: t.error);
        expect(fs.exists('/d'), isFalse);
        expect(fs.exists('/keep.txt'), isTrue);
        // Every rmdir came after the files in it.
        final log = fs.log;
        expect(
          log.indexOf('rm /d/sub/b.txt'),
          lessThan(log.indexOf('rmdir /d/sub')),
        );
        expect(log.indexOf('rmdir /d/sub'), lessThan(log.indexOf('rmdir /d')));
        expect(log, contains('rm /d/link'));
      },
    );

    test('an error stops the delete and is reported', () async {
      final fs = FakeFs(const PosixPathStyle())..addFile('/d/a.txt', 'a');
      final item = FsEntry(name: 'ghost', path: '/ghost', kind: FsKind.file);
      final t = await run(
        q,
        TransferEngine.delete(fs: fs, items: [item]),
        kind: TaskKind.delete,
      );
      expect(t.status, TaskStatus.failed);
      expect(t.error, contains('missing'));
    });
  });

  group('uniqueName', () {
    test('adds a counter before the extension', () {
      expect(uniqueName('a.txt', (n) => n == 'a.txt'), 'a (1).txt');
      expect(
        uniqueName('a.txt', (n) => n == 'a.txt' || n == 'a (1).txt'),
        'a (2).txt',
      );
      expect(uniqueName('a.txt', (n) => false), 'a.txt');
    });

    test('folders and dotfiles keep their dots', () {
      expect(
        uniqueName('v1.2', (n) => n == 'v1.2', isDirectory: true),
        'v1.2 (1)',
      );
      expect(uniqueName('.bashrc', (n) => n == '.bashrc'), '.bashrc (1)');
      expect(
        uniqueName('archive.tar.gz', (n) => n == 'archive.tar.gz'),
        'archive.tar (1).gz',
      );
    });
  });

  test('utf8 content survives the byte pipeline', () async {
    final text = 'héllo wörld \u2192 日本語';
    final src = FakeFs(const PosixPathStyle(), chunk: 3)
      ..addFile('/f', utf8.encode(text));
    final dst = FakeFs(const PosixPathStyle())..addDir('/t');
    final t = await run(
      q,
      TransferEngine.copy(
        from: src,
        to: dst,
        items: [CopyItem((await src.stat('/f'))!)],
        destDir: '/t',
      ),
    );
    expect(t.status, TaskStatus.completed);
    expect(utf8.decode(dst.data('/t/f')), text);
  });
}
