import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'diagnostic_session_metadata.dart';

enum DiagnosticLevel { debug, info, warning, error, fatal }

/// A small, failure-isolated diagnostic recorder for operational events.
///
/// Records are JSON Lines and deliberately exclude document content, stroke
/// points, titles, user/device file-system paths and exception messages.
/// String fields supplied by callers are accepted only when they are short
/// machine-readable tokens. Stack traces retain only package-relative source
/// locations needed to diagnose application defects.
class DiagnosticLogService {
  DiagnosticLogService({
    String? sessionId,
    DateTime Function()? now,
    this.maxFileBytes = 768 * 1024,
    this.maxFiles = 4,
    this.maxQueuedRecords = 256,
    this.maxPreInitializationRecords = 32,
    this.ioWaitTimeout = const Duration(seconds: 2),
  }) : assert(maxFileBytes > 0),
       assert(maxFiles > 0),
       assert(maxQueuedRecords > 0),
       assert(maxPreInitializationRecords >= 0),
       assert(ioWaitTimeout > Duration.zero),
       _sessionId = _validSessionId(sessionId) ?? const Uuid().v4(),
       _now = now ?? DateTime.now;

  static final DiagnosticLogService instance = DiagnosticLogService();

  static const String currentFileName = 'flowboard-diagnostics.jsonl';

  final int maxFileBytes;
  final int maxFiles;
  final int maxQueuedRecords;
  final int maxPreInitializationRecords;
  final Duration ioWaitTimeout;
  final String _sessionId;
  final DateTime Function() _now;

  final List<_PendingDiagnosticRecord> _beforeInitialization = [];
  Future<void> _writeTail = Future<void>.value();
  Directory? _directory;
  DiagnosticSessionMetadata? _metadata;
  bool _initialized = false;
  bool _disabled = false;
  bool _acceptingRecords = true;
  int _queuedRecords = 0;
  int _droppedRecords = 0;
  Future<void>? _shutdownFuture;

  String get sessionId => _sessionId;
  bool get isInitialized => _initialized && !_disabled;
  bool get isAcceptingRecords => _acceptingRecords && !_disabled;

  /// Starts persistent recording. Failure disables file output without ever
  /// preventing the whiteboard from starting.
  Future<bool> initialize({
    required Directory directory,
    required DiagnosticSessionMetadata metadata,
  }) async {
    if (!_acceptingRecords) return false;
    if (_initialized) return !_disabled;
    _initialized = true;
    _metadata = metadata;
    _directory = directory;
    try {
      await directory.create(recursive: true).timeout(ioWaitTimeout);
    } on Object {
      _disabled = true;
      _beforeInitialization.clear();
      return false;
    }

    final buffered = List<_PendingDiagnosticRecord>.of(_beforeInitialization);
    _beforeInitialization.clear();
    _enqueue(
      _PendingDiagnosticRecord(
        timestamp: _now().toUtc(),
        level: DiagnosticLevel.info,
        event: 'session.start',
        fields: const {},
      ),
    );
    for (final record in buffered) {
      _enqueue(record);
    }
    // Persistent writes remain behind the failure-isolated queue. App startup
    // must not wait for a slow or damaged diagnostics file.
    return true;
  }

  void debug(String event, {Map<String, Object?> fields = const {}}) =>
      record(DiagnosticLevel.debug, event, fields: fields);

  void info(String event, {Map<String, Object?> fields = const {}}) =>
      record(DiagnosticLevel.info, event, fields: fields);

  void warning(String event, {Map<String, Object?> fields = const {}}) =>
      record(DiagnosticLevel.warning, event, fields: fields);

  void record(
    DiagnosticLevel level,
    String event, {
    Map<String, Object?> fields = const {},
  }) {
    try {
      if (!_acceptingRecords) return;
      final safeEvent = _safeEventName(event);
      final record = _PendingDiagnosticRecord(
        timestamp: _now().toUtc(),
        level: level,
        event: safeEvent,
        fields: _safeFields(fields),
      );
      if (!_initialized) {
        if (_beforeInitialization.length >= maxPreInitializationRecords &&
            _beforeInitialization.isNotEmpty) {
          _beforeInitialization.removeAt(0);
          _droppedRecords++;
        }
        if (maxPreInitializationRecords > 0) {
          _beforeInitialization.add(record);
        }
        return;
      }
      _enqueue(record);
    } on Object {
      // A diagnostic call is never allowed to affect the application path.
    }
  }

