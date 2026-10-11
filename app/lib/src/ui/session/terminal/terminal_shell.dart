import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
// The buffer/parser is pure Dart; only the widget needs Flutter. Importing
// core keeps this file testable without a window.
import 'package:xterm/core.dart';

import '../session_controller.dart';

enum ShellState {
  /// Opening the PTY.
  starting,
  running,

  /// The remote shell ended (user typed `exit`) while the connection is fine.
  exited,

  /// The connection went away under a running shell.
  dropped,

  /// The shell could not be opened.
  failed,
}

/// One remote shell: a [Terminal] buffer wired to a PTY channel.
///
/// The buffer belongs to this object, not to the widget that draws it, so
/// scrollback survives tab switches and reconnects.
class TerminalShell extends ChangeNotifier {
  TerminalShell({
    required this.number,
    int maxLines = 10000,
    TerminalTargetPlatform platform = TerminalTargetPlatform.linux,
  }) {
    terminal = Terminal(
      maxLines: maxLines,
      platform: platform,
      onOutput: _sendToShell,
      onResize: _handleResize,
      onTitleChange: _handleTitle,
    );
  }

  /// Stable ordinal for the default tab title ("Terminal 2").
  final int number;

  late final Terminal terminal;

  ShellState _state = ShellState.starting;
  ShellState get state => _state;

  /// Exit status, failure reason or drop reason, depending on [state].
  String? _detail;
  String? get detail => _detail;

  String _title = '';

  /// What the remote program set as the window title, if anything.
  String get remoteTitle => _title;

  SSHSession? _session;
  final List<StreamSubscription<dynamic>> _subs = [];
  final Completer<void> _sized = Completer<void>();
  var _generation = 0;
  var _disposed = false;

  /// Test hook: everything the shell received, before it hit the buffer.
  void Function(String text)? onRawOutput;

  bool get isRunning => _state == ShellState.running;

  /// Test hook: pretend the PTY is up so input and paste can be exercised
  /// without a connection.
  @visibleForTesting
  void debugSetState(ShellState state, [String? detail]) {
    _state = state;
    _detail = detail;
    _notify();
  }

  /// Opens the PTY on [client]. Waits briefly for the view to report its real
  /// size so the first prompt is not drawn at 80x24 and redrawn.
  Future<void> start(SSHClient client) async {
    final gen = ++_generation;
    _teardown();
    _state = ShellState.starting;
    _detail = null;
    _notify();

    if (!_sized.isCompleted) {
      await _sized.future.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () {},
      );
    }
    if (_disposed || gen != _generation) return;

    final SSHSession session;
    try {
      session = await client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: terminal.viewWidth,
          height: terminal.viewHeight,
        ),
      );
    } catch (e) {
      if (_disposed || gen != _generation) return;
      _state = ShellState.failed;
      _detail = 'Could not open a shell: $e';
      _notify();
      return;
    }
    if (_disposed || gen != _generation) {
      session.close();
      return;
    }
    _session = session;
    // A streaming decoder: a multi-byte character split across two packets
    // must not turn into replacement characters.
    for (final stream in [session.stdout, session.stderr]) {
      _subs.add(
        stream
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(_onOutput),
      );
    }
    unawaited(session.done.then((_) => _onSessionDone(session, client, gen)));
    _state = ShellState.running;
    _notify();
  }

  void _onOutput(String text) {
    onRawOutput?.call(text);
    terminal.write(text);
  }

  Future<void> _onSessionDone(
    SSHSession session,
    SSHClient client,
    int gen,
  ) async {
    // The channel closes both when the user types `exit` and when the whole
    // connection dies; give the transport a moment to say which.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (_disposed || gen != _generation || !identical(_session, session)) {
      return;
    }
    _session = null;
    if (client.isClosed) {
      _state = ShellState.dropped;
      _detail = 'Connection lost.';
    } else {
      _state = ShellState.exited;
      final code = session.exitCode;
      final signal = session.exitSignal;
      _detail = signal != null
          ? 'Shell ended by signal ${signal.signalName}.'
          : code != null
          ? 'Shell exited with status $code.'
          : 'Shell closed.';
    }
    _notify();
  }

  /// The connection under this shell is gone.
  void markDropped(String reason) {
    if (_state == ShellState.exited || _state == ShellState.failed) return;
    _generation++;
    _teardown();
    _state = ShellState.dropped;
    _detail = reason;
    _notify();
  }

  /// Marks where one session ended and the next begins.
  ///
  /// Two things need care. The dead program may have left the terminal in a
  /// mode (alternate screen, mouse reporting, bracketed paste, hidden cursor)
  /// that would garble the new shell, so those are reset first. And a fresh
  /// shell often clears the screen on startup (cmd.exe through ConPTY does),
  /// which would wipe the last output, so the visible screen, rule included,
  /// is scrolled into the scrollback first.
  void writeSeparator(String text) {
    terminal.write(
      '\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l'
      '\x1b[?2004l\x1b[?1l\x1b[?25h\x1b[0m',
    );
    terminal.write('\r\n\x1b[2m-- $text --\x1b[0m\r\n');
    // The rule is pushed up with everything else, then the cursor goes home
    // so the new shell starts on a clean screen.
    terminal.write('\r\n' * terminal.viewHeight);
    terminal.write('\x1b[H');
  }

  void _sendToShell(String data) {
    final session = _session;
    if (session == null || _state != ShellState.running) return;
    session.write(Uint8List.fromList(utf8.encode(data)));
  }

  void _handleResize(int width, int height, int pixelWidth, int pixelHeight) {
    if (width > 0 && height > 0 && !_sized.isCompleted) _sized.complete();
    _session?.resizeTerminal(width, height, pixelWidth, pixelHeight);
  }

  void _handleTitle(String title) {
    _title = title.trim();
    _notify();
  }

  void _teardown() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _session?.close();
    _session = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _teardown();
    super.dispose();
  }
}

