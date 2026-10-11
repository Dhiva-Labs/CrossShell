import 'dart:io' show Platform;

import 'package:path/path.dart' as p;

import '../session_types.dart';

/// One crumb of a path bar.
class PathCrumb {
  const PathCrumb(this.label, this.path);
  final String label;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is PathCrumb && other.label == label && other.path == path;

  @override
  int get hashCode => Object.hash(label, path);

  @override
  String toString() => 'PathCrumb($label, $path)';
}

/// Path arithmetic for one kind of filesystem.
///
/// Three flavours exist because the app talks to three different path
/// grammars, and `package:path` can only describe the host's own:
///  * [PosixPathStyle]: Linux locally and Linux/macOS peers over SFTP.
///  * [LocalWindowsPathStyle]: `C:\Users\me`, with a virtual root that lists
///    the drives.
///  * [SftpWindowsPathStyle]: what Win32-OpenSSH's sftp-server speaks:
///    `/C:/Users/me`, with `/` listing the drives.
abstract class PathStyle {
  const PathStyle();

  /// The top of the tree. Listing it yields drives on Windows styles.
  String get root;

  bool get isWindows;

  /// How a path is shown in the path bar.
  String displayPath(String path) => path;

  /// Label for [root] in breadcrumbs.
  String get rootLabel;

  /// Canonical form: absolute, `.`/`..`/duplicate separators collapsed.
  String normalize(String path);

  String join(String dir, String name);

  /// The containing directory. [root] is its own parent.
  String parent(String path);

  /// The final segment; empty for [root].
  String basename(String path);

  List<PathCrumb> breadcrumbs(String path);

  bool isRoot(String path) => normalize(path) == root;

  /// Resolves what a user typed in the path bar against [cwd].
  String resolveInput(String input, String cwd, {String? home}) {
    var text = input.trim();
    if (text.isEmpty) return cwd;
    if (home != null && (text == '~' || text.startsWith('~/'))) {
      text = text == '~' ? home : join(home, text.substring(2));
    }
    return join(cwd, text);
  }

  /// True when [path] is [ancestor] itself or lies below it. Used to refuse
  /// copying a folder into itself.
  bool isWithin(String ancestor, String path);

  /// Whether a file manager would hide [name] by default.
  bool isHidden(String name);

  /// A human sentence if [name] cannot be used for a new file or folder, or
  /// null when it is fine.
  String? invalidNameReason(String name);

  /// [name] with characters this filesystem forbids replaced, for names that
  /// arrive from a different kind of filesystem.
  String sanitizeName(String name);

  static PathStyle local() => Platform.isWindows
      ? const LocalWindowsPathStyle()
      : const PosixPathStyle();

  /// The style for a peer. [home] is the server's own answer to
  /// `realpath('.')` and wins over [os]: a Windows sshd reports
  /// `/C:/Users/me`, which no POSIX host would.
  static PathStyle remote(RemoteOs os, {String? home}) {
    if (home != null && SftpWindowsPathStyle.looksLikeWindows(home)) {
      return const SftpWindowsPathStyle();
    }
    return os == RemoteOs.windows
        ? const SftpWindowsPathStyle()
        : const PosixPathStyle();
  }
}

class PosixPathStyle extends PathStyle {
  const PosixPathStyle();

  @override
  String get root => '/';

  @override
  bool get isWindows => false;

  @override
  String get rootLabel => '/';

  @override
  String normalize(String path) {
    final segments = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    return '/${segments.join('/')}';
  }

  @override
  String join(String dir, String name) {
    if (name.startsWith('/')) return normalize(name);
    if (dir.isEmpty) return normalize('/$name');
    return normalize('$dir/$name');
  }

  @override
  String parent(String path) {
    final n = normalize(path);
    if (n == '/') return '/';
    final i = n.lastIndexOf('/');
    return i <= 0 ? '/' : n.substring(0, i);
  }

  @override
  String basename(String path) {
    final n = normalize(path);
    return n == '/' ? '' : n.substring(n.lastIndexOf('/') + 1);
  }

  @override
  List<PathCrumb> breadcrumbs(String path) {
    final n = normalize(path);
    final crumbs = <PathCrumb>[const PathCrumb('/', '/')];
    var acc = '';
    for (final part in n.split('/')) {
      if (part.isEmpty) continue;
      acc = '$acc/$part';
      crumbs.add(PathCrumb(part, acc));
    }
    return crumbs;
  }

