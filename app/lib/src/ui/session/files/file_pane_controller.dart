import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../widgets/format.dart';
import 'fs_backend.dart';

enum SortColumn { name, size, modified }

/// Orders [entries] for display: folders first (always), then by [column].
List<FsEntry> sortEntries(
  Iterable<FsEntry> entries,
  SortColumn column,
  bool ascending,
) {
  int byColumn(FsEntry a, FsEntry b) {
    switch (column) {
      case SortColumn.name:
        return naturalCompare(a.name, b.name);
      case SortColumn.size:
        // Entries without a size (folders, odd files) sort as zero so they
        // stay together; ties fall back to the name.
        final c = (a.size ?? -1).compareTo(b.size ?? -1);
        return c != 0 ? c : naturalCompare(a.name, b.name);
      case SortColumn.modified:
        final am = a.modified?.millisecondsSinceEpoch ?? 0;
        final bm = b.modified?.millisecondsSinceEpoch ?? 0;
        final c = am.compareTo(bm);
        return c != 0 ? c : naturalCompare(a.name, b.name);
    }
  }

  final list = entries.toList();
  list.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    final c = byColumn(a, b);
    return ascending ? c : -c;
  });
  return list;
}

/// State of one file pane: where it is, what it shows, what is selected.
/// No widgets in here, so the logic is testable against a fake backend.
class FilePaneController extends ChangeNotifier {
  FilePaneController({required FsBackend backend, this.initialPath})
    // ignore: prefer_initializing_formals
    : _backend = backend;

  FsBackend _backend;
  final String? initialPath;

  FsBackend get backend => _backend;

  String _cwd = '';
  String get cwd => _cwd;

  List<FsEntry> _all = const [];
  List<FsEntry> _visible = const [];

  /// What the list shows after hidden-file filtering and sorting.
  List<FsEntry> get visible => _visible;
  int get totalCount => _all.length;
  int get hiddenCount => _all.length - _all.where(_passesHidden).length;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  bool _initialised = false;
  bool get initialised => _initialised;

  // True once a directory has loaded; the Windows drive list has an empty
  // path, so emptiness cannot stand in for "no location yet".
  bool _located = false;

  SortColumn _sortColumn = SortColumn.name;
  bool _ascending = true;
  SortColumn get sortColumn => _sortColumn;
  bool get ascending => _ascending;

  bool _showHidden = false;
  bool get showHidden => _showHidden;

  final Set<String> _selection = {};
  Set<String> get selection => Set.unmodifiable(_selection);
  String? _anchor;
  String? _cursor;
  String? get cursor => _cursor;

  final List<String> _back = [];
  final List<String> _forward = [];
  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;
  bool get canGoUp => _cwd.isNotEmpty && !_backend.style.isRoot(_cwd);

  var _requestId = 0;
  var _disposed = false;

  bool _passesHidden(FsEntry e) =>
      _showHidden || !_backend.style.isHidden(e.name);

  List<FsEntry> get selectedEntries =>
      _visible.where((e) => _selection.contains(e.path)).toList();

  /// Loads the starting directory. Safe to call again after [rebind].
  Future<void> init() async {
    final start = initialPath ?? await _backend.home();
    _initialised = true;
    await navigate(start, record: false);
  }

  /// Swaps in a fresh backend (after a reconnect) and reloads where we were.
  Future<void> rebind(FsBackend backend) async {
    _backend = backend;
    if (_located) {
      await navigate(_cwd, record: false);
    } else {
      await init();
    }
  }

  /// Changes directory. On failure the pane stays where it was and [error]
  /// says why (an unreadable folder is normal on a shared machine).
  Future<void> navigate(String path, {bool record = true}) async {
    final id = ++_requestId;
    _loading = true;
    _error = null;
    _notify();
    try {
      final target = await _backend.canonicalize(path);
      final entries = await _backend.list(target);
      if (id != _requestId || _disposed) return;
      if (record && _located && _cwd != target) {
        _back.add(_cwd);
        _forward.clear();
      }
      _located = true;
      _cwd = target;
      _all = entries;
      _selection.clear();
      _anchor = null;
      _cursor = null;
      _rebuildVisible();
    } catch (e) {
      if (id != _requestId || _disposed) return;
      _error = e.toString();
    } finally {
      if (id == _requestId && !_disposed) {
        _loading = false;
        _notify();
      }
    }
  }

