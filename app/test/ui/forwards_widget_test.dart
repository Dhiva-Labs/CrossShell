import 'dart:async';
import 'dart:io';

import 'package:cross_shell/src/ui/session/forwards/forward_manager.dart';
import 'package:cross_shell/src/ui/session/forwards/forward_models.dart';
import 'package:cross_shell/src/ui/session/forwards/forward_store.dart';
import 'package:cross_shell/src/ui/session/forwards/forwards_tab.dart';
import 'package:cross_shell/src/ui/session/session_controller.dart';
import 'package:cross_shell/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_session.dart';

class _Rig {
  _Rig(this.tester, {FakeSession? session})
    : session = session ?? FakeSession(),
      dir = Directory.systemTemp.createTempSync('cs_fwd_ui_') {
    manager = ForwardManager(
      peerId: 'peer-1',
      session: this.session,
      store: ForwardStore(dir),
    );
    addTearDown(() async {
      manager.dispose();
      this.session.dispose();
      dir.deleteSync(recursive: true);
    });
  }

  final WidgetTester tester;
  final FakeSession session;
  final Directory dir;
  late final ForwardManager manager;

  /// Real I/O (files, sockets) only advances outside the fake-async zone.
  /// For flows that began in the fake zone (a dialog's continuation): the
  /// real I/O and the fake-zone continuations take turns.
  Future<void> drain([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Runs [action] (a tap or callback that kicks off file and socket work)
  /// in the real zone, so its follow-up I/O completes, then redraws.
  Future<void> real(FutureOr<void> Function() action, [int ms = 250]) async {
    await tester.runAsync(() async {
      await action();
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> pump() async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(manager.load);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: ForwardsTab(manager: manager, peerTitle: 'lenovo'),
        ),
      ),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('empty state explains forwards and offers the dev ports', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    expect(find.text('No forwards yet'), findsOneWidget);
    for (final port in ['3000', '4200', '5173', '8000', '8080', '5432']) {
      expect(find.widgetWithText(ActionChip, port), findsOneWidget);
    }
    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
  });

  testWidgets('one click on 5173 adds, saves and starts a local forward', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await r.real(() => tester.tap(find.widgetWithText(ActionChip, '5173')));
    expect(r.manager.items.single.rule.bindPort, 5173);
    expect(r.manager.items.single.rule.kind, ForwardKind.local);
    expect(find.text('Port 5173'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:5173'), findsOneWidget);
    // It really bound the port (or says why not), and persisted.
    final state = r.manager.items.single.state;
    expect([ForwardState.running, ForwardState.error], contains(state));
    final stored = await tester.runAsync(
      () => ForwardStore(r.dir).load('peer-1'),
    );
    expect(stored!.rules.single.bindPort, 5173);
    await tester.runAsync(r.manager.stopAll);
  });

  testWidgets('the Remote switch makes the presets reverse forwards', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await tester.tap(find.text('Remote'));
    await tester.pump();
    await r.real(() => tester.tap(find.widgetWithText(ActionChip, '8080')));
    final rt = r.manager.items.single;
    expect(rt.rule.kind, ForwardKind.remote);
    expect(rt.rule.bindHost, 'localhost');
    expect(find.text('Port 8080 (reverse)'), findsOneWidget);
    expect(find.textContaining('Listens on lenovo'), findsOneWidget);
    await tester.runAsync(r.manager.stopAll);
  });

  testWidgets('clicking a preset that is already running says so', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await r.real(() => tester.tap(find.widgetWithText(ActionChip, '3000')));
    final rt = r.manager.items.single;
    if (rt.state == ForwardState.running) {
      await r.real(() => tester.tap(find.widgetWithText(ActionChip, '3000')));
      expect(find.textContaining('already forwarded'), findsOneWidget);
      expect(r.manager.items.length, 1);
    }
    await tester.runAsync(r.manager.stopAll);
  });

  testWidgets('a port that is taken shows the real reason on the card', (
    tester,
  ) async {
    final taken = await tester.runAsync(
      () => ServerSocket.bind('127.0.0.1', 0),
    );
    addTearDown(() => taken!.close());
    final r = _Rig(tester);
    await r.pump();
    await tester.runAsync(
      () => r.manager.add(
        ForwardRule.create(
          kind: ForwardKind.local,
          bindPort: taken!.port,
          targetPort: 80,
        ),
        start: true,
      ),
    );
    await tester.pump();
    expect(find.text('Error'), findsOneWidget);
    expect(find.textContaining('already in use'), findsOneWidget);
  });

  testWidgets('the switch stops and restarts; the stopped card says Stopped', (
    tester,
  ) async {
    final r = _Rig(tester);
    await r.pump();
    await tester.runAsync(
      () => r.manager.add(
        ForwardRule.devPort(48555, ForwardKind.local),
        start: true,
      ),
    );
    await tester.pump();
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('0 active'), findsOneWidget);

    await r.real(
      () => tester.widget<Switch>(find.byType(Switch)).onChanged!(false),
    );
    expect(find.text('Stopped'), findsOneWidget);
    expect(r.manager.items.single.state, ForwardState.stopped);

    await r.real(
      () => tester.widget<Switch>(find.byType(Switch)).onChanged!(true),
    );
    expect(find.text('Running'), findsOneWidget);
    await tester.runAsync(r.manager.stopAll);
  });

