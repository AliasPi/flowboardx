import 'package:flowboard_x/src/features/timer/countdown_timer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CountdownTimerController', () {
    test('uses a monotonic deadline and delivers the alarm exactly once', () {
      final time = _ManualTime();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 5),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
      );
      addTearDown(controller.dispose);

      expect(controller.start(), isTrue);
      time.jumpWithoutCallbacks(const Duration(seconds: 7));
      time.runDueCallbacks();

      expect(controller.status, CountdownTimerStatus.finished);
      expect(controller.remaining, Duration.zero);
      expect(alarmCount, 1);

      time.runDueCallbacks();
      controller.refresh();
      expect(alarmCount, 1);
    });

    test('refresh finishes an elapsed timer after an app resume', () {
      final time = _ManualTime();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 3),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
      );
      addTearDown(controller.dispose);

      controller.start();
      time.jumpWithoutCallbacks(const Duration(minutes: 2));
      controller.refresh();

      expect(controller.status, CountdownTimerStatus.finished);
      expect(controller.remaining, Duration.zero);
      expect(alarmCount, 1);
      time.runDueCallbacks(runCanceledCallbacks: true);
      expect(alarmCount, 1);
    });

    test('pause and resume invalidate stale wake-ups', () {
      final time = _ManualTime();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 10),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
      );
      addTearDown(controller.dispose);

      controller.start();
      time.elapse(const Duration(milliseconds: 2250));
      controller.refresh();
      expect(
        controller.remaining.inMicroseconds,
        inInclusiveRange(
          const Duration(milliseconds: 7749).inMicroseconds,
          const Duration(milliseconds: 7751).inMicroseconds,
        ),
      );

      expect(controller.pause(), isTrue);
      final pausedAt = controller.remaining;
      time.elapse(const Duration(minutes: 2), runCanceledCallbacks: true);
      expect(controller.remaining, pausedAt);
      expect(controller.status, CountdownTimerStatus.paused);
      expect(alarmCount, 0);

      controller.start();
      time.elapse(pausedAt);
      expect(controller.status, CountdownTimerStatus.finished);
      expect(alarmCount, 1);
    });

    test('setDuration and reset cancel pending work defensively', () {
      final time = _ManualTime();
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 4),
        now: time.now,
        scheduler: time.schedule,
      );
      addTearDown(controller.dispose);

      controller.start();
      time.elapse(const Duration(seconds: 1));
      controller.setDuration(const Duration(minutes: 3));
      time.elapse(const Duration(seconds: 10), runCanceledCallbacks: true);

      expect(controller.status, CountdownTimerStatus.idle);
      expect(controller.remaining, const Duration(minutes: 3));

      controller.start();
      time.elapse(const Duration(seconds: 1));
      controller.reset();
      expect(controller.status, CountdownTimerStatus.idle);
      expect(controller.remaining, const Duration(minutes: 3));
    });

    test('dispose makes already queued callbacks harmless', () {
      final time = _ManualTime();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 1),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
      );

      controller.start();
      controller.dispose();
      time.elapse(const Duration(seconds: 5), runCanceledCallbacks: true);

      expect(alarmCount, 0);
    });

    test('zero cannot start and excessive durations are clamped', () {
      final controller = CountdownTimerController(
        initialDuration: Duration.zero,
      );
      addTearDown(controller.dispose);

      expect(controller.start(), isFalse);
      controller.setDuration(const Duration(days: 8));
      expect(
        controller.configuredDuration,
        CountdownTimerController.maximumDuration,
      );
    });
  });

  group('formatCountdown', () {
    test('ceil-formats seconds and adds hours only when needed', () {
      expect(formatCountdown(Duration.zero), '00:00');
      expect(formatCountdown(const Duration(microseconds: 1)), '00:01');
      expect(formatCountdown(const Duration(minutes: 2, seconds: 3)), '02:03');
      expect(
        formatCountdown(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '01:02:03',
      );
    });
  });
}

final class _ManualTime {
  Duration _elapsed = Duration.zero;
  final List<_ManualWakeUp> _wakeUps = <_ManualWakeUp>[];

  Duration now() => _elapsed;

  CountdownWakeUp schedule(Duration delay, void Function() callback) {
    final wakeUp = _ManualWakeUp(_elapsed + delay, callback);
    _wakeUps.add(wakeUp);
    return wakeUp;
  }

  void jumpWithoutCallbacks(Duration duration) {
    _elapsed += duration;
  }

  void runDueCallbacks({bool runCanceledCallbacks = false}) {
    while (true) {
      final due =
          _wakeUps
              .where(
                (entry) =>
                    !entry.fired &&
                    entry.due <= _elapsed &&
                    (runCanceledCallbacks || !entry.canceled),
              )
              .toList()
            ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) return;
      final wakeUp = due.first;
      wakeUp.fired = true;
      wakeUp.callback();
    }
  }

  void elapse(Duration duration, {bool runCanceledCallbacks = false}) {
    final target = _elapsed + duration;
    while (true) {
      final pending =
          _wakeUps
              .where(
                (entry) =>
                    !entry.fired &&
                    entry.due <= target &&
                    (runCanceledCallbacks || !entry.canceled),
              )
              .toList()
            ..sort((a, b) => a.due.compareTo(b.due));
      if (pending.isEmpty) break;
      final wakeUp = pending.first;
      _elapsed = wakeUp.due;
      wakeUp.fired = true;
      wakeUp.callback();
    }
    _elapsed = target;
  }
}

final class _ManualWakeUp implements CountdownWakeUp {
  _ManualWakeUp(this.due, this.callback);

  final Duration due;
  final void Function() callback;
  bool canceled = false;
  bool fired = false;

  @override
  void cancel() => canceled = true;
}
