import 'dart:convert';
import 'dart:io';

import 'forward_models.dart';

class ForwardLoadResult {
  const ForwardLoadResult(this.rules, {this.error});
  final List<ForwardRule> rules;

  /// Set when the file existed but could not be fully used. The rules that
  /// could be read are still returned.
  final String? error;
}

/// Saves a peer's forward presets as JSON under the app support directory:
/// `<support>/forwards/<peerId>.json`.
class ForwardStore {
  ForwardStore(this.directory);

  final Directory directory;

  /// Peer ids come from the caller; keep file names tame regardless.
  static String fileSafe(String id) {
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty || cleaned.startsWith('.') ? '_$cleaned' : cleaned;
  }

  File fileFor(String peerId) => File(
    '${directory.path}${Platform.pathSeparator}forwards'
    '${Platform.pathSeparator}${fileSafe(peerId)}.json',
  );

  Future<ForwardLoadResult> load(String peerId) async {
    final file = fileFor(peerId);
    final String text;
    try {
      if (!await file.exists()) return const ForwardLoadResult([]);
      text = await file.readAsString();
    } catch (e) {
      return ForwardLoadResult(
        const [],
        error: 'Could not read ${file.path}: $e',
      );
    }
    try {
      final json = jsonDecode(text);
      final list = json is Map ? json['rules'] : null;
      if (list is! List) throw const FormatException('missing "rules" list');
      final rules = <ForwardRule>[];
      var skipped = 0;
      for (final item in list) {
        final rule = ForwardRule.fromJson(item);
        if (rule == null) {
          skipped++;
        } else if (!rules.any((r) => r.id == rule.id)) {
          rules.add(rule);
        }
      }
      return ForwardLoadResult(
        rules,
        error: skipped > 0
            ? '$skipped saved forward(s) were invalid and ignored.'
            : null,
      );
    } catch (e) {
      // Keep the unreadable file so nothing the user wrote is destroyed by
      // the next save.
      String note = '';
      try {
        final backup = File('${file.path}.bad');
        if (await backup.exists()) await backup.delete();
        await file.rename(backup.path);
        note = ' It was kept as ${backup.path}.';
      } catch (_) {}
      return ForwardLoadResult(
        const [],
        error: 'Saved forwards could not be read ($e).$note',
      );
    }
  }

  /// Writes atomically: a crash mid-save leaves the previous file intact.
  Future<void> save(String peerId, List<ForwardRule> rules) async {
    final file = fileFor(peerId);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    final body = const JsonEncoder.withIndent('  ').convert({
      'v': 1,
      'rules': [for (final r in rules) r.toJson()],
    });
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(file.path);
  }
}
