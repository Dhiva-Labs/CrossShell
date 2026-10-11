import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/format.dart';
import 'transfer_queue.dart';

/// The strip under the panes: one summary line that expands into the full
/// list of transfers with progress, speed, ETA and cancel/retry.
class TransferPanel extends StatefulWidget {
  const TransferPanel({
    super.key,
    required this.queue,
    required this.expanded,
    required this.onToggle,
  });

  final TransferQueue queue;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<TransferPanel> createState() => _TransferPanelState();
}

class _TransferPanelState extends State<TransferPanel> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // Speed and ETA change between progress notifications; redraw once a
    // second while anything is running.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.queue.hasActive) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final queue = widget.queue;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        final tasks = queue.tasks;
        return Material(
          color: scheme.surfaceContainerLow,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(),
              _SummaryBar(
                queue: queue,
                expanded: widget.expanded,
                onToggle: widget.onToggle,
              ),
              if (widget.expanded)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 230),
                  child: tasks.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(18),
                          child: Text(
                            'No transfers yet. Drag files between the panes, '
                            'or select and press Ctrl+C then Ctrl+V in the '
                            'other pane.',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: tasks.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (context, i) {
                            final task = tasks[tasks.length - 1 - i];
                            return TransferRow(
                              task: task,
                              onCancel: () => queue.cancel(task.id),
                              onRetry: () => queue.retry(task.id),
                            );
                          },
                        ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.queue,
    required this.expanded,
    required this.onToggle,
  });

  final TransferQueue queue;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = CrossShellColors.of(context);
    final tasks = queue.tasks;
    final active = queue.active.toList();
    final failed = tasks.where((t) => t.status == TaskStatus.failed).length;

    final IconData icon;
    Color? color;
    final String label;
    if (active.isNotEmpty) {
      final running = active.firstWhere(
        (t) => t.status == TaskStatus.running,
        orElse: () => active.first,
      );
      final more = active.length - 1;
      label = more > 0
          ? '${_verb(running)} ${running.title}  ·  $more more queued'
          : '${_verb(running)} ${running.title}';
      icon = _kindIcon(running.kind);
    } else if (failed > 0) {
      label = failed == 1 ? '1 transfer failed' : '$failed transfers failed';
      icon = Icons.error_outline;
      color = scheme.error;
    } else if (tasks.isNotEmpty) {
      final done = tasks.where((t) => t.status == TaskStatus.completed).length;
      label = done > 0
          ? '$done transfer${done == 1 ? '' : 's'} done'
          : 'Transfers';
      icon = Icons.check_circle_outline;
      color = colors.success;
    } else {
      label = 'Transfers';
      icon = Icons.swap_vert;
    }

    final progress = queue.aggregateProgress;
    final first = active.isEmpty ? null : active.first;
    final speed = first?.bytesPerSecond();

    return InkWell(
      onTap: onToggle,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active.isNotEmpty)
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(
              children: [
                Icon(icon, size: 17, color: color ?? scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (active.isNotEmpty && speed != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      formatSpeed(speed),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (active.isNotEmpty && progress != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      '${(progress * 100).round()}%',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (queue.hasActive)
                  TextButton(
                    onPressed: queue.cancelAll,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Cancel all'),
                  ),
                if (queue.hasFinished && !queue.hasActive)
                  TextButton(
                    onPressed: queue.clearFinished,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Clear'),
                  ),
                Icon(
                  expanded ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _verb(TransferTask t) => switch (t.kind) {
  TaskKind.upload => 'Uploading',
  TaskKind.download => 'Downloading',
  TaskKind.delete => 'Deleting',
};

IconData _kindIcon(TaskKind kind) => switch (kind) {
  TaskKind.upload => Icons.upload,
  TaskKind.download => Icons.download,
  TaskKind.delete => Icons.delete_outline,
};

/// One transfer: title, route, live numbers, progress bar, actions.
class TransferRow extends StatelessWidget {
  const TransferRow({
    super.key,
    required this.task,
    required this.onCancel,
    required this.onRetry,
  });

  final TransferTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = CrossShellColors.of(context);
    final status = task.status;

    final (IconData icon, Color iconColor) = switch (status) {
      TaskStatus.completed => (Icons.check_circle, colors.success),
      TaskStatus.failed => (Icons.error, scheme.error),
      TaskStatus.cancelled => (Icons.cancel, scheme.outline),
      _ => (_kindIcon(task.kind), scheme.primary),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  task.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  describeTask(task),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: status == TaskStatus.failed
                        ? scheme.error
                        : scheme.onSurface,
                  ),
                ),
                if (status.isActive) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: status == TaskStatus.running ? task.progress : 0,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
                if (task.warnings.isNotEmpty && status.isFinished)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      task.warnings.length == 1
                          ? task.warnings.first
                          : '${task.warnings.length} warnings, e.g. ${task.warnings.first}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: colors.warning),
                    ),
                  ),
              ],
            ),
          ),
          if (status.isActive)
            IconButton(
              tooltip: 'Cancel',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
          if (status == TaskStatus.failed || status == TaskStatus.cancelled)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          if (status == TaskStatus.failed && task.error != null)
            IconButton(
              tooltip: 'Copy error',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(
                copyToClipboard(context, task.error!, what: 'error'),
              ),
              icon: const Icon(Icons.copy),
            ),
        ],
      ),
    );
  }
}

/// The status line of a transfer row: "12.3 MB of 45 MB, 27%, 3.2 MB/s, 10s left".
String describeTask(TransferTask t, {DateTime? now}) {
  switch (t.status) {
    case TaskStatus.queued:
      return 'Waiting...';
    case TaskStatus.cancelled:
      return 'Cancelled';
    case TaskStatus.failed:
      return t.error ?? 'Failed';
    case TaskStatus.completed:
      if (t.kind == TaskKind.delete) {
        return 'Deleted ${t.filesDone} item${t.filesDone == 1 ? '' : 's'}';
      }
      final speed = t.bytesPerSecond();
      final files = (t.filesTotal ?? 0) > 1 ? '${t.filesTotal} files, ' : '';
      return '$files${formatBytes(t.doneBytes)}'
          '${speed == null ? '' : ' at ${formatSpeed(speed)}'}';
    case TaskStatus.running:
      if (t.kind == TaskKind.delete) return t.phase ?? 'Deleting...';
      if (t.phase != null && t.totalBytes == null) return t.phase!;
      final parts = <String>[];
      final total = t.totalBytes;
      parts.add(
        total == null
            ? formatBytes(t.doneBytes)
            : '${formatBytes(t.doneBytes)} of ${formatBytes(total)}',
      );
      final pct = t.progress;
      if (total != null && pct != null) parts.add('${(pct * 100).round()}%');
      final speed = t.bytesPerSecond(now);
      if (speed != null) parts.add(formatSpeed(speed));
      final eta = t.eta(now);
      if (eta != null) parts.add('${formatDuration(eta)} left');
      if ((t.filesTotal ?? 0) > 1) {
        parts.add('file ${t.filesDone + 1} of ${t.filesTotal}');
      }
      return parts.join('  ·  ');
  }
}