  testWidgets('Add forward dialog validates ports and saves a remote forward', (
    tester,
  ) async {
    final r = _Rig(tester);
    r.session.set(ConnectionPhase.lost);
    await r.pump();
    await tester.tap(find.text('Add forward'));
    await tester.pumpAndSettle();
    expect(find.text('Add forward'), findsWidgets);

    Future<void> submit() async {
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add and start'),
          )
          .onPressed!();
      await tester.pump();
    }

    await submit();
    expect(find.textContaining('listening port'), findsOneWidget);

    final fields = find.byType(TextField);
    // name, bind host, bind port, target host, target port
    await tester.enterText(fields.at(2), '9000');
    await tester.enterText(fields.at(4), '70000');
    await submit();
    expect(find.textContaining('destination port'), findsOneWidget);
    expect(
      find.text('Add forward'),
      findsWidgets,
      reason: 'the dialog stays open',
    );

    await tester.enterText(fields.at(4), '3000');
    await tester.enterText(fields.at(0), 'my api');
    await tester.tap(find.text('Remote  (-R)'));
    await tester.pump();
    await submit();
    await tester.pumpAndSettle();
    await r.drain();
    final rule = r.manager.items.single.rule;
    expect(rule.kind, ForwardKind.remote);
    expect(rule.bindPort, 9000);
    expect(rule.targetPort, 3000);
    expect(rule.label, 'my api');
    expect(find.text('my api'), findsOneWidget);
  });

  testWidgets('Delete asks for confirmation and removes the saved preset', (
    tester,
  ) async {
    final r = _Rig(tester);
    r.session.set(ConnectionPhase.lost);
    await r.pump();
    await tester.runAsync(
      () => r.manager.add(ForwardRule.devPort(3000, ForwardKind.local)),
    );
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete forward?'), findsOneWidget);
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
        .onPressed!();
    await r.drain();
    expect(r.manager.items, isEmpty);
    final stored = await tester.runAsync(
      () => ForwardStore(r.dir).load('peer-1'),
    );
    expect(stored!.rules, isEmpty);
  });

  testWidgets(
    'a corrupt preset file shows a banner instead of failing silently',
    (tester) async {
      final r = _Rig(tester);
      final file = ForwardStore(r.dir).fileFor('peer-1');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not json at all');
      await r.pump();
      expect(find.textContaining('could not be read'), findsOneWidget);
    },
  );

  testWidgets('presets saved earlier are listed when the tab opens', (
    tester,
  ) async {
    final r = _Rig(tester);
    await tester.runAsync(
      () => ForwardStore(r.dir).save('peer-1', [
        ForwardRule.devPort(3000, ForwardKind.local, label: 'web'),
        ForwardRule.devPort(9229, ForwardKind.remote, label: 'debugger'),
      ]),
    );
    await r.pump();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('debugger'), findsOneWidget);
    expect(find.text('Stopped'), findsNWidgets(2));
  });
}
