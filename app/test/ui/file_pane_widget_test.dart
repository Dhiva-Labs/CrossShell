import 'package:cross_shell/src/ui/session/files/file_pane.dart';
import 'package:cross_shell/src/ui/session/files/file_pane_controller.dart';
import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:cross_shell/src/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_fs.dart';

FakeFs windowsPeer() =>
    FakeFs(const SftpWindowsPathStyle(), home: '/C:/Users/alex')
      ..addDir('/C:/Users/alex/Documents')
      ..addDir('/C:/Users/alex/Projects')
      ..addFile('/C:/Users/alex/notes.txt', 'n' * 1500)
      ..addFile('/C:/Users/alex/readme.md', 'hello')
      ..addFile('/C:/Users/alex/file2.txt', '2')
      ..addFile('/C:/Users/alex/file10.txt', '10')
      ..addFile('/C:/Users/alex/.hidden', 'x')
      ..addDir('/D:/data');

class _Calls {
  final transfers = <List<String>>[];
  final drops = <(List<String>, String)>[];
  final deletes = <List<String>>[];
  final copies = <List<String>>[];
  int pastes = 0;
  int switches = 0;
  int activations = 0;
}

class _PaneHarness {
  _PaneHarness(this.tester, this.fs);
  final WidgetTester tester;
  final FakeFs fs;
  final String title = 'peer';
  final String? initial = null;
  final _Calls calls = _Calls();
  late FilePaneController controller;
  final FocusNode focus = FocusNode();

  Widget pane(
    FilePaneController c,
    FocusNode f,
    _Calls k, {
    String label = 'Upload',
  }) => FilePane(
    controller: c,
    focusNode: f,
    title: title,
    icon: Icons.dns_outlined,
    active: true,
    transferLabel: label,
    onActivate: () => k.activations++,
    onTransfer: (e) => k.transfers.add(e.map((x) => x.name).toList()),
    onDropped: (p, dir) =>
        k.drops.add((p.entries.map((x) => x.name).toList(), dir)),
    onDelete: (e) => k.deletes.add(e.map((x) => x.name).toList()),
    onCopy: (e) => k.copies.add(e.map((x) => x.name).toList()),
    onPaste: () => k.pastes++,
    onSwitchPane: () => k.switches++,
  );

