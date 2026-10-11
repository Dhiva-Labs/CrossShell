// Facts about this machine and helpers for running OS tools.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum HostOs { linux, windows, macos, other }

class LocalSystem {
  LocalSystem._();

  static HostOs get os {
    if (Platform.isLinux) return HostOs.linux;
    if (Platform.isWindows) return HostOs.windows;
    if (Platform.isMacOS) return HostOs.macos;
    return HostOs.other;
  }

  /// `linux` / `windows` / `macos` / `other` — the wire name.
  static String get osName => os.name;

  static String get hostname {
    final h = Platform.localHostname.trim();
    // Windows reports upper case NetBIOS names; lower case reads better.
    return h.isEmpty ? 'computer' : (Platform.isWindows ? h.toLowerCase() : h);
  }

  static String get userName {
    final env = Platform.environment;
    final u = Platform.isWindows
        ? env['USERNAME']
        : (env['USER'] ?? env['LOGNAME']);
    if (u != null && u.isNotEmpty) return u;
    try {
      return (Process.runSync('id', ['-un']).stdout as String).trim();
    } catch (_) {
      return 'user';
    }
  }

  static String get homeDir {
    final env = Platform.environment;
    return (Platform.isWindows ? env['USERPROFILE'] : env['HOME']) ??
        Directory.current.path;
  }

  static String get sshDir => p.join(homeDir, '.ssh');

  /// Path of an OpenSSH tool (`ssh`, `ssh-keygen`, `ssh-keyscan`).
  /// Windows ships them in System32\OpenSSH, which isn't always on PATH for
  /// GUI apps.
  static String sshTool(String name) {
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final exe = p.join(root, 'System32', 'OpenSSH', '$name.exe');
      if (File(exe).existsSync()) return exe;
      return '$name.exe';
    }
    return name;
  }

  /// Windows: is this user a member of BUILTIN\Administrators (even with a
  /// filtered UAC token)? sshd then reads administrators_authorized_keys.
  static Future<bool> isWindowsAdmin() async {
    if (!Platform.isWindows) return false;
    final r = await Process.run('whoami', ['/groups']);
    return (r.stdout as String).contains('S-1-5-32-544');
  }

  /// Directory holding persistent agent metadata other machines read over
  /// SSH (`agent-path`): Linux `~/.local/state/crossshell`, Windows
  /// `%LOCALAPPDATA%\CrossShell`. Mirrors crossshell-host's runtime paths.
  static String get stateDir {
    final env = Platform.environment;
    if (Platform.isWindows) {
      return p.join(
        env['LOCALAPPDATA'] ?? p.join(homeDir, 'AppData', 'Local'),
        'CrossShell',
      );
    }
    final xdg = env['XDG_STATE_HOME'];
    return p.join(
      xdg != null && xdg.isNotEmpty ? xdg : p.join(homeDir, '.local', 'state'),
      'crossshell',
    );
  }

  /// Runtime dir of the local crossshell-host (`host.json`, `status.json`).
  static String get agentRuntimeDir {
    final env = Platform.environment;
    if (Platform.isWindows) return stateDir;
    final xdg = env['XDG_RUNTIME_DIR'];
    return p.join(
      xdg != null && xdg.isNotEmpty ? xdg : p.join(homeDir, '.cache'),
      'crossshell',
    );
  }
}

/// Run a tool and return stdout, throwing [ToolError] on failure.
Future<String> runTool(
  String exe,
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
  String? stdin,
}) async {
  final proc = await Process.start(exe, args);
  if (stdin != null) proc.stdin.write(stdin);
  await proc.stdin.close();
  final out = proc.stdout.transform(utf8.decoder).join();
  final err = proc.stderr.transform(utf8.decoder).join();
  final code = await proc.exitCode.timeout(
    timeout,
    onTimeout: () {
      proc.kill();
      throw ToolError('$exe timed out after ${timeout.inSeconds}s');
    },
  );
  final o = await out;
  if (code != 0) {
    throw ToolError(
      '${p.basename(exe)} failed (exit $code): ${(await err).trim()}',
      exitCode: code,
      stdout: o,
    );
  }
  return o;
}

class ToolError implements Exception {
  ToolError(this.message, {this.exitCode, this.stdout});
  final String message;
  final int? exitCode;
  final String? stdout;
  @override
  String toString() => message;
}

/// Write [contents] atomically, private to this user on Unix.
Future<void> writePrivateFile(String path, String contents) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(contents, flush: true);
  if (!Platform.isWindows) await Process.run('chmod', ['600', tmp.path]);
  await renameReplacing(tmp, path);
}

/// `rename` that replaces [to]. On Windows, antivirus and indexers briefly
/// open freshly written files, and a rename then fails with a sharing
/// violation; retry a few times before giving up.
Future<File> renameReplacing(File from, String to) async {
  for (var attempt = 1; ; attempt++) {
    try {
      return await from.rename(to);
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      final transient =
          Platform.isWindows && (code == 32 || code == 5 || code == 33);
      if (!transient || attempt >= 10) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
    }
  }
}

/// Create a directory private to this user on Unix.
Future<void> ensurePrivateDir(String path) async {
  await Directory(path).create(recursive: true);
  if (!Platform.isWindows) await Process.run('chmod', ['700', path]);
}