  @override
  bool isWithin(String ancestor, String path) {
    final a = normalize(ancestor);
    final b = normalize(path);
    if (a == '/') return true;
    return b == a || b.startsWith('$a/');
  }

  @override
  bool isHidden(String name) => name.startsWith('.');

  @override
  String? invalidNameReason(String name) {
    if (name.isEmpty) return 'Name cannot be empty.';
    if (name == '.' || name == '..') return 'That name is reserved.';
    if (name.contains('/')) return 'Names cannot contain "/".';
    if (name.contains('\u0000')) return 'Names cannot contain NUL.';
    return null;
  }

  @override
  String sanitizeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[/\u0000]'), '_');
    return cleaned.isEmpty ? '_' : cleaned;
  }
}

final RegExp _driveSegment = RegExp(r'^[A-Za-z]:$');
final RegExp _leadingDrive = RegExp(r'^/?[A-Za-z]:(?:[/\\]|$)');

/// Names Windows hides (or that nobody wants to see) with no attribute
/// available over SFTP v3, so this is a heuristic, not a promise.
const Set<String> _windowsHiddenNames = {
  'desktop.ini',
  'thumbs.db',
  'appdata',
  'application data',
  'cookies',
  'local settings',
  'nethood',
  'printhood',
  'recent',
  'sendto',
  'start menu',
  'templates',
  'my documents',
  'documents and settings',
  'system volume information',
  'pagefile.sys',
  'swapfile.sys',
  'hiberfil.sys',
  'config.msi',
  'recovery',
  'programdata',
};

bool _windowsHidden(String name) {
  if (name.startsWith('.') || name.startsWith(r'$')) return true;
  final lower = name.toLowerCase();
  return _windowsHiddenNames.contains(lower) || lower.startsWith('ntuser.');
}

const String _windowsForbidden = r'<>:"/\|?*';

String? _windowsInvalidName(String name) {
  if (name.isEmpty) return 'Name cannot be empty.';
  if (name == '.' || name == '..') return 'That name is reserved.';
  for (final c in name.runes) {
    if (c < 0x20 || _windowsForbidden.contains(String.fromCharCode(c))) {
      return 'Windows names cannot contain $_windowsForbidden';
    }
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    return 'Windows names cannot end with a dot or a space.';
  }
  return null;
}

String _windowsSanitize(String name) {
  var cleaned = name.replaceAllMapped(
    RegExp(r'[<>:"/\\|?*\u0000-\u001f]'),
    (_) => '_',
  );
  cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
  return cleaned.isEmpty ? '_' : cleaned;
}

/// `/C:/Users/me` as spoken by Win32-OpenSSH's sftp-server.
///
/// `/` lists the drives (`C:`, `D:`), and a drive root is canonically
/// `/C:/`, which is also what the server's own `realpath` returns.
class SftpWindowsPathStyle extends PathStyle {
  const SftpWindowsPathStyle();

  /// True for paths shaped like `/C:/...` (or `C:\...`).
  static bool looksLikeWindows(String path) => _leadingDrive.hasMatch(path);

  @override
  String get root => '/';

  @override
  bool get isWindows => true;

  @override
  String get rootLabel => 'Drives';

