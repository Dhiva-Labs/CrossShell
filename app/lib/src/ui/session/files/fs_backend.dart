import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'path_style.dart';

enum FsKind { file, directory, link, other }

/// One row of a directory listing.
class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.size,
    this.modified,
    this.linkIsDirectory = false,
    this.mode,
  });

  final String name;
  final String path;
  final FsKind kind;
  final int? size;
  final DateTime? modified;

  /// For [FsKind.link]: whether the target is a directory, so the row
  /// navigates instead of transferring.
  final bool linkIsDirectory;

  /// POSIX permission bits when the filesystem reports them.
  final int? mode;

  /// A real directory, or a link that points at one.
  bool get isDirectory =>
      kind == FsKind.directory || (kind == FsKind.link && linkIsDirectory);

  FsEntry copyWith({bool? linkIsDirectory}) => FsEntry(
    name: name,
    path: path,
    kind: kind,
    size: size,
    modified: modified,
    linkIsDirectory: linkIsDirectory ?? this.linkIsDirectory,
    mode: mode,
  );
}

enum FsErrorKind {
  notFound,
  permissionDenied,
  exists,
  notEmpty,
  disconnected,
  other,
}

/// A filesystem failure with a message written for a human. The raw error is
/// kept in [details] so nothing is swallowed.
class FsException implements Exception {
  const FsException(
    this.message, {
    this.kind = FsErrorKind.other,
    this.details,
  });

  final String message;
  final FsErrorKind kind;
  final String? details;

  @override
  String toString() => message;
}

/// A directory tree that can be browsed and transferred: the local disk or an
/// SFTP session. Transfers only ever talk to this interface, which is what
/// lets the same engine do uploads, downloads and (in tests) local copies.
abstract class FsBackend {
  PathStyle get style;

  /// Pane title: "This computer" or the peer's name.
  String get label;

  Future<String> home();

  /// The server's idea of [path] (`realpath`); [style.normalize] locally.
  Future<String> canonicalize(String path);

  /// Entries of [dir] (without `.`/`..`), unsorted.
  Future<List<FsEntry>> list(String dir);

  /// Null when [path] does not exist.
  Future<FsEntry?> stat(String path);

  /// Creates one directory; the parent must exist. Fails if [path] exists.
  Future<void> mkdir(String path);

  /// Fails with [FsErrorKind.exists] rather than replacing [to].
  Future<void> rename(String from, String to);

  /// Removes a file or a link itself (never a link's target).
  Future<void> deleteFile(String path);

  Future<void> deleteEmptyDirectory(String path);

  /// Streams the file's bytes. Must not buffer the whole file.
  Stream<Uint8List> read(String path);

  /// Creates or truncates [path] and writes [data] to it, awaiting the
  /// consumer so a slow disk or link slows the source down too.
  Future<void> write(String path, Stream<Uint8List> data);

  Future<void> close();
}

String _osMessage(FileSystemException e) {
  final os = e.osError;
  final base = (os != null && os.message.isNotEmpty) ? os.message : e.message;
  return base.trim();
}

FsException describeLocalError(Object error, String path) {
  if (error is FsException) return error;
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    final text = _osMessage(error).toLowerCase();
    final name = path.isEmpty ? 'this location' : '"$path"';
    if (code == 2 ||
        code == 3 && Platform.isWindows ||
        text.contains('no such file')) {
      return FsException(
        '$name does not exist.',
        kind: FsErrorKind.notFound,
        details: error.toString(),
      );
    }
    if (code == 13 ||
        code == 5 ||
        text.contains('permission denied') ||
        text.contains('access is denied')) {
      return FsException(
        'Permission denied: $name',
        kind: FsErrorKind.permissionDenied,
        details: error.toString(),
      );
    }
    if (code == 17 || code == 183 || code == 80 || text.contains('exists')) {
      return FsException(
        '$name already exists.',
        kind: FsErrorKind.exists,
        details: error.toString(),
      );
    }
    if (code == 39 || code == 145 || text.contains('not empty')) {
      return FsException(
        '$name is not empty.',
        kind: FsErrorKind.notEmpty,
        details: error.toString(),
      );
    }
    return FsException(
      '${_osMessage(error)}: $name',
      details: error.toString(),
    );
  }
  return FsException(error.toString(), details: error.toString());
}

/// The machine this app runs on.
class LocalFsBackend implements FsBackend {
  LocalFsBackend({PathStyle? style, this.label = 'This computer'})
    : style = style ?? PathStyle.local();

  @override
  final PathStyle style;

  @override
  final String label;

  @override
  Future<String> home() async {
    final env = Platform.environment;
    final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    if (home != null && home.isNotEmpty && Directory(home).existsSync()) {
      return style.normalize(home);
    }
    return style.isWindows ? style.root : '/';
  }

