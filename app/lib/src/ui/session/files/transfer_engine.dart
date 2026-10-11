import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'fs_backend.dart';
import 'transfer_queue.dart';

/// What to do when a file already exists at the destination.
enum ConflictPolicy { overwrite, skip }

/// One top-level item to copy: [source] lands in the destination directory as
/// [destName] (usually its own name; different when the user chose "keep
/// both").
class CopyItem {
  const CopyItem(this.source, [String? destName]) : _destName = destName;
  final FsEntry source;
  final String? _destName;
  String get destName => _destName ?? source.name;
}

/// `report.pdf` -> `report (1).pdf` -> `report (2).pdf`, skipping any name
/// [taken] reports. Folders keep their dots (`v1.2` -> `v1.2 (1)`).
String uniqueName(
  String name,
  bool Function(String) taken, {
  bool isDirectory = false,
}) {
  if (!taken(name)) return name;
  final dot = name.lastIndexOf('.');
  final hasExt = !isDirectory && dot > 0 && dot < name.length - 1;
  final stem = hasExt ? name.substring(0, dot) : name;
  final ext = hasExt ? name.substring(dot) : '';
  for (var n = 1; n < 10000; n++) {
    final candidate = '$stem ($n)$ext';
    if (!taken(candidate)) return candidate;
  }
  return '$stem (${DateTime.now().millisecondsSinceEpoch})$ext';
}

class _FilePlan {
  _FilePlan(this.from, this.to, this.size, {this.isLink = false});
  final String from;
  final String to;
  final int? size;

  /// A link whose target is read through. If the target is gone that is
  /// worth a warning, not a failed transfer: broken links are routine in
  /// real folders (node_modules/.bin, old build trees).
  final bool isLink;
}

class _Plan {
  final List<String> dirs = []; // destination directories, parents first
  final List<_FilePlan> files = [];
  int skippedLinks = 0;
  int unknownSizes = 0;
}

/// Copies and deletes between any two [FsBackend]s. Everything streams: no
/// file is ever held in memory whole.
class TransferEngine {
  const TransferEngine._();

  /// Builds the runner for copying [items] from [from] into [destDir] on [to].
  static TaskRunner copy({
    required FsBackend from,
    required FsBackend to,
    required List<CopyItem> items,
    required String destDir,
    ConflictPolicy policy = ConflictPolicy.overwrite,
    int parallelFiles = 4,
  }) {
    return (ctx) async {
      ctx.setPhase('Scanning...');
      final plan = _Plan();
      for (final item in items) {
        ctx.throwIfCancelled();
        await _scan(from, to, item, destDir, plan, ctx);
      }
      final known = plan.files.where((f) => f.size != null);
      ctx.setTotal(
        plan.unknownSizes > 0
            ? null
            : known.fold<int>(0, (s, f) => s + f.size!),
      );
      ctx.setFiles(done: 0, total: plan.files.length);
      ctx.setPhase(null);
      if (plan.skippedLinks > 0) {
        ctx.warn(
          'Skipped ${plan.skippedLinks} link(s) to folders or special files.',
        );
      }

      for (final dir in plan.dirs) {
        ctx.throwIfCancelled();
        await _ensureDirectory(to, dir);
      }

      var done = 0;
      final failures = <String>[];
      final pending = Queue<_FilePlan>.of(plan.files);

      Future<void> worker() async {
        while (pending.isNotEmpty && !ctx.cancelled) {
          final file = pending.removeFirst();
          try {
            await _copyFile(from, to, file, policy, ctx);
          } catch (e) {
            if (ctx.cancelled) return;
            if (file.isLink) {
              ctx.warn('Skipped broken link ${file.from}: $e');
            } else {
              failures.add('${file.from}: $e');
              ctx.warn('${file.from}: $e');
            }
          }
          done++;
          ctx.setFiles(done: done);
        }
      }

      final workers = plan.files.length <= 1 ? 1 : parallelFiles.clamp(1, 16);
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
      ctx.throwIfCancelled();

      if (failures.isNotEmpty) {
        final first = failures.first;
        throw FsException(
          failures.length == 1
              ? first
              : '${failures.length} files failed. First: $first',
        );
      }
    };
  }

