import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

enum BannerTone { error, warning, info }

/// An inline message that stays on screen until dismissed or resolved. Used
/// where a snackbar would vanish before the user can read a long error.
class InlineBanner extends StatelessWidget {
  const InlineBanner({
    super.key,
    required this.message,
    this.tone = BannerTone.error,
    this.onDismiss,
    this.actionLabel,
    this.onAction,
    this.busy = false,
    this.details,
  });

  final String message;
  final BannerTone tone;
  final VoidCallback? onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Shows a spinner in place of the icon (for "reconnecting...").
  final bool busy;

  /// Extra text copied by the copy button (defaults to [message]).
  final String? details;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = CrossShellColors.of(context);
    final (Color bg, Color fg, IconData icon) = switch (tone) {
      BannerTone.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
      BannerTone.warning => (
        colors.warning.withValues(alpha: 0.16),
        scheme.onSurface,
        Icons.warning_amber_rounded,
      ),
      BannerTone.info => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        Icons.info_outline,
      ),
    };

    return Material(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            else
              Icon(icon, size: 18, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(
                message,
                style: TextStyle(color: fg, fontSize: 13),
                maxLines: 4,
              ),
            ),
            if (onAction != null && actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(foregroundColor: fg),
                child: Text(actionLabel!),
              ),
            if (tone == BannerTone.error)
              IconButton(
                tooltip: 'Copy message',
                iconSize: 16,
                color: fg,
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: details ?? message)),
                icon: const Icon(Icons.copy),
              ),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                iconSize: 16,
                color: fg,
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shows [message] as a floating snackbar, replacing any current one.
void showToast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: error ? TextStyle(color: scheme.onErrorContainer) : null,
        ),
        backgroundColor: error ? scheme.errorContainer : null,
        duration: Duration(seconds: error ? 8 : 3),
        showCloseIcon: error,
      ),
    );
}
