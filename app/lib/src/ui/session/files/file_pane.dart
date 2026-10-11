import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/dialogs.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/format.dart';
import '../session_shortcuts.dart';
import 'file_pane_controller.dart';
import 'fs_backend.dart';
import 'path_style.dart';

/// What is being dragged between panes.
class FileDragPayload {
  const FileDragPayload(this.source, this.entries);
  final FilePaneController source;
  final List<FsEntry> entries;
}

const double _rowHeight = 30;

/// One side of the file manager: path bar, sortable listing, selection,
/// keyboard and mouse handling. All state lives in [FilePaneController]; the
/// transfer decisions are delegated to the callbacks so the same widget
/// serves the local and the remote side.
class FilePane extends StatefulWidget {
  const FilePane({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.title,
    required this.icon,
    required this.active,
    required this.transferLabel,
    required this.onActivate,
    required this.onTransfer,
    required this.onDropped,
    required this.onDelete,
    required this.onCopy,
    required this.onPaste,
    required this.onSwitchPane,
    this.toolbarExtras = const [],
    this.contextExtras = const [],
    this.statusBanner,
    this.canPaste = false,
  });

  final FilePaneController controller;
  final FocusNode focusNode;
  final String title;
  final IconData icon;
  final bool active;

  /// "Upload" or "Download": what moving the selection to the other pane is.
  final String transferLabel;

  final VoidCallback onActivate;
  final void Function(List<FsEntry> entries) onTransfer;

  /// Something from the other pane was dropped on this one (or on one of its
  /// folders; [destDir] is where it should land).
  final void Function(FileDragPayload payload, String destDir) onDropped;
  final void Function(List<FsEntry> entries) onDelete;
  final void Function(List<FsEntry> entries) onCopy;
  final VoidCallback onPaste;
  final VoidCallback onSwitchPane;
  final List<Widget> toolbarExtras;

  /// Extra entries appended to the empty-area context menu.
  final List<PopupMenuEntry<String>> contextExtras;

  /// Shown above the list (connection problems and the like).
  final Widget? statusBanner;
  final bool canPaste;

  @override
  State<FilePane> createState() => _FilePaneState();
}

class _FilePaneState extends State<FilePane> {
  final ScrollController _scroll = ScrollController();
  bool _editingPath = false;
  bool _dropHover = false;
  String? _dropFolder;

  // Hand-rolled click handling: GestureDetector would delay a single tap
  // until the double-tap window expires, which makes selection feel laggy.
  String? _lastClickPath;
  DateTime _lastClick = DateTime.fromMillisecondsSinceEpoch(0);
  String? _collapseOnUp;
  bool _dragged = false;
  bool _rowHandledPointer = false;

  String _typeahead = '';
  Timer? _typeaheadTimer;

  FilePaneController get c => widget.controller;

  @override
  void dispose() {
    _typeaheadTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- actions

  void _toast(String message, {bool error = false}) {
    if (mounted) showToast(context, message, error: error);
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _toast(e.toString(), error: true);
    }
  }

  Future<void> _newFolder() async {
    final name = await showTextPromptDialog(
      context,
      title: 'New folder',
      label: 'Name',
      confirmLabel: 'Create',
      validator: c.backend.style.invalidNameReason,
    );
    if (name == null) return;
    await _guard(() => c.makeDirectory(name));
    _scrollToCursor();
  }

  Future<void> _rename(FsEntry entry) async {
    final name = await showTextPromptDialog(
      context,
      title: 'Rename',
      label: 'New name',
      initialValue: entry.name,
      confirmLabel: 'Rename',
      selectStem: !entry.isDirectory,
      validator: c.backend.style.invalidNameReason,
    );
    if (name == null) return;
    await _guard(() => c.renameEntry(entry, name));
  }

  List<FsEntry> get _targets => c.selectedEntries;

  void _activate() {
    widget.onActivate();
    if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
  }

  // ----------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // The path field owns the keyboard while it is open.
    if (_editingPath) return KeyEventResult.ignored;