/// The ordered set of terminal tabs, shared between the tab strip, the
/// keyboard shortcuts and the connection lifecycle.
class TerminalTabs extends ChangeNotifier {
  TerminalTabs({
    required this.session,
    this.platform = TerminalTargetPlatform.linux,
    this.shellFactory,
  }) {
    session.addListener(_onSessionChanged);
    _lastGeneration = session.generation;
  }

  final SessionController session;
  final TerminalTargetPlatform platform;

  /// Test seam: build shells without a real PTY.
  final TerminalShell Function(int number)? shellFactory;

  final List<TerminalShell> _tabs = [];
  List<TerminalShell> get tabs => List.unmodifiable(_tabs);

  int _active = 0;
  int get activeIndex => _active;
  TerminalShell? get active => _tabs.isEmpty ? null : _tabs[_active];

  var _counter = 0;
  late int _lastGeneration;
  var _disposed = false;

  /// Opens a new shell tab and focuses it. Returns the shell.
  TerminalShell add() {
    final shell =
        shellFactory?.call(++_counter) ??
        TerminalShell(number: ++_counter, platform: platform);
    _tabs.add(shell);
    _active = _tabs.length - 1;
    _notify();
    if (session.isConnected) unawaited(shell.start(session.client));
    return shell;
  }

  /// Opens the first tab if none exists.
  void ensureOne() {
    if (_tabs.isEmpty) add();
  }

  void select(int index) {
    if (index < 0 || index >= _tabs.length || index == _active) return;
    _active = index;
    _notify();
  }

  void next() {
    if (_tabs.length > 1) select((_active + 1) % _tabs.length);
  }

  void previous() {
    if (_tabs.length > 1) select((_active - 1 + _tabs.length) % _tabs.length);
  }

  /// Closes tab [index] (the active one by default). Closing the last tab
  /// leaves an empty strip with a "new terminal" prompt, not a dead page.
  void close([int? index]) {
    final i = index ?? _active;
    if (i < 0 || i >= _tabs.length) return;
    final shell = _tabs.removeAt(i);
    shell.dispose();
    if (_tabs.isEmpty) {
      _active = 0;
    } else if (_active > i || _active >= _tabs.length) {
      _active = (_active - (_active > i ? 1 : 0)).clamp(0, _tabs.length - 1);
    }
    _notify();
  }

  /// Restarts a finished or dropped shell in place (same tab, same scrollback).
  Future<void> restart(TerminalShell shell) async {
    if (!session.isConnected) {
      await session.reconnect();
      if (!session.isConnected) return;
    }
    shell.writeSeparator('new session');
    await shell.start(session.client);
  }

  void _onSessionChanged() {
    if (_disposed) return;
    if (session.phase == ConnectionPhase.lost ||
        session.phase == ConnectionPhase.failed) {
      for (final shell in _tabs) {
        shell.markDropped(session.message ?? 'Connection lost.');
      }
    } else if (session.phase == ConnectionPhase.connected &&
        session.generation != _lastGeneration) {
      // Shells killed by the drop come back by themselves; ones the user
      // ended with `exit` stay ended.
      for (final shell in _tabs) {
        if (shell.state == ShellState.dropped) {
          shell.writeSeparator('reconnected');
          unawaited(shell.start(session.client));
        } else if (shell.state == ShellState.starting) {
          unawaited(shell.start(session.client));
        }
      }
    }
    if (session.phase == ConnectionPhase.connected) {
      _lastGeneration = session.generation;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_onSessionChanged);
    for (final shell in _tabs) {
      shell.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}
