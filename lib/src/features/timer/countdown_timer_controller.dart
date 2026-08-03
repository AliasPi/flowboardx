import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Monotonic time source used by [CountdownTimerController].
///
/// A monotonic clock keeps a running countdown correct when the system clock is
/// changed while a lesson is in progress. Tests can inject a deterministic
/// implementation.
typedef CountdownNow = Duration Function();

/// A cancelable, one-shot wake-up used by [CountdownTimerController].
abstract interface class CountdownWakeUp {
  void cancel();
}

/// Schedules a one-shot wake-up.
typedef CountdownScheduler =
    CountdownWakeUp Function(Duration delay, VoidCallback callback);

enum CountdownTimerStatus { idle, running, paused, finished }

/// Presentation milestones that may request the non-modal large timer panel.
///
/// A stage is deliberately derived from the authoritative countdown state. It
/// therefore also changes correctly after an app resume without relying on a
/// particular one-second wake-up having run in the foreground.
enum CountdownTimerPresentationStage { none, finalMinute, alarm }

/// Immutable state consumed by every countdown presentation.
///
/// Keeping the toolbar and the large overlay on this single listenable avoids
/// presentation-local timer copies and guarantees that both views render the
/// same tick and alarm state.
@immutable
final class CountdownTimerState {
  const CountdownTimerState({
    required this.configuredDuration,
    required this.remaining,
    required this.status,
    required this.alarmActive,
  });

  final Duration configuredDuration;
  final Duration remaining;
  final CountdownTimerStatus status;
  final bool alarmActive;

  bool get isRunning => status == CountdownTimerStatus.running;
  bool get isPaused => status == CountdownTimerStatus.paused;
  bool get isFinished => status == CountdownTimerStatus.finished;

  CountdownTimerPresentationStage get presentationStage {
    if (alarmActive) return CountdownTimerPresentationStage.alarm;
    if (isRunning && remaining <= const Duration(minutes: 1)) {
      return CountdownTimerPresentationStage.finalMinute;
    }
    return CountdownTimerPresentationStage.none;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CountdownTimerState &&
          configuredDuration == other.configuredDuration &&
          remaining == other.remaining &&
          status == other.status &&
          alarmActive == other.alarmActive;

  @override
  int get hashCode =>
      Object.hash(configuredDuration, remaining, status, alarmActive);
}

/// Drift-resistant countdown state that owns at most one native timer.
///
/// The controller derives the remaining duration from a monotonic deadline
/// instead of subtracting a fixed amount on every tick. A delayed UI frame
/// therefore never makes the timer run slow.
final class CountdownTimerController extends ChangeNotifier {
  CountdownTimerController({
    Duration initialDuration = const Duration(minutes: 5),
    VoidCallback? onAlarm,
    CountdownNow? now,
    CountdownScheduler? scheduler,
    this.refreshInterval = const Duration(seconds: 1),
    this.alarmRepeatInterval = const Duration(seconds: 1),
  }) : assert(!refreshInterval.isNegative && refreshInterval > Duration.zero),
       assert(
         !alarmRepeatInterval.isNegative && alarmRepeatInterval > Duration.zero,
       ),
       _configuredDuration = clampCountdownDuration(initialDuration),
       _remaining = clampCountdownDuration(initialDuration),
       _onAlarm = onAlarm,
       _clock = now == null ? _MonotonicClock() : null,
       _nowOverride = now,
       _scheduler = scheduler ?? _scheduleWithDartTimer {
    _liveState = ValueNotifier<CountdownTimerState>(_snapshot());
  }

  static const Duration maximumDuration = Duration(
    hours: 23,
    minutes: 59,
    seconds: 59,
  );

  final Duration refreshInterval;
  final Duration alarmRepeatInterval;
  final VoidCallback? _onAlarm;
  final _MonotonicClock? _clock;
  final CountdownNow? _nowOverride;
  final CountdownScheduler _scheduler;

  Duration _configuredDuration;
  Duration _remaining;
  Duration? _deadline;
  CountdownWakeUp? _wakeUp;
  CountdownWakeUp? _alarmWakeUp;
  late final ValueNotifier<CountdownTimerState> _liveState;
  CountdownTimerStatus _status = CountdownTimerStatus.idle;
  int _generation = 0;
  int _alarmGeneration = 0;
  bool _alarmActive = false;
  bool _disposed = false;

