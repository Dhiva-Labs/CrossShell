/// Decides whether a paste into a shell deserves a confirmation. Plain string
/// logic, kept apart from the widget so it is unit-testable.
class PasteGuard {
  const PasteGuard._();

  /// Lines in [text]. `\r\n` and a lone `\r` count as one break each, and a
  /// single trailing break is not an extra empty line: copying "ls\n" and
  /// pasting it is one command, not two.
  static int lineCount(String text) {
    if (text.isEmpty) return 0;
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
    return lines.length;
  }

  /// Two or more lines can each be a separate command that runs unseen.
  static bool needsConfirmation(String text) => lineCount(text) > 1;
}
