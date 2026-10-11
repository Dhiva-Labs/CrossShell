import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A yes/no question. Returns true only for an explicit yes.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool destructive = false,
  Widget? content,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: content ?? Text(message),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          autofocus: !destructive,
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Asks for one line of text. [validator] returns an error sentence or null.
/// Returns null when cancelled.
Future<String?> showTextPromptDialog(
  BuildContext context, {
  required String title,
  String? label,
  String initialValue = '',
  String confirmLabel = 'OK',
  String? Function(String value)? validator,
  bool selectStem = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _PromptDialog(
      title: title,
      label: label,
      initialValue: initialValue,
      confirmLabel: confirmLabel,
      validator: validator,
      selectStem: selectStem,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.initialValue,
    required this.confirmLabel,
    required this.validator,
    required this.selectStem,
  });

  final String title;
  final String? label;
  final String initialValue;
  final String confirmLabel;
  final String? Function(String value)? validator;
  final bool selectStem;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    // Rename: select the name but not the extension, like a file manager.
    final dot = widget.initialValue.lastIndexOf('.');
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.selectStem && dot > 0
          ? dot
          : widget.initialValue.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    final problem = widget.validator?.call(value);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.label,
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// What the user chose when files already exist at the destination.
enum ConflictChoice { replace, skip, keepBoth, cancel }

Future<ConflictChoice> showConflictDialog(
  BuildContext context, {
  required List<String> names,
  required bool offerKeepBoth,
}) async {
  final preview = names.take(6).join('\n');
  final more = names.length > 6 ? '\n... and ${names.length - 6} more' : '';
  final result = await showDialog<ConflictChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        names.length == 1
            ? 'Already exists'
            : '${names.length} items already exist',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Text(
          '$preview$more\n\nReplace overwrites files with the same name; Skip '
          'leaves the existing ones untouched.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(ConflictChoice.cancel),
          child: const Text('Cancel'),
        ),
        if (offerKeepBoth)
          TextButton(
            onPressed: () => Navigator.of(context).pop(ConflictChoice.keepBoth),
            child: const Text('Keep both'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(ConflictChoice.skip),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ConflictChoice.replace),
          child: const Text('Replace'),
        ),
      ],
    ),
  );
  return result ?? ConflictChoice.cancel;
}

/// Confirmation before pasting several lines into a shell: each line is
/// executed as if typed, which is the classic way to run something unseen.
Future<bool> showPasteConfirmDialog(
  BuildContext context, {
  required String text,
  required int lineCount,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final preview = text.length > 1200 ? '${text.substring(0, 1200)}\n...' : text;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Paste $lineCount lines?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Each line is sent to the shell as if you typed it and pressed '
              'Enter, so this can run more than one command.',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    preview,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Paste'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Puts [text] on the system clipboard and says so.
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  String? what,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Copied ${what ?? 'to clipboard'}'),
        duration: const Duration(seconds: 2),
      ),
    );
}