    final kb = HardwareKeyboard.instance;
    final shortcut = matchPaneShortcut(
      event.logicalKey,
      ctrl: kb.isControlPressed,
      shift: kb.isShiftPressed,
      alt: kb.isAltPressed,
    );
    if (shortcut != null) {
      _run(shortcut);
      return KeyEventResult.handled;
    }
    final ch = event.character;
    if (ch != null &&
        ch.isNotEmpty &&
        !kb.isControlPressed &&
        !kb.isAltPressed &&
        ch.codeUnitAt(0) >= 0x20) {
      _typeaheadTimer?.cancel();
      _typeahead += ch;
      _typeaheadTimer = Timer(
        const Duration(milliseconds: 900),
        () => _typeahead = '',
      );
      if (!c.jumpToPrefix(_typeahead) && _typeahead.length > 1) {
        // A repeated letter cycles instead of failing.
        _typeahead = ch;
        c.jumpToPrefix(ch);
      }
      _scrollToCursor();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _run(PaneShortcut shortcut) {
    switch (shortcut) {
      case PaneShortcut.up:
        c.moveCursor(-1);
        _scrollToCursor();
      case PaneShortcut.down:
        c.moveCursor(1);
        _scrollToCursor();
      case PaneShortcut.extendUp:
        c.moveCursor(-1, extend: true);
        _scrollToCursor();
      case PaneShortcut.extendDown:
        c.moveCursor(1, extend: true);
        _scrollToCursor();
      case PaneShortcut.pageUp:
        c.moveCursor(-10);
        _scrollToCursor();
      case PaneShortcut.pageDown:
        c.moveCursor(10);
        _scrollToCursor();
      case PaneShortcut.home:
        c.moveCursorTo(0);
        _scrollToCursor();
      case PaneShortcut.end:
        c.moveCursorTo(c.visible.length - 1);
        _scrollToCursor();
      case PaneShortcut.open:
        final sel = _targets;
        if (sel.length == 1 && sel.first.isDirectory) {
          unawaited(c.open(sel.first));
        }
      case PaneShortcut.goUp:
        unawaited(c.goUp());
      case PaneShortcut.back:
        unawaited(c.goBack());
      case PaneShortcut.forward:
        unawaited(c.goForward());
      case PaneShortcut.refresh:
        unawaited(c.refresh());
      case PaneShortcut.rename:
        final sel = _targets;
        if (sel.length == 1) unawaited(_rename(sel.first));
      case PaneShortcut.delete:
        final sel = _targets;
        if (sel.isNotEmpty) widget.onDelete(sel);
      case PaneShortcut.newFolder:
        unawaited(_newFolder());
      case PaneShortcut.selectAll:
        c.selectAll();
      case PaneShortcut.clearSelection:
        c.clearSelection();
      case PaneShortcut.copy:
        final sel = _targets;
        if (sel.isNotEmpty) widget.onCopy(sel);
      case PaneShortcut.paste:
        widget.onPaste();
      case PaneShortcut.editPath:
        setState(() => _editingPath = true);
      case PaneShortcut.toggleHidden:
        c.toggleHidden();
      case PaneShortcut.switchPane:
        widget.onSwitchPane();
    }
  }

  void _scrollToCursor() {
    final i = c.indexOfCursor();
    if (i < 0 || !_scroll.hasClients) return;
    final top = i * _rowHeight;
    final bottom = top + _rowHeight;
    final pos = _scroll.position;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(bottom - pos.viewportDimension);
    }
  }

  // ------------------------------------------------------------- mouse

