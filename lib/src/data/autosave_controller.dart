import 'dart:async';

import '../domain/model/document.dart';
import 'document_repository.dart';

final class AutosaveController {
  AutosaveController(
    this.repository,
    this.documentId, {
    this.debounce = const Duration(milliseconds: 350),
    this.maxLatency = const Duration(seconds: 2),
    this.interactionIdleDelay = const Duration(milliseconds: 1200),
    this.retryBaseDelay = const Duration(seconds: 1),
    this.retryMaximumDelay = const Duration(seconds: 30),
  }) {
    if (debounce.isNegative) {
      throw ArgumentError.value(
        debounce,
        'debounce',
        'darf nicht negativ sein',
      );
    }
    if (maxLatency <= Duration.zero) {
      throw ArgumentError.value(maxLatency, 'maxLatency', 'muss positiv sein');
    }
    if (interactionIdleDelay.isNegative) {
      throw ArgumentError.value(
        interactionIdleDelay,
        'interactionIdleDelay',
        'darf nicht negativ sein',
      );
    }
    if (retryBaseDelay <= Duration.zero || retryMaximumDelay < retryBaseDelay) {
      throw ArgumentError('Auto-Save-Wiederholungsintervalle sind ungültig.');
    }
  }

  final DocumentRepository repository;
  final String documentId;
  final Duration debounce;
  final Duration maxLatency;
  final Duration interactionIdleDelay;
  final Duration retryBaseDelay;
  final Duration retryMaximumDelay;
  final StreamController<Object> _errors = StreamController.broadcast();
  Timer? _timer;
  Timer? _maxTimer;
  Timer? _retryTimer;
  WhiteboardDocument? _pending;
  Future<void>? _activeSave;
  bool _disposed = false;
  int _retryAttempt = 0;
  int _interactionDepth = 0;
  int _interactionEpoch = 0;

  bool get hasPendingChanges => _pending != null || _activeSave != null;
  Stream<Object> get errors => _errors.stream;

  /// Defers expensive full-document persistence while latency-sensitive input
  /// is active. A document snapshot is still retained in [_pending] and
  /// [flush] always persists it immediately for lifecycle/crash boundaries.
  ///
  /// Multiple pens and the two participant views may overlap, hence the
  /// reference count instead of a single boolean.
  void beginInteraction() {
    _ensureActive();
    _interactionEpoch++;
    _interactionDepth++;
    _timer?.cancel();
    _timer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void endInteraction() {
    _ensureActive();
    if (_interactionDepth == 0) return;
    _interactionDepth--;
    if (_interactionDepth == 0 && _pending != null && _activeSave == null) {
      _armSaveTimers(delay: interactionIdleDelay);
    }
  }

  void schedule(WhiteboardDocument document) {
    _ensureActive();
    if (document.id != documentId) {
      throw ArgumentError.value(
        document.id,
        'document.id',
        'erwartet wurde $documentId',
      );
    }
    _pending = document;
    _retryTimer?.cancel();
    _retryTimer = null;
    _timer?.cancel();
    _timer = null;
    if (_interactionDepth == 0) {
      _armSaveTimers(delay: debounce);
    } else {
      // A max-latency timer must not copy and encode a growing document in the
      // middle of a stylus gesture. Lifecycle flushes remain unconditional.
      _maxTimer?.cancel();
      _maxTimer = null;
    }
  }

  void _triggerSave() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _timer?.cancel();
    _timer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    if (_interactionDepth > 0) return;
    if (_activeSave != null) {
      // A slow save is not a storage failure. The active drain observes a
      // newer [_pending] snapshot when it completes and arms the normal
      // debounce itself. Starting exponential failure backoff here created
      // avoidable timers exactly when large documents took longer to encode.
      return;
    }
    _startDrain().catchError((Object _) {
      // Error is emitted through [errors] and retried by flush/next schedule.
    });
  }

  Future<void> flush() async {
    _ensureActive();
    _timer?.cancel();
    _timer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final active = _activeSave;
    if (active != null) {
      await active;
      if (identical(_activeSave, active)) _activeSave = null;
    }
    while (_pending != null) {
      await _startDrain(drainAll: true);
    }
  }

  Future<void> dispose({bool flushPending = true}) async {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (flushPending) {
      final active = _activeSave;
      if (active != null) {
        await active;
        if (identical(_activeSave, active)) _activeSave = null;
      }
      while (_pending != null) {
        await _startDrain(drainAll: true);
      }
    }
    _disposed = true;
    _interactionDepth = 0;
    if (!flushPending) _pending = null;
    await _errors.close();
  }

  Future<void> _startDrain({bool drainAll = false}) {
    final active = _activeSave;
    if (active != null) return active;
    final operation = _drain(drainAll: drainAll);
    _activeSave = operation;
    operation.then<void>(
      (_) {
        if (identical(_activeSave, operation)) _activeSave = null;
      },
      onError: (Object _, StackTrace stackTrace) {
        if (identical(_activeSave, operation)) _activeSave = null;
      },
    );
    return operation;
  }

  Future<void> _drain({required bool drainAll}) async {
    var deferredForInteraction = false;
    do {
      if (_pending == null) break;
      final document = _pending!;
      _pending = null;
      if (!drainAll) {
        // Yield once before repository.save starts its isolate message copy.
        // A pointer-down already queued for this frame can then invalidate the
        // idle save before any page-dependent snapshot work begins.
        final idleEpoch = _interactionEpoch;
        await Future<void>.delayed(Duration.zero);
        if (_interactionDepth > 0 || idleEpoch != _interactionEpoch) {
          _pending ??= document;
          deferredForInteraction = true;
          break;
        }
      }
      try {
        await repository.save(document);
        _retryAttempt = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
      } catch (error) {
        _pending ??= document;
        if (!_errors.isClosed) _errors.add(error);
        _scheduleRetry();
        rethrow;
      }
    } while (drainAll && _pending != null);
    if (_pending == null) {
      _timer?.cancel();
      _timer = null;
      _maxTimer?.cancel();
      _maxTimer = null;
    } else {
      if (_interactionDepth == 0) {
        _armSaveTimers(
          delay: deferredForInteraction ? interactionIdleDelay : debounce,
        );
      }
    }
  }

  void _scheduleRetry() {
    if (_disposed ||
        _interactionDepth > 0 ||
        _retryTimer != null ||
        _pending == null) {
      return;
    }
    final exponent = _retryAttempt.clamp(0, 10).toInt();
    _retryAttempt++;
    final multiplier = 1 << exponent;
    final delayMicros = (retryBaseDelay.inMicroseconds * multiplier)
        .clamp(retryBaseDelay.inMicroseconds, retryMaximumDelay.inMicroseconds)
        .toInt();
    _retryTimer = Timer(Duration(microseconds: delayMicros), () {
      _retryTimer = null;
      _triggerSave();
    });
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('AutosaveController wurde bereits geschlossen.');
    }
  }

  void _armSaveTimers({required Duration delay}) {
    if (_disposed || _interactionDepth > 0 || _pending == null) return;
    _timer?.cancel();
    _timer = Timer(delay, _triggerSave);
    _maxTimer ??= Timer(maxLatency, _triggerSave);
  }
}
