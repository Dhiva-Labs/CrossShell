import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, KeyUpEvent;
import 'package:path_provider/path_provider.dart';
import 'package:xterm/core.dart' show TerminalTargetPlatform;

import '../theme.dart';
import '../widgets/error_banner.dart';
import 'files/files_tab.dart';
import 'files/fs_backend.dart';
import 'forwards/forward_manager.dart';
import 'forwards/forward_store.dart';
import 'forwards/forwards_tab.dart';
import 'session_controller.dart';
import 'session_shortcuts.dart';
import 'session_types.dart';
import 'terminal/terminal_shell.dart';
import 'terminal/terminal_view.dart';

export 'session_types.dart';

/// Everything you do with a connected peer: terminal tabs, the SFTP file
/// manager and port forwards, over one shared SSH connection.
/// Seams for widget tests; production code leaves them unset.
@visibleForTesting
class SessionTestHooks {
  const SessionTestHooks({
    this.session,
    this.shellFactory,
    this.localBackend,
    this.remoteBackendOpener,
  });

  /// Replaces the connection owner (e.g. one that reports connected).
  final SessionController Function()? session;
  final TerminalShell Function(int number)? shellFactory;
  final FsBackend? localBackend;
  final Future<FsBackend> Function()? remoteBackendOpener;
}

class SessionPage extends StatefulWidget {
  const SessionPage({
    super.key,
    required this.peerId,
    required this.title,
    required this.os,
    required this.connect,
    this.onRemoteDesktop,
    this.onOpenSystemTerminal,
    this.onOpenVsCode,
    this.initialTab = SessionTab.terminal,
    this.supportDirectory,
    @visibleForTesting this.testHooks,
  });

  /// Stable id of the peer; forward presets are saved under it.
  final String peerId;

  /// The peer's display name.
  final String title;
  final RemoteOs os;

  /// Returns a fresh, authenticated client (host key already pinned by the
  /// caller). Called again on every reconnect.
  final Future<SSHClient> Function() connect;

  final VoidCallback? onRemoteDesktop;
  final VoidCallback? onOpenSystemTerminal;

  /// Receives the folder the file manager is showing on the peer.
  final void Function(String remotePath)? onOpenVsCode;
  final SessionTab initialTab;

  /// Where forward presets live. Defaults to the app support directory.
  final Future<Directory> Function()? supportDirectory;

  /// Stand-ins for the parts that need a real connection or disk.
  final SessionTestHooks? testHooks;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  late final SessionController _session;
  late final TerminalTabs _terminals;
  ForwardManager? _forwards;

  late SessionTab _tab;
  final Set<SessionTab> _visited = {};
  bool _everConnected = false;