  void _rowDown(FsEntry entry, PointerDownEvent event) {
    _rowHandledPointer = true;
    _activate();
    if (event.buttons == kSecondaryMouseButton) {
      if (!c.selection.contains(entry.path)) c.selectOnly(entry.path);
      unawaited(_showContextMenu(event.position, onRow: true));
      return;
    }
    if (event.buttons != kPrimaryMouseButton) return;

    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed) {
      c.toggle(entry.path);
    } else if (kb.isShiftPressed) {
      c.selectRange(entry.path);
    } else {
      final now = DateTime.now();
      final isDouble =
          _lastClickPath == entry.path &&
          now.difference(_lastClick) < const Duration(milliseconds: 400);
      if (isDouble) {
        _lastClickPath = null;
        if (entry.isDirectory) unawaited(c.open(entry));
        return;
      }
      if (!c.selection.contains(entry.path)) {
        c.selectOnly(entry.path);
      } else {
        // Already part of a selection: keep it in case this becomes a drag,
        // and collapse to this row on release if it did not.
        _collapseOnUp = entry.path;
      }
      _lastClickPath = entry.path;
      _lastClick = now;
    }
  }

  void _rowUp(FsEntry entry) {
    if (_collapseOnUp == entry.path && !_dragged) c.selectOnly(entry.path);
    _collapseOnUp = null;
  }

  void _emptyDown(PointerDownEvent event) {
    if (_rowHandledPointer) {
      _rowHandledPointer = false;
      return;
    }
    _activate();
    if (event.buttons == kSecondaryMouseButton) {
      unawaited(_showContextMenu(event.position, onRow: false));
    } else if (event.buttons == kPrimaryMouseButton) {
      c.clearSelection();
    }
  }

  Future<void> _showContextMenu(
    Offset globalPosition, {
    required bool onRow,
  }) async {
    final sel = _targets;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    );
    final single = sel.length == 1 ? sel.first : null;
    final items = <PopupMenuEntry<String>>[
      if (onRow && sel.isNotEmpty) ...[
        if (single != null && single.isDirectory)
          const PopupMenuItem(value: 'open', child: Text('Open')),
        PopupMenuItem(
          value: 'transfer',
          child: Text(
            '${widget.transferLabel} ${sel.length > 1 ? '${sel.length} items' : ''}'
                .trim(),
          ),
        ),
        const PopupMenuItem(value: 'copy', child: Text('Copy (Ctrl+C)')),
        const PopupMenuDivider(),
        if (single != null)
          const PopupMenuItem(value: 'rename', child: Text('Rename (F2)')),
        const PopupMenuItem(value: 'delete', child: Text('Delete (Del)')),
        if (single != null)
          const PopupMenuItem(value: 'copypath', child: Text('Copy path')),
        const PopupMenuDivider(),
      ],
      if (!onRow || sel.isEmpty) ...[
        PopupMenuItem(
          value: 'paste',
          enabled: widget.canPaste,
          child: const Text('Paste (Ctrl+V)'),
        ),
      ],
      const PopupMenuItem(value: 'mkdir', child: Text('New folder (F7)')),
      const PopupMenuItem(value: 'refresh', child: Text('Refresh (F5)')),
      PopupMenuItem(
        value: 'hidden',
        child: Text(c.showHidden ? 'Hide hidden files' : 'Show hidden files'),
      ),
      ...widget.contextExtras,
    ];
    final choice = await showMenu<String>(
      context: context,
      position: position,
      items: items,
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'open':
        unawaited(c.open(single!));
      case 'transfer':
        widget.onTransfer(sel);
      case 'copy':
        widget.onCopy(sel);
      case 'rename':
        unawaited(_rename(single!));
      case 'delete':
        widget.onDelete(sel);
      case 'copypath':
        unawaited(copyToClipboard(context, single!.path, what: 'path'));
      case 'paste':
        widget.onPaste();
      case 'mkdir':
        unawaited(_newFolder());
      case 'refresh':
        unawaited(c.refresh());
      case 'hidden':
        c.toggleHidden();
    }
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        if (focused) widget.onActivate();
      },
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: widget.active ? scheme.primary : scheme.outlineVariant,
                width: widget.active ? 1.5 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Column(
                children: [
                  _header(context),
                  _toolbar(context),
                  if (widget.statusBanner != null) widget.statusBanner!,
                  if (c.error != null)
                    InlineBanner(
                      message: c.error!,
                      onDismiss: () => unawaited(c.refresh()),
                      actionLabel: 'Retry',
                      onAction: () => unawaited(c.refresh()),
                    ),
                  _columnHeader(context),
                  const Divider(),
                  Expanded(child: _list(context)),
                  const Divider(),
                  _footer(context),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: widget.active
          ? scheme.primaryContainer.withValues(alpha: 0.5)
          : scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(widget.icon, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          if (c.loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final style = c.backend.style;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: Row(
        children: [
          PaneIconButton(
            icon: Icons.arrow_back,
            tooltip: 'Back (Alt+Left)',
            onPressed: c.canGoBack ? () => unawaited(c.goBack()) : null,
          ),
          PaneIconButton(
            icon: Icons.arrow_forward,
            tooltip: 'Forward (Alt+Right)',
            onPressed: c.canGoForward ? () => unawaited(c.goForward()) : null,
          ),
          PaneIconButton(
            icon: Icons.arrow_upward,
            tooltip: 'Up one folder (Backspace)',
            onPressed: c.canGoUp ? () => unawaited(c.goUp()) : null,
          ),
          PaneIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh (F5)',
            onPressed: () => unawaited(c.refresh()),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _PathBar(
              path: c.cwd,
              style: style,
              editing: _editingPath,
              onEdit: () {
                setState(() => _editingPath = true);
              },
              onSubmit: (text) {
                setState(() => _editingPath = false);
                widget.focusNode.requestFocus();
                if (text == null) return;
                unawaited(c.navigate(style.resolveInput(text, c.cwd)));
              },
              onCrumb: (path) => unawaited(c.navigate(path)),
            ),
          ),
          const SizedBox(width: 2),
          PaneIconButton(
            icon: c.showHidden
                ? Icons.visibility
                : Icons.visibility_off_outlined,
            tooltip: c.showHidden
                ? 'Hide hidden files (Ctrl+H)'
                : 'Show hidden files (Ctrl+H)',
            onPressed: c.toggleHidden,
            selected: c.showHidden,
          ),
          PaneIconButton(
            icon: Icons.create_new_folder_outlined,
            tooltip: 'New folder (F7)',
            onPressed: () => unawaited(_newFolder()),
          ),
          ...widget.toolbarExtras,
        ],
      ),
    );
  }

  Widget _columnHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(
      String label,
      SortColumn column, {
      Alignment align = Alignment.centerLeft,
    }) {
      final sorted = c.sortColumn == column;
      return InkWell(
        onTap: () => c.setSort(column),
        child: Container(
          alignment: align,
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: sorted ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              if (sorted)
                Icon(
                  c.ascending ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  size: 16,
                  color: scheme.primary,
                ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final cols = _columnsFor(box.maxWidth);
        return Row(
          children: [
            const SizedBox(width: 30),
            Expanded(child: cell('Name', SortColumn.name)),
            if (cols.size)
              SizedBox(
                width: _sizeWidth,
                child: cell(
                  'Size',
                  SortColumn.size,
                  align: Alignment.centerRight,
                ),
              ),
            if (cols.modified)
              SizedBox(
                width: _modifiedWidth,
                child: cell('Modified', SortColumn.modified),
              ),
          ],
        );
      },
    );
  }

  static const double _sizeWidth = 84;
  static const double _modifiedWidth = 142;

  ({bool size, bool modified}) _columnsFor(double width) =>
      (size: width > 300, modified: width > 470);

  Widget _list(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = c.visible;

    Widget body;
    if (c.loading && entries.isEmpty && !c.initialised) {
      body = const Center(child: CircularProgressIndicator());
    } else if (entries.isEmpty) {
      body = Center(
        child: Text(
          c.error != null
              ? ''
              : c.hiddenCount > 0
              ? 'Empty (${c.hiddenCount} hidden)'
              : 'Empty folder',
          style: TextStyle(color: scheme.outline),
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, box) {
          final cols = _columnsFor(box.maxWidth);
          return Scrollbar(
            controller: _scroll,
            child: ListView.builder(
              controller: _scroll,
              itemExtent: _rowHeight,
              itemCount: entries.length,
              itemBuilder: (context, i) => _row(context, entries[i], cols),
            ),
          );
        },
      );
    }

    return DragTarget<FileDragPayload>(
      onWillAcceptWithDetails: (d) => d.data.source != c,
      onMove: (_) {
        if (!_dropHover || _dropFolder != null) {
          setState(() {
            _dropHover = true;
            _dropFolder = null;
          });
        }
      },
      onLeave: (_) => setState(() {
        _dropHover = false;
        _dropFolder = null;
      }),
      onAcceptWithDetails: (d) {
        setState(() {
          _dropHover = false;
          _dropFolder = null;
        });
        widget.onDropped(d.data, c.cwd);
      },
      builder: (context, candidates, rejected) {
        final hovering =
            candidates.isNotEmpty && _dropHover && _dropFolder == null;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _emptyDown,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              color: hovering ? scheme.primary.withValues(alpha: 0.08) : null,
              border: hovering
                  ? Border.all(color: scheme.primary, width: 2)
                  : null,
            ),
            child: SizedBox.expand(child: body),
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    FsEntry entry,
    ({bool size, bool modified}) cols,
  ) {
    final selected = c.selection.contains(entry.path);
    final isCursor = c.cursor == entry.path;
    final dim = c.backend.style.isHidden(entry.name);

    Widget row = _EntryRow(
      entry: entry,
      selected: selected,
      cursor: isCursor && widget.active,
      dimmed: dim,
      paneActive: widget.active,
      showSize: cols.size,
      showModified: cols.modified,
      sizeWidth: _sizeWidth,
      modifiedWidth: _modifiedWidth,
      dropTarget: _dropFolder == entry.path,
    );

    row = Listener(
      onPointerDown: (e) => _rowDown(entry, e),
      onPointerUp: (_) => _rowUp(entry),
      child: row,
    );

    final draggable = Draggable<FileDragPayload>(
      maxSimultaneousDrags: 1,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      data: FileDragPayload(c, selected ? c.selectedEntries : [entry]),
      onDragStarted: () {
        _dragged = true;
        _collapseOnUp = null;
        if (!c.selection.contains(entry.path)) c.selectOnly(entry.path);
      },
      onDragEnd: (_) => _dragged = false,
      onDraggableCanceled: (_, _) => _dragged = false,
      feedback: _DragFeedback(
        count: selected ? c.selection.length : 1,
        name: entry.name,
        isDirectory: entry.isDirectory,
      ),
      child: row,
    );

    if (!entry.isDirectory) return draggable;
    // Dropping on a folder row sends the files into that folder.
    return DragTarget<FileDragPayload>(
      onWillAcceptWithDetails: (d) => d.data.source != c,
      onMove: (_) {
        if (_dropFolder != entry.path) {
          setState(() {
            _dropFolder = entry.path;
            _dropHover = false;
          });
        }
      },
      onLeave: (_) {
        if (_dropFolder == entry.path) setState(() => _dropFolder = null);
      },
      onAcceptWithDetails: (d) {
        setState(() => _dropFolder = null);
        widget.onDropped(d.data, entry.path);
      },
      builder: (context, _, _) => draggable,
    );
  }

  Widget _footer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = c.visible;
    final folders = entries.where((e) => e.isDirectory).length;
    final files = entries.length - folders;
    final selected = c.selectedEntries;
    final selectedBytes = selected.fold<int>(
      0,
      (s, e) => s + (e.isDirectory ? 0 : (e.size ?? 0)),
    );
    final parts = <String>[
      if (folders > 0) '$folders folder${folders == 1 ? '' : 's'}',
      if (files > 0) '$files file${files == 1 ? '' : 's'}',
      if (entries.isEmpty) '0 items',
      if (c.hiddenCount > 0 && !c.showHidden) '${c.hiddenCount} hidden',
    ];
    final selText = selected.isEmpty
        ? ''
        : '   ·   ${selected.length} selected'
              '${selectedBytes > 0 ? ' (${formatBytes(selectedBytes)})' : ''}';
    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      alignment: Alignment.centerLeft,
      child: Text(
        parts.join(', ') + selText,
        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// A compact toolbar button that never takes keyboard focus.
class PaneIconButton extends StatelessWidget {
  const PaneIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    // Excluded from focus so a click on a toolbar button leaves the keyboard
    // with the list; the shortcuts keep working afterwards.
    return ExcludeFocus(
      child: IconButton(
        icon: Icon(icon),
        iconSize: 18,
        tooltip: tooltip,
        isSelected: selected,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.cursor,
    required this.dimmed,
    required this.paneActive,
    required this.showSize,
    required this.showModified,
    required this.sizeWidth,
    required this.modifiedWidth,
    required this.dropTarget,
  });

  final FsEntry entry;
  final bool selected;
  final bool cursor;
  final bool dimmed;
  final bool paneActive;
  final bool showSize;
  final bool showModified;
  final double sizeWidth;
  final double modifiedWidth;
  final bool dropTarget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = dimmed
        ? scheme.onSurface.withValues(alpha: 0.55)
        : scheme.onSurface;
    final secondary = scheme.onSurfaceVariant.withValues(
      alpha: dimmed ? 0.6 : 1,
    );
    Color? bg;
    if (dropTarget) {
      bg = scheme.primary.withValues(alpha: 0.22);
    } else if (selected) {
      bg = scheme.primary.withValues(alpha: paneActive ? 0.20 : 0.11);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: cursor
              ? Border.all(color: scheme.primary.withValues(alpha: 0.6))
              : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Icon(
                iconForEntry(entry),
                size: 18,
                color: entry.isDirectory
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: Text(
                entry.kind == FsKind.link ? '${entry.name}  →' : entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: textColor),
              ),
            ),
            if (showSize)
              SizedBox(
                width: sizeWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    entry.isDirectory ? '' : formatBytes(entry.size),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    style: TextStyle(fontSize: 12, color: secondary),
                  ),
                ),
              ),
            if (showModified)
              SizedBox(
                width: modifiedWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    formatModified(entry.modified),
                    maxLines: 1,
                    style: TextStyle(fontSize: 12, color: secondary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData iconForEntry(FsEntry entry) {
  if (entry.isDirectory) {
    return entry.kind == FsKind.link
        ? Icons.folder_shared_outlined
        : Icons.folder;
  }
  if (entry.kind == FsKind.link) return Icons.link;
  final dot = entry.name.lastIndexOf('.');
  final ext = dot > 0 ? entry.name.substring(dot + 1).toLowerCase() : '';
  const images = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'svg',
    'ico',
    'heic',
  };
  const archives = {
    'zip',
    'tar',
    'gz',
    'tgz',
    'xz',
    'bz2',
    '7z',
    'rar',
    'deb',
    'rpm',
  };
  const code = {
    'dart',
    'rs',
    'py',
    'js',
    'ts',
    'tsx',
    'jsx',
    'c',
    'h',
    'cpp',
    'hpp',
    'cs',
    'java',
    'kt',
    'go',
    'sh',
    'ps1',
    'bat',
    'cmd',
    'json',
    'yaml',
    'yml',
    'toml',
    'xml',
    'html',
    'css',
    'sql',
  };
  const media = {
    'mp3',
    'wav',
    'flac',
    'ogg',
    'mp4',
    'mkv',
    'mov',
    'avi',
    'webm',
  };
  if (images.contains(ext)) return Icons.image_outlined;
  if (archives.contains(ext)) return Icons.inventory_2_outlined;
  if (code.contains(ext)) return Icons.code;
  if (media.contains(ext)) return Icons.movie_outlined;
  if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
  if (ext == 'txt' || ext == 'md' || ext == 'log') {
    return Icons.description_outlined;
  }
  if (ext == 'exe' || ext == 'msi' || ext == 'appimage') {
    return Icons.settings_applications_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({
    required this.count,
    required this.name,
    required this.isDirectory,
  });

  final int count;
  final String name;
  final bool isDirectory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 260),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(blurRadius: 10, color: Color(0x44000000)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              count > 1
                  ? Icons.file_copy_outlined
                  : (isDirectory
                        ? Icons.folder
                        : Icons.insert_drive_file_outlined),
              size: 18,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                count > 1 ? '$count items' : name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Breadcrumbs that turn into a text field on click (or Ctrl+L).
class _PathBar extends StatefulWidget {
  const _PathBar({
    required this.path,
    required this.style,
    required this.editing,
    required this.onEdit,
    required this.onSubmit,
    required this.onCrumb,
  });

  final String path;
  final PathStyle style;
  final bool editing;
  final VoidCallback onEdit;

  /// Null text means cancelled.
  final void Function(String? text) onSubmit;
  final void Function(String path) onCrumb;

  @override
  State<_PathBar> createState() => _PathBarState();
}

class _PathBarState extends State<_PathBar> {
  late final TextEditingController _text;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text = TextEditingController();
    _focus.addListener(() {
      // Losing focus without Enter cancels the edit.
      if (!_focus.hasFocus && widget.editing) widget.onSubmit(null);
    });
  }

  @override
  void didUpdateWidget(_PathBar old) {
    super.didUpdateWidget(old);
    if (widget.editing && !old.editing) {
      _text.text = widget.style.displayPath(widget.path);
      _text.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _text.text.length,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.editing) {
      return SizedBox(
        height: 30,
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onSubmit(null);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: _text,
            focusNode: _focus,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
            onSubmitted: widget.onSubmit,
          ),
        ),
      );
    }
    final crumbs = widget.style.breadcrumbs(widget.path);
    return InkWell(
      onTap: widget.onEdit,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        // Reversed so the deepest folder stays visible when the path is long;
        // the minimum width keeps short paths flush left.
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0)
                      Icon(
                        Icons.chevron_right,
                        size: 14,
                        color: scheme.outline,
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => widget.onCrumb(crumbs[i].path),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Text(
                          crumbs[i].label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: i == crumbs.length - 1
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
