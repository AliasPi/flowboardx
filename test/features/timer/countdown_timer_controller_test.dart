import 'package:flowboard_x/src/features/timer/countdown_timer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CountdownTimerController', () {
    test('uses a monotonic deadline and starts the alarm on expiry', () {
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

    test('repeats the alarm until the user explicitly acknowledges it', () {
      final time = _ManualTime();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 2),
        now: time.now,
        scheduler: time.schedule,
        alarmRepeatInterval: const Duration(milliseconds: 750),
        onAlarm: () => alarmCount++,
      );
      addTearDown(controller.dispose);

      controller.start();
      time.elapse(const Duration(seconds: 2));

      expect(controller.status, CountdownTimerStatus.finished);
      expect(controller.isAlarmActive, isTrue);
      expect(controller.state.alarmActive, isTrue);
      expect(alarmCount, 1, reason: 'Expiry sounds immediately.');

      time.elapse(const Duration(milliseconds: 2250));
      expect(alarmCount, 4, reason: 'Three repeat pulses follow.');

      expect(controller.acknowledgeAlarm(), isTrue);
      expect(controller.isAlarmActive, isFalse);
      expect(controller.state.alarmActive, isFalse);
      final acknowledgedAt = alarmCount;
      time.elapse(const Duration(seconds: 10), runCanceledCallbacks: true);
      expect(alarmCount, acknowledgedAt);
      expect(controller.acknowledgeAlarm(), isFalse);
    });

    test('stops active alarm output exactly once', () {
      final time = _ManualTime();
      var alarmCount = 0;
      var stopCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 1),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
        onAlarmStopped: () => stopCount++,
      );

      controller.start();
      time.elapse(const Duration(seconds: 2));
      expect(alarmCount, 2);
      expect(stopCount, 0);

      expect(controller.acknowledgeAlarm(), isTrue);
      expect(stopCount, 1);
      expect(controller.acknowledgeAlarm(), isFalse);
      controller.reset();
      expect(stopCount, 1);

      controller.start();
      time.elapse(const Duration(seconds: 1));
      controller.dispose();
      expect(stopCount, 2, reason: 'Disposal must stop native playback too.');
    });

    test('publishes one atomic live state for every countdown view', () {
      final time = _ManualTime();
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 4),
        now: time.now,
        scheduler: time.schedule,
      );
      addTearDown(controller.dispose);
      final states = <CountdownTimerState>[];
      controller.liveState.addListener(() => states.add(controller.state));

      controller.start();
      time.elapse(const Duration(seconds: 2));

      expect(states, hasLength(3));
      expect(states.first.status, CountdownTimerStatus.running);
      expect(states.last.remaining, const Duration(seconds: 2));
      expect(states.last, controller.state);
    });

    test('derives final-minute and alarm presentation stages', () {
      const idle = CountdownTimerState(
        configuredDuration: Duration(minutes: 2),
        remaining: Duration(minutes: 2),
        status: CountdownTimerStatus.idle,
        alarmActive: false,
      );
      const beforeFinalMinute = CountdownTimerState(
        configuredDuration: Duration(minutes: 2),
        remaining: Duration(seconds: 61),
        status: CountdownTimerStatus.running,
        alarmActive: false,
      );
      const finalMinute = CountdownTimerState(
        configuredDuration: Duration(minutes: 2),
        remaining: Duration(minutes: 1),
        status: CountdownTimerStatus.running,
        alarmActive: false,
      );
      const alarm = CountdownTimerState(
        configuredDuration: Duration(minutes: 2),
        remaining: Duration.zero,
        status: CountdownTimerStatus.finished,
        alarmActive: true,
      );

      expect(idle.presentationStage, CountdownTimerPresentationStage.none);
      expect(
        beforeFinalMinute.presentationStage,
        CountdownTimerPresentationStage.none,
      );
      expect(
        finalMinute.presentationStage,
        CountdownTimerPresentationStage.finalMinute,
      );
      expect(alarm.presentationStage, CountdownTimerPresentationStage.alarm);
    });

    test('default display wake-ups are bounded to one per second', () {
      final time = _ManualTime();
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 10),
        now: time.now,
        scheduler: time.schedule,
      );
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.start();
      time.elapse(const Duration(seconds: 3));

      expect(notifications, 4, reason: 'Start plus three displayed seconds.');
      expect(
        time.scheduledWakeUpCount,
        4,
        reason: 'A text-only countdown does not need five wake-ups per second.',
      );
      expect(controller.remaining, const Duration(seconds: 7));
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

    test('reset, setDuration and restart all stop an active alarm', () {
      final time = _ManualTime();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 1),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
      );
      addTearDown(controller.dispose);

      controller.start();
      time.elapse(const Duration(seconds: 1));
      expect(controller.isAlarmActive, isTrue);
      controller.reset();
      expect(controller.isAlarmActive, isFalse);
      final afterReset = alarmCount;
      time.elapse(const Duration(seconds: 2), runCanceledCallbacks: true);
      expect(alarmCount, afterReset);

      controller.start();
      time.elapse(const Duration(seconds: 1));
      expect(controller.isAlarmActive, isTrue);
      controller.setDuration(const Duration(seconds: 2));
      expect(controller.isAlarmActive, isFalse);
      final afterSetDuration = alarmCount;
      time.elapse(const Duration(seconds: 2), runCanceledCallbacks: true);
      expect(alarmCount, afterSetDuration);

      controller.start();
      time.elapse(const Duration(seconds: 2));
      expect(controller.isAlarmActive, isTrue);
      final beforeRestart = alarmCount;
      expect(controller.start(), isTrue);
      expect(controller.isAlarmActive, isFalse);
      expect(controller.isRunning, isTrue);
      time.elapse(const Duration(seconds: 1), runCanceledCallbacks: true);
      expect(alarmCount, beforeRestart);
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

    test('dispose stops an already active repeating alarm', () {
      final time = _ManualTime();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 1),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
      );

      controller.start();
      time.elapse(const Duration(seconds: 1));
      expect(alarmCount, 1);
      expect(controller.isAlarmActive, isTrue);

      controller.dispose();
      time.elapse(const Duration(seconds: 5), runCanceledCallbacks: true);
      expect(alarmCount, 1);
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
  int get scheduledWakeUpCount => _wakeUps.length;

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
