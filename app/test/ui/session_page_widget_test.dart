import 'dart:io';

import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:cross_shell/src/ui/session/session_controller.dart';
import 'package:cross_shell/src/ui/session/session_page.dart';
import 'package:cross_shell/src/ui/session/terminal/terminal_shell.dart';
import 'package:cross_shell/src/ui/theme.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_fs.dart';
import 'helpers/fake_session.dart';

/// A shell that is "running" at once, so nothing animates forever.
class _TestShell extends TerminalShell {
  _TestShell(int number) : super(number: number);

  @override
  Future<void> start(SSHClient client) async =>
      debugSetState(ShellState.running);
}

class _Page {
  _Page(
    this.tester, {
    FakeSession? session,
    this.initialTab = SessionTab.terminal,
  }) : session = session ?? FakeSession();

  final WidgetTester tester;
  final FakeSession session;
  final SessionTab initialTab;
  final List<String> events = [];
  final List<TerminalShell> shells = [];
  late final Directory support;

  Future<void> pump({
    bool withActions = true,
    Future<SSHClient> Function()? connect,
    Size size = const Size(3000, 800),
    SessionTestHooks? hooks,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    support = Directory.systemTemp.createTempSync('cs_page_');
    addTearDown(() => support.deleteSync(recursive: true));
    final remote = FakeFs(const SftpWindowsPathStyle(), home: '/C:/Users/dhiva')
      ..addDir('/C:/Users/dhiva/Documents')
      ..addFile('/C:/Users/dhiva/a.txt', 'a');
    final local = FakeFs(const PosixPathStyle(), home: '/home/me')
      ..addFile('/home/me/x.txt', 'x');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: SessionPage(
          peerId: 'peer-1',
          title: 'lenovo',
          os: RemoteOs.windows,
          connect: connect ?? () async => throw StateError('unused'),
          initialTab: initialTab,
          supportDirectory: () async => support,
          onRemoteDesktop: withActions ? () => events.add('desktop') : null,
          onOpenSystemTerminal: withActions
              ? () => events.add('terminal')
              : null,
          onOpenVsCode: withActions ? (path) => events.add('code:$path') : null,
          testHooks:
              hooks ??
              SessionTestHooks(
                session: () => session,
                shellFactory: (n) {
                  final s = _TestShell(n);
                  shells.add(s);
                  return s;
                },
                localBackend: local,
                remoteBackendOpener: () async => remote,
              ),
        ),
      ),
    );
    await tester.pump();
    // The forwards manager reads its presets from real disk, which only
    // advances outside the fake-async zone.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> chord(
    LogicalKeyboardKey key, {
    bool ctrl = false,
    bool shift = false,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets(
    'shows the peer, status and the optional actions, which call back',
    (tester) async {
      final p = _Page(tester);
      await p.pump();
      expect(find.text('lenovo'), findsWidgets);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Forwards'), findsOneWidget);
      await tester.tap(find.text('Remote desktop'));
      await tester.tap(find.text('Open in system terminal'));
      expect(p.events, ['desktop', 'terminal']);
    },
  );

  testWidgets('actions are absent when the caller does not provide them', (
    tester,
  ) async {
    final p = _Page(tester);
    await p.pump(withActions: false);
    expect(find.text('Remote desktop'), findsNothing);
    expect(find.text('Open in system terminal'), findsNothing);
    expect(find.text('Open in VS Code'), findsNothing);
  });

  testWidgets('narrow windows fold the actions into a menu', (tester) async {
    final p = _Page(tester);
    await p.pump(size: const Size(700, 700));
    expect(find.text('Remote desktop'), findsNothing);
    await tester.tap(find.byTooltip('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('Remote desktop'), findsOneWidget);
    await tester.tap(find.text('Remote desktop'));
    await tester.pumpAndSettle();
    expect(p.events, ['desktop']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Ctrl+1/2/3 switch page tabs; the files and forwards views appear',
    (tester) async {
      final p = _Page(tester);
      await p.pump();
      expect(find.text('Port forwards'), findsNothing);
      await p.chord(LogicalKeyboardKey.digit3, ctrl: true);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Port forwards'), findsOneWidget);
      await p.chord(LogicalKeyboardKey.digit2, ctrl: true);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('This computer'), findsOneWidget);
      expect(find.text('Drives'), findsOneWidget);
      await p.chord(LogicalKeyboardKey.digit1, ctrl: true);
      expect(find.text('Terminal 1'), findsOneWidget);
    },
  );

  testWidgets(
    'Ctrl+Shift+T opens a new terminal from any page tab; Ctrl+Shift+W closes it',
    (tester) async {
      final p = _Page(tester);
      await p.pump();
      expect(
        p.shells.length,
        1,
        reason: 'the first shell opens when connected',
      );
      await p.chord(LogicalKeyboardKey.digit2, ctrl: true);
      await tester.pump(const Duration(milliseconds: 200));
      await p.chord(LogicalKeyboardKey.keyT, ctrl: true, shift: true);
      expect(p.shells.length, 2);
      expect(find.text('Terminal 2'), findsOneWidget);
      await p.chord(LogicalKeyboardKey.keyW, ctrl: true, shift: true);
      expect(find.text('Terminal 2'), findsNothing);
      expect(find.text('Terminal 1'), findsOneWidget);
    },
  );

  testWidgets(
    'Open in VS Code hands over the folder the file manager is showing',
    (tester) async {
      final p = _Page(tester);
      await p.pump();
      await p.chord(LogicalKeyboardKey.digit2, ctrl: true);
      await tester.pump(const Duration(milliseconds: 300));
      // Navigate the peer pane into Documents.
      final panes = find.byType(Scrollbar);
      await tester.tap(
        find.descendant(of: panes.last, matching: find.text('Documents')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(
        find.descendant(of: panes.last, matching: find.text('Documents')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Open in VS Code'));
      await tester.pump();
      expect(p.events, ['code:/C:/Users/dhiva/Documents']);
    },
  );

  testWidgets(
    'a lost connection shows a banner with Reconnect; terminals mark themselves dropped',
    (tester) async {
      final p = _Page(tester);
      await p.pump();
      p.session.set(ConnectionPhase.lost, 'Connection reset by peer');
      await tester.pump();
      expect(find.textContaining('Connection reset by peer'), findsWidgets);
      expect(find.text('Disconnected'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Reconnect').first);
      expect(p.session.reconnects, 1);

      p.session.set(ConnectionPhase.connecting);
      await tester.pump();
      expect(find.textContaining('Reconnecting to lenovo'), findsOneWidget);

      p.session.set(ConnectionPhase.failed, 'No route to host');
      await tester.pump();
      expect(find.textContaining('No route to host'), findsWidgets);
      expect(find.text('Try again'), findsWidgets);
    },
  );

  testWidgets('first connect: spinner, then the real error with Try again', (
    tester,
  ) async {
    var attempts = 0;
    final p = _Page(tester);
    await p.pump(
      connect: () async {
        attempts++;
        throw SSHSocketError('Connection refused');
      },
      hooks: const SessionTestHooks(),
    );
    // The real controller is used here (no session hook), so the failure
    // is the one connect() threw.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Could not connect to lenovo'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsOneWidget);
    expect(attempts, 1);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(attempts, 2);
  });

  testWidgets('initialTab opens straight on that page', (tester) async {
    final p = _Page(tester, initialTab: SessionTab.forwards);
    await p.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Port forwards'), findsOneWidget);
  });

  testWidgets('auth failures are explained in words', (tester) async {
    expect(
      describeConnectionError(SSHAuthFailError('denied')),
      contains('rejected this machine'),
    );
    expect(
      describeConnectionError(SSHHostkeyError('mismatch')),
      contains('host key'),
    );
  });
}