  Future<void> pump({Size size = const Size(700, 600)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    controller = FilePaneController(backend: fs, initialPath: initial);
    await controller.init();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: pane(controller, focus, calls),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> key(
    LogicalKeyboardKey k, {
    bool ctrl = false,
    bool shift = false,
    bool alt = false,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(k);
    await tester.sendKeyUpEvent(k);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Future<void> clickRow(
    String name, {
    bool ctrl = false,
    bool shift = false,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text(name));
    await tester.pump(
      const Duration(milliseconds: 500),
    ); // outside the double-click window
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  List<String> get names => controller.visible.map((e) => e.name).toList();
  List<String> get selected =>
      controller.selectedEntries.map((e) => e.name).toList();
}

void main() {
  testWidgets(
    'shows the peer\'s folder with sizes, folders first, hidden files off',
    (tester) async {
      final h = _PaneHarness(tester, windowsPeer());
      await h.pump();
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('.hidden'), findsNothing);
      expect(find.text('1.5 KB'), findsOneWidget);
      expect(find.text('2026-10-11 12:30'), findsWidgets);
      expect(h.names.take(2), ['Documents', 'Projects']);
      expect(
        find.textContaining('hidden'),
        findsOneWidget,
        reason: 'the footer counts hidden files',
      );
      // Breadcrumbs show the Windows SFTP path.
      expect(find.text('Drives'), findsOneWidget);
      expect(find.text('C:'), findsOneWidget);
      expect(find.text('Users'), findsOneWidget);
      expect(find.text('alex'), findsOneWidget);
    },
  );

  testWidgets('click, ctrl+click and shift+click select', (tester) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await h.clickRow('notes.txt');
    expect(h.selected, ['notes.txt']);
    await h.clickRow('readme.md', ctrl: true);
    expect(h.selected.toSet(), {'notes.txt', 'readme.md'});
    await h.clickRow('Documents');
    await h.clickRow('file2.txt', shift: true);
    expect(h.selected, ['Documents', 'Projects', 'file2.txt']);
    expect(h.calls.activations, greaterThan(0));
  });

  testWidgets('double-click opens a folder, single click on a file does not', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.controller.cwd, '/C:/Users/alex');

    await tester.tap(find.text('Documents'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(h.controller.cwd, '/C:/Users/alex/Documents');
    expect(find.text('Empty folder'), findsOneWidget);
  });

  testWidgets('keyboard: arrows, Enter, Backspace, Home/End, type-ahead', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await tester.tap(find.text('Documents'));
    await tester.pump(const Duration(milliseconds: 500));
    await h.key(LogicalKeyboardKey.arrowDown);
    expect(h.selected, ['Projects']);
    await h.key(LogicalKeyboardKey.arrowDown, shift: true);
    expect(h.selected, ['Projects', 'file2.txt']);
    await h.key(LogicalKeyboardKey.end);
    expect(h.selected, ['readme.md']);
    await h.key(LogicalKeyboardKey.home);
    expect(h.selected, ['Documents']);

    await h.key(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.controller.cwd, '/C:/Users/alex/Documents');
    await h.key(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(h.controller.cwd, '/C:/Users/alex');

    await h.key(LogicalKeyboardKey.keyR);
    expect(h.selected, [
      'readme.md',
    ], reason: 'typing jumps to a matching name');
  });

  testWidgets('Alt+Up goes up through the drive list; Alt+Left goes back', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 500));
    for (final expected in ['/C:/Users', '/C:/', '/']) {
      await h.key(LogicalKeyboardKey.arrowUp, alt: true);
      await tester.pumpAndSettle();
      expect(h.controller.cwd, expected);
    }
    expect(find.text('C:'), findsWidgets);
    expect(find.text('D:'), findsWidgets);
    await h.key(LogicalKeyboardKey.arrowLeft, alt: true);
    await tester.pumpAndSettle();
    expect(h.controller.cwd, '/C:/');
  });

