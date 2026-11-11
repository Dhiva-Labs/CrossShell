// Renders the Microsoft Store screenshots from the app's own screens.
//
//   flutter test tool/store_shots_test.dart
//
// Writes 1920x1080 PNGs to $STORE_SHOTS_DIR (default build/store_shots).
// The screens are the real widgets (HomePage, SetupPage, the pairing dialog,
// SessionPage) fed with fictional sample data: no network, SSH, firewall or
// registry is touched, and nothing is read from or written to the user's
// ~/.ssh. They are rendered widgets, not captures of the running app.
//
// It lives in tool/ so a plain `flutter test` doesn't run it.
//
// Fonts: on Windows the app's text uses the platform font Segoe UI (Material
// typography for TargetPlatform.windows) and the terminal the first installed
// family of terminalFontFamilies (Cascadia Mono on a stock Windows 11). Both
// are loaded here from C:\Windows\Fonts; nothing is copied into the repo.
//
// A test in all but location, so it uses the test seams too.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cross_shell/main.dart';
import 'package:cross_shell/src/core/app_controller.dart';
import 'package:cross_shell/src/core/discovery/discovery.dart';
import 'package:cross_shell/src/core/pairing/pairing_messages.dart';
import 'package:cross_shell/src/core/pairing/pairing_session.dart';
import 'package:cross_shell/src/core/peers/peer.dart';
import 'package:cross_shell/src/core/ssh/public_key.dart';
import 'package:cross_shell/src/core/ssh/ssh_files.dart';
import 'package:cross_shell/src/ui/home/home_page.dart';
import 'package:cross_shell/src/ui/home/pairing_dialog.dart';
import 'package:cross_shell/src/ui/session/files/path_style.dart';
import 'package:cross_shell/src/ui/session/session_page.dart';
import 'package:cross_shell/src/ui/session/terminal/terminal_shell.dart';
import 'package:cross_shell/src/ui/theme.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/ui/helpers/fake_fs.dart';
import '../test/ui/helpers/fake_session.dart';

// ------------------------------------------------------------ sample data
// All fictional: names, user "demo", documentation/LAN addresses.

const _thisPc = 'Home PC';
const _thisIp = '192.168.1.20';
const _user = 'demo';
const _demoSshDir = r'C:\Users\demo\.ssh';

/// A syntactically valid ed25519 public key made of filler bytes.
String _fakeKeyLine() {
  List<int> str(List<int> b) => [
    ...(ByteData(4)..setUint32(0, b.length)).buffer.asUint8List(),
    ...b,
  ];
  final blob = [
    ...str(utf8.encode('ssh-ed25519')),
    ...str(List<int>.generate(32, (i) => (i * 37 + 11) & 0xff)),
  ];
  return 'ssh-ed25519 ${base64.encode(blob)}';
}

Peer _peer(String id, String name, String os, String ip) => Peer(
  id: id,
  name: name,
  os: os,
  alias: makeAlias(name, const []),
  sshUser: _user,
  sshPort: 22,
  hostKeys: [_fakeKeyLine()],
  clientKey: _fakeKeyLine(),
  lastIp: ip,
  pairedAt: DateTime(2026, 10, 1),
);

SeenPeer _seen(String id, String name, String os, String ip) => SeenPeer(
  Beacon(
    id: id,
    name: name,
    os: os,
    user: _user,
    sshPort: 22,
    pairPort: pairingPort,
    version: appVersion,
  ),
  ip,
  DateTime.now(),
);

/// SSH files that never touch disk.
class _SampleSshFiles extends SshFiles {
  _SampleSshFiles(super.layout);

  @override
  Future<PublicKey> ensureClientKey() async => PublicKey.parse(_fakeKeyLine());
}

/// The real controller, with sample state instead of init(): no discovery
/// socket, pairing server, agent or health probes.
class _SampleApp extends AppController {
  _SampleApp() {
    identity = DeviceIdentity('00000000-demo-4000-8000-000000000001', _thisPc);
    settings = AppSettings(); // screen sharing off, port 22
    peers = [
      _peer(
        '00000000-demo-4000-8000-000000000002',
        'Office desktop',
        'windows',
        '192.168.1.23',
      ),
    ];
    seen = [
      _seen(
        '00000000-demo-4000-8000-000000000002',
        'Office desktop',
        'windows',
        '192.168.1.23',
      ),
      _seen(
        '00000000-demo-4000-8000-000000000003',
        'Studio laptop',
        'linux',
        '192.168.1.31',
      ),
    ];
    health = LocalHealth(
      sshServerBanner: 'SSH-2.0-OpenSSH_for_Windows_9.5',
      clientKeyReady: true,
      discoveryError: null,
      pairingError: null,
      agentPath: r'C:\Program Files\CrossShell\crossshell-host.exe',
      agentError: null,
      addresses: const [_thisIp],
    );
  }

  final _layout = SshLayout(_demoSshDir);
  late final _files = _SampleSshFiles(_layout);

  @override
  SshLayout get layout => _layout;
  @override
  SshFiles get files => _files;
  @override
  bool get ready => true;
  @override
  String get userName => _user;

  @override
  Future<void> refreshHealth() async {
    // Like the real probe, report after the current frame.
    await Future<void>.value();
    notifyListeners();
  }
}

/// A shell that is running at once and shows only what the test writes.
class _SampleShell extends TerminalShell {
  _SampleShell(int number) : super(number: number);

  @override
  Future<void> start(SSHClient client) async =>
      debugSetState(ShellState.running);
}

