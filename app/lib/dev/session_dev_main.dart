// Development entrypoint for the connected-peer session UI. Not part of the
// shipped app.
//
//   CS_DEV_HOST=192.168.0.129 CS_DEV_USER=dhiva CS_DEV_KEY=~/.ssh/id_ed25519 \
//   CS_DEV_OS=windows flutter run -d linux -t lib/dev/session_dev_main.dart
//
// Optional: CS_DEV_PORT, CS_DEV_TITLE, CS_DEV_TAB=terminal|files|forwards,
// CS_DEV_KEY_PASSPHRASE, CS_DEV_SUPPORT (where presets are saved),
// CS_DEV_SHOT=/path.png [CS_DEV_SHOT_DELAY=seconds] (save a screenshot and exit),
// CS_DEV_SHOT_COUNT=n CS_DEV_SHOT_EVERY=seconds (save /path-1.png ... n, then
// exit; lets an outside script drive the window with xdotool).
//
// This connects WITHOUT checking the host key. That is acceptable only here:
// the real app pins host keys at pairing and never trusts on first use.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../src/ui/session/session_page.dart';
import 'package:cross_shell/src/core/ssh/ssh_algorithms.dart';
import '../src/ui/theme.dart';

final Map<String, String> _env = Platform.environment;

String _expandHome(String path) => path.startsWith('~')
    ? '${_env['HOME'] ?? _env['USERPROFILE'] ?? ''}${path.substring(1)}'
    : path;

Future<SSHClient> _connect() async {
  final host = _env['CS_DEV_HOST']!;
  final port = int.tryParse(_env['CS_DEV_PORT'] ?? '') ?? 22;
  final keyPath = _expandHome(_env['CS_DEV_KEY'] ?? '~/.ssh/id_ed25519');
  final pem = await File(keyPath).readAsString();
  final passphrase = _env['CS_DEV_KEY_PASSPHRASE'];
  final identities = SSHKeyPair.isEncryptedPem(pem)
      ? SSHKeyPair.fromPem(pem, passphrase)
      : SSHKeyPair.fromPem(pem);
  final socket = await SSHSocket.connect(
    host,
    port,
    timeout: const Duration(seconds: 10),
  );
  return SSHClient(
    socket,
    username: _env['CS_DEV_USER'] ?? Platform.environment['USER'] ?? 'user',
    identities: identities,
    algorithms: fastSshAlgorithms,
    // DEV ONLY: accept any host key. Never do this outside this file.
    onVerifyHostKey: (type, fingerprint) => true,
  );
}

void main() {
  runApp(const _DevApp());
}

class _DevApp extends StatefulWidget {
  const _DevApp();

  @override
  State<_DevApp> createState() => _DevAppState();
}

class _DevAppState extends State<_DevApp> {
  final GlobalKey _shotKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final shot = _env['CS_DEV_SHOT'];
    if (shot == null || shot.isEmpty) return;
    final delay = int.tryParse(_env['CS_DEV_SHOT_DELAY'] ?? '') ?? 7;
    final count = int.tryParse(_env['CS_DEV_SHOT_COUNT'] ?? '') ?? 0;
    if (count <= 0) {
      Timer(
        Duration(seconds: delay),
        () => unawaited(_capture(shot, exitAfter: true)),
      );
      return;
    }
    final every = int.tryParse(_env['CS_DEV_SHOT_EVERY'] ?? '') ?? 2;
    var n = 0;
    Timer(Duration(seconds: delay), () {
      Timer.periodic(Duration(seconds: every), (timer) async {
        n++;
        final base = shot.endsWith('.png')
            ? shot.substring(0, shot.length - 4)
            : shot;
        await _capture('$base-$n.png', exitAfter: n >= count);
        if (n >= count) timer.cancel();
      });
    });
  }

  Future<void> _capture(String path, {required bool exitAfter}) async {
    try {
      final boundary =
          _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      stdout.writeln('screenshot saved to $path');
    } catch (e) {
      stderr.writeln('screenshot failed: $e');
    }
    if (exitAfter) exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final host = _env['CS_DEV_HOST'];
    return MaterialApp(
      title: 'CrossShell session (dev)',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      home: RepaintBoundary(
        key: _shotKey,
        child: host == null || host.isEmpty
            ? const _MissingConfig()
            : SessionPage(
                peerId: 'dev-${_env['CS_DEV_HOST']}',
                title: _env['CS_DEV_TITLE'] ?? host,
                os:
                    RemoteOs.values.asNameMap()[_env['CS_DEV_OS']] ??
                    RemoteOs.other,
                connect: _connect,
                initialTab:
                    SessionTab.values.asNameMap()[_env['CS_DEV_TAB']] ??
                    SessionTab.terminal,
                supportDirectory: () async {
                  final dir = Directory(
                    _env['CS_DEV_SUPPORT'] ??
                        '${Directory.systemTemp.path}/crossshell_dev_support',
                  );
                  await dir.create(recursive: true);
                  return dir;
                },
                onRemoteDesktop: () =>
                    debugPrint('dev: remote desktop requested'),
                onOpenSystemTerminal: () =>
                    debugPrint('dev: system terminal requested'),
                onOpenVsCode: (path) =>
                    debugPrint('dev: VS Code requested for $path'),
              ),
      ),
    );
  }
}

class _MissingConfig extends StatelessWidget {
  const _MissingConfig();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SelectableText(
          'Set CS_DEV_HOST (and CS_DEV_USER, CS_DEV_KEY, CS_DEV_OS) to connect.\n\n'
          'CS_DEV_HOST=192.168.0.129 CS_DEV_USER=dhiva CS_DEV_OS=windows \\\n'
          '  flutter run -d linux -t lib/dev/session_dev_main.dart',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
