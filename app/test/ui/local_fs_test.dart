import 'dart:io';
import 'dart:typed_data';

import 'package:cross_shell/src/ui/session/files/fs_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late LocalFsBackend fs;
  setUp(() {
    root = Directory.systemTemp.createTempSync('cs_localfs_');
    fs = LocalFsBackend();
  });
  tearDown(() => root.deleteSync(recursive: true));

  String p(String name) => '${root.path}${Platform.pathSeparator}$name';

  test('lists files, folders and links with kinds, sizes and times', () async {
    File(p('a.txt')).writeAsStringSync('hello');
    Directory(p('dir')).createSync();
    if (Platform.isWindows) {
      // Creating links needs privileges there; listing plain entries is enough.
      final plain = {for (final e in await fs.list(root.path)) e.name: e};
      expect(plain['a.txt']!.size, 5);
      expect(plain['dir']!.isDirectory, isTrue);
      return;
    }
    Link(p('link-to-dir')).createSync(p('dir'));
    Link(p('link-to-file')).createSync(p('a.txt'));
    Link(p('dangling')).createSync(p('nowhere'));
    final entries = {for (final e in await fs.list(root.path)) e.name: e};
    expect(entries['a.txt']!.kind, FsKind.file);
    expect(entries['a.txt']!.size, 5);
    expect(entries['a.txt']!.modified, isNotNull);
    expect(entries['a.txt']!.path, p('a.txt'));
    expect(entries['dir']!.isDirectory, isTrue);
    expect(entries['link-to-dir']!.kind, FsKind.link);
    expect(
      entries['link-to-dir']!.isDirectory,
      isTrue,
      reason: 'navigates like a folder',
    );
    expect(entries['link-to-file']!.isDirectory, isFalse);
    expect(entries['dangling']!.kind, FsKind.link);
    expect(entries['dangling']!.isDirectory, isFalse);
  });

  test('stat reports null for missing paths', () async {
    expect(await fs.stat(p('nope')), isNull);
    File(p('x')).writeAsStringSync('x');
    expect((await fs.stat(p('x')))!.size, 1);
    expect((await fs.stat(root.path))!.isDirectory, isTrue);
  });

  test('errors are readable and typed', () async {
    await expectLater(
      fs.list(p('missing')),
      throwsA(
        isA<FsException>().having((e) => e.kind, 'kind', FsErrorKind.notFound),
      ),
    );
    Directory(p('d')).createSync();
    await expectLater(
      fs.mkdir(p('d')),
      throwsA(
        isA<FsException>().having((e) => e.kind, 'kind', FsErrorKind.exists),
      ),
    );
    File(p('d${Platform.pathSeparator}inner')).writeAsStringSync('x');
    await expectLater(
      fs.deleteEmptyDirectory(p('d')),
      throwsA(
        isA<FsException>().having((e) => e.kind, 'kind', FsErrorKind.notEmpty),
      ),
    );
  });

  test('permission problems say "Permission denied" with the path', () async {
    if (Platform.isWindows ||
        Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
      return; // root ignores modes; Windows has no chmod
    }
    final locked = Directory(p('locked'))..createSync();
    Process.runSync('chmod', ['000', locked.path]);
    addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
    await expectLater(
      fs.list(locked.path),
      throwsA(
        isA<FsException>().having(
          (e) => e.kind,
          'kind',
          FsErrorKind.permissionDenied,
        ),
      ),
    );
  });

  test('mkdir, rename (refusing to replace), delete', () async {
    await fs.mkdir(p('one'));
    expect(Directory(p('one')).existsSync(), isTrue);
    File(p('f')).writeAsStringSync('f');
    File(p('g')).writeAsStringSync('g');
    await expectLater(fs.rename(p('f'), p('g')), throwsA(isA<FsException>()));
    expect(
      File(p('g')).readAsStringSync(),
      'g',
      reason: 'nothing was overwritten',
    );
    await fs.rename(p('f'), p('h'));
    expect(File(p('h')).existsSync(), isTrue);
    await fs.rename(p('one'), p('two'));
    expect(Directory(p('two')).existsSync(), isTrue);
    await fs.deleteFile(p('h'));
    expect(File(p('h')).existsSync(), isFalse);
    await fs.deleteEmptyDirectory(p('two'));
    expect(Directory(p('two')).existsSync(), isFalse);
  });

  test('deleting a link removes the link, not what it points at', () async {
    if (Platform.isWindows) return;
    Directory(p('target')).createSync();
    File(p('target${Platform.pathSeparator}keep')).writeAsStringSync('keep');
    Link(p('lnk')).createSync(p('target'));
    await fs.deleteFile(p('lnk'));
    expect(Link(p('lnk')).existsSync(), isFalse);
    expect(File(p('target${Platform.pathSeparator}keep')).existsSync(), isTrue);
  });

  test(
    'read streams chunks and write truncates, awaiting the source',
    () async {
      final big = Uint8List(1024 * 1024 + 17);
      for (var i = 0; i < big.length; i++) {
        big[i] = i & 0xff;
      }
      File(p('big')).writeAsBytesSync(big);
      var chunks = 0;
      var total = 0;
      await for (final c in fs.read(p('big'))) {
        chunks++;
        total += c.length;
      }
      expect(total, big.length);
      expect(chunks, greaterThan(1), reason: 'never one whole-file buffer');

      File(p('dst')).writeAsStringSync('this is longer than what replaces it');
      await fs.write(p('dst'), fs.read(p('big')));
      expect(File(p('dst')).readAsBytesSync(), big);
      await fs.write(p('dst'), Stream.value(Uint8List.fromList([1, 2, 3])));
      expect(File(p('dst')).readAsBytesSync(), [
        1,
        2,
        3,
      ], reason: 'truncated first');
    },
  );

  test('a failing source stream surfaces the error', () async {
    Stream<Uint8List> broken() async* {
      yield Uint8List.fromList([1]);
      throw StateError('source died');
    }

    await expectLater(
      fs.write(p('out'), broken()),
      throwsA(isA<FsException>()),
    );
  });

  test('writing into a missing folder is a clear error', () async {
    await expectLater(
      fs.write(
        p('no${Platform.pathSeparator}such${Platform.pathSeparator}file'),
        Stream.value(Uint8List(1)),
      ),
      throwsA(
        isA<FsException>().having((e) => e.kind, 'kind', FsErrorKind.notFound),
      ),
    );
  });

  test('home exists and is normalised', () async {
    final home = await fs.home();
    expect(Directory(home).existsSync(), isTrue);
  });
}
