import 'package:cross_shell/src/ui/session/files/files_tab.dart';
import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:cross_shell/src/ui/session/session_controller.dart';
import 'package:cross_shell/src/ui/session/session_types.dart';
import 'package:cross_shell/src/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_fs.dart';
import 'helpers/fake_session.dart';

class _ConnectedSession extends SessionController {
  _ConnectedSession()
    : super(
        connect: () async => throw StateError('unused'),
        os: RemoteOs.windows,
      );
  @override
  bool get isConnected => true;
  @override
  ConnectionPhase get phase => ConnectionPhase.connected;
  @override
  int get generation => 1;
}

class _Rig {
  _Rig(this.tester) {
    local =
        FakeFs(const PosixPathStyle(), home: '/home/me', label: 'This computer')
          ..addFile('/home/me/report.txt', 'quarterly numbers')
          ..addFile('/home/me/photo.png', 'PNGDATA')
          ..addFile('/home/me/proj/src/main.dart', 'void main() {}')
          ..addFile('/home/me/proj/README.md', '# proj')
          ..addDir('/home/me/proj/empty');
    remote =
        FakeFs(
            const SftpWindowsPathStyle(),
            home: '/C:/Users/dhiva',
            label: 'lenovo',
          )
          ..addDir('/C:/Users/dhiva/Documents')
          ..addFile('/C:/Users/dhiva/hello.txt', 'hi from windows')
          ..addFile('/C:/Users/dhiva/builds/app.exe', 'MZ....')
          ..addDir('/D:/data');
    session = _ConnectedSession();
  }

  final WidgetTester tester;
  late final FakeFs local;
  late final FakeFs remote;
  late final SessionController session;

