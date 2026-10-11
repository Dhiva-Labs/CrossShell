import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'fs_backend.dart';
import 'path_style.dart';

/// SFTP wire sizes. 32 KiB is the largest data block every server accepts;
/// 32 requests in flight (1 MiB) keeps a LAN link full: measured the same
/// throughput as 64, with half the buffering.
const int sftpChunkSize = 32 * 1024;
const int sftpMaxPending = 32;

/// How many symlinks per listing get their target resolved. Each costs a round
/// trip, and a directory of thousands (`/etc/alternatives`) must still open
/// quickly.
const int _symlinkResolveLimit = 64;

FsException describeSftpError(Object error, String path) {
  if (error is FsException) return error;
  final name = '"$path"';
  if (error is SftpStatusError) {
    switch (error.code) {
      case 2:
        return FsException(
          '$name does not exist.',
          kind: FsErrorKind.notFound,
          details: error.toString(),
        );
      case 3:
        return FsException(
          'Permission denied: $name',
          kind: FsErrorKind.permissionDenied,
          details: error.toString(),
        );
      case 4:
        return FsException(
          'The server refused the operation on $name: ${error.message}',
          details: error.toString(),
        );
      case 6:
      case 7:
        return FsException(
          'The connection to the peer was lost.',
          kind: FsErrorKind.disconnected,
          details: error.toString(),
        );
      case 8:
        return FsException(
          'The server does not support that operation.',
          details: error.toString(),
        );
    }
    return FsException('${error.message} ($name)', details: error.toString());
  }
  if (error is SftpAbortError) {
    return FsException(
      'The connection to the peer was lost.',
      kind: FsErrorKind.disconnected,
      details: error.toString(),
    );
  }
  if (error is SftpError) {
    return FsException('${error.message} ($name)', details: error.toString());
  }
  if (error is SSHError) {
    return FsException(
      'SSH error: $error',
      kind: FsErrorKind.disconnected,
      details: error.toString(),
    );
  }
  return FsException('$error ($name)', details: error.toString());
}

/// A peer's filesystem over an already-open [SftpClient].
class SftpFsBackend implements FsBackend {
  SftpFsBackend(this._sftp, {required this.style, required this.label});

  final SftpClient _sftp;

  @override
  final PathStyle style;

  @override
  final String label;

  @override
  Future<String> home() async {
    try {
      return style.normalize(await _sftp.absolute('.'));
    } catch (_) {
      // Not fatal: the root is always listable enough to get started.
      return style.root;
    }
  }

  @override
  Future<String> canonicalize(String path) async {
    try {
      return style.normalize(await _sftp.absolute(path));
    } catch (_) {
      // realpath fails for paths that do not exist; listing will then report
      // that properly, which is the better error.
      return style.normalize(path);
    }
  }