  /// Keeps the page-level shortcuts reachable when no tab holds focus (the
  /// Forwards page has nothing focusable, and hidden tabs give theirs up).
  final FocusNode _pageFocus = FocusNode(debugLabel: 'session page');

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    // The terminal view is always built (even when another page opens first)
    // because its layout is what tells the first shell its real size.
    _visited
      ..add(SessionTab.terminal)
      ..add(_tab);
    _session =
        widget.testHooks?.session?.call() ??
        SessionController(connect: widget.connect, os: widget.os);
    _session.addListener(_onSession);
    _terminals = TerminalTabs(
      session: _session,
      shellFactory: widget.testHooks?.shellFactory,
      platform: defaultTargetPlatform == TargetPlatform.windows
          ? TerminalTargetPlatform.windows
          : TerminalTargetPlatform.linux,
    );
    unawaited(_initForwards());
    _ensureKeyboardFocus();
    if (_session.isConnected) {
      // Already connected (a session handed in ready-made).
      _everConnected = true;
      _terminals.ensureOne();
    } else {
      unawaited(_session.reconnect());
    }
  }

  Future<void> _initForwards() async {
    Directory dir;
    String? problem;
    try {
      dir = await (widget.supportDirectory ?? getApplicationSupportDirectory)();
    } catch (e) {
      dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}crossshell-presets',
      );
      problem =
          'The app data folder is not available ($e); forward presets '
          'will not be kept after you close the app.';
    }
    if (!mounted) return;
    final manager = ForwardManager(
      peerId: widget.peerId,
      session: _session,
      store: ForwardStore(dir),
    );
    await manager.load();
    if (!mounted) {
      manager.dispose();
      return;
    }
    if (problem != null) manager.storeError ??= problem;
    setState(() => _forwards = manager);
  }

  void _onSession() {
    if (!mounted) return;
    if (_session.isConnected && !_everConnected) {
      _everConnected = true;
      // The first shell opens as soon as the connection is ready, whichever
      // tab is showing.
      _terminals.ensureOne();
    }
    setState(() {});
  }

  void _ensureKeyboardFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pageFocus.hasFocus) _pageFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _pageFocus.dispose();
    _session.removeListener(_onSession);
    _forwards?.dispose();
    _terminals.dispose();
    _session.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------- actions

  void _showTab(SessionTab tab) {
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      _visited.add(tab);
    });
    _ensureKeyboardFocus();
  }

  void _handleShortcut(SessionShortcut shortcut) {
    switch (shortcut) {
      case SessionShortcut.newTerminal:
        _showTab(SessionTab.terminal);
        _terminals.add();
      case SessionShortcut.closeTerminal:
        if (_tab == SessionTab.terminal) _terminals.close();
      case SessionShortcut.nextTerminal:
        if (_tab == SessionTab.terminal) _terminals.next();
      case SessionShortcut.previousTerminal:
        if (_tab == SessionTab.terminal) _terminals.previous();
      case SessionShortcut.showTerminal:
        _showTab(SessionTab.terminal);
      case SessionShortcut.showFiles:
        _showTab(SessionTab.files);
      case SessionShortcut.showForwards:
        _showTab(SessionTab.forwards);
      case SessionShortcut.copy:
      case SessionShortcut.paste:
        break; // terminal-only
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final shortcut = matchSessionShortcut(
      event.logicalKey,
      ctrl: kb.isControlPressed,
      shift: kb.isShiftPressed,
      alt: kb.isAltPressed,
    );
    if (shortcut == null ||
        shortcut == SessionShortcut.copy ||
        shortcut == SessionShortcut.paste) {
      return KeyEventResult.ignored;
    }
    _handleShortcut(shortcut);
    return KeyEventResult.handled;
  }

  /// The folder to hand VS Code: where the file manager is, else the peer's
  /// home directory.
  Future<void> _openVsCode() async {
    final callback = widget.onOpenVsCode;
    if (callback == null) return;
    var dir = _session.remoteDir;
    if (dir == null && _session.isConnected) {
      try {
        final sftp = await _session.client.sftp();
        dir = await sftp.absolute('.');
        await sftp.close();
      } catch (e) {
        if (mounted) {
          showToast(
            context,
            'Could not find the remote folder: $e',
            error: true,
          );
        }
        return;
      }
    }
    callback(dir ?? '/');
  }

  void _openTerminalHere(String dir) {
    _showTab(SessionTab.terminal);
    final shell = _terminals.add();
    // `cd` once the shell is up. Single-quoted so any folder name is safe.
    final quoted = "'${dir.replaceAll("'", r"'\''")}'";
    void send() {
      if (shell.state != ShellState.running) return;
      shell.removeListener(send);
      shell.terminal.textInput('cd -- $quoted\r');
    }

    shell.addListener(send);
    send();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _pageFocus,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: Column(
          children: [
            _Header(
              title: widget.title,
              os: widget.os,
              session: _session,
              tab: _tab,
              onTab: _showTab,
              onRemoteDesktop: widget.onRemoteDesktop,
              onOpenSystemTerminal: widget.onOpenSystemTerminal,
              onOpenVsCode: widget.onOpenVsCode == null
                  ? null
                  : () => unawaited(_openVsCode()),
            ),
            const Divider(),
            _connectionBanner(),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _connectionBanner() {
    if (!_everConnected) return const SizedBox.shrink();
    switch (_session.phase) {
      case ConnectionPhase.connected:
        return const SizedBox.shrink();
      case ConnectionPhase.connecting:
        return InlineBanner(
          tone: BannerTone.info,
          busy: true,
          message: 'Reconnecting to ${widget.title}...',
        );
      case ConnectionPhase.lost:
        return InlineBanner(
          tone: BannerTone.warning,
          message:
              'Connection to ${widget.title} lost: ${_session.message ?? 'unknown reason'}',
          actionLabel: 'Reconnect',
          onAction: () => unawaited(_session.reconnect()),
        );
      case ConnectionPhase.failed:
        return InlineBanner(
          message:
              'Could not reconnect to ${widget.title}: ${_session.message ?? 'unknown error'}',
          actionLabel: 'Try again',
          onAction: () => unawaited(_session.reconnect()),
        );
    }
  }

  Widget _body(BuildContext context) {
    if (!_everConnected) {
      return _FirstConnect(
        title: widget.title,
        phase: _session.phase,
        message: _session.message,
        onRetry: () => unawaited(_session.reconnect()),
      );
    }
    Widget page(SessionTab tab, Widget Function() build) {
      if (!_visited.contains(tab)) return const SizedBox.shrink();
      return Offstage(
        offstage: _tab != tab,
        child: TickerMode(enabled: _tab == tab, child: build()),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: page(
            SessionTab.terminal,
            () => TerminalTabsView(
              tabs: _terminals,
              visible: _tab == SessionTab.terminal,
              onShortcut: _handleShortcut,
            ),
          ),
        ),
        Positioned.fill(
          child: page(
            SessionTab.files,
            () => FilesTab(
              session: _session,
              peerTitle: widget.title,
              os: widget.os,
              visible: _tab == SessionTab.files,
              localBackend: widget.testHooks?.localBackend,
              remoteBackendOpener: widget.testHooks?.remoteBackendOpener,
              onOpenTerminalHere: _openTerminalHere,
            ),
          ),
        ),
        Positioned.fill(
          child: page(
            SessionTab.forwards,
            () => _forwards == null
                ? const Center(child: CircularProgressIndicator())
                : ForwardsTab(manager: _forwards!, peerTitle: widget.title),
          ),
        ),
      ],
    );
  }
}

class _FirstConnect extends StatelessWidget {
  const _FirstConnect({
    required this.title,
    required this.phase,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final ConnectionPhase phase;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed =
        phase == ConnectionPhase.failed || phase == ConnectionPhase.lost;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: failed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link_off, size: 40, color: scheme.error),
                    const SizedBox(height: 12),
                    Text(
                      'Could not connect to $title',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      message ?? 'Unknown error.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text('Connecting to $title...'),
                  ],
                ),
        ),
      ),
    );
  }
}

