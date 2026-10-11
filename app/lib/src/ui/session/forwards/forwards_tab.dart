import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/format.dart';
import 'forward_manager.dart';
import 'forward_models.dart';

/// The Forwards tab: saved forwards with start/stop switches, live counters
/// and one-click presets for common dev ports.
class ForwardsTab extends StatefulWidget {
  const ForwardsTab({
    super.key,
    required this.manager,
    required this.peerTitle,
  });

  final ForwardManager manager;
  final String peerTitle;

  @override
  State<ForwardsTab> createState() => _ForwardsTabState();
}

class _ForwardsTabState extends State<ForwardsTab> {
  ForwardKind _presetKind = ForwardKind.local;

  ForwardManager get _m => widget.manager;

  Future<void> _addPreset(int port) async {
    final rule = ForwardRule.devPort(port, _presetKind);
    final existing = _m.items.where((rt) => rt.rule.sameRoute(rule));
    if (existing.isNotEmpty && existing.first.isActive) {
      showToast(context, 'Port $port is already forwarded.');
      return;
    }
    await _m.add(rule, start: true);
  }

  Future<void> _edit([ForwardRuntime? existing]) async {
    final result = await showDialog<ForwardRule>(
      context: context,
      builder: (context) => _ForwardDialog(
        initial: existing?.rule,
        peerTitle: widget.peerTitle,
        defaultKind: _presetKind,
      ),
    );
    if (result == null) return;
    if (existing == null) {
      await _m.add(result, start: true);
    } else {
      await _m.update(result);
    }
  }

