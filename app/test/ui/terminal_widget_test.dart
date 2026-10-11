import 'package:cross_shell/src/ui/session/session_controller.dart';
import 'package:cross_shell/src/ui/session/session_shortcuts.dart';
import 'package:cross_shell/src/ui/session/session_types.dart';
import 'package:cross_shell/src/ui/session/terminal/terminal_shell.dart';
import 'package:cross_shell/src/ui/session/terminal/terminal_view.dart';
import 'package:cross_shell/src/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

class _Harness {
  _Harness(this.tester) {
    session = SessionController(
      connect: () async => throw StateError('no network in tests'),
      os: RemoteOs.linux,
    );
    tabs = TerminalTabs(
      session: session,
      shellFactory: (n) => TerminalShell(number: n),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': clipboard};
        }
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
  }

  final WidgetTester tester;
  late final SessionController session;
  late final TerminalTabs tabs;
  final List<SessionShortcut> shortcuts = [];
  String? clipboard;

  /// Adds a tab whose PTY is "up" and whose keystrokes are captured.
  TerminalShell addRunningTab(List<String> sent) {
    final shell = tabs.add();
    shell.debugSetState(ShellState.running);
    shell.terminal.onOutput = sent.add;
    return shell;
  }

  Future<void> pump({bool visible = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: TerminalTabsView(
            tabs: tabs,
            visible: visible,
            onShortcut: shortcuts.add,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
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
    await tester.pump();
  }

  void dispose() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  }
}

void main() {
  testWidgets(
    'Ctrl+Shift+T and Ctrl+Shift+W reach the session; plain keys reach the shell',
    (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      final sent = <String>[];
      h.addRunningTab(sent);
      await h.pump();

      await h.chord(LogicalKeyboardKey.keyT, ctrl: true, shift: true);
      await h.chord(LogicalKeyboardKey.keyW, ctrl: true, shift: true);
      expect(h.shortcuts, [
        SessionShortcut.newTerminal,
        SessionShortcut.closeTerminal,
      ]);
      expect(sent, isEmpty, reason: 'shortcuts must not leak into the shell');

      // Plain Ctrl+C is the shell's (SIGINT, 0x03), not copy.
      await h.chord(LogicalKeyboardKey.keyC, ctrl: true);
      expect(sent, ['\x03']);
      // Plain Ctrl+V is the shell's too, not paste.
      sent.clear();
      await h.chord(LogicalKeyboardKey.keyV, ctrl: true);
      expect(sent, ['\x16']);
    },
  );

  testWidgets(
    'Ctrl+Tab and Ctrl+PageDown cycle tabs; Ctrl+1..3 switch page tabs',
    (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      h.addRunningTab([]);
      await h.pump();
      await h.chord(LogicalKeyboardKey.tab, ctrl: true);
      await h.chord(LogicalKeyboardKey.tab, ctrl: true, shift: true);
      await h.chord(LogicalKeyboardKey.digit2, ctrl: true);
      await h.chord(LogicalKeyboardKey.digit3, ctrl: true);
      expect(h.shortcuts, [
        SessionShortcut.nextTerminal,
        SessionShortcut.previousTerminal,
        SessionShortcut.showFiles,
        SessionShortcut.showForwards,
      ]);
    },
  );

  testWidgets(
    'a multi-line paste asks first; Cancel sends nothing, Paste sends all',
    (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      final sent = <String>[];
      h.addRunningTab(sent);
      await h.pump();

      h.clipboard = 'echo one\necho two';
      await h.chord(LogicalKeyboardKey.keyV, ctrl: true, shift: true);
      await tester.pumpAndSettle();
      expect(find.text('Paste 2 lines?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);

      await h.chord(LogicalKeyboardKey.keyV, ctrl: true, shift: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(sent.join(), 'echo one\necho two');
    },
  );

  testWidgets(
    'a single-line paste goes straight through, also via Shift+Insert',
    (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      final sent = <String>[];
      h.addRunningTab(sent);
      await h.pump();
      h.clipboard = 'ls -la';
      await h.chord(LogicalKeyboardKey.keyV, ctrl: true, shift: true);
      await tester.pumpAndSettle();
      expect(find.textContaining('Paste'), findsNothing);
      expect(sent.join(), 'ls -la');
      sent.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.insert);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.insert);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(sent.join(), 'ls -la');
    },
  );

  testWidgets('paste is ignored while the shell is not running', (
    tester,
  ) async {
    final h = _Harness(tester);
    addTearDown(h.dispose);
    final sent = <String>[];
    final shell = h.addRunningTab(sent);
    shell.debugSetState(ShellState.exited, 'Shell exited with status 0.');
    await h.pump();
    h.clipboard = 'rm -rf /';
    await h.chord(LogicalKeyboardKey.keyV, ctrl: true, shift: true);
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
  });

  testWidgets('selecting text and pressing Ctrl+Shift+C copies it', (
    tester,
  ) async {
    final h = _Harness(tester);
    addTearDown(h.dispose);
    final shell = h.addRunningTab([]);
    shell.terminal.write('hello selectable world');
    await h.pump();

    final origin = tester.getTopLeft(find.byType(TerminalView));
    // Drag across the first line, from its left edge well past the text.
    final start = origin + const Offset(12, 14);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    await h.chord(LogicalKeyboardKey.keyC, ctrl: true, shift: true);
    await tester.pump();
    expect(h.clipboard, isNotNull);
    expect(h.clipboard, contains('hello'));
  });

  testWidgets('right click offers copy, paste and select all', (tester) async {
    final h = _Harness(tester);
    addTearDown(h.dispose);
    h.addRunningTab([]);
    await h.pump();
    await tester.tapAt(
      tester.getCenter(find.byType(TerminalView)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('New terminal'), findsWidgets);
  });

  testWidgets('tab strip: add, title from the remote, close', (tester) async {
    final h = _Harness(tester);
    addTearDown(h.dispose);
    final first = h.addRunningTab([]);
    await h.pump();
    expect(find.text('Terminal 1'), findsOneWidget);

    await tester.tap(find.byTooltip('New terminal (Ctrl+Shift+T)'));
    await tester.pump();
    expect(h.tabs.tabs.length, 2);
    expect(h.tabs.activeIndex, 1);
    expect(find.text('Terminal 2'), findsOneWidget);

    // A remote title (cmd.exe sets one) replaces the number.
    first.terminal.write(
      '\x1b]0;Administrator: C:\\Windows\\system32\\cmd.exe\x07',
    );
    await tester.pump();
    expect(find.textContaining('Administrator'), findsOneWidget);

    await tester.tap(find.byTooltip('Close (Ctrl+Shift+W)').last);
    await tester.pump();
    expect(h.tabs.tabs.length, 1);
    expect(h.tabs.active, same(first));
  });

  testWidgets(
    'a dropped connection shows a Reconnect banner, an exit shows Restart',
    (tester) async {
      final h = _Harness(tester);
      addTearDown(h.dispose);
      final shell = h.addRunningTab([]);
      await h.pump();
      expect(find.text('Reconnect'), findsNothing);

      shell.debugSetState(ShellState.dropped, 'Connection lost.');
      await tester.pump();
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.text('Connection lost.'), findsOneWidget);

      shell.debugSetState(ShellState.exited, 'Shell exited with status 0.');
      await tester.pump();
      expect(find.text('Restart shell'), findsOneWidget);
      expect(find.text('Shell exited with status 0.'), findsOneWidget);

      shell.debugSetState(ShellState.failed, 'Could not open a shell: refused');
      await tester.pump();
      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining('refused'), findsOneWidget);
    },
  );

  testWidgets('empty strip offers a new terminal', (tester) async {
    final h = _Harness(tester);
    addTearDown(h.dispose);
    await h.pump();
    expect(find.text('New terminal'), findsOneWidget);
    await tester.tap(find.text('New terminal'));
    await tester.pump();
    expect(h.tabs.tabs.length, 1);
  });

  test(
    'a separator keeps the old screen in scrollback even if the new shell clears it',
    () {
      final shell = TerminalShell(number: 1);
      shell.terminal.resize(40, 6);
      shell.terminal.write('old output line 1\r\nold output line 2\r\n');
      shell.writeSeparator('reconnected');
      // What cmd.exe/ConPTY does on startup: clear the screen, home the cursor.
      shell.terminal.write('\x1b[2J\x1b[H');
      shell.terminal.write('Microsoft Windows\r\nC:\\>');
      final text = shell.terminal.buffer.getText();
      expect(text, contains('old output line 1'));
      expect(text, contains('old output line 2'));
      expect(text, contains('-- reconnected --'));
      expect(text, contains('Microsoft Windows'));
      shell.dispose();
    },
  );

  test('a separator resets modes a dead full-screen program left on', () {
    final shell = TerminalShell(number: 1);
    shell.terminal.write(
      '\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?25l',
    );
    expect(shell.terminal.isUsingAltBuffer, isTrue);
    expect(shell.terminal.bracketedPasteMode, isTrue);
    expect(shell.terminal.mouseMode, isNot(MouseMode.none));
    shell.writeSeparator('new session');
    expect(shell.terminal.isUsingAltBuffer, isFalse);
    expect(shell.terminal.bracketedPasteMode, isFalse);
    expect(shell.terminal.mouseMode, MouseMode.none);
    expect(shell.terminal.cursorVisibleMode, isTrue);
    shell.dispose();
  });

  test('closing tabs keeps a sensible active tab', () {
    final session = SessionController(
      connect: () async => throw StateError('x'),
      os: RemoteOs.linux,
    );
    final tabs = TerminalTabs(
      session: session,
      shellFactory: (n) => TerminalShell(number: n),
    );
    for (var i = 0; i < 4; i++) {
      tabs.add();
    }
    expect(tabs.activeIndex, 3);
    tabs.select(1);
    tabs.close(0);
    expect(
      tabs.active!.number,
      2,
      reason: 'closing a tab before the active one keeps it',
    );
    tabs.close();
    expect(tabs.active!.number, 3, reason: 'next tab slides in');
    tabs.close();
    tabs.close();
    expect(tabs.tabs, isEmpty);
    tabs.close(); // no-op
    tabs.next(); // no-op
    tabs.dispose();
  });

  test('tabs react to the connection dropping and returning', () async {
    final session = _ScriptedSession();
    final tabs = TerminalTabs(
      session: session,
      shellFactory: (n) => TerminalShell(number: n),
    );
    final shell = tabs.add();
    shell.debugSetState(ShellState.running);
    session.setPhase(ConnectionPhase.lost, 'wifi gone');
    expect(shell.state, ShellState.dropped);
    expect(shell.detail, 'wifi gone');

    // A shell the user ended with `exit` stays ended across a reconnect.
    final exited = tabs.add();
    exited.debugSetState(ShellState.exited, 'Shell exited with status 0.');
    session.setPhase(ConnectionPhase.lost, 'again');
    expect(exited.state, ShellState.exited);
    tabs.dispose();
  });
}

/// A session whose state the test drives by hand.
class _ScriptedSession extends SessionController {
  _ScriptedSession()
    : super(connect: () async => throw StateError('x'), os: RemoteOs.linux);

  ConnectionPhase _p = ConnectionPhase.connected;
  String? _m;

  void setPhase(ConnectionPhase p, [String? message]) {
    _p = p;
    _m = message;
    notifyListeners();
  }

  @override
  ConnectionPhase get phase => _p;

  @override
  String? get message => _m;
}
