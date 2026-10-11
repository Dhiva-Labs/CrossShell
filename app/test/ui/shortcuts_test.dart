import 'package:cross_shell/src/ui/session/session_shortcuts.dart';
import 'package:cross_shell/src/ui/session/terminal/paste_guard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

SessionShortcut? s(
  LogicalKeyboardKey k, {
  bool ctrl = false,
  bool shift = false,
  bool alt = false,
}) => matchSessionShortcut(k, ctrl: ctrl, shift: shift, alt: alt);

PaneShortcut? p(
  LogicalKeyboardKey k, {
  bool ctrl = false,
  bool shift = false,
  bool alt = false,
}) => matchPaneShortcut(k, ctrl: ctrl, shift: shift, alt: alt);

void main() {
  group('session shortcuts', () {
    test('Ctrl+Shift+T / W open and close terminal tabs', () {
      expect(
        s(LogicalKeyboardKey.keyT, ctrl: true, shift: true),
        SessionShortcut.newTerminal,
      );
      expect(
        s(LogicalKeyboardKey.keyW, ctrl: true, shift: true),
        SessionShortcut.closeTerminal,
      );
    });

    test(
      'Ctrl+Shift+C / V copy and paste; plain Ctrl+C / V stay with the shell',
      () {
        expect(
          s(LogicalKeyboardKey.keyC, ctrl: true, shift: true),
          SessionShortcut.copy,
        );
        expect(
          s(LogicalKeyboardKey.keyV, ctrl: true, shift: true),
          SessionShortcut.paste,
        );
        expect(
          s(LogicalKeyboardKey.keyC, ctrl: true),
          isNull,
          reason: 'Ctrl+C is SIGINT',
        );
        expect(s(LogicalKeyboardKey.keyV, ctrl: true), isNull);
        expect(s(LogicalKeyboardKey.keyT, ctrl: true), isNull);
        expect(
          s(LogicalKeyboardKey.keyW, ctrl: true),
          isNull,
          reason: 'Ctrl+W is delete-word',
        );
      },
    );

    test('classic Insert shortcuts', () {
      expect(s(LogicalKeyboardKey.insert, ctrl: true), SessionShortcut.copy);
      expect(s(LogicalKeyboardKey.insert, shift: true), SessionShortcut.paste);
      expect(s(LogicalKeyboardKey.insert), isNull);
    });

    test('tab cycling', () {
      expect(
        s(LogicalKeyboardKey.tab, ctrl: true),
        SessionShortcut.nextTerminal,
      );
      expect(
        s(LogicalKeyboardKey.tab, ctrl: true, shift: true),
        SessionShortcut.previousTerminal,
      );
      expect(
        s(LogicalKeyboardKey.pageDown, ctrl: true),
        SessionShortcut.nextTerminal,
      );
      expect(
        s(LogicalKeyboardKey.pageUp, ctrl: true),
        SessionShortcut.previousTerminal,
      );
      expect(
        s(LogicalKeyboardKey.tab),
        isNull,
        reason: 'plain Tab is shell completion',
      );
    });

    test('Ctrl+1..3 switch page tabs', () {
      expect(
        s(LogicalKeyboardKey.digit1, ctrl: true),
        SessionShortcut.showTerminal,
      );
      expect(
        s(LogicalKeyboardKey.digit2, ctrl: true),
        SessionShortcut.showFiles,
      );
      expect(
        s(LogicalKeyboardKey.digit3, ctrl: true),
        SessionShortcut.showForwards,
      );
    });

    test(
      'Alt combinations are never claimed (AltGr is Ctrl+Alt on Windows)',
      () {
        expect(
          s(LogicalKeyboardKey.keyT, ctrl: true, shift: true, alt: true),
          isNull,
        );
        expect(s(LogicalKeyboardKey.digit1, ctrl: true, alt: true), isNull);
      },
    );

    test('ordinary typing is untouched', () {
      expect(s(LogicalKeyboardKey.keyA), isNull);
      expect(s(LogicalKeyboardKey.enter), isNull);
      expect(s(LogicalKeyboardKey.keyL, ctrl: true), isNull);
    });
  });

  group('file pane shortcuts', () {
    test('navigation', () {
      expect(p(LogicalKeyboardKey.arrowDown), PaneShortcut.down);
      expect(p(LogicalKeyboardKey.arrowUp, shift: true), PaneShortcut.extendUp);
      expect(p(LogicalKeyboardKey.enter), PaneShortcut.open);
      expect(p(LogicalKeyboardKey.backspace), PaneShortcut.goUp);
      expect(p(LogicalKeyboardKey.arrowUp, alt: true), PaneShortcut.goUp);
      expect(p(LogicalKeyboardKey.arrowLeft, alt: true), PaneShortcut.back);
      expect(p(LogicalKeyboardKey.arrowRight, alt: true), PaneShortcut.forward);
      expect(p(LogicalKeyboardKey.home), PaneShortcut.home);
      expect(p(LogicalKeyboardKey.pageDown), PaneShortcut.pageDown);
    });

    test('file operations', () {
      expect(p(LogicalKeyboardKey.f2), PaneShortcut.rename);
      expect(p(LogicalKeyboardKey.delete), PaneShortcut.delete);
      expect(p(LogicalKeyboardKey.delete, shift: true), PaneShortcut.delete);
      expect(p(LogicalKeyboardKey.f7), PaneShortcut.newFolder);
      expect(
        p(LogicalKeyboardKey.keyN, ctrl: true, shift: true),
        PaneShortcut.newFolder,
      );
      expect(p(LogicalKeyboardKey.f5), PaneShortcut.refresh);
      expect(p(LogicalKeyboardKey.keyR, ctrl: true), PaneShortcut.refresh);
    });

    test('clipboard between panes and selection', () {
      expect(p(LogicalKeyboardKey.keyC, ctrl: true), PaneShortcut.copy);
      expect(p(LogicalKeyboardKey.keyV, ctrl: true), PaneShortcut.paste);
      expect(p(LogicalKeyboardKey.keyA, ctrl: true), PaneShortcut.selectAll);
      expect(p(LogicalKeyboardKey.escape), PaneShortcut.clearSelection);
    });

    test('path bar, hidden files and pane switching', () {
      expect(p(LogicalKeyboardKey.keyL, ctrl: true), PaneShortcut.editPath);
      expect(p(LogicalKeyboardKey.keyH, ctrl: true), PaneShortcut.toggleHidden);
      expect(p(LogicalKeyboardKey.tab), PaneShortcut.switchPane);
      expect(p(LogicalKeyboardKey.tab, shift: true), PaneShortcut.switchPane);
    });

    test('plain letters are left for type-ahead', () {
      expect(p(LogicalKeyboardKey.keyA), isNull);
      expect(p(LogicalKeyboardKey.space), isNull);
    });
  });

  group('PasteGuard', () {
    test('counts lines across platforms', () {
      expect(PasteGuard.lineCount(''), 0);
      expect(PasteGuard.lineCount('ls'), 1);
      expect(
        PasteGuard.lineCount('ls\n'),
        1,
        reason: 'one command with its Enter',
      );
      expect(PasteGuard.lineCount('a\nb'), 2);
      expect(PasteGuard.lineCount('a\r\nb\r\nc'), 3);
      expect(PasteGuard.lineCount('a\rb'), 2);
      expect(PasteGuard.lineCount('a\n\nb'), 3);
    });

    test('only multi-line pastes need confirming', () {
      expect(PasteGuard.needsConfirmation('ls -la'), isFalse);
      expect(PasteGuard.needsConfirmation('ls -la\n'), isFalse);
      expect(PasteGuard.needsConfirmation('cd /\nrm -rf x'), isTrue);
      expect(PasteGuard.needsConfirmation('line one\r\nline two\r\n'), isTrue);
    });
  });
}