  Future<void> _delete(ForwardRuntime rt) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Delete forward?',
      message:
          '${rt.rule.title} (${rt.rule.route}) will be stopped and removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok) await _m.remove(rt.rule.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _m,
      builder: (context, _) {
        final items = _m.items;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_m.storeError != null)
              InlineBanner(message: _m.storeError!, tone: BannerTone.warning),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Port forwards',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Reach services across the connection with nothing '
                          'exposed to the network.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => unawaited(_edit()),
                    icon: const Icon(Icons.add),
                    label: const Text('Add forward'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<ForwardKind>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: ForwardKind.local,
                        label: Text('Local'),
                        tooltip: 'A port on this computer reaches the peer',
                      ),
                      ButtonSegment(
                        value: ForwardKind.remote,
                        label: Text('Remote'),
                        tooltip: 'A port on the peer reaches this computer',
                      ),
                    ],
                    selected: {_presetKind},
                    onSelectionChanged: (s) =>
                        setState(() => _presetKind = s.first),
                  ),
                  for (final preset in commonDevPorts)
                    ActionChip(
                      avatar: const Icon(Icons.bolt, size: 16),
                      label: Text('${preset.port}'),
                      tooltip: _presetKind == ForwardKind.local
                          ? '${preset.hint}: reach the peer\'s port ${preset.port} '
                                'at 127.0.0.1:${preset.port} on this computer'
                          : '${preset.hint}: let the peer reach this computer\'s '
                                'port ${preset.port}',
                      onPressed: () => unawaited(_addPreset(preset.port)),
                    ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: !_m.loaded
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? _EmptyState(peerTitle: widget.peerTitle)
                  : ListView.separated(
                      padding: const EdgeInsets.all(20),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _ForwardCard(
                        runtime: items[i],
                        peerTitle: widget.peerTitle,
                        onToggle: () => unawaited(_m.toggle(items[i].rule.id)),
                        onEdit: () => unawaited(_edit(items[i])),
                        onDelete: () => unawaited(_delete(items[i])),
                        onDuplicate: () => unawaited(
                          _m.add(
                            ForwardRule.create(
                              kind: items[i].rule.kind,
                              bindHost: items[i].rule.bindHost,
                              bindPort: items[i].rule.bindPort + 1,
                              targetHost: items[i].rule.targetHost,
                              targetPort: items[i].rule.targetPort,
                              label: items[i].rule.label,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.peerTitle});
  final String peerTitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_horiz, size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'No forwards yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Local: open a dev server running on $peerTitle in this '
              'computer\'s browser at 127.0.0.1.\n'
              'Remote: let $peerTitle reach a service on this computer.\n\n'
              'Click a port above to forward it at once.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForwardCard extends StatelessWidget {
  const _ForwardCard({
    required this.runtime,
    required this.peerTitle,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onDuplicate,
  });

  final ForwardRuntime runtime;
  final String peerTitle;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = CrossShellColors.of(context);
    final rule = runtime.rule;
    final isLocal = rule.kind == ForwardKind.local;

    final (Color stateColor, String stateLabel) = switch (runtime.state) {
      ForwardState.running => (colors.success, 'Running'),
      ForwardState.starting => (colors.warning, 'Starting'),
      ForwardState.error => (scheme.error, 'Error'),
      ForwardState.stopped => (scheme.outline, 'Stopped'),
    };

    final bound = runtime.boundPort;
    final bindLabel = isLocal ? 'this computer' : peerTitle;
    final targetLabel = isLocal ? peerTitle : 'this computer';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isLocal
                      ? Icons.arrow_circle_right_outlined
                      : Icons.arrow_circle_left_outlined,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              rule.title,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _Pill(
                            label: isLocal ? 'Local' : 'Remote',
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 6),
                          _Pill(label: stateLabel, color: stateColor),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        rule.route,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isLocal
                            ? 'Listens on $bindLabel; connects from $targetLabel.'
                            : 'Listens on $bindLabel; connects to a service on $targetLabel.',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(value: runtime.isActive, onChanged: (_) => onToggle()),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (v) {
                    switch (v) {
                      case 'edit':
                        onEdit();
                      case 'dup':
                        onDuplicate();
                      case 'del':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'dup', child: Text('Duplicate')),
                    PopupMenuItem(value: 'del', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            if (runtime.state == ForwardState.running) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.link, size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    '${runtime.liveConnections} active  ·  '
                    '${runtime.totalConnections} total  ·  '
                    '↑ ${formatBytes(runtime.bytesUp)}  '
                    '↓ ${formatBytes(runtime.bytesDown)}'
                    '${bound != null && bound != rule.bindPort ? '  ·  port $bound' : ''}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
            if (runtime.message != null) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 16,
                    color: runtime.state == ForwardState.error
                        ? scheme.error
                        : colors.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      runtime.message!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: runtime.state == ForwardState.error
                            ? scheme.error
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ForwardDialog extends StatefulWidget {
  const _ForwardDialog({
    required this.initial,
    required this.peerTitle,
    required this.defaultKind,
  });

  final ForwardRule? initial;
  final String peerTitle;
  final ForwardKind defaultKind;

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  late ForwardKind _kind;
  late final TextEditingController _label;
  late final TextEditingController _bindHost;
  late final TextEditingController _bindPort;
  late final TextEditingController _targetHost;
  late final TextEditingController _targetPort;
  String? _error;
  var _targetEdited = false;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _kind = r?.kind ?? widget.defaultKind;
    _label = TextEditingController(text: r?.label ?? '');
    _bindHost = TextEditingController(text: r?.bindHost ?? _defaultBind(_kind));
    _bindPort = TextEditingController(text: r == null ? '' : '${r.bindPort}');
    _targetHost = TextEditingController(text: r?.targetHost ?? 'localhost');
    _targetPort = TextEditingController(
      text: r == null ? '' : '${r.targetPort}',
    );
    _targetEdited = r != null;
  }

  static String _defaultBind(ForwardKind k) =>
      k == ForwardKind.local ? '127.0.0.1' : 'localhost';

  @override
  void dispose() {
    _label.dispose();
    _bindHost.dispose();
    _bindPort.dispose();
    _targetHost.dispose();
    _targetPort.dispose();
    super.dispose();
  }

  void _setKind(ForwardKind kind) {
    if (kind == _kind) return;
    // Swap the default listen address only if the user left it untouched.
    if (_bindHost.text == _defaultBind(_kind)) {
      _bindHost.text = _defaultBind(kind);
    }
    setState(() => _kind = kind);
  }

  void _submit() {
    final bindPort = parsePort(_bindPort.text);
    final targetPort = parsePort(_targetPort.text);
    if (bindPort == null) {
      setState(() => _error = 'Enter a listening port between 1 and 65535.');
      return;
    }
    if (targetPort == null) {
      setState(() => _error = 'Enter a destination port between 1 and 65535.');
      return;
    }
    final base = widget.initial;
    final rule = ForwardRule(
      id: base?.id ?? ForwardRule.newId(),
      kind: _kind,
      label: _label.text.trim(),
      bindHost: _bindHost.text.trim(),
      bindPort: bindPort,
      targetHost: _targetHost.text.trim(),
      targetPort: targetPort,
    );
    final problem = rule.validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(rule);
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = _kind == ForwardKind.local;
    final peer = widget.peerTitle;
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add forward' : 'Edit forward'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<ForwardKind>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ForwardKind.local,
                    label: Text('Local  (-L)'),
                  ),
                  ButtonSegment(
                    value: ForwardKind.remote,
                    label: Text('Remote  (-R)'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => _setKind(s.first),
              ),
              const SizedBox(height: 8),
              Text(
                isLocal
                    ? 'Connections to a port on this computer are sent through '
                          'the tunnel to a host and port on $peer\'s side.'
                    : 'Connections to a port on $peer are sent back through the '
                          'tunnel to a host and port on this computer.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Name (optional)'),
              ),
              const SizedBox(height: 14),
              Text(
                isLocal ? 'Listen on this computer' : 'Listen on $peer',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _bindHost,
                      decoration: const InputDecoration(labelText: 'Address'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _bindPort,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                      onChanged: (v) {
                        if (!_targetEdited) _targetPort.text = v;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                isLocal
                    ? 'Forward to (as seen from $peer)'
                    : 'Forward to (on this computer)',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _targetHost,
                      decoration: const InputDecoration(labelText: 'Host'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _targetPort,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _targetEdited = true,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.initial == null ? 'Add and start' : 'Save'),
        ),
      ],
    );
  }
}