  /// Re-lists the current directory, keeping the selection where possible.
  Future<void> refresh() async {
    if (!_located) return;
    final id = ++_requestId;
    _loading = true;
    _notify();
    try {
      final entries = await _backend.list(_cwd);
      if (id != _requestId || _disposed) return;
      _all = entries;
      _error = null;
      final names = _all.map((e) => e.path).toSet();
      _selection.removeWhere((p) => !names.contains(p));
      _rebuildVisible();
    } catch (e) {
      if (id != _requestId || _disposed) return;
      _error = e.toString();
    } finally {
      if (id == _requestId && !_disposed) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> goUp() => navigate(_backend.style.parent(_cwd));

  Future<void> goBack() async {
    if (_back.isEmpty) return;
    final target = _back.removeLast();
    _forward.add(_cwd);
    await navigate(target, record: false);
  }

  Future<void> goForward() async {
    if (_forward.isEmpty) return;
    final target = _forward.removeLast();
    _back.add(_cwd);
    await navigate(target, record: false);
  }

  /// Opens [entry] if it is a folder (or a link to one).
  Future<void> open(FsEntry entry) async {
    if (entry.isDirectory) await navigate(entry.path);
  }

  void setSort(SortColumn column) {
    if (_sortColumn == column) {
      _ascending = !_ascending;
    } else {
      _sortColumn = column;
      _ascending = true;
    }
    _rebuildVisible();
    _notify();
  }

  void toggleHidden() {
    _showHidden = !_showHidden;
    _rebuildVisible();
    // Hidden rows leave the selection with them.
    _selection.removeWhere((p) => !_visible.any((e) => e.path == p));
    _notify();
  }

  void _rebuildVisible() {
    _visible = sortEntries(_all.where(_passesHidden), _sortColumn, _ascending);
  }

  // ----------------------------------------------------------- selection

  void selectOnly(String path) {
    _selection
      ..clear()
      ..add(path);
    _anchor = path;
    _cursor = path;
    _notify();
  }

  void toggle(String path) {
    if (!_selection.remove(path)) _selection.add(path);
    _anchor = path;
    _cursor = path;
    _notify();
  }

  /// Selects the range between the anchor and [path] (Shift+click).
  void selectRange(String path) {
    final anchor = _anchor ?? path;
    final a = _visible.indexWhere((e) => e.path == anchor);
    final b = _visible.indexWhere((e) => e.path == path);
    if (a < 0 || b < 0) {
      selectOnly(path);
      return;
    }
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    _selection
      ..clear()
      ..addAll(_visible.sublist(lo, hi + 1).map((e) => e.path));
    _cursor = path;
    _notify();
  }

  void selectAll() {
    _selection
      ..clear()
      ..addAll(_visible.map((e) => e.path));
    _notify();
  }

  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    _notify();
  }

  /// Moves the cursor by [delta] rows (negative = up). With [extend] the
  /// selection grows from the anchor; otherwise it collapses onto the cursor.
  void moveCursor(int delta, {bool extend = false}) {
    if (_visible.isEmpty) return;
    final current = _cursor == null
        ? -1
        : _visible.indexWhere((e) => e.path == _cursor);
    final next =
        (current < 0 ? (delta > 0 ? 0 : _visible.length - 1) : current + delta)
            .clamp(0, _visible.length - 1);
    moveCursorTo(next, extend: extend);
  }

  void moveCursorTo(int index, {bool extend = false}) {
    if (_visible.isEmpty) return;
    final path = _visible[index.clamp(0, _visible.length - 1)].path;
    if (extend) {
      _anchor ??= _cursor ?? path;
      selectRange(path);
    } else {
      selectOnly(path);
    }
  }

  /// Jumps to the first row whose name starts with [prefix] (type-ahead).
  bool jumpToPrefix(String prefix) {
    final lower = prefix.toLowerCase();
    final i = _visible.indexWhere(
      (e) => e.name.toLowerCase().startsWith(lower),
    );
    if (i < 0) return false;
    selectOnly(_visible[i].path);
    return true;
  }

  int indexOfCursor() =>
      _cursor == null ? -1 : _visible.indexWhere((e) => e.path == _cursor);

  // ------------------------------------------------------------ mutations

  Future<void> makeDirectory(String name) async {
    final problem = _backend.style.invalidNameReason(name);
    if (problem != null) throw FsException(problem);
    if (_nameTaken(name)) {
      throw FsException(
        '"$name" already exists here.',
        kind: FsErrorKind.exists,
      );
    }
    final path = _backend.style.join(_cwd, name);
    await _backend.mkdir(path);
    await refresh();
    selectOnly(path);
  }

  Future<void> renameEntry(FsEntry entry, String newName) async {
    if (newName == entry.name) return;
    final problem = _backend.style.invalidNameReason(newName);
    if (problem != null) throw FsException(problem);
    final caseOnly =
        _backend.style.isWindows &&
        newName.toLowerCase() == entry.name.toLowerCase();
    if (!caseOnly && _nameTaken(newName)) {
      throw FsException(
        '"$newName" already exists here.',
        kind: FsErrorKind.exists,
      );
    }
    final to = _backend.style.join(_backend.style.parent(entry.path), newName);
    await _backend.rename(entry.path, to);
    await refresh();
    selectOnly(to);
  }

  bool _nameTaken(String name) {
    final ci = _backend.style.isWindows;
    final needle = ci ? name.toLowerCase() : name;
    return _all.any((e) => (ci ? e.name.toLowerCase() : e.name) == needle);
  }

  /// Every name in the current directory, hidden ones included.
  Iterable<String> get allEntryNames => _all.map((e) => e.name);

  /// Whether a name already exists in the current directory listing (used by
  /// transfers to detect conflicts without extra round trips).
  FsEntry? entryNamed(String name) {
    final ci = _backend.style.isWindows;
    final needle = ci ? name.toLowerCase() : name;
    for (final e in _all) {
      if ((ci ? e.name.toLowerCase() : e.name) == needle) return e;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