  @override
  Future<List<FsEntry>> list(String dir) async {
    final List<SftpName> names;
    try {
      names = await _sftp.listdir(dir);
    } catch (e) {
      throw describeSftpError(e, dir);
    }
    final entries = <FsEntry>[];
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      entries.add(_entry(dir, n.filename, n.attr));
    }
    await _resolveLinks(entries);
    return entries;
  }

  FsEntry _entry(String dir, String name, SftpFileAttrs attrs) {
    final kind = _kindOf(attrs);
    final mtime = attrs.modifyTime;
    return FsEntry(
      name: name,
      path: style.join(dir, name),
      kind: kind,
      // Directory sizes are filesystem noise (4096, 0, 8192).
      size: kind == FsKind.directory ? null : attrs.size,
      modified: (mtime == null || mtime <= 0)
          ? null
          : DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
      mode: attrs.mode == null ? null : attrs.mode!.value & 0xFFF,
    );
  }

  static FsKind _kindOf(SftpFileAttrs a) {
    if (a.isDirectory) return FsKind.directory;
    if (a.isSymbolicLink) return FsKind.link;
    if (a.isFile) return FsKind.file;
    // Some servers omit the mode in listings; a size without one is almost
    // certainly a regular file.
    if (a.mode == null) return a.size != null ? FsKind.file : FsKind.other;
    return FsKind.other;
  }

  Future<void> _resolveLinks(List<FsEntry> entries) async {
    final idx = <int>[];
    for (
      var i = 0;
      i < entries.length && idx.length < _symlinkResolveLimit;
      i++
    ) {
      if (entries[i].kind == FsKind.link) idx.add(i);
    }
    if (idx.isEmpty) return;
    await Future.wait(
      idx.map((i) async {
        try {
          final target = await _sftp.stat(entries[i].path);
          entries[i] = entries[i].copyWith(linkIsDirectory: target.isDirectory);
        } catch (_) {
          // Dangling or unreadable: leave it as a plain link.
        }
      }),
    );
  }

  @override
  Future<FsEntry?> stat(String path) async {
    if (style.isRoot(path)) {
      return FsEntry(name: '', path: path, kind: FsKind.directory);
    }
    try {
      final attrs = await _sftp.stat(path, followLink: false);
      var entry = _entry(style.parent(path), style.basename(path), attrs);
      if (entry.kind == FsKind.link) {
        try {
          entry = entry.copyWith(
            linkIsDirectory: (await _sftp.stat(path)).isDirectory,
          );
        } catch (_) {}
      }
      return entry;
    } on SftpStatusError catch (e) {
      if (e.code == 2) return null;
      throw describeSftpError(e, path);
    } catch (e) {
      throw describeSftpError(e, path);
    }
  }

  @override
  Future<void> mkdir(String path) async {
    try {
      await _sftp.mkdir(path);
    } catch (e) {
      throw describeSftpError(e, path);
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    if (from == to) return;
    final caseOnly = style.isWindows && from.toLowerCase() == to.toLowerCase();
    if (caseOnly) {
      // Win32-OpenSSH's posix-rename deletes the destination before moving
      // the source. For a case-only change those are the same directory, so
      // renaming `docs` to `Docs` destroys it. Go through a temporary name.
      final temp = '$from.cs-rename-${DateTime.now().microsecondsSinceEpoch}';
      await _rename(from, temp);
      try {
        await _rename(temp, to);
      } catch (_) {
        try {
          await _rename(temp, from);
        } catch (_) {
          // Nothing more can be done; the original error is the useful one.
        }
        rethrow;
      }
      return;
    }
    if (await stat(to) != null) {
      throw FsException('"$to" already exists.', kind: FsErrorKind.exists);
    }
    await _rename(from, to);
  }

  Future<void> _rename(String from, String to) async {
    try {
      await _sftp.rename(from, to);
    } catch (e) {
      throw describeSftpError(e, from);
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    try {
      await _sftp.remove(path);
    } catch (e) {
      throw describeSftpError(e, path);
    }
  }

  @override
  Future<void> deleteEmptyDirectory(String path) async {
    try {
      await _sftp.rmdir(path);
    } catch (e) {
      throw describeSftpError(e, path);
    }
  }

  @override
  Stream<Uint8List> read(String path) async* {
    final SftpFile file;
    try {
      file = await _sftp.open(path, mode: SftpFileOpenMode.read);
    } catch (e) {
      throw describeSftpError(e, path);
    }
    try {
      yield* file.read(
        chunkSize: sftpChunkSize,
        maxPendingRequests: sftpMaxPending,
      );
    } catch (e) {
      throw describeSftpError(e, path);
    } finally {
      try {
        await file.close();
      } catch (_) {
        // Channel already gone.
      }
    }
  }

  @override
  Future<void> write(String path, Stream<Uint8List> data) async {
    final SftpFile file;
    try {
      file = await _sftp.open(
        path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
    } catch (e) {
      throw describeSftpError(e, path);
    }
    try {
      final writer = file.write(
        data,
        chunkSize: sftpChunkSize,
        maxPendingRequests: sftpMaxPending,
      );
      await writer.done;
    } catch (e) {
      throw describeSftpError(e, path);
    } finally {
      try {
        await file.close();
      } catch (_) {
        // Channel already gone.
      }
    }
  }

  @override
  Future<void> close() async {
    try {
      await _sftp.close();
    } catch (_) {
      // Already gone.
    }
  }
}
