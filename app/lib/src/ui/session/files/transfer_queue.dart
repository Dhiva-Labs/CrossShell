import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

enum TaskKind { upload, download, delete }

enum TaskStatus {
  queued,
  running,
  completed,
  failed,
  cancelled;

  bool get isFinished =>
      this == completed || this == failed || this == cancelled;
  bool get isActive => this == queued || this == running;
}

/// Thrown by runners that noticed [TaskContext.cancelled].
class TransferCancelled implements Exception {
  const TransferCancelled();
  @override
  String toString() => 'Transfer cancelled';
}

/// What a runner uses to publish progress and notice cancellation.
class TaskContext {
  TaskContext._(this._task, this._queue);

  final TransferTask _task;
  final TransferQueue _queue;

  /// True once the user asked for this task to stop. Runners must check it
  /// between chunks and bail out promptly.
  bool get cancelled => _task._cancelRequested;

  void throwIfCancelled() {
    if (cancelled) throw const TransferCancelled();
  }

  /// Declares the total byte count once known (after scanning a folder).
  void setTotal(int? bytes) {
    _task.totalBytes = bytes;
    _queue._touch();
  }

  void addBytes(int n) {
    if (n <= 0) return;
    _task.doneBytes += n;
    _task._sample(_queue._clock());
    _queue._touch();
  }

  void setFiles({required int done, int? total}) {
    _task.filesDone = done;
    if (total != null) _task.filesTotal = total;
    _queue._touch();
  }

  void setPhase(String? text) {
    _task.phase = text;
    _queue._touch();
  }

  /// Notes something that did not stop the task (a skipped link, a file that
  /// could not be read inside a folder). Capped so a pathological tree cannot
  /// grow memory.
  void warn(String message) {
    if (_task.warnings.length < 200) _task.warnings.add(message);
    _queue._touch();
  }
}

typedef TaskRunner = Future<void> Function(TaskContext ctx);

/// One queued operation and its live progress. Mutable on purpose: the queue
/// owns it and notifies listeners after changes.
class TransferTask {
  TransferTask._({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.runner,
    required this.queuedAt,
  });

  final int id;
  final TaskKind kind;

  /// "photos" or "3 items".
  final String title;

  /// "This computer -> lenovo:/C:/Users/dhiva".
  final String subtitle;
  final TaskRunner runner;
  final DateTime queuedAt;

  TaskStatus status = TaskStatus.queued;
  String? error;
  int? totalBytes;
  int doneBytes = 0;
  int filesDone = 0;
  int? filesTotal;
  String? phase;
  final List<String> warnings = [];
  DateTime? startedAt;
  DateTime? finishedAt;
  bool _cancelRequested = false;

  // Rolling window for a speed that tracks the link, not the lifetime average.
  final ListQueue<({DateTime at, int bytes})> _samples = ListQueue();
  static const Duration _window = Duration(seconds: 4);

  void _sample(DateTime now) {
    if (_samples.isNotEmpty &&
        now.difference(_samples.last.at) < const Duration(milliseconds: 200)) {
      return;
    }
    _samples.addLast((at: now, bytes: doneBytes));
    while (_samples.length > 2 && now.difference(_samples.first.at) > _window) {
      _samples.removeFirst();
    }
  }

  /// 0..1, or null while the total is unknown.
  double? get progress {
    final total = totalBytes;
    if (total == null) {
      return filesTotal != null && filesTotal! > 0
          ? filesDone / filesTotal!
          : null;
    }
    if (total <= 0) return status == TaskStatus.completed ? 1 : null;
    return (doneBytes / total).clamp(0.0, 1.0);
  }

  /// Bytes per second over the recent window; the lifetime average once done.
  double? bytesPerSecond([DateTime? now]) {
    final start = startedAt;
    if (start == null || doneBytes == 0) return null;
    if (status.isFinished) {
      final end = finishedAt ?? start;
      final secs = end.difference(start).inMilliseconds / 1000;
      return secs < 0.25 ? null : doneBytes / secs;
    }
    final current = now ?? DateTime.now();
    if (_samples.length >= 2) {
      final first = _samples.first;
      final secs = current.difference(first.at).inMilliseconds / 1000;
      if (secs >= 0.5) return (doneBytes - first.bytes) / secs;
    }
    final secs = current.difference(start).inMilliseconds / 1000;
    return secs < 0.5 ? null : doneBytes / secs;
  }

  Duration? eta([DateTime? now]) {
    final total = totalBytes;
    final speed = bytesPerSecond(now);
    if (total == null || speed == null || speed < 1) return null;
    final left = total - doneBytes;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).ceil());
  }
}