  @override
  Future<String> canonicalize(String path) async => style.normalize(path);

  @override
  Future<List<FsEntry>> list(String dir) async {
    if (style.isWindows && style.isRoot(dir)) return _drives();
    try {
      final entities = await Directory(dir).list(followLinks: false).toList();
      final entries = <FsEntry>[];
      // Stat in small parallel batches: serial is slow on big folders, and
      // unbounded parallelism exhausts file descriptors.
      for (var i = 0; i < entities.length; i += 32) {
        final batch = entities.skip(i).take(32);
        entries.addAll(await Future.wait(batch.map((e) => _entryFor(dir, e))));
      }
      return entries;
    } catch (e) {
      throw describeLocalError(e, dir);
    }
  }

  Future<FsEntry> _entryFor(String dir, FileSystemEntity entity) async {
    final name = style.basename(entity.path);
    final path = style.join(dir, name);
    try {
      final stat = await entity.stat();
      if (entity is Link) {
        return FsEntry(
          name: name,
          path: path,
          kind: FsKind.link,
          size: stat.type == FileSystemEntityType.notFound ? null : stat.size,
          modified: stat.type == FileSystemEntityType.notFound
              ? null
              : stat.modified,
          linkIsDirectory: stat.type == FileSystemEntityType.directory,
        );
      }
      final kind = switch (stat.type) {
        FileSystemEntityType.directory => FsKind.directory,
        FileSystemEntityType.file => FsKind.file,
        _ => FsKind.other,
      };
      return FsEntry(
        name: name,
        path: path,
        kind: kind,
        size: kind == FsKind.file ? stat.size : null,
        modified: stat.type == FileSystemEntityType.notFound
            ? null
            : stat.modified,
        mode: Platform.isWindows ? null : stat.mode & 0xFFF,
      );
    } catch (_) {
      // Vanished between list and stat, or unreadable: still show the name.
      return FsEntry(name: name, path: path, kind: FsKind.other);
    }
  }

  Future<List<FsEntry>> _drives() async {
    final letters = [for (var c = 0x43; c <= 0x5a; c++) String.fromCharCode(c)];
    final found = await Future.wait(
      letters.map((l) async {
        final path = '$l:\\';
        try {
          return await Directory(path).exists() ? l : null;
        } catch (_) {
          return null;
        }
      }),
    );
    return [
      for (final l in found.whereType<String>())
        FsEntry(name: '$l:', path: '$l:\\', kind: FsKind.directory),
    ];
  }

  @override
  Future<FsEntry?> stat(String path) async {
    if (style.isWindows && style.isRoot(path)) {
      return FsEntry(name: '', path: path, kind: FsKind.directory);
    }
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      final parent = style.parent(path);
      return await _entryFor(parent, switch (type) {
        FileSystemEntityType.directory => Directory(path),
        FileSystemEntityType.link => Link(path),
        _ => File(path),
      });
    } catch (e) {
      throw describeLocalError(e, path);
    }
  }

  @override
  Future<void> mkdir(String path) async {
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FsException('"$path" already exists.', kind: FsErrorKind.exists);
      }
      await Directory(path).create();
    } catch (e) {
      throw describeLocalError(e, path);
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    try {
      final sameFile =
          style.isWindows && from.toLowerCase() == to.toLowerCase();
      if (!sameFile &&
          await FileSystemEntity.type(to, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw FsException('"$to" already exists.', kind: FsErrorKind.exists);
      }
      final type = await FileSystemEntity.type(from, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(from).rename(to);
        case FileSystemEntityType.link:
          await Link(from).rename(to);
        default:
          await File(from).rename(to);
      }
    } catch (e) {
      throw describeLocalError(e, from);
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    try {
      if (await FileSystemEntity.isLink(path)) {
        await Link(path).delete();
      } else {
        await File(path).delete();
      }
    } catch (e) {
      throw describeLocalError(e, path);
    }
  }

  @override
  Future<void> deleteEmptyDirectory(String path) async {
    try {
      await Directory(path).delete();
    } catch (e) {
      throw describeLocalError(e, path);
    }
  }

  @override
  Stream<Uint8List> read(String path) async* {
    try {
      await for (final chunk in File(path).openRead()) {
        yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      }
    } catch (e) {
      throw describeLocalError(e, path);
    }
  }

  @override
  Future<void> write(String path, Stream<Uint8List> data) async {
    final IOSink sink;
    try {
      sink = File(path).openWrite();
    } catch (e) {
      throw describeLocalError(e, path);
    }
    try {
      await sink.addStream(data);
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {
        // The original error is the one worth reporting.
      }
      throw describeLocalError(e, path);
    }
  }

  @override
  Future<void> close() async {}
}