enum _HeaderMode {
  /// Labelled tabs and labelled action buttons.
  full,

  /// Labelled tabs, icon-only actions.
  iconActions,

  /// Only the selected tab shows its label; actions in a menu.
  compact,
}

typedef _HeaderAction = ({IconData icon, String label, VoidCallback onTap});

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.os,
    required this.session,
    required this.tab,
    required this.onTab,
    required this.onRemoteDesktop,
    required this.onOpenSystemTerminal,
    required this.onOpenVsCode,
  });

  final String title;
  final RemoteOs os;
  final SessionController session;
  final SessionTab tab;
  final void Function(SessionTab) onTab;
  final VoidCallback? onRemoteDesktop;
  final VoidCallback? onOpenSystemTerminal;
  final VoidCallback? onOpenVsCode;

  static const _tabs = [
    (SessionTab.terminal, Icons.terminal, 'Terminal', 'Ctrl+1'),
    (SessionTab.files, Icons.folder_outlined, 'Files', 'Ctrl+2'),
    (SessionTab.forwards, Icons.swap_horiz, 'Forwards', 'Ctrl+3'),
  ];

  /// Picks the roomiest layout that fits, by measuring the actual text. A
  /// fixed breakpoint would break with another font, a larger text scale or
  /// a longer peer name.
  _HeaderMode _modeFor(
    BuildContext context,
    double width,
    List<_HeaderAction> actions,
  ) {
    double text(String s, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      return painter.width;
    }

    final base = DefaultTextStyle.of(context).style;
    final titleWidth = text(
      title,
      base.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
    ).clamp(0, 220);
    final left = 16 + 20 + 10 + titleWidth + 24;
    final tabLabel = base.copyWith(fontWeight: FontWeight.w600, fontSize: 13.5);
    final fullTabs = _tabs.fold<double>(
      0,
      (sum, t) => sum + 32 + 18 + 8 + text(t.$3, tabLabel),
    );
    final actionLabel = base.copyWith(fontSize: 14);
    final fullActions = actions.fold<double>(
      0,
      (sum, a) => sum + 8 + 40 + 18 + 8 + text(a.label, actionLabel),
    );
    const right = 8.0;
    if (left + fullTabs + fullActions + right <= width) return _HeaderMode.full;
    if (left + fullTabs + actions.length * 48 + right <= width) {
      return _HeaderMode.iconActions;
    }
    return _HeaderMode.compact;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = CrossShellColors.of(context);
    final (Color dot, String status) = switch (session.phase) {
      ConnectionPhase.connected => (colors.success, 'Connected'),
      ConnectionPhase.connecting => (colors.warning, 'Connecting'),
      ConnectionPhase.lost => (scheme.error, 'Disconnected'),
      ConnectionPhase.failed => (scheme.error, 'Not connected'),
    };

    final actions = <_HeaderAction>[
      if (onRemoteDesktop != null)
        (
          icon: Icons.desktop_windows_outlined,
          label: 'Remote desktop',
          onTap: onRemoteDesktop!,
        ),
      if (onOpenSystemTerminal != null)
        (
          icon: Icons.terminal,
          label: 'Open in system terminal',
          onTap: onOpenSystemTerminal!,
        ),
      if (onOpenVsCode != null)
        (icon: Icons.code, label: 'Open in VS Code', onTap: onOpenVsCode!),
    ];

    // Excluded from focus: clicking a tab or an action must not take the
    // keyboard away from the terminal or file list. The tabs have shortcuts.
    return ExcludeFocus(
      child: Material(
        color: scheme.surfaceContainerLow,
        child: LayoutBuilder(
          builder: (context, box) {
            final mode = _modeFor(context, box.maxWidth, actions);
            final compact = mode == _HeaderMode.compact;
            return SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Icon(
                    os == RemoteOs.windows
                        ? Icons.laptop_windows
                        : Icons.dns_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    flex: 0,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: dot,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                status,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  for (final t in _tabs)
                    _PageTab(
                      icon: t.$2,
                      label: t.$3,
                      shortcut: t.$4,
                      selected: tab == t.$1,
                      compact: compact,
                      onTap: () => onTab(t.$1),
                    ),
                  const Spacer(),
                  if (mode == _HeaderMode.compact && actions.isNotEmpty)
                    PopupMenuButton<int>(
                      tooltip: 'Actions',
                      icon: const Icon(Icons.more_vert),
                      onSelected: (i) => actions[i].onTap(),
                      itemBuilder: (_) => [
                        for (var i = 0; i < actions.length; i++)
                          PopupMenuItem(
                            value: i,
                            child: Row(
                              children: [
                                Icon(actions[i].icon, size: 18),
                                const SizedBox(width: 10),
                                Flexible(child: Text(actions[i].label)),
                              ],
                            ),
                          ),
                      ],
                    )
                  else if (mode == _HeaderMode.iconActions)
                    for (final a in actions)
                      IconButton(
                        tooltip: a.label,
                        onPressed: a.onTap,
                        icon: Icon(a.icon, size: 20),
                      )
                  else
                    for (final a in actions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: OutlinedButton.icon(
                          onPressed: a.onTap,
                          icon: Icon(a.icon, size: 18),
                          label: Text(a.label),
                        ),
                      ),
                  const SizedBox(width: 8),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PageTab extends StatelessWidget {
  const _PageTab({
    required this.icon,
    required this.label,
    required this.shortcut,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String shortcut;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: '$label ($shortcut)',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 52,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              if (!compact || selected) ...[
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
