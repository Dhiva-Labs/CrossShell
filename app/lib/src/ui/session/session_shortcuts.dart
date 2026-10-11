import 'package:flutter/services.dart';

/// App-level shortcuts of the session page, active in the terminal and
/// everywhere else. Plain Ctrl+C / Ctrl+V are deliberately absent: in a
/// terminal they mean SIGINT and literal-next, so copy and paste use the
/// terminal-emulator convention (Ctrl+Shift+C/V, Ctrl+Insert / Shift+Insert).
enum SessionShortcut {
  newTerminal,
  closeTerminal,
  nextTerminal,
  previousTerminal,
  copy,
  paste,
  showTerminal,
  showFiles,
  showForwards,
}

/// Pure so it can be tested without a widget tree. Meta is ignored on
/// purpose: these bindings target Linux and Windows.
SessionShortcut? matchSessionShortcut(
  LogicalKeyboardKey key, {
  required bool ctrl,
  required bool shift,
  bool alt = false,
}) {
  if (alt) return null;
  if (ctrl && shift) {
    if (key == LogicalKeyboardKey.keyT) return SessionShortcut.newTerminal;
    if (key == LogicalKeyboardKey.keyW) return SessionShortcut.closeTerminal;
    if (key == LogicalKeyboardKey.keyC) return SessionShortcut.copy;
    if (key == LogicalKeyboardKey.keyV) return SessionShortcut.paste;
    if (key == LogicalKeyboardKey.tab) return SessionShortcut.previousTerminal;
    return null;
  }
  if (ctrl && !shift) {
    if (key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.pageDown) {
      return SessionShortcut.nextTerminal;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      return SessionShortcut.previousTerminal;
    }
    if (key == LogicalKeyboardKey.insert) return SessionShortcut.copy;
    if (key == LogicalKeyboardKey.digit1) return SessionShortcut.showTerminal;
    if (key == LogicalKeyboardKey.digit2) return SessionShortcut.showFiles;
    if (key == LogicalKeyboardKey.digit3) return SessionShortcut.showForwards;
    return null;
  }
  if (shift && !ctrl && key == LogicalKeyboardKey.insert) {
    return SessionShortcut.paste;
  }
  return null;
}

/// Shortcuts inside a file pane.
enum PaneShortcut {
  up,
  down,
  extendUp,
  extendDown,
  pageUp,
  pageDown,
  home,
  end,
  open,
  goUp,
  back,
  forward,
  refresh,
  rename,
  delete,
  newFolder,
  selectAll,
  clearSelection,
  copy,
  paste,
  editPath,
  toggleHidden,
  switchPane,
}

PaneShortcut? matchPaneShortcut(
  LogicalKeyboardKey key, {
  required bool ctrl,
  required bool shift,
  required bool alt,
}) {
  if (alt) {
    if (ctrl || shift) return null;
    if (key == LogicalKeyboardKey.arrowUp) return PaneShortcut.goUp;
    if (key == LogicalKeyboardKey.arrowLeft) return PaneShortcut.back;
    if (key == LogicalKeyboardKey.arrowRight) return PaneShortcut.forward;
    return null;
  }
  if (ctrl) {
    if (shift) {
      return key == LogicalKeyboardKey.keyN ? PaneShortcut.newFolder : null;
    }
    if (key == LogicalKeyboardKey.keyA) return PaneShortcut.selectAll;
    if (key == LogicalKeyboardKey.keyC) return PaneShortcut.copy;
    if (key == LogicalKeyboardKey.keyV) return PaneShortcut.paste;
    if (key == LogicalKeyboardKey.keyR) return PaneShortcut.refresh;
    if (key == LogicalKeyboardKey.keyL) return PaneShortcut.editPath;
    if (key == LogicalKeyboardKey.keyH) return PaneShortcut.toggleHidden;
    return null;
  }
  if (key == LogicalKeyboardKey.arrowUp) {
    return shift ? PaneShortcut.extendUp : PaneShortcut.up;
  }
  if (key == LogicalKeyboardKey.arrowDown) {
    return shift ? PaneShortcut.extendDown : PaneShortcut.down;
  }
  if (shift) {
    if (key == LogicalKeyboardKey.delete) return PaneShortcut.delete;
    if (key == LogicalKeyboardKey.tab) return PaneShortcut.switchPane;
    return null;
  }
  if (key == LogicalKeyboardKey.pageUp) return PaneShortcut.pageUp;
  if (key == LogicalKeyboardKey.pageDown) return PaneShortcut.pageDown;
  if (key == LogicalKeyboardKey.home) return PaneShortcut.home;
  if (key == LogicalKeyboardKey.end) return PaneShortcut.end;
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return PaneShortcut.open;
  }
  if (key == LogicalKeyboardKey.backspace) return PaneShortcut.goUp;
  if (key == LogicalKeyboardKey.f5) return PaneShortcut.refresh;
  if (key == LogicalKeyboardKey.f2) return PaneShortcut.rename;
  if (key == LogicalKeyboardKey.f7) return PaneShortcut.newFolder;
  if (key == LogicalKeyboardKey.delete) return PaneShortcut.delete;
  if (key == LogicalKeyboardKey.escape) return PaneShortcut.clearSelection;
  if (key == LogicalKeyboardKey.tab) return PaneShortcut.switchPane;
  return null;
}
