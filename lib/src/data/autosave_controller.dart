import 'dart:async';

import '../domain/model/document.dart';
import 'document_repository.dart';

final class AutosaveController {
  AutosaveController(
    this.repository,
    this.documentId, {
    this.debounce = const Duration(milliseconds: 350),
    this.maxLatency = const Duration(seconds: 2),
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
  }

  final DocumentRepository repository;
  final String documentId;
  final Duration debounce;
  final Duration maxLatency;
  final StreamController<Object> _errors = StreamController.broadcast();
  Timer? _timer;
  Timer? _maxTimer;
  WhiteboardDocument? _pending;
  Future<void>? _activeSave;
  bool _disposed = false;

  bool get hasPendingChanges => _pending != null || _activeSave != null;
  Stream<Object> get errors => _errors.stream;

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
    _timer?.cancel();
    _timer = Timer(debounce, _triggerSave);
    _maxTimer ??= Timer(maxLatency, _triggerSave);
  }

  void _triggerSave() {
    _timer?.cancel();
    _timer = null;
    _maxTimer?.cancel();
    _maxTimer = null;
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
    do {
      if (_pending == null) break;
      final document = _pending!;
      _pending = null;
      try {
        await repository.save(document);
      } catch (error) {
        _pending ??= document;
        if (!_errors.isClosed) _errors.add(error);
        rethrow;
      }
    } while (drainAll && _pending != null);
    if (_pending == null) {
      _timer?.cancel();
      _timer = null;
      _maxTimer?.cancel();
      _maxTimer = null;
    } else {
      _timer ??= Timer(debounce, _triggerSave);
      _maxTimer ??= Timer(maxLatency, _triggerSave);
    }
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('AutosaveController wurde bereits geschlossen.');
    }
  }
}