  /// Builds the runner for deleting [items] (folders recursively) on [fs].
  static TaskRunner delete({
    required FsBackend fs,
    required List<FsEntry> items,
  }) {
    return (ctx) async {
      var removed = 0;
      Future<void> remove(FsEntry e) async {
        ctx.throwIfCancelled();
        // A link is removed itself; following it could delete outside the
        // folder the user selected.
        if (e.kind == FsKind.directory) {
          for (final child in await fs.list(e.path)) {
            await remove(child);
          }
          ctx.throwIfCancelled();
          await fs.deleteEmptyDirectory(e.path);
        } else {
          await fs.deleteFile(e.path);
        }
        removed++;
        ctx.setFiles(done: removed);
        ctx.setPhase('Deleted $removed item${removed == 1 ? '' : 's'}');
      }

      for (final item in items) {
        await remove(item);
      }
    };
  }

  static Future<void> _scan(
    FsBackend from,
    FsBackend to,
    CopyItem item,
    String destDir,
    _Plan plan,
    TaskContext ctx,
  ) async {
    final source = item.source;
    final destPath = to.style.join(
      destDir,
      to.style.sanitizeName(item.destName),
    );
    if (source.isDirectory && source.kind != FsKind.link) {
      plan.dirs.add(destPath);
      await _scanDir(from, to, source.path, destPath, plan, ctx);
    } else if (source.kind == FsKind.link && source.linkIsDirectory) {
      plan.skippedLinks++;
    } else if (source.kind == FsKind.other) {
      plan.skippedLinks++;
    } else {
      plan.files.add(
        _FilePlan(
          source.path,
          destPath,
          source.size,
          isLink: source.kind == FsKind.link,
        ),
      );
      if (source.size == null) plan.unknownSizes++;
    }
  }

  static Future<void> _scanDir(
    FsBackend from,
    FsBackend to,
    String srcDir,
    String dstDir,
    _Plan plan,
    TaskContext ctx,
  ) async {
    ctx.throwIfCancelled();
    final children = await from.list(srcDir);
    for (final child in children) {
      final dst = to.style.join(dstDir, to.style.sanitizeName(child.name));
      if (child.kind == FsKind.directory) {
        plan.dirs.add(dst);
        await _scanDir(from, to, child.path, dst, plan, ctx);
      } else if (child.kind == FsKind.file ||
          (child.kind == FsKind.link && !child.linkIsDirectory)) {
        plan.files.add(
          _FilePlan(
            child.path,
            dst,
            child.size,
            isLink: child.kind == FsKind.link,
          ),
        );
        if (child.size == null) plan.unknownSizes++;
      } else {
        plan.skippedLinks++;
      }
    }
    ctx.setPhase('Scanning... ${plan.files.length} files');
  }

  static Future<void> _ensureDirectory(FsBackend to, String path) async {
    final existing = await to.stat(path);
    if (existing == null) {
      await to.mkdir(path);
    } else if (!existing.isDirectory) {
      throw FsException(
        '"$path" exists and is not a folder.',
        kind: FsErrorKind.exists,
      );
    }
  }

  static Future<void> _copyFile(
    FsBackend from,
    FsBackend to,
    _FilePlan file,
    ConflictPolicy policy,
    TaskContext ctx,
  ) async {
    ctx.throwIfCancelled();
    final existing = await to.stat(file.to);
    if (existing != null) {
      if (existing.isDirectory) {
        throw FsException(
          '"${file.to}" exists and is a folder.',
          kind: FsErrorKind.exists,
        );
      }
      if (policy == ConflictPolicy.skip) {
        // Count the skipped bytes as done so the bar still reaches 100%.
        ctx.addBytes(file.size ?? 0);
        return;
      }
    }

    Stream<Uint8List> source() async* {
      await for (final chunk in from.read(file.from)) {
        if (ctx.cancelled) throw const TransferCancelled();
        ctx.addBytes(chunk.length);
        yield chunk;
      }
    }

    try {
      await to.write(file.to, source());
    } catch (_) {
      // Never leave a truncated file that looks complete to everything else.
      try {
        await to.deleteFile(file.to);
      } catch (_) {}
      rethrow;
    }
  }
}
