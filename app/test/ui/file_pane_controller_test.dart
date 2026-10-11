import 'package:cross_shell/src/ui/session/files/file_pane_controller.dart';
import 'package:cross_shell/src/ui/session/files/fs_backend.dart';
import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_fs.dart';

FakeFs windowsFs() => FakeFs(const SftpWindowsPathStyle())
  ..addDir('/C:/Users/alex/Documents')
  ..addFile('/C:/Users/alex/notes.txt', 'n')
  ..addFile('/C:/Users/alex/file10.txt', '10')
  ..addFile('/C:/Users/alex/file2.txt', '2')
  ..addFile('/C:/Users/alex/.npmrc.json', '{}')
  ..addDir('/C:/Users/alex/AppData')
  ..addDir('/D:/data');

void main() {
  test('lists the drives at the root and walks into a drive', () async {
    final pane = FilePaneController(backend: windowsFs(), initialPath: '/');
    await pane.init();
    expect(pane.cwd, '/');
    expect(pane.visible.map((e) => e.name), ['C:', 'D:']);
    expect(pane.canGoUp, isFalse);

    await pane.open(pane.visible.first);
    expect(pane.cwd, '/C:/');
    expect(pane.visible.map((e) => e.name), ['Users']);
    expect(pane.canGoUp, isTrue);
    await pane.goUp();
    expect(pane.cwd, '/');
  });

  test('navigating through Windows paths and back/forward history', () async {
    final pane = FilePaneController(
      backend: windowsFs(),
      initialPath: '/C:/Users/alex',
    );
    await pane.init();
    expect(pane.cwd, '/C:/Users/alex');
    await pane.navigate('/C:/Users/alex/Documents');
    expect(pane.cwd, '/C:/Users/alex/Documents');
    await pane.goUp();
    expect(pane.cwd, '/C:/Users/alex');
    await pane.goUp();
    await pane.goUp();
    expect(pane.cwd, '/C:/');
    await pane.goUp();
    expect(pane.cwd, '/');
    await pane.goBack();
    expect(pane.cwd, '/C:/');
    await pane.goForward();
    expect(pane.cwd, '/');
  });

  test(
    'typed Windows paths with backslashes resolve through the style',
    () async {
      final fs = windowsFs();
      final pane = FilePaneController(
        backend: fs,
        initialPath: '/C:/Users/alex',
      );
      await pane.init();
      final target = fs.style.resolveInput(r'D:\data', pane.cwd);
      await pane.navigate(target);
      expect(pane.cwd, '/D:/data');
    },
  );

  test(
    'a failed navigation keeps the old folder and reports the error',
    () async {
      final pane = FilePaneController(
        backend: windowsFs(),
        initialPath: '/C:/Users/alex',
      );
      await pane.init();
      await pane.navigate('/C:/nowhere');
      expect(pane.cwd, '/C:/Users/alex');
      expect(pane.error, contains('does not exist'));
      expect(pane.visible, isNotEmpty);
      await pane.refresh();
      expect(pane.error, isNull);
    },
  );

  test('hidden files follow the toggle; Windows heuristics apply', () async {
    final pane = FilePaneController(
      backend: windowsFs(),
      initialPath: '/C:/Users/alex',
    );
    await pane.init();
    expect(pane.visible.map((e) => e.name), isNot(contains('.npmrc.json')));
    expect(pane.visible.map((e) => e.name), isNot(contains('AppData')));
    expect(pane.hiddenCount, 2);
    pane.toggleHidden();
    expect(
      pane.visible.map((e) => e.name),
      containsAll(['.npmrc.json', 'AppData']),
    );
  });

  test('folders sort first and names sort naturally', () async {
    final pane = FilePaneController(
      backend: windowsFs(),
      initialPath: '/C:/Users/alex',
    );
    await pane.init();
    expect(pane.visible.map((e) => e.name), [
      'Documents',
      'file2.txt',
      'file10.txt',
      'notes.txt',
    ]);
    pane.setSort(SortColumn.name); // toggles to descending
    expect(pane.visible.map((e) => e.name), [
      'Documents',
      'notes.txt',
      'file10.txt',
      'file2.txt',
    ]);
  });

  test('sort by size and modified keeps folders on top', () {
    final e = [
      const FsEntry(name: 'big', path: '/big', kind: FsKind.file, size: 900),
      const FsEntry(name: 'dir', path: '/dir', kind: FsKind.directory),
      const FsEntry(name: 'small', path: '/small', kind: FsKind.file, size: 5),
    ];
    expect(sortEntries(e, SortColumn.size, true).map((x) => x.name), [
      'dir',
      'small',
      'big',
    ]);
    expect(sortEntries(e, SortColumn.size, false).map((x) => x.name), [
      'dir',
      'big',
      'small',
    ]);
  });

  group('selection', () {
    late FilePaneController pane;
    setUp(() async {
      pane = FilePaneController(
        backend: windowsFs(),
        initialPath: '/C:/Users/alex',
      );
      await pane.init();
    });

    test('click, toggle, range, select all, clear', () {
      final names = pane.visible.map((e) => e.path).toList();
      pane.selectOnly(names[1]);
      expect(pane.selection, {names[1]});
      pane.toggle(names[3]);
      expect(pane.selection, {names[1], names[3]});
      pane.selectOnly(names[0]);
      pane.selectRange(names[2]);
      expect(pane.selection, {names[0], names[1], names[2]});
      pane.selectAll();
      expect(pane.selection.length, names.length);
      pane.clearSelection();
      expect(pane.selection, isEmpty);
    });

    test('cursor movement clamps and extends', () {
      pane.moveCursor(1);
      expect(pane.visible[pane.indexOfCursor()].name, 'Documents');
      pane.moveCursor(1, extend: true);
      expect(pane.selection.length, 2);
      pane.moveCursor(-50);
      expect(pane.indexOfCursor(), 0);
      pane.moveCursor(50);
      expect(pane.indexOfCursor(), pane.visible.length - 1);
    });

    test('type-ahead jumps to the first match', () {
      expect(pane.jumpToPrefix('no'), isTrue);
      expect(pane.selectedEntries.single.name, 'notes.txt');
      expect(pane.jumpToPrefix('zzz'), isFalse);
    });

    test('navigating clears the selection', () async {
      pane.selectAll();
      await pane.navigate('/C:/Users');
      expect(pane.selection, isEmpty);
    });
  });

  group('mutations', () {
    test(
      'make directory validates, refuses duplicates and selects the new folder',
      () async {
        final pane = FilePaneController(
          backend: windowsFs(),
          initialPath: '/C:/Users/alex',
        );
        await pane.init();
        await pane.makeDirectory('Projects');
        expect(pane.cwd, '/C:/Users/alex');
        expect(pane.selectedEntries.single.name, 'Projects');
        expect(
          () => pane.makeDirectory('projects'),
          throwsA(isA<FsException>()),
          reason: 'Windows names are case-insensitive',
        );
        expect(() => pane.makeDirectory('a:b'), throwsA(isA<FsException>()));
        expect(() => pane.makeDirectory(''), throwsA(isA<FsException>()));
      },
    );

    test(
      'rename refuses a taken name but allows a case-only change on Windows',
      () async {
        final fs = windowsFs();
        final pane = FilePaneController(
          backend: fs,
          initialPath: '/C:/Users/alex',
        );
        await pane.init();
        final notes = pane.visible.firstWhere((e) => e.name == 'notes.txt');
        await expectLater(
          pane.renameEntry(notes, 'file2.txt'),
          throwsA(isA<FsException>()),
        );
        await pane.renameEntry(notes, 'Notes.txt');
        expect(fs.exists('/C:/Users/alex/Notes.txt'), isTrue);
        final renamed = pane.visible.firstWhere((e) => e.name == 'Notes.txt');
        await pane.renameEntry(renamed, 'journal.txt');
        expect(pane.selectedEntries.single.name, 'journal.txt');
      },
    );

    test('POSIX names are case-sensitive', () async {
      final fs = FakeFs(const PosixPathStyle())..addFile('/a/File', 'x');
      final pane = FilePaneController(backend: fs, initialPath: '/a');
      await pane.init();
      await pane.makeDirectory('file');
      expect(fs.exists('/a/file'), isTrue);
    });
  });

  test('rebind after a reconnect reloads the same folder', () async {
    final first = windowsFs();
    final pane = FilePaneController(
      backend: first,
      initialPath: '/C:/Users/alex',
    );
    await pane.init();
    final second = windowsFs()..addFile('/C:/Users/alex/new.txt', 'x');
    await pane.rebind(second);
    expect(pane.cwd, '/C:/Users/alex');
    expect(pane.visible.map((e) => e.name), contains('new.txt'));
  });

  test('a stale listing never overwrites a newer navigation', () async {
    final fs = windowsFs();
    final pane = FilePaneController(
      backend: fs,
      initialPath: '/C:/Users/alex',
    );
    await pane.init();
    final slow = pane.navigate('/C:/Users');
    final fast = pane.navigate('/D:/data');
    await Future.wait([slow, fast]);
    expect(pane.cwd, '/D:/data');
  });
}
