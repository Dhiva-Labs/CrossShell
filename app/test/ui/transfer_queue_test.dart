import 'dart:async';

import 'package:cross_shell/src/ui/session/files/transfer_queue.dart';
import 'package:flutter_test/flutter_test.dart';

TransferQueue newQueue({DateTime Function()? clock}) =>
    TransferQueue(progressInterval: Duration.zero, clock: clock);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  test('runs tasks one at a time, in order', () async {
    final q = newQueue();
    final order = <String>[];
    final gate = Completer<void>();
    q.enqueue(
      kind: TaskKind.upload,
      title: 'a',
      subtitle: '',
      runner: (ctx) async {
        order.add('a start');
        await gate.future;
        order.add('a end');
      },
    );
    q.enqueue(
      kind: TaskKind.upload,
      title: 'b',
      subtitle: '',
      runner: (ctx) async => order.add('b'),
    );
    await settle();
    expect(order, ['a start']);
    expect(q.tasks[1].status, TaskStatus.queued);
    gate.complete();
    await settle();
    expect(order, ['a start', 'a end', 'b']);
    expect(q.tasks.map((t) => t.status), everyElement(TaskStatus.completed));
    q.dispose();
  });

  test('progress, totals and completion', () async {
    final q = newQueue();
    final gate = Completer<void>();
    final t = q.enqueue(
      kind: TaskKind.download,
      title: 'f',
      subtitle: '',
      runner: (ctx) async {
        ctx.setTotal(1000);
        ctx.addBytes(250);
        await gate.future;
        ctx.addBytes(750);
      },
    );
    await settle();
    expect(t.status, TaskStatus.running);
    expect(t.progress, 0.25);
    expect(q.aggregateProgress, 0.25);
    gate.complete();
    await settle();
    expect(t.status, TaskStatus.completed);
    expect(t.progress, 1.0);
    expect(t.doneBytes, 1000);
    q.dispose();
  });

  test('a total learned only at the end becomes the completed size', () async {
    final q = newQueue();
    final t = q.enqueue(
      kind: TaskKind.download,
      title: 'f',
      subtitle: '',
      runner: (ctx) async => ctx.addBytes(42),
    );
    await settle();
    expect(t.totalBytes, 42);
    q.dispose();
  });

  test('cancelling a queued task never runs it', () async {
    final q = newQueue();
    final gate = Completer<void>();
    var ran = false;
    q.enqueue(
      kind: TaskKind.upload,
      title: 'a',
      subtitle: '',
      runner: (ctx) => gate.future,
    );
    final b = q.enqueue(
      kind: TaskKind.upload,
      title: 'b',
      subtitle: '',
      runner: (ctx) async => ran = true,
    );
    await settle();
    q.cancel(b.id);
    expect(b.status, TaskStatus.cancelled);
    gate.complete();
    await settle();
    expect(ran, isFalse);
    q.dispose();
  });

  test(
    'cancelling a running task flips the flag and shows cancelled at once',
    () async {
      final q = newQueue();
      final started = Completer<void>();
      late TaskContext captured;
      final t = q.enqueue(
        kind: TaskKind.upload,
        title: 'big',
        subtitle: '',
        runner: (ctx) async {
          captured = ctx;
          started.complete();
          while (!ctx.cancelled) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          ctx.throwIfCancelled();
        },
      );
      await started.future;
      q.cancel(t.id);
      expect(t.status, TaskStatus.cancelled);
      expect(captured.cancelled, isTrue);
      await settle();
      expect(t.status, TaskStatus.cancelled);
      expect(q.hasActive, isFalse);
      q.dispose();
    },
  );

  test('next task starts only after a cancelled one has unwound', () async {
    final q = newQueue();
    final order = <String>[];
    final release = Completer<void>();
    final a = q.enqueue(
      kind: TaskKind.upload,
      title: 'a',
      subtitle: '',
      runner: (ctx) async {
        order.add('a');
        await release.future;
        order.add('a unwound');
      },
    );
    q.enqueue(
      kind: TaskKind.upload,
      title: 'b',
      subtitle: '',
      runner: (ctx) async => order.add('b'),
    );
    await settle();
    q.cancel(a.id);
    await settle();
    expect(order, ['a'], reason: 'b must wait for a to finish unwinding');
    release.complete();
    await settle();
    expect(order, ['a', 'a unwound', 'b']);
    q.dispose();
  });

  test('failures carry the message and can be retried', () async {
    final q = newQueue();
    var attempts = 0;
    final t = q.enqueue(
      kind: TaskKind.upload,
      title: 'x',
      subtitle: '',
      runner: (ctx) async {
        attempts++;
        if (attempts == 1) throw StateError('disk full');
        ctx.addBytes(5);
      },
    );
    await settle();
    expect(t.status, TaskStatus.failed);
    expect(t.error, contains('disk full'));
    final again = q.retry(t.id)!;
    await settle();
    expect(again.status, TaskStatus.completed);
    expect(q.tasks, [again], reason: 'the failed row is replaced');
    expect(attempts, 2);
    q.dispose();
  });

  test(
    'retry is refused for tasks that did not fail or get cancelled',
    () async {
      final q = newQueue();
      final t = q.enqueue(
        kind: TaskKind.upload,
        title: 'x',
        subtitle: '',
        runner: (ctx) async {},
      );
      await settle();
      expect(q.retry(t.id), isNull);
      q.dispose();
    },
  );

  test(
    'finished stream fires once per task with the terminal status',
    () async {
      final q = newQueue();
      final seen = <TaskStatus>[];
      q.finished.listen((t) => seen.add(t.status));
      q.enqueue(
        kind: TaskKind.upload,
        title: 'ok',
        subtitle: '',
        runner: (ctx) async {},
      );
      q.enqueue(
        kind: TaskKind.upload,
        title: 'bad',
        subtitle: '',
        runner: (ctx) async => throw StateError('x'),
      );
      await settle();
      expect(seen, [TaskStatus.completed, TaskStatus.failed]);
      q.dispose();
    },
  );

  test('clearFinished keeps active rows', () async {
    final q = newQueue();
    final gate = Completer<void>();
    q.enqueue(
      kind: TaskKind.upload,
      title: 'done',
      subtitle: '',
      runner: (ctx) async {},
    );
    await settle();
    q.enqueue(
      kind: TaskKind.upload,
      title: 'live',
      subtitle: '',
      runner: (ctx) => gate.future,
    );
    await settle();
    q.clearFinished();
    expect(q.tasks.map((t) => t.title), ['live']);
    gate.complete();
    await settle();
    q.dispose();
  });

  test('speed follows the recent window, and ETA derives from it', () async {
    var now = DateTime(2026, 1, 1);
    final q = newQueue(clock: () => now);
    final gate = Completer<void>();
    late TaskContext ctx0;
    final t = q.enqueue(
      kind: TaskKind.upload,
      title: 'x',
      subtitle: '',
      runner: (ctx) async {
        ctx0 = ctx;
        ctx.setTotal(10000);
        await gate.future;
      },
    );
    await settle();
    // 1000 B/s for 3 s...
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(seconds: 1));
      ctx0.addBytes(1000);
    }
    expect(t.bytesPerSecond(now), closeTo(1000, 1));
    expect(t.eta(now), const Duration(seconds: 7));
    // ...then it speeds up to 4000 B/s; the window forgets the old rate.
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(seconds: 1));
      ctx0.addBytes(4000);
    }
    expect(t.bytesPerSecond(now), greaterThan(3000));
    gate.complete();
    await settle();
    q.dispose();
  });

  test('progress notifications are coalesced', () async {
    final q = TransferQueue(progressInterval: const Duration(milliseconds: 50));
    var notifications = 0;
    final gate = Completer<void>();
    q.addListener(() => notifications++);
    q.enqueue(
      kind: TaskKind.upload,
      title: 'x',
      subtitle: '',
      runner: (ctx) async {
        for (var i = 0; i < 1000; i++) {
          ctx.addBytes(1);
        }
        await gate.future;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final early = notifications;
    expect(
      early,
      lessThan(10),
      reason: '1000 updates must not mean 1000 rebuilds',
    );
    gate.complete();
    await settle();
    q.dispose();
  });
}