  Duration get configuredDuration => _configuredDuration;
  Duration get remaining => _remaining;
  CountdownTimerStatus get status => _status;
  bool get isRunning => _status == CountdownTimerStatus.running;
  bool get isPaused => _status == CountdownTimerStatus.paused;
  bool get isFinished => _status == CountdownTimerStatus.finished;
  bool get isAlarmActive => _alarmActive;

  /// Atomic live state shared by the toolbar and the resizable overlay.
  ValueListenable<CountdownTimerState> get liveState => _liveState;

  CountdownTimerState get state => _liveState.value;

  /// Remaining fraction in the inclusive range 0…1.
  double get remainingFraction {
    final total = _configuredDuration.inMicroseconds;
    if (total <= 0) return 0;
    return (_remaining.inMicroseconds / total).clamp(0.0, 1.0);
  }

  /// Changes the target time and returns the timer to its idle state.
  ///
  /// Values outside the supported range are safely clamped. Passing zero keeps
  /// the timer idle; [start] will simply return `false`.
  void setDuration(Duration duration) {
    if (_disposed) return;
    final value = clampCountdownDuration(duration);
    _invalidateWakeUp();
    _stopAlarm(notify: false);
    final changed =
        _configuredDuration != value ||
        _remaining != value ||
        _status != CountdownTimerStatus.idle;
    _configuredDuration = value;
    _remaining = value;
    _deadline = null;
    _status = CountdownTimerStatus.idle;
    if (changed) _publish();
  }

  /// Starts a fresh timer or resumes a paused timer.
  ///
  /// A finished timer starts again with its configured duration.
  bool start() {
    if (_disposed || _status == CountdownTimerStatus.running) return false;
    _stopAlarm(notify: false);
    if (_status == CountdownTimerStatus.finished) {
      _remaining = _configuredDuration;
    }
    if (_remaining <= Duration.zero) return false;

    _invalidateWakeUp();
    _deadline = _now() + _remaining;
    _status = CountdownTimerStatus.running;
    _publish();
    _scheduleNextWakeUp();
    return true;
  }

  /// Pauses at the deadline-derived remaining duration.
  bool pause() {
    if (_disposed || _status != CountdownTimerStatus.running) return false;
    _synchronize(deliverAlarm: true, scheduleNext: false);
    if (_status != CountdownTimerStatus.running) return false;
    _invalidateWakeUp();
    _deadline = null;
    _status = CountdownTimerStatus.paused;
    _publish();
    return true;
  }

  /// Restores the configured duration without starting it.
  void reset() {
    if (_disposed) return;
    _invalidateWakeUp();
    _stopAlarm(notify: false);
    final changed =
        _remaining != _configuredDuration ||
        _status != CountdownTimerStatus.idle;
    _remaining = _configuredDuration;
    _deadline = null;
    _status = CountdownTimerStatus.idle;
    if (changed) _publish();
  }

  /// Stops a finished timer's repeating alarm after an explicit user action.
  ///
  /// The timer remains at `00:00`, making the elapsed state visible until the
  /// user starts it again or resets it.
  bool acknowledgeAlarm() {
    if (_disposed || !_alarmActive) return false;
    _stopAlarm(notify: false);
    _publish();
    return true;
  }

  /// Synchronizes immediately, useful after returning from the background.
  ///
  /// Normal countdown operation does not require callers to invoke this.
  void refresh() {
    if (_disposed || _status != CountdownTimerStatus.running) return;
    _synchronize(deliverAlarm: true, scheduleNext: true);
  }

  Duration _now() => _nowOverride?.call() ?? _clock!.elapsed;

  void _scheduleNextWakeUp() {
    if (_disposed || _status != CountdownTimerStatus.running) return;
    _wakeUp?.cancel();
    final generation = _generation;
    final delay = _remaining < refreshInterval ? _remaining : refreshInterval;
    _wakeUp = _scheduler(
      delay <= Duration.zero ? const Duration(microseconds: 1) : delay,
      () {
        if (_disposed ||
            generation != _generation ||
            _status != CountdownTimerStatus.running) {
          return;
        }
        _wakeUp = null;
        _synchronize(deliverAlarm: true, scheduleNext: true);
      },
    );
  }