  void recordFlutterError(FlutterErrorDetails details) {
    recordException(
      event: 'flutter.unhandled',
      error: details.exception,
      stackTrace: details.stack,
      fields: {'library': _safeEventName(details.library ?? 'flutter')},
    );
  }

  void recordException({
    required String event,
    required Object error,
    StackTrace? stackTrace,
    bool fatal = false,
    Map<String, Object?> fields = const {},
  }) {
    try {
      final safeStack = _safeStackTrace(stackTrace);
      final type = _safeTypeName(error.runtimeType.toString());
      final fingerprint = sha256
          .convert(utf8.encode('$type\n${safeStack.join('\n')}'))
          .toString()
          .substring(0, 16);
      record(
        fatal ? DiagnosticLevel.fatal : DiagnosticLevel.error,
        event,
        fields: {
          ...fields,
          'error_type': type,
          'fingerprint': fingerprint,
          if (safeStack.isNotEmpty) 'stack': safeStack,
        },
      );
      developer.log(
        '${_safeEventName(event)} [$type/$fingerprint]',
        name: 'flowboard_x.diagnostics',
        level: fatal ? 1200 : 1000,
      );
    } on Object {
      // Never throw from an error handler.
    }
  }

  /// Waits until every record accepted before/during this call is durable.
  Future<void> flush({bool durable = false}) async {
    var queueTimedOut = false;
    for (var attempt = 0; attempt < 4; attempt++) {
      final pending = _writeTail;
      try {
        await pending.timeout(ioWaitTimeout);
      } on TimeoutException {
        queueTimedOut = true;
        break;
      } on Object {
        // Write failures are isolated inside the queue as an extra safeguard.
      }
      if (identical(pending, _writeTail)) break;
    }
    if (durable && isInitialized && !queueTimedOut) {
      final directory = _directory;
      if (directory == null) return;
      try {
        final file = File(p.join(directory.path, currentFileName));
        if (!await file.exists().timeout(ioWaitTimeout)) return;
        final handle = await file
            .open(mode: FileMode.append)
            .timeout(ioWaitTimeout);
        try {
          await handle.flush().timeout(ioWaitTimeout);
        } finally {
          await handle.close().timeout(ioWaitTimeout);
        }
      } on Object {
        // Durability is best-effort when the OS has revoked storage access.
      }
    }
  }

  /// Stops accepting records and drains the bounded queue best-effort.
  /// Calling this more than once is safe.
  Future<void> shutdown() => _shutdownFuture ??= _performShutdown();

  Future<void> _performShutdown() async {
    if (!_acceptingRecords) return;
    if (isInitialized) {
      _enqueue(
        _PendingDiagnosticRecord(
          timestamp: _now().toUtc(),
          level: DiagnosticLevel.info,
          event: 'session.end',
          fields: const {},
        ),
      );
    }
    _acceptingRecords = false;
    _beforeInitialization.clear();
    await flush(durable: true);
  }

  /// Produces one sanitized JSONL file suitable for the existing share flows.
  /// The caller chooses the destination and owns the returned file.
  Future<File?> createExportCopy(Directory destination) async {
    if (!isInitialized) return null;
    await flush();
    try {
      await destination.create(recursive: true);
      final files = await _existingLogFiles(oldestFirst: true);
      if (files.isEmpty) return null;
      final stamp = _now()
          .toUtc()
          .toIso8601String()
          .replaceAll(RegExp(r'[^0-9]'), '')
          .substring(0, 14);
      var target = File(
        p.join(destination.path, 'flowboard-diagnostics-$stamp.jsonl'),
      );
      var suffix = 1;
      while (await target.exists()) {
        target = File(
          p.join(
            destination.path,
            'flowboard-diagnostics-$stamp-$suffix.jsonl',
          ),
        );
        suffix++;
      }
      final temporary = File('${target.path}.partial');
      final sink = temporary.openWrite(mode: FileMode.writeOnly);
      try {
        for (final file in files) {
          await sink.addStream(file.openRead());
        }
      } finally {
        await sink.close();
      }
      return await temporary.rename(target.path);
    } on Object {
      return null;
    }
  }

  Future<List<File>> logFiles() async {
    if (!isInitialized) return const [];
    await flush();
    try {
      return _existingLogFiles(oldestFirst: false);
    } on Object {
      return const [];
    }
  }