const _terminalText =
    'PS C:\\Users\\demo> whoami\r\n'
    'office-desktop\\demo\r\n'
    'PS C:\\Users\\demo> Get-ChildItem Documents\r\n'
    '\r\n'
    '    Directory: C:\\Users\\demo\\Documents\r\n'
    '\r\n'
    'Mode                 LastWriteTime         Length Name\r\n'
    '----                 -------------         ------ ----\r\n'
    'd----          10/28/2026  9:14 AM                Projects\r\n'
    'd----          11/02/2026  4:40 PM                Recipes\r\n'
    '-a---          11/05/2026 11:02 AM          18342 budget-2027.xlsx\r\n'
    '-a---          11/09/2026  8:27 PM           2210 notes.txt\r\n'
    '\r\n'
    'PS C:\\Users\\demo> ';

// ---------------------------------------------------------------- harness

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
      );
    }
    await loader.load();
  }

  final win = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\Fonts';
  // Segoe UI: regular, semibold, bold (what the Windows app resolves).
  final segoe = [
    '$win\\segoeui.ttf',
    '$win\\seguisb.ttf',
    '$win\\segoeuib.ttf',
  ];
  await family('Segoe UI', segoe);
  // The generic 'monospace' (public key on "This machine") is no family on
  // Windows, where Flutter falls back to the default font, Segoe UI.
  await family('monospace', segoe);
  // The terminal asks for terminalFontFamilies.first and lists the rest as
  // fallbacks; on stock Windows 11 the first installed one is Cascadia Mono.
  // The test font manager answers *any* family name with its box font, so
  // the fallback never happens here: give the first name Cascadia Mono's
  // glyphs, which is what the real app draws on such a PC.
  final cascadia = ['$win\\CascadiaMono.ttf'];
  await family(terminalFontFamilies.first, cascadia);
  await family('Cascadia Mono', cascadia);
  // The icon font ships with the Flutter SDK, next to the dart binary.
  final cache = File(Platform.resolvedExecutable).parent.parent.parent.path;
  await family('MaterialIcons', [
    '$cache/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('store screenshots', (tester) async {
    debugDisableShadows = false;
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final out = Directory(
      Platform.environment['STORE_SHOTS_DIR'] ?? 'build/store_shots',
    )..createSync(recursive: true);
    final support = Directory.systemTemp.createTempSync('cs_shots_');
    addTearDown(() => support.deleteSync(recursive: true));

    final key = GlobalKey();
    Future<void> shot(String name) async {
      await tester.runAsync(() async {
        final box =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await box.toImage(pixelRatio: 1.0);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${out.path}/$name.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    Future<void> settle() async {
      // Let spinners run a little, then stop: pumpAndSettle would wait
      // forever on an indeterminate progress indicator.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    // 1. Home: one paired machine, one nearby.
    final app = _SampleApp();
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: CrossShellApp(app: app)),
    );
    await settle();
    expect(find.text('Office desktop'), findsOneWidget);
    expect(find.text('Studio laptop'), findsOneWidget);
    await shot('01-main');

    // 4 (taken here, over the home page). Pairing with the nearby laptop.
    final cancelled = Completer<String>();
    unawaited(
      showPairingCodeDialog(
        tester.element(find.byType(HomePage)),
        PairingPrompt(
          peer: PeerIdentity(
            id: '00000000-demo-4000-8000-000000000003',
            name: 'Studio laptop',
            os: 'linux',
          ),
          code: '482 913',
          incoming: false,
          remoteCancelled: cancelled.future,
        ),
      ),
    );
    await settle();
    await tester.pumpAndSettle();
    await shot('04-pairing');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // 2. This machine, opened from the gear button.
    await tester.tap(find.byTooltip('This machine'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Let paired PCs view and control this screen'), findsOne);
    await shot('02-this-machine');

    // 3. Scrolled to the end: Network type check and the Remove row.
    await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('Network type'), findsOne);
    expect(find.text('Remove CrossShell changes from this PC'), findsOne);
    await shot('03-remove-and-network');

    // 5. A terminal on the paired Windows machine, with sample output.
    final shells = <_SampleShell>[];
    final remote = FakeFs(const SftpWindowsPathStyle(), home: '/C:/Users/demo')
      ..addDir('/C:/Users/demo/Documents');
    final local = FakeFs(const SftpWindowsPathStyle(), home: '/C:/Users/demo')
      ..addDir('/C:/Users/demo/Documents');
    final session = FakeSession();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          home: SessionPage(
            peerId: '00000000-demo-4000-8000-000000000002',
            title: 'Office desktop',
            os: RemoteOs.windows,
            connect: () async => throw StateError('no network in screenshots'),
            supportDirectory: () async => support,
            onRemoteDesktop: () {},
            onOpenSystemTerminal: () {},
            onOpenVsCode: (_) {},
            testHooks: SessionTestHooks(
              session: () => session,
              shellFactory: (n) {
                final s = _SampleShell(n);
                shells.add(s);
                return s;
              },
              localBackend: local,
              remoteBackendOpener: () async => remote,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await settle();
    shells.first.terminal.write(_terminalText);
    await settle();
    await shot('05-terminal');

    // 6. Home again, in the dark theme (follows Windows' app mode).
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final app2 = _SampleApp();
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: CrossShellApp(app: app2)),
    );
    await settle();
    await shot('06-main-dark');

    // Unmount so timers and controllers are disposed before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    debugDisableShadows = true;
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
