import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/pairing/pairing_session.dart';

/// Ask the user to compare the 6-digit code with the other screen.
/// Closes itself if the other side cancels.
Future<bool> showPairingCodeDialog(
  BuildContext context,
  PairingPrompt prompt,
) async {
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  unawaited(
    prompt.remoteCancelled.then((_) {
      if (open && nav.mounted) nav.pop(false);
    }),
  );
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PairingCodeDialog(prompt: prompt),
  );
  open = false;
  return ok ?? false;
}

class _PairingCodeDialog extends StatelessWidget {
  const _PairingCodeDialog({required this.prompt});
  final PairingPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peer = prompt.peer;
    return AlertDialog(
      icon: Icon(
        prompt.incoming ? Icons.link : Icons.verified_user_outlined,
        size: 32,
      ),
      title: Text(
        prompt.incoming
            ? '${peer.name} wants to pair'
            : 'Pairing with ${peer.name}',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Check that ${peer.name} shows exactly this code:',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                prompt.code,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Pairing lets each machine sign in to the other over SSH and share its screen. '
              'Only confirm if the codes match — a different code means someone else is in the middle.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.check),
          label: const Text('Codes match'),
        ),
      ],
    );
  }
}

/// Ask for an address to pair with manually.
Future<String?> askPairAddress(BuildContext context) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Pair by address'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the IP address shown in CrossShell on the other machine. '
              'Use this when it doesn\'t appear under Nearby (different subnet, VPN, firewall).',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'IP address',
                hintText: '192.168.1.20',
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: const Text('Pair'),
        ),
      ],
    ),
  );
}
