import 'dart:async';
import 'dart:typed_data';

import 'package:cross_shell/src/ui/session/files/fs_backend.dart';
import 'package:cross_shell/src/ui/session/files/path_style.dart';

class _Node {
  _Node.dir() : isDir = true, bytes = null, isLink = false, mtime = null;
  _Node.file(this.bytes, {this.mtime}) : isDir = false, isLink = false;
  _Node.link({this.linksToDir = false})
    : isDir = false,
      bytes = null,
      isLink = true,
      mtime = null;
  final bool isDir;
  final bool isLink;
  bool linksToDir = false;
  Uint8List? bytes;
  DateTime? mtime;
}

/// An in-memory filesystem speaking any [PathStyle], so path and transfer
/// logic can be tested without disks or servers.
class FakeFs implements FsBackend {
  FakeFs(this.style, {this.label = 'fake', this.chunk = 4, String? home})
    : homeDir = home {
    // Root always exists.
    _nodes[style.root] = _Node.dir();
  }

  @override
  final PathStyle style;
  @override
  final String label;

  /// Stream chunk size, small so tests exercise multi-chunk paths.
  final int chunk;

  final String? homeDir;

  final Map<String, _Node> _nodes = {};
  final List<String> log = [];

  /// Paths whose reads fail, to test error handling.
  final Set<String> failReads = {};

  /// Called for every chunk read, to slow or cancel mid-transfer.
  Future<void> Function(String path, int offset)? onChunk;

  void addDir(String path) {
    var cur = style.normalize(path);
    final chain = <String>[];
    while (!_nodes.containsKey(cur)) {
      chain.add(cur);
      cur = style.parent(cur);
    }
    for (final p in chain.reversed) {
      _nodes[p] = _Node.dir();
    }
  }

  void addFile(String path, [Object content = '']) {
    final n = style.normalize(path);
    addDir(style.parent(n));
    _nodes[n] = _Node.file(
      content is String
          ? Uint8List.fromList(content.codeUnits)
          : content as Uint8List,
      mtime: DateTime(2026, 10, 11, 12, 30),
    );
  }

  void addLink(String path, {bool toDirectory = false}) {
    final n = style.normalize(path);
    addDir(style.parent(n));
    _nodes[n] = _Node.link(linksToDir: toDirectory);
  }

  bool exists(String path) => _nodes.containsKey(style.normalize(path));

  String text(String path) =>
      String.fromCharCodes(_nodes[style.normalize(path)]!.bytes!);

  Uint8List data(String path) => _nodes[style.normalize(path)]!.bytes!;

  List<String> get paths => _nodes.keys.toList()..sort();

  FsEntry _entry(String path, _Node n) => FsEntry(
    name: style.basename(path),
    path: path,
    kind: n.isLink ? FsKind.link : (n.isDir ? FsKind.directory : FsKind.file),
    size: n.bytes?.length,
    modified: n.mtime,
    linkIsDirectory: n.isLink && n.linksToDir,
  );

  @override
  Future<String> home() async => homeDir ?? style.root;

  @override
  Future<String> canonicalize(String path) async => style.normalize(path);

  @override
  Future<List<FsEntry>> list(String dir) async {
    final d = style.normalize(dir);
    final node = _nodes[d];
    if (node == null) {
      throw const FsException('does not exist', kind: FsErrorKind.notFound);
    }
    if (!node.isDir) throw const FsException('not a folder');
    return [
      for (final e in _nodes.entries)
        if (e.key != d && style.parent(e.key) == d) _entry(e.key, e.value),
    ];
  }

  @override
  Future<FsEntry?> stat(String path) async {
    final p = style.normalize(path);
    final n = _nodes[p];
    return n == null ? null : _entry(p, n);
  }

  @override
  Future<void> mkdir(String path) async {
    final p = style.normalize(path);
    log.add('mkdir $p');
    if (_nodes.containsKey(p)) {
      throw const FsException('exists', kind: FsErrorKind.exists);
    }
    if (!(_nodes[style.parent(p)]?.isDir ?? false)) {
      throw const FsException('parent missing', kind: FsErrorKind.notFound);
    }
    _nodes[p] = _Node.dir();
  }

  @override
  Future<void> rename(String from, String to) async {
    final f = style.normalize(from);
    final t = style.normalize(to);
    log.add('rename $f $t');
    if (_nodes.containsKey(t) && f.toLowerCase() != t.toLowerCase()) {
      throw const FsException('exists', kind: FsErrorKind.exists);
    }
    final moved = {
      for (final e in _nodes.entries)
        if (e.key == f || e.key.startsWith('$f/')) e.key: e.value,
    };
    for (final k in moved.keys) {
      _nodes.remove(k);
    }
    for (final e in moved.entries) {
      _nodes[t + e.key.substring(f.length)] = e.value;
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    final p = style.normalize(path);
    log.add('rm $p');
    final n = _nodes[p];
    if (n == null) {
      throw const FsException('missing', kind: FsErrorKind.notFound);
    }
    if (n.isDir) throw const FsException('is a folder');
    _nodes.remove(p);
  }

  @override
  Future<void> deleteEmptyDirectory(String path) async {
    final p = style.normalize(path);
    log.add('rmdir $p');
    if (_nodes.keys.any((k) => k != p && style.parent(k) == p)) {
      throw const FsException('not empty', kind: FsErrorKind.notEmpty);
    }
    _nodes.remove(p);
  }

  @override
  Stream<Uint8List> read(String path) async* {
    final p = style.normalize(path);
    if (failReads.contains(p)) throw const FsException('read failed');
    final n = _nodes[p];
    if (n == null || n.bytes == null) {
      throw const FsException('missing', kind: FsErrorKind.notFound);
    }
    final bytes = n.bytes!;
    for (var i = 0; i < bytes.length; i += chunk) {
      await onChunk?.call(p, i);
      yield Uint8List.sublistView(
        bytes,
        i,
        i + chunk > bytes.length ? bytes.length : i + chunk,
      );
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> write(String path, Stream<Uint8List> data) async {
    final p = style.normalize(path);
    log.add('write $p');
    if (!(_nodes[style.parent(p)]?.isDir ?? false)) {
      throw const FsException('parent missing', kind: FsErrorKind.notFound);
    }
    final b = BytesBuilder();
    final node = _Node.file(Uint8List(0), mtime: DateTime(2026, 10, 12));
    _nodes[p] = node; // visible while writing, like a real filesystem
    await for (final c in data) {
      b.add(c);
    }
    node.bytes = b.toBytes();
  }

  @override
  Future<void> close() async {}
}