  void _enqueue(_PendingDiagnosticRecord record) {
    if (_disabled) return;
    if (_queuedRecords >= maxQueuedRecords) {
      _droppedRecords++;
      return;
    }
    _queuedRecords++;
    final previous = _writeTail;
    _writeTail = () async {
      try {
        await previous;
        if (_disabled) return;
        final dropped = _droppedRecords;
        if (dropped > 0) {
          _droppedRecords = 0;
          await _writeRecord(
            _PendingDiagnosticRecord(
              timestamp: _now().toUtc(),
              level: DiagnosticLevel.warning,
              event: 'diagnostics.queue_overflow',
              fields: {'dropped_count': dropped},
            ),
          );
        }
        await _writeRecord(record);
      } on Object {
        // A full disk, revoked permission or antivirus race must not poison the
        // queue and must never crash the board.
      } finally {
        _queuedRecords--;
      }
    }();
  }

  Future<void> _writeRecord(_PendingDiagnosticRecord record) async {
    final directory = _directory;
    final metadata = _metadata;
    if (directory == null || metadata == null) return;
    final payload = <String, Object?>{
      'schema': 1,
      'timestamp_utc': record.timestamp.toIso8601String(),
      'level': record.level.name,
      'event': record.event,
      'session_id': _sessionId,
      'app_version': _safeMetadataToken(metadata.appVersion),
      'build_number': _safeMetadataToken(metadata.buildNumber),
      'platform': _safeMetadataToken(metadata.platform),
      'platform_version': _safeMetadataSentence(metadata.platformVersion),
      'build_mode': _safeMetadataToken(metadata.buildMode),
      if (record.fields.isNotEmpty) 'fields': record.fields,
    };
    final encoded = '${jsonEncode(payload)}\n';
    final encodedBytes = utf8.encode(encoded).length;
    final current = File(p.join(directory.path, currentFileName));
    await _rotateIfNeeded(current, encodedBytes);
    await current.writeAsString(
      encoded,
      mode: FileMode.append,
      encoding: utf8,
      flush: record.level.index >= DiagnosticLevel.error.index,
    );
  }

  Future<void> _rotateIfNeeded(File current, int incomingBytes) async {
    if (!await current.exists()) return;
    final length = await current.length();
    if (length == 0 || length + incomingBytes <= maxFileBytes) return;

    for (var index = maxFiles - 1; index >= 1; index--) {
      final target = File(p.join(current.parent.path, _rotatedName(index)));
      if (await target.exists()) await target.delete();
      final source = index == 1
          ? current
          : File(p.join(current.parent.path, _rotatedName(index - 1)));
      if (await source.exists()) await source.rename(target.path);
    }
    if (maxFiles == 1 && await current.exists()) await current.delete();
  }

  Future<List<File>> _existingLogFiles({required bool oldestFirst}) async {
    final directory = _directory;
    if (directory == null) return const [];
    final files = <File>[];
    for (var index = 0; index < maxFiles; index++) {
      final file = File(
        p.join(
          directory.path,
          index == 0 ? currentFileName : _rotatedName(index),
        ),
      );
      if (await file.exists()) files.add(file);
    }
    if (oldestFirst) return files.reversed.toList(growable: false);
    return files;
  }

  static String _rotatedName(int index) => 'flowboard-diagnostics.$index.jsonl';