  void _synchronize({required bool deliverAlarm, required bool scheduleNext}) {
    final deadline = _deadline;
    if (_disposed ||
        deadline == null ||
        _status != CountdownTimerStatus.running) {
      return;
    }

    final nextRemaining = deadline - _now();
    if (nextRemaining <= Duration.zero) {
      _invalidateWakeUp();
      _remaining = Duration.zero;
      _deadline = null;
      _status = CountdownTimerStatus.finished;
      if (deliverAlarm) _startAlarm();
      _publish();
      return;
    }

    _remaining = nextRemaining;
    _publish();
    if (scheduleNext) _scheduleNextWakeUp();
  }

  void _startAlarm() {
    if (_disposed || _alarmActive) return;
    _alarmActive = true;
    _deliverAlarmPulse();
    _scheduleNextAlarmPulse();
  }

  void _deliverAlarmPulse() {
    if (!_alarmActive || _disposed) return;
    final callback = _onAlarm;
    if (callback == null) return;
    try {
      callback();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'FlowboardX countdown timer',
          context: ErrorDescription('while playing the countdown alarm'),
        ),
      );
    }
  }

  void _scheduleNextAlarmPulse() {
    if (_disposed || !_alarmActive) return;
    _alarmWakeUp?.cancel();
    final generation = _alarmGeneration;
    _alarmWakeUp = _scheduler(alarmRepeatInterval, () {
      if (_disposed || generation != _alarmGeneration || !_alarmActive) {
        return;
      }
      _alarmWakeUp = null;
      _deliverAlarmPulse();
      _scheduleNextAlarmPulse();
    });
  }

  void _stopAlarm({required bool notify}) {
    final changed = _alarmActive;
    _alarmGeneration++;
    _alarmWakeUp?.cancel();
    _alarmWakeUp = null;
    _alarmActive = false;
    if (notify && changed) _publish();
  }

  CountdownTimerState _snapshot() => CountdownTimerState(
    configuredDuration: _configuredDuration,
    remaining: _remaining,
    status: _status,
    alarmActive: _alarmActive,
  );

  void _publish() {
    if (_disposed) return;
    final snapshot = _snapshot();
    if (_liveState.value != snapshot) {
      _liveState.value = snapshot;
    }
    if (!_disposed) notifyListeners();
  }

  void _invalidateWakeUp() {
    _generation++;
    _wakeUp?.cancel();
    _wakeUp = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidateWakeUp();
    _stopAlarm(notify: false);
    _deadline = null;
    _liveState.dispose();
    super.dispose();
  }
}

Duration clampCountdownDuration(Duration duration) {
  if (duration <= Duration.zero) return Duration.zero;
  if (duration > CountdownTimerController.maximumDuration) {
    return CountdownTimerController.maximumDuration;
  }
  return duration;
}

/// Formats a countdown using ceiling seconds, so 00:01 never appears as 00:00.
String formatCountdown(Duration duration) {
  final micros = duration.inMicroseconds.clamp(
    0,
    CountdownTimerController.maximumDuration.inMicroseconds,
  );
  final totalSeconds =
      (micros + Duration.microsecondsPerSecond - 1) ~/
      Duration.microsecondsPerSecond;
  final hours = totalSeconds ~/ Duration.secondsPerHour;
  final minutes = (totalSeconds ~/ Duration.secondsPerMinute) % 60;
  final seconds = totalSeconds % 60;
  final minuteText = minutes.toString().padLeft(2, '0');
  final secondText = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minuteText:$secondText';
  }
  return '$minuteText:$secondText';
}

/// Plays the platform's alert sound without letting a missing platform
/// implementation terminate the countdown callback.
void playSystemCountdownAlarm() {
  unawaited(
    SystemSound.play(SystemSoundType.alert).onError((
      Object error,
      StackTrace stackTrace,
    ) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'FlowboardX countdown timer',
          context: ErrorDescription('while invoking the system alert sound'),
        ),
      );
    }),
  );
}

final class _MonotonicClock {
  _MonotonicClock() {
    _stopwatch.start();
  }

  final Stopwatch _stopwatch = Stopwatch();
  Duration get elapsed => _stopwatch.elapsed;
}

final class _DartTimerWakeUp implements CountdownWakeUp {
  _DartTimerWakeUp(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

CountdownWakeUp _scheduleWithDartTimer(Duration delay, VoidCallback callback) =>
    _DartTimerWakeUp(Timer(delay, callback));
