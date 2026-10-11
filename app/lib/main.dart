import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:window_manager/window_manager.dart';

import 'src/core/app_controller.dart';
import 'src/ui/home/home_page.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'CrossShell',
      size: Size(1100, 760),
      minimumSize: Size(720, 520),
      center: true,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  final app = AppController();
  runApp(
    RepaintBoundary(
      key: _shotKey,
      child: CrossShellApp(app: app),
    ),
  );
  await app.init();
  _maybeScreenshot();
}

final _shotKey = GlobalKey();

/// `CROSSSHELL_SHOT=/path.png` saves a picture of this window (only the
/// app's own widgets, never the screen) after a few seconds and exits.
/// Used for docs and release checks.
void _maybeScreenshot() {
  final path = Platform.environment['CROSSSHELL_SHOT'];
  if (path == null || path.isEmpty) return;
  final delay =
      int.tryParse(Platform.environment['CROSSSHELL_SHOT_DELAY'] ?? '') ?? 6;
  Timer(Duration(seconds: delay), () async {
    final boundary =
        _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary != null) {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes != null) {
        await File(path).writeAsBytes(bytes.buffer.asUint8List());
      }
    }
    exit(0);
  });
}

class CrossShellApp extends StatelessWidget {
  const CrossShellApp({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CrossShell',
    debugShowCheckedModeBanner: false,
    theme: buildLightTheme(),
    darkTheme: buildDarkTheme(),
    home: ListenableBuilder(
      listenable: app,
      builder: (context, _) => app.ready
          ? HomePage(app: app)
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    ),
  );
}