/// Runs operations one at a time and notifies listeners as they progress.
///
/// Sequential on purpose: concurrent transfers share one SSH connection's
/// window, so they finish no sooner in aggregate but make every bar crawl.
/// (A folder copy parallelises its own files inside one task.)
class TransferQueue extends ChangeNotifier {
  TransferQueue({
    this.progressInterval = const Duration(milliseconds: 120),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Progress ticks are coalesced to at most one notification per interval
  /// so a fast transfer does not rebuild the UI thousands of times a second.
  final Duration progressInterval;
  final DateTime Function() _clock;

  final List<TransferTask> _tasks = [];
  final _finished = StreamController<TransferTask>.broadcast();
  var _nextId = 1;
  var _pumping = false;
  var _disposed = false;
  Timer? _tick;

  List<TransferTask> get tasks => List.unmodifiable(_tasks);
  Iterable<TransferTask> get active => _tasks.where((t) => t.status.isActive);
  bool get hasActive => _tasks.any((t) => t.status.isActive);
  int get activeCount => active.length;
  bool get hasFinished => _tasks.any((t) => t.status.isFinished);

  /// Emits each task as it reaches a terminal state, so panes can refresh.
  Stream<TransferTask> get finished => _finished.stream;

  /// Combined progress of unfinished tasks with a known size.
  double? get aggregateProgress {
    final known = active
        .where((t) => t.totalBytes != null && t.totalBytes! > 0)
        .toList();
    if (known.isEmpty) return null;
    final total = known.fold<int>(0, (s, t) => s + t.totalBytes!);
    final done = known.fold<int>(0, (s, t) => s + t.doneBytes);
    return (done / total).clamp(0.0, 1.0);
  }

  TransferTask enqueue({
    required TaskKind kind,
    required String title,
    required String subtitle,
    required TaskRunner runner,
    int? totalBytes,
  }) {
    final task = TransferTask._(
      id: _nextId++,
      kind: kind,
      title: title,
      subtitle: subtitle,
      runner: runner,
      queuedAt: _clock(),
    )..totalBytes = totalBytes;
    _tasks.add(task);
    _notifyNow();
    unawaited(_pump());
    return task;
  }

  /// Cancels a queued or running task. Finished tasks are left alone.
  void cancel(int id) {
    final task = _find(id);
    if (task == null || task.status.isFinished) return;
    task._cancelRequested = true;
    if (task.status == TaskStatus.queued) {
      _finish(task, TaskStatus.cancelled);
      return;
    }
    // Running: show it as cancelled at once; the runner unwinds on its own
    // and the pump waits for it before starting the next task.
    task.status = TaskStatus.cancelled;
    task.finishedAt = _clock();
    _notifyNow();
  }

  void cancelAll() {
    for (final t in _tasks.where((t) => t.status.isActive).toList()) {
      cancel(t.id);
    }
  }

  /// Re-queues a failed or cancelled task under a fresh row.
  TransferTask? retry(int id) {
    final task = _find(id);
    if (task == null ||
        (task.status != TaskStatus.failed &&
            task.status != TaskStatus.cancelled)) {
      return null;
    }
    _tasks.remove(task);
    return enqueue(
      kind: task.kind,
      title: task.title,
      subtitle: task.subtitle,
      runner: task.runner,
    );
  }

  void clearFinished() {
    _tasks.removeWhere((t) => t.status.isFinished);
    _notifyNow();
  }

  TransferTask? _find(int id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_disposed) {
        TransferTask? next;
        for (final t in _tasks) {
          if (t.status == TaskStatus.queued) {
            next = t;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(TransferTask task) async {
    task.status = TaskStatus.running;
    task.startedAt = _clock();
    _notifyNow();
    final ctx = TaskContext._(task, this);
    try {
      await task.runner(ctx);
      if (task.status == TaskStatus.running) {
        _finish(
          task,
          task._cancelRequested ? TaskStatus.cancelled : TaskStatus.completed,
        );
      } else {
        _emitFinished(task);
      }
    } on TransferCancelled {
      _finish(task, TaskStatus.cancelled);
    } catch (e) {
      if (task._cancelRequested) {
        _finish(task, TaskStatus.cancelled);
      } else {
        task.error = e.toString();
        _finish(task, TaskStatus.failed);
      }
    }
  }

  void _finish(TransferTask task, TaskStatus status) {
    if (task.status.isFinished &&
        task.finishedAt != null &&
        status == task.status) {
      _emitFinished(task);
      return;
    }
    task.status = status;
    task.finishedAt = _clock();
    if (status == TaskStatus.completed && task.totalBytes == null) {
      task.totalBytes = task.doneBytes;
    }
    _notifyNow();
    _emitFinished(task);
  }

  void _emitFinished(TransferTask task) {
    if (!_finished.isClosed) _finished.add(task);
  }

  void _touch() {
    if (_disposed) return;
    if (progressInterval == Duration.zero) {
      notifyListeners();
      return;
    }
    _tick ??= Timer(progressInterval, () {
      _tick = null;
      if (!_disposed) notifyListeners();
    });
  }

  void _notifyNow() {
    if (_disposed) return;
    _tick?.cancel();
    _tick = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _tasks) {
      if (t.status.isActive) t._cancelRequested = true;
    }
    _tick?.cancel();
    _finished.close();
    super.dispose();
  }
}
