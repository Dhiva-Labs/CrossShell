// End-to-end test hooks, honoured only in debug/profile builds (release
// builds ignore them, so a stray environment variable can never make a
// shipped app confirm a pairing on its own).
//
//   CROSSSHELL_TEST_LOG=/path.log      append test events (one JSON per line)
//   CROSSSHELL_TEST_AUTOCONFIRM=1      confirm pairing codes automatically,
//                                      logging the code so both sides can be compared
//   CROSSSHELL_TEST_PAIR=<address>     pair with <address> once the app is up

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../src/core/app_controller.dart';

bool get testHooksEnabled => !kReleaseMode;

void _log(Map<String, Object?> event) {
  final path = Platform.environment['CROSSSHELL_TEST_LOG'];
  if (path == null || path.isEmpty) return;
  File(path).writeAsStringSync(
    '${jsonEncode({'t': DateTime.now().toIso8601String(), ...event})}\n',
    mode: FileMode.append,
    flush: true,
  );
}

/// Install the hooks after the UI has registered its own handlers.
Future<void> installTestHooks(AppController app) async {
  if (!testHooksEnabled) return;
  final env = Platform.environment;
  if (env['CROSSSHELL_TEST_LOG'] == null) return;
  _log({'ev': 'ready', 'id': app.identity.id, 'name': app.identity.name});

  if (env['CROSSSHELL_TEST_AUTOCONFIRM'] == '1') {
    app.promptHandler = (prompt) async {
      _log({
        'ev': 'code',
        'code': prompt.code,
        'peer': prompt.peer.name,
        'incoming': prompt.incoming,
      });
      return true;
    };
    final previous = app.onNotice;
    app.onNotice = (msg, {error = false}) {
      _log({'ev': 'notice', 'msg': msg, 'error': error});
      previous?.call(msg, error: error);
    };
  }

  final target = env['CROSSSHELL_TEST_PAIR'];
  if (target != null && target.isNotEmpty) {
    try {
      final peer = await app.pairWith(target);
      _log({
        'ev': 'paired',
        'peer': peer.name,
        'alias': peer.alias,
        'canConnect': peer.canConnect,
      });
    } catch (e) {
      _log({'ev': 'pair-failed', 'error': '$e'});
    }
  }
}