  testWidgets('Ctrl+A, Delete, Ctrl+C, Ctrl+V, Tab call out', (tester) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 500));
    await h.key(LogicalKeyboardKey.keyA, ctrl: true);
    expect(h.controller.selection.length, h.controller.visible.length);
    await h.key(LogicalKeyboardKey.delete);
    expect(h.calls.deletes.single.length, h.controller.visible.length);
    await h.key(LogicalKeyboardKey.keyC, ctrl: true);
    expect(h.calls.copies.length, 1);
    await h.key(LogicalKeyboardKey.keyV, ctrl: true);
    expect(h.calls.pastes, 1);
    await h.key(LogicalKeyboardKey.tab);
    expect(h.calls.switches, 1);
    await h.key(LogicalKeyboardKey.escape);
    expect(h.controller.selection, isEmpty);
  });

  testWidgets('F2 renames through a dialog, refusing a taken name', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await h.clickRow('readme.md');
    await h.key(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsWidgets);
    // Windows rejects ':'
    await tester.enterText(find.byType(TextField).last, 'bad:name.md');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot contain'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'README.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(h.fs.exists('/C:/Users/alex/README.txt'), isTrue);
    expect(h.fs.exists('/C:/Users/alex/readme.md'), isFalse);
    expect(h.selected, ['README.txt']);

    // A name that already exists is reported inline, not swallowed.
    await h.key(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'notes.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already exists'), findsOneWidget);
  });

  testWidgets('F7 creates a folder and selects it', (tester) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 500));
    await h.key(LogicalKeyboardKey.f7);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'New Stuff');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(h.fs.exists('/C:/Users/alex/New Stuff'), isTrue);
    expect(h.selected, ['New Stuff']);
  });

  testWidgets('Ctrl+L edits the path; Windows paths with backslashes work', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 500));
    await h.key(LogicalKeyboardKey.keyL, ctrl: true);
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(
      (tester.widget(field) as TextField).controller!.text,
      '/C:/Users/alex',
    );
    await tester.enterText(field, r'D:\data');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.controller.cwd, '/D:/data');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'clicking a breadcrumb navigates; a bad path shows the error with Retry',
    (tester) async {
      final h = _PaneHarness(tester, windowsPeer());
      await h.pump();
      await tester.tap(find.text('Users'));
      await tester.pumpAndSettle();
      expect(h.controller.cwd, '/C:/Users');

      await h.controller.navigate('/C:/Users/nobody');
      await tester.pumpAndSettle();
      expect(find.textContaining('does not exist'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(h.controller.cwd, '/C:/Users', reason: 'stays where it was');
    },
  );

  testWidgets('header click sorts; the hidden toggle reveals dotfiles', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    expect(h.names.skip(2).first, 'file2.txt');
    await tester.tap(find.text('Name'));
    await tester.pump();
    expect(
      h.names.skip(2).first,
      'readme.md',
      reason: 'descending after a second click',
    );
    await tester.tap(find.text('Size'));
    await tester.pump();
    expect(h.controller.sortColumn, SortColumn.size);
    expect(h.names.skip(2).first, 'file2.txt', reason: 'smallest file first');

    await tester.tap(find.byTooltip('Show hidden files (Ctrl+H)'));
    await tester.pump();
    expect(find.text('.hidden'), findsOneWidget);
  });

  testWidgets('right click selects the row and offers the file actions', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    await tester.tap(find.text('notes.txt'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(h.selected, ['notes.txt']);
    expect(find.text('Upload'), findsOneWidget);
    expect(find.textContaining('Rename'), findsOneWidget);
    expect(find.textContaining('Delete'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    expect(h.calls.transfers.single, ['notes.txt']);
  });

  testWidgets('dragging a row out of one pane into another reports the drop', (
    tester,
  ) async {
    final left = FakeFs(const PosixPathStyle(), home: '/home/me')
      ..addFile('/home/me/a.txt', 'a')
      ..addFile('/home/me/b.txt', 'b')
      ..addDir('/home/me/dir');
    final right = windowsPeer();
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lc = FilePaneController(backend: left);
    final rc = FilePaneController(backend: right);
    await lc.init();
    await rc.init();
    final lcalls = _Calls();
    final rcalls = _Calls();
    final h = _PaneHarness(tester, left);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: h.pane(lc, FocusNode(), lcalls, label: 'Upload')),
              Expanded(
                child: h.pane(rc, FocusNode(), rcalls, label: 'Download'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // Select both files in the left pane, then drag one of them across.
    await tester.tap(find.text('a.txt').first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('b.txt').first);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 500));
    expect(lc.selection.length, 2);

    final drag = await tester.startGesture(
      tester.getCenter(find.text('b.txt').first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    // Drop on empty space of the right pane (below the rows).
    final rightPane = tester.getRect(find.byType(FilePane).last);
    await drag.moveTo(Offset(rightPane.center.dx, rightPane.bottom - 60));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(rcalls.drops.single.$1.toSet(), {
      'a.txt',
      'b.txt',
    }, reason: 'the whole selection travels');
    expect(rcalls.drops.single.$2, '/C:/Users/alex');
    expect(lcalls.drops, isEmpty);

    // Drop onto a folder row of the right pane: lands inside that folder.
    final drag2 = await tester.startGesture(
      tester.getCenter(find.text('dir')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag2.moveBy(const Offset(40, 0));
    await tester.pump();
    await drag2.moveTo(tester.getCenter(find.text('Projects')));
    await tester.pump();
    await drag2.up();
    await tester.pumpAndSettle();
    expect(rcalls.drops.last.$1, ['dir']);
    expect(rcalls.drops.last.$2, '/C:/Users/alex/Projects');
  });

  testWidgets('dropping a pane\'s own selection back on itself does nothing', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump();
    final drag = await tester.startGesture(
      tester.getCenter(find.text('notes.txt')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveBy(const Offset(30, 0));
    await tester.pump();
    await drag.moveTo(tester.getCenter(find.text('Projects')));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(h.calls.drops, isEmpty);
  });

  testWidgets('narrow panes drop the Modified column instead of overflowing', (
    tester,
  ) async {
    final h = _PaneHarness(tester, windowsPeer());
    await h.pump(size: const Size(380, 600));
    expect(find.text('Modified'), findsNothing);
    expect(find.text('Size'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