  @override
  String normalize(String path) {
    var s = path.replaceAll('\\', '/');
    if (RegExp(r'^[A-Za-z]:').hasMatch(s)) s = '/$s';
    final segments = <String>[];
    for (final part in s.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    if (segments.isEmpty) return '/';
    if (_driveSegment.hasMatch(segments.first)) {
      segments[0] = segments.first.toUpperCase();
      if (segments.length == 1) return '/${segments.first}/';
    }
    return '/${segments.join('/')}';
  }

  @override
  String join(String dir, String name) {
    if (name.startsWith('/') ||
        name.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:([/\\]|$)').hasMatch(name)) {
      return normalize(name);
    }
    if (dir.isEmpty) return normalize('/$name');
    return normalize('$dir/$name');
  }

  @override
  String parent(String path) {
    final n = normalize(path);
    if (n == '/') return '/';
    if (RegExp(r'^/[A-Z]:/$').hasMatch(n)) return '/';
    final i = n.lastIndexOf('/');
    return i <= 0 ? '/' : normalize(n.substring(0, i));
  }

  @override
  String basename(String path) {
    final n = normalize(path);
    if (n == '/') return '';
    if (RegExp(r'^/[A-Z]:/$').hasMatch(n)) return n.substring(1, 3);
    return n.substring(n.lastIndexOf('/') + 1);
  }

  @override
  List<PathCrumb> breadcrumbs(String path) {
    final n = normalize(path);
    final crumbs = <PathCrumb>[PathCrumb(rootLabel, '/')];
    var acc = '';
    for (final part in n.split('/')) {
      if (part.isEmpty) continue;
      acc = '$acc/$part';
      crumbs.add(PathCrumb(part, normalize(acc)));
    }
    return crumbs;
  }

  @override
  bool isWithin(String ancestor, String path) {
    final a = normalize(ancestor).toLowerCase();
    final b = normalize(path).toLowerCase();
    if (a == '/') return true;
    final prefix = a.endsWith('/') ? a : '$a/';
    return b == a || b.startsWith(prefix);
  }

  @override
  bool isHidden(String name) => _windowsHidden(name);

  @override
  String? invalidNameReason(String name) => _windowsInvalidName(name);

  @override
  String sanitizeName(String name) => _windowsSanitize(name);
}

/// `C:\Users\me` on a Windows machine running this app. The virtual root is
/// the empty string and lists the drives.
class LocalWindowsPathStyle extends PathStyle {
  const LocalWindowsPathStyle();

  @override
  String get root => '';

  @override
  bool get isWindows => true;

  @override
  String get rootLabel => 'This PC';

  @override
  String displayPath(String path) => path.isEmpty ? rootLabel : path;

  @override
  String normalize(String path) {
    var s = path.trim().replaceAll('/', '\\');
    if (s.isEmpty) return '';
    if (_driveSegment.hasMatch(s)) s = '$s\\';
    var n = p.windows.normalize(s);
    if (RegExp(r'^[A-Za-z]:').hasMatch(n)) {
      n = n[0].toUpperCase() + n.substring(1);
    }
    if (n.length > 3 && n.endsWith('\\')) n = n.substring(0, n.length - 1);
    return n == '.' ? '' : n;
  }

  bool _isDriveRoot(String n) => RegExp(r'^[A-Z]:\\$').hasMatch(n);

  @override
  String join(String dir, String name) {
    final fixed = name.replaceAll('/', '\\');
    if (p.windows.isAbsolute(fixed) || _driveSegment.hasMatch(fixed)) {
      return normalize(fixed);
    }
    if (dir.isEmpty) return normalize(fixed);
    return normalize(p.windows.join(dir, fixed));
  }

  @override
  String parent(String path) {
    final n = normalize(path);
    if (n.isEmpty || _isDriveRoot(n)) return '';
    final up = p.windows.dirname(n);
    return up == n ? '' : normalize(up);
  }

  @override
  String basename(String path) {
    final n = normalize(path);
    if (n.isEmpty) return '';
    if (_isDriveRoot(n)) return n.substring(0, 2);
    return p.windows.basename(n);
  }

  @override
  List<PathCrumb> breadcrumbs(String path) {
    final n = normalize(path);
    final crumbs = <PathCrumb>[PathCrumb(rootLabel, '')];
    if (n.isEmpty) return crumbs;
    final parts = <String>[];
    var cursor = n;
    while (cursor.isNotEmpty) {
      parts.add(cursor);
      cursor = parent(cursor);
    }
    for (final full in parts.reversed) {
      crumbs.add(PathCrumb(basename(full), full));
    }
    return crumbs;
  }

  @override
  bool isWithin(String ancestor, String path) {
    final a = normalize(ancestor).toLowerCase();
    final b = normalize(path).toLowerCase();
    if (a.isEmpty) return true;
    final prefix = a.endsWith('\\') ? a : '$a\\';
    return b == a || b.startsWith(prefix);
  }

  @override
  bool isHidden(String name) => _windowsHidden(name);

  @override
  String? invalidNameReason(String name) => _windowsInvalidName(name);

  @override
  String sanitizeName(String name) => _windowsSanitize(name);
}
