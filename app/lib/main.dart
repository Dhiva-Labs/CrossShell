import 'package:flutter/material.dart';
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
  runApp(CrossShellApp(app: app));
  await app.init();
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
