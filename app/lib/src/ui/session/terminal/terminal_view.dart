import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../theme.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/error_banner.dart';
import '../session_shortcuts.dart';
import 'paste_guard.dart';
import 'terminal_shell.dart';

const double _minFont = 8;
const double _maxFont = 28;
const double _defaultFont = 13.5;

/// The Terminal tab: a strip of shell tabs over one terminal view each.
class TerminalTabsView extends StatefulWidget {
  const TerminalTabsView({
    super.key,
    required this.tabs,
    required this.visible,
    required this.onShortcut,
  });

  final TerminalTabs tabs;

  /// False while another page tab is in front: the terminals stay alive
  /// (a running `htop` must keep running) but give up keyboard focus.
  final bool visible;

  /// Session-level shortcuts the terminal does not handle itself (new tab,
  /// close tab, switching page tabs).
  final void Function(SessionShortcut shortcut) onShortcut;

  @override
  State<TerminalTabsView> createState() => _TerminalTabsViewState();
}

class _TerminalTabsViewState extends State<TerminalTabsView> {
  double _fontSize = _defaultFont;

  void _zoom(double delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(_minFont, _maxFont));
  }

  @override
  Widget build(BuildContext context) {
    final colors = CrossShellColors.of(context);
    return ListenableBuilder(
      listenable: widget.tabs,
      builder: (context, _) {
        final tabs = widget.tabs;
        final shells = tabs.tabs;
        return ColoredBox(
          color: colors.terminal.background,
          child: Column(
            children: [
              _TabStrip(tabs: tabs),
              Expanded(
                child: shells.isEmpty
                    ? Center(
                        child: FilledButton.icon(
                          onPressed: tabs.add,
                          icon: const Icon(Icons.add),
                          label: const Text('New terminal'),
                        ),
                      )
                    : Stack(
                        children: [
                          for (var i = 0; i < shells.length; i++)
                            Positioned.fill(
                              key: ValueKey(shells[i]),
                              child: Offstage(
                                offstage: i != tabs.activeIndex,
                                child: ExcludeFocus(
                                  excluding:
                                      i != tabs.activeIndex || !widget.visible,
                                  child: TerminalPane(
                                    shell: shells[i],
                                    tabs: tabs,
                                    fontSize: _fontSize,
                                    focused:
                                        widget.visible && i == tabs.activeIndex,
                                    onShortcut: widget.onShortcut,
                                    onZoom: _zoom,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.tabs});

  final TerminalTabs tabs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Excluded from focus so clicking a tab's buttons leaves the keyboard
    // with the terminal.
    return ExcludeFocus(
      child: Material(
        color: scheme.surfaceContainerLow,
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: tabs.tabs.length,
                  itemBuilder: (context, i) => _TerminalTab(
                    shell: tabs.tabs[i],
                    active: i == tabs.activeIndex,
                    onSelect: () => tabs.select(i),
                    onClose: () => tabs.close(i),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'New terminal (Ctrl+Shift+T)',
                iconSize: 18,
                onPressed: tabs.add,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TerminalTab extends StatelessWidget {
  const _TerminalTab({
    required this.shell,
    required this.active,
    required this.onSelect,
    required this.onClose,
  });

  final TerminalShell shell;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = CrossShellColors.of(context);
    return ListenableBuilder(
      listenable: shell,
      builder: (context, _) {
        final title = shell.remoteTitle.isNotEmpty
            ? shell.remoteTitle
            : 'Terminal ${shell.number}';
        final dot = switch (shell.state) {
          ShellState.running => colors.success,
          ShellState.starting => colors.warning,
          ShellState.exited => scheme.outline,
          ShellState.dropped || ShellState.failed => scheme.error,
        };
        return Listener(
          // Middle-click closes, like every browser and terminal.
          onPointerDown: (e) {
            if (e.buttons == kMiddleMouseButton) onClose();
          },
          child: InkWell(
            onTap: onSelect,
            child: Container(
              constraints: const BoxConstraints(minWidth: 110, maxWidth: 220),
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: active ? colors.terminal.background : null,
                border: Border(
                  bottom: BorderSide(
                    color: active ? scheme.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: active
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close (Ctrl+Shift+W)',
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One shell's terminal view plus its status overlays.
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.shell,
    required this.tabs,
    required this.fontSize,
    required this.focused,
    required this.onShortcut,
    required this.onZoom,
  });

  final TerminalShell shell;
  final TerminalTabs tabs;
  final double fontSize;

  /// Whether this pane should hold keyboard focus.
  final bool focused;
  final void Function(SessionShortcut shortcut) onShortcut;
  final void Function(double delta) onZoom;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final TerminalController _controller = TerminalController();
  final FocusNode _focus = FocusNode(debugLabel: 'terminal');

  @override
  void initState() {
    super.initState();
    if (widget.focused) _requestFocusSoon();
  }

  @override
  void didUpdateWidget(TerminalPane old) {
    super.didUpdateWidget(old);
    if (widget.focused && !old.focused) _requestFocusSoon();
  }

  void _requestFocusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.focused) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Terminal get _terminal => widget.shell.terminal;

  Future<void> _copy() async {
    final range = _controller.selection;
    if (range == null) return;
    final text = _terminal.buffer.getText(range);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _paste() async {
    if (!widget.shell.isRunning) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    if (PasteGuard.needsConfirmation(text)) {
      final ok = await showPasteConfirmDialog(
        context,
        text: text,
        lineCount: PasteGuard.lineCount(text),
      );
      if (!ok || !mounted) return;
    }
    _controller.clearSelection();
    // Wraps in bracketed-paste escapes only if the remote program asked.
    _terminal.paste(text);
  }

  void _selectAll() {
    final buffer = _terminal.buffer;
    _controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(_terminal.viewWidth, buffer.height - 1),
    );
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
    if (shortcut == null) return KeyEventResult.ignored;
    switch (shortcut) {
      case SessionShortcut.copy:
        unawaited(_copy());
      case SessionShortcut.paste:
        unawaited(_paste());
      default:
        widget.onShortcut(shortcut);
    }
    return KeyEventResult.handled;
  }

  void _contextMenu(TapDownDetails details) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      details.globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    );
    showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: _controller.selection != null,
          child: const Text('Copy'),
        ),
        PopupMenuItem(
          value: 'paste',
          enabled: widget.shell.isRunning,
          child: const Text('Paste'),
        ),
        const PopupMenuItem(value: 'all', child: Text('Select all')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'new', child: Text('New terminal')),
        const PopupMenuItem(value: 'close', child: Text('Close terminal')),
      ],
    ).then((value) {
      switch (value) {
        case 'copy':
          unawaited(_copy());
        case 'paste':
          unawaited(_paste());
        case 'all':
          _selectAll();
        case 'new':
          widget.onShortcut(SessionShortcut.newTerminal);
        case 'close':
          widget.onShortcut(SessionShortcut.closeTerminal);
      }
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = CrossShellColors.of(context);
    return ListenableBuilder(
      listenable: widget.shell,
      builder: (context, _) {
        final shell = widget.shell;
        final live =
            shell.state == ShellState.running ||
            shell.state == ShellState.starting;
        return Column(
          children: [
            Expanded(
              child: Listener(
                // Ctrl + wheel zooms, like every terminal emulator.
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent &&
                      HardwareKeyboard.instance.isControlPressed) {
                    widget.onZoom(event.scrollDelta.dy < 0 ? 1 : -1);
                  }
                },
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: TerminalView(
                        _terminal,
                        controller: _controller,
                        focusNode: _focus,
                        autofocus: widget.focused,
                        theme: colors.terminal,
                        textStyle: TerminalStyle(
                          fontSize: widget.fontSize,
                          height: 1.25,
                          fontFamily: terminalFontFamilies.first,
                          fontFamilyFallback: terminalFontFamilies,
                        ),
                        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                        readOnly: !live,
                        // Replaces xterm's defaults, which bind plain Ctrl+V
                        // and Ctrl+A; the shell needs both.
                        shortcuts: const {},
                        onKeyEvent: _onKey,
                        onSecondaryTapDown: (d, _) => _contextMenu(d),
                        mouseCursor: SystemMouseCursors.text,
                      ),
                    ),
                    if (shell.state == ShellState.starting)
                      Positioned(
                        top: 8,
                        right: 12,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Opening shell...',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.terminal.foreground.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (shell.state == ShellState.dropped)
              InlineBanner(
                tone: BannerTone.warning,
                message: shell.detail ?? 'Connection lost.',
                actionLabel: 'Reconnect',
                onAction: () => unawaited(widget.tabs.restart(shell)),
              ),
            if (shell.state == ShellState.exited)
              InlineBanner(
                tone: BannerTone.info,
                message: shell.detail ?? 'Shell closed.',
                actionLabel: 'Restart shell',
                onAction: () => unawaited(widget.tabs.restart(shell)),
              ),
            if (shell.state == ShellState.failed)
              InlineBanner(
                message: shell.detail ?? 'Could not open a shell.',
                actionLabel: 'Try again',
                onAction: () => unawaited(widget.tabs.restart(shell)),
              ),
          ],
        );
      },
    );
  }
}