  static String? _validSessionId(String? value) {
    if (value == null) return null;
    return RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
        ).hasMatch(value)
        ? value.toLowerCase()
        : null;
  }

  static String _safeEventName(String value) {
    final trimmed = value.trim();
    if (RegExp(r'^[A-Za-z][A-Za-z0-9_.:-]{0,63}$').hasMatch(trimmed)) {
      return trimmed.toLowerCase();
    }
    return 'diagnostics.invalid_event';
  }

  static String _safeTypeName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_.<>]'), '_');
    if (cleaned.isEmpty) return 'Object';
    return cleaned.substring(0, cleaned.length.clamp(0, 80));
  }

  static String _safeMetadataToken(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._+\-]'), '_');
    if (cleaned.isEmpty) return 'unknown';
    return cleaned.substring(0, cleaned.length.clamp(0, 64));
  }

  static String _safeMetadataSentence(String value) {
    final withoutPaths = value
        .split(RegExp(r'[\r\n]'))
        .first
        .replaceAll(RegExp(r'[A-Za-z]:[\\/][^\s]+'), '<path>')
        .replaceAll(
          RegExp(r'/(?:Users|home|data|storage|sdcard)/[^\s]+'),
          '<path>',
        );
    final cleaned = withoutPaths.replaceAll(
      RegExp(r'[^A-Za-z0-9 ._+\-()/<>]'),
      '_',
    );
    if (cleaned.isEmpty) return 'unknown';
    return cleaned.substring(0, cleaned.length.clamp(0, 120));
  }

  static Map<String, Object?> _safeFields(Map<String, Object?> fields) {
    final result = <String, Object?>{};
    for (final entry in fields.entries.take(24)) {
      final key = entry.key.trim().toLowerCase();
      if (!RegExp(r'^[a-z][a-z0-9_]{0,47}$').hasMatch(key) ||
          _sensitiveFieldKey.hasMatch(key)) {
        continue;
      }
      if (key == 'stack' && entry.value is Iterable<Object?>) {
        final stack = (entry.value as Iterable<Object?>)
            .whereType<String>()
            .where(_isSafeStackFrame)
            .take(24)
            .toList(growable: false);
        if (stack.isNotEmpty) result[key] = stack;
        continue;
      }
      final safe = _safeFieldValue(
        entry.value,
        allowString: _safeStringFieldKeys.contains(key),
      );
      if (!identical(safe, _discarded)) result[key] = safe;
    }
    return result;
  }

  static Object? _safeFieldValue(Object? value, {bool allowString = false}) {
    if (value == null || value is bool || value is int) return value;
    if (value is double && value.isFinite) {
      return double.parse(value.toStringAsFixed(3));
    }
    if (allowString &&
        value is String &&
        RegExp(r'^[A-Za-z0-9_.:+\-]{1,80}$').hasMatch(value)) {
      return value;
    }
    if (value is Iterable<Object?>) {
      final safe = <Object?>[];
      for (final item in value.take(24)) {
        final converted = _safeFieldValue(item, allowString: allowString);
        if (!identical(converted, _discarded)) safe.add(converted);
      }
      return safe;
    }
    return _discarded;
  }

  static List<String> _safeStackTrace(StackTrace? stackTrace) {
    if (stackTrace == null) return const [];
    final result = <String>[];
    for (final line in stackTrace.toString().split(RegExp(r'[\r\n]+'))) {
      final packageMatch = _packageFrame.firstMatch(line);
      if (packageMatch != null) {
        result.add(packageMatch.group(0)!);
      } else {
        final localMatch = _localLibFrame.firstMatch(line);
        if (localMatch != null) {
          result.add(localMatch.group(0)!.replaceAll('\\', '/'));
        } else if (line.contains('<asynchronous suspension>')) {
          result.add('<async>');
        }
      }
      if (result.length == 24) break;
    }
    return result;
  }

  static bool _isSafeStackFrame(String value) =>
      value == '<async>' ||
      _packageFrame.matchAsPrefix(value)?.end == value.length ||
      _localLibFrame.matchAsPrefix(value)?.end == value.length;

  static final RegExp _sensitiveFieldKey = RegExp(
    r'(?:path|file|uri|url|token|secret|password|title|name|text|content|data|stroke|point|document|query|account|email)',
  );
  static const Set<String> _safeStringFieldKeys = {
    'build_mode',
    'engine',
    'error_type',
    'fingerprint',
    'input_kind',
    'library',
    'mode',
    'operation',
    'phase',
    'platform',
    'reason_code',
    'state',
    'tool',
  };
  static final RegExp _packageFrame = RegExp(
    r'(?:package:[A-Za-z0-9_]+/[A-Za-z0-9_./\-]+\.dart:\d+(?::\d+)?|dart:[a-z_]+)',
  );
  static final RegExp _localLibFrame = RegExp(
    r'lib[\\/][A-Za-z0-9_./\\-]+\.dart:\d+(?::\d+)?',
  );
  static const Object _discarded = Object();
}

class DiagnosticLifecycleObserver with WidgetsBindingObserver {
  DiagnosticLifecycleObserver(this.diagnostics);

  final DiagnosticLogService diagnostics;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    diagnostics.info('app.lifecycle', fields: {'state': state.name});
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(diagnostics.flush(durable: true));
    }
  }

  @override
  void didHaveMemoryPressure() {
    diagnostics.warning('app.memory_pressure');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}

class _PendingDiagnosticRecord {
  const _PendingDiagnosticRecord({
    required this.timestamp,
    required this.level,
    required this.event,
    required this.fields,
  });

  final DateTime timestamp;
  final DiagnosticLevel level;
  final String event;
  final Map<String, Object?> fields;
}