  Future<void> pump() async {
    tester.view.physicalSize = const Size(1300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: FilesTab(
            session: session,
            peerTitle: 'lenovo',
            os: RemoteOs.windows,
            visible: true,
            localBackend: local,
            remoteBackendOpener: () async => remote,
          ),
        ),
      ),
    );
    await settle();
  }

  /// Lets queued work (fake timers, microtasks) run.
  Future<void> settle([int ticks = 60]) async {
    for (var i = 0; i < ticks; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Finder row(String name, {required bool remotePane}) {
    final panes = find.byType(Scrollbar);
    return find.descendant(
      of: remotePane ? panes.last : panes.first,
      matching: find.text(name),
    );
  }

  Future<void> click(Finder f) async {
    await tester.tap(f);
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  testWidgets(
    'both panes load: local home on the left, the Windows peer on the right',
    (tester) async {
      final r = _Rig(tester);
      await r.pump();
      expect(r.row('report.txt', remotePane: false), findsOneWidget);
      expect(r.row('proj', remotePane: false), findsOneWidget);
      expect(r.row('hello.txt', remotePane: true), findsOneWidget);
      expect(r.row('Documents', remotePane: true), findsOneWidget);
      expect(find.text('Drives'), findsOneWidget);
      expect(find.text('lenovo'), findsWidgets);
    },
  );

  testWidgets('upload button sends the selection to the peer\'s current folder', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await r.click(r.row('report.txt', remotePane: false));
    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await r.settle();
    expect(r.remote.text('/C:/Users/dhiva/report.txt'), 'quarterly numbers');
    // The finished upload shows up in the remote pane without a manual refresh.
    expect(r.row('report.txt', remotePane: true), findsOneWidget);
    expect(find.textContaining('1 transfer done'), findsOneWidget);
  });

  testWidgets('uploading a folder recreates the whole tree on the peer', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await r.click(r.row('proj', remotePane: false));
    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await r.settle();
    expect(
      r.remote.text('/C:/Users/dhiva/proj/src/main.dart'),
      'void main() {}',
    );
    expect(r.remote.text('/C:/Users/dhiva/proj/README.md'), '# proj');
    expect(r.remote.exists('/C:/Users/dhiva/proj/empty'), isTrue);
  });

  testWidgets('download button copies the peer\'s folder to the local folder', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await r.click(r.row('Documents', remotePane: true));
    await tester.tap(find.byTooltip('Download selected to this computer'));
    await r.settle();
    expect(r.local.exists('/home/me/Documents'), isTrue);

    await r.click(r.row('hello.txt', remotePane: true));
    await tester.tap(find.byTooltip('Download selected to this computer'));
    await r.settle();
    expect(r.local.text('/home/me/hello.txt'), 'hi from windows');
  });

  testWidgets(
    'drag and drop between the panes, onto a folder row, lands inside it',
    (tester) async {
      final r = _Rig(tester);
      await r.pump();
      // File from the local pane dropped on the peer's Documents folder.
      final from = tester.getCenter(r.row('photo.png', remotePane: false));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await g.moveBy(const Offset(60, 0));
      await tester.pump();
      await g.moveTo(tester.getCenter(r.row('Documents', remotePane: true)));
      await tester.pump();
      await g.up();
      await r.settle();
      expect(r.remote.text('/C:/Users/dhiva/Documents/photo.png'), 'PNGDATA');

      // And from the peer back to the local folder (empty area of the pane).
      final back = tester.getCenter(r.row('hello.txt', remotePane: true));
      final g2 = await tester.startGesture(back, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await g2.moveBy(const Offset(-60, 0));
      await tester.pump();
      final localRect = tester.getRect(find.byType(Scrollbar).first);
      await g2.moveTo(Offset(localRect.center.dx, localRect.bottom - 30));
      await tester.pump();
      await g2.up();
      await r.settle();
      expect(r.local.text('/home/me/hello.txt'), 'hi from windows');
    },
  );

  testWidgets('a name conflict asks; Keep both numbers the new copy', (
    tester,
  ) async {
    final r = _Rig(tester);
    r.remote.addFile('/C:/Users/dhiva/report.txt', 'OLD REMOTE');
    await r.pump();
    await r.click(r.row('report.txt', remotePane: false));
    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await tester.pumpAndSettle();
    expect(find.text('Already exists'), findsOneWidget);
    await tester.tap(find.text('Keep both'));
    await r.settle();
    expect(r.remote.text('/C:/Users/dhiva/report.txt'), 'OLD REMOTE');
    expect(
      r.remote.text('/C:/Users/dhiva/report (1).txt'),
      'quarterly numbers',
    );
  });

  testWidgets('Replace overwrites, Skip keeps, Cancel does nothing', (
    tester,
  ) async {
    final r = _Rig(tester);
    r.remote.addFile('/C:/Users/dhiva/report.txt', 'OLD REMOTE');
    await r.pump();
    await r.click(r.row('report.txt', remotePane: false));

    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await r.settle();
    expect(r.remote.text('/C:/Users/dhiva/report.txt'), 'OLD REMOTE');

    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await r.settle();
    expect(r.remote.text('/C:/Users/dhiva/report.txt'), 'OLD REMOTE');

    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await r.settle();
    expect(r.remote.text('/C:/Users/dhiva/report.txt'), 'quarterly numbers');
  });

  testWidgets('Ctrl+C in one pane, Tab, Ctrl+V in the other transfers', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await r.click(r.row('photo.png', remotePane: false));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.textContaining('copied'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await r.settle();
    expect(r.remote.text('/C:/Users/dhiva/photo.png'), 'PNGDATA');
  });

  testWidgets(
    'pasting into the pane the files came from is explained, not performed',
    (tester) async {
      final r = _Rig(tester);
      await r.pump();
      await r.click(r.row('photo.png', remotePane: false));
      for (final k in [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyV]) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(k);
        await tester.sendKeyUpEvent(k);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }
      expect(find.textContaining('other pane'), findsOneWidget);
      expect(r.local.log.where((l) => l.startsWith('write')), isEmpty);
    },
  );

  testWidgets(
    'delete asks first and then removes folders recursively on the peer',
    (tester) async {
      final r = _Rig(tester);
      await r.pump();
      await r.click(r.row('builds', remotePane: true));
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete "builds"?'), findsOneWidget);
      expect(find.textContaining('no undo'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r.remote.exists('/C:/Users/dhiva/builds'), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await r.settle();
      expect(r.remote.exists('/C:/Users/dhiva/builds'), isFalse);
      expect(r.remote.exists('/C:/Users/dhiva/builds/app.exe'), isFalse);
      expect(r.remote.exists('/C:/Users/dhiva/hello.txt'), isTrue);
    },
  );

  testWidgets('files cannot be dropped into the drive list', (tester) async {
    final r = _Rig(tester);
    await r.pump();
    // Navigate the peer pane up to the drive list.
    await r.click(r.row('hello.txt', remotePane: true));
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await r.settle(5);
    }
    expect(r.row('C:', remotePane: true), findsOneWidget);
    await r.click(r.row('photo.png', remotePane: false));
    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open a drive or folder first'), findsOneWidget);
  });

  testWidgets('a transfer error is shown with the real message', (
    tester,
  ) async {
    final r = _Rig(tester);
    r.local.failReads.add('/home/me/report.txt');
    await r.pump();
    await r.click(r.row('report.txt', remotePane: false));
    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await r.settle();
    expect(find.textContaining('read failed'), findsWidgets);
    expect(find.textContaining('1 transfer failed'), findsOneWidget);
    expect(r.remote.exists('/C:/Users/dhiva/report.txt'), isFalse);
  });

  testWidgets(
    'after a reconnect the peer pane rebinds and reloads the same folder',
    (tester) async {
      final session = FakeSession();
      addTearDown(session.dispose);
      final first = FakeFs(
        const SftpWindowsPathStyle(),
        home: '/C:/Users/dhiva',
      )..addFile('/C:/Users/dhiva/before.txt', 'x');
      var current = first;
      final local = FakeFs(const PosixPathStyle(), home: '/home/me')
        ..addFile('/home/me/a', 'a');
      tester.view.physicalSize = const Size(1300, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: FilesTab(
              session: session,
              peerTitle: 'lenovo',
              os: RemoteOs.windows,
              visible: true,
              localBackend: local,
              remoteBackendOpener: () async => current,
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('before.txt'), findsOneWidget);

      session.set(ConnectionPhase.lost, 'wifi dropped');
      await tester.pump();
      expect(find.textContaining('Connection to lenovo lost'), findsOneWidget);
      expect(
        find.text('before.txt'),
        findsOneWidget,
        reason: 'the last listing stays readable',
      );

      current = FakeFs(const SftpWindowsPathStyle(), home: '/C:/Users/dhiva')
        ..addFile('/C:/Users/dhiva/after.txt', 'y');
      session.reconnected();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('after.txt'), findsOneWidget);
      expect(find.text('before.txt'), findsNothing);
      expect(find.textContaining('Connection to lenovo lost'), findsNothing);
    },
  );

  testWidgets(
    'Keep both counts hidden names and the folder a file is dropped into',
    (tester) async {
      final r = _Rig(tester);
      // Dropping onto Documents, which already holds report.txt and report (1).txt.
      r.remote
        ..addFile('/C:/Users/dhiva/Documents/report.txt', 'OLD')
        ..addFile('/C:/Users/dhiva/Documents/report (1).txt', 'OLD1');
      await r.pump();
      final from = tester.getCenter(r.row('report.txt', remotePane: false));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await g.moveBy(const Offset(60, 0));
      await tester.pump();
      await g.moveTo(tester.getCenter(r.row('Documents', remotePane: true)));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('Already exists'), findsOneWidget);
      await tester.tap(find.text('Keep both'));
      await r.settle();
      expect(r.remote.text('/C:/Users/dhiva/Documents/report.txt'), 'OLD');
      expect(r.remote.text('/C:/Users/dhiva/Documents/report (1).txt'), 'OLD1');
      expect(
        r.remote.text('/C:/Users/dhiva/Documents/report (2).txt'),
        'quarterly numbers',
      );
    },
  );

  testWidgets('Keep both avoids a hidden file that is not on screen', (
    tester,
  ) async {
    final r = _Rig(tester);
    r.local.addFile('/home/me/.rc', 'new');
    r.remote
      ..addFile('/C:/Users/dhiva/.rc', 'old')
      ..addFile('/C:/Users/dhiva/.rc (1)', 'old1');
    await r.pump();
    // Show the local dotfile, select it and send it over.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await r.click(r.row('.rc', remotePane: false));
    await tester.tap(find.byTooltip('Upload selected to lenovo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep both'));
    await r.settle();
    expect(r.remote.text('/C:/Users/dhiva/.rc'), 'old');
    expect(r.remote.text('/C:/Users/dhiva/.rc (1)'), 'old1');
    expect(r.remote.text('/C:/Users/dhiva/.rc (2)'), 'new');
  });
}
