import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum WidgetLaunchActionType { newWhiteboard, openDocument }

@immutable
final class WidgetLaunchAction {
  const WidgetLaunchAction({
    required this.type,
    required this.eventId,
    this.documentId,
  });

  factory WidgetLaunchAction.fromMap(Map<Object?, Object?> map) {
    final rawType = map['type'];
    final eventId = map['eventId'];
    if (eventId is! String || eventId.isEmpty) {
      throw const FormatException(
        'Widget launch action is missing an eventId.',
      );
    }
    return switch (rawType) {
      'newWhiteboard' => WidgetLaunchAction(
        type: WidgetLaunchActionType.newWhiteboard,
        eventId: eventId,
      ),
      'openDocument' => WidgetLaunchAction(
        type: WidgetLaunchActionType.openDocument,
        eventId: eventId,
        documentId: _requiredString(map['documentId'], 'documentId'),
      ),
      _ => throw FormatException('Unknown widget action: $rawType'),
    };
  }

  final WidgetLaunchActionType type;
  final String eventId;
  final String? documentId;
}

@immutable
final class WidgetDocument {
  const WidgetDocument({
    required this.id,
    required this.title,
    required this.modifiedAt,
    this.previewPath,
  });

  factory WidgetDocument.fromMap(Map<Object?, Object?> map) {
    final epochValue = map['updatedAtEpochMillis'];
    final epoch = switch (epochValue) {
      int value => value,
      String value => int.tryParse(value),
      _ => null,
    };
    if (epoch == null || epoch < 0) {
      throw const FormatException('Invalid widget document modification date.');
    }
    final preview = map['previewPath'];
    if (preview != null && preview is! String) {
      throw const FormatException('Invalid widget document preview path.');
    }
    return WidgetDocument(
      id: _requiredString(map['id'], 'id'),
      title: _requiredString(map['title'], 'title'),
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(epoch),
      previewPath: preview as String?,
    );
  }

  final String id;
  final String title;
  final DateTime modifiedAt;

  /// Absolute path to an app-owned, small PNG/JPEG preview. Android decodes it
  /// with sampling and never exposes the path outside the process.
  final String? previewPath;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'title': title,
    'updatedAtEpochMillis': modifiedAt.millisecondsSinceEpoch,
    'previewPath': previewPath,
  };
}

/// Method-channel bridge for the Android home-screen widget.
///
/// Launch actions are queued as well as streamed, so an initial cold-start
/// action cannot be lost before application routing has subscribed.
final class AndroidWidgetBridge {
  AndroidWidgetBridge({MethodChannel? channel, bool? isSupported})
    : _channel = channel ?? const MethodChannel(channelName),
      _isSupported =
          isSupported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const channelName = 'de.flowboardx/platform_widget';
  static final AndroidWidgetBridge instance = AndroidWidgetBridge();

  final MethodChannel _channel;
  final bool _isSupported;
  final StreamController<WidgetLaunchAction> _launchController =
      StreamController<WidgetLaunchAction>.broadcast(sync: true);
  final Queue<WidgetLaunchAction> _pendingActions = Queue<WidgetLaunchAction>();
  final Set<String> _seenEventIds = <String>{};
  bool _initialized = false;
  bool _disposed = false;

  bool get isSupported => _isSupported;
  Stream<WidgetLaunchAction> get launchActions => _launchController.stream;
  bool get hasPendingLaunchAction => _pendingActions.isNotEmpty;

  Future<void> initialize() async {
    _ensureNotDisposed();
    if (_initialized || !_isSupported) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>(
        'consumeLaunchAction',
      );
      if (value != null) _acceptAction(value);
    } on MissingPluginException {
      // Allows desktop/web builds to use the same application shell.
    } on PlatformException {
      _initialized = false;
      rethrow;
    }
  }

  WidgetLaunchAction? consumePendingLaunchAction() =>
      _pendingActions.isEmpty ? null : _pendingActions.removeFirst();

  Future<int> updateRecentDocuments(Iterable<WidgetDocument> documents) async {
    _ensureNotDisposed();
    if (!_isSupported) return 0;
    final unique = <String, WidgetDocument>{};
    for (final document in documents) {
      if (document.id.trim().isEmpty || document.title.trim().isEmpty) continue;
      final existing = unique[document.id];
      if (existing == null ||
          document.modifiedAt.isAfter(existing.modifiedAt)) {
        unique[document.id] = document;
      }
    }
    final recent = unique.values.toList()
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final payload = recent
        .take(12)
        .map((document) => document.toMap())
        .toList();
    try {
      final result = await _channel.invokeMethod<int>(
        'updateDocuments',
        <String, Object?>{'documents': payload},
      );
      return result ?? 0;
    } on MissingPluginException {
      return 0;
    }
  }

  Future<void> refresh() async {
    _ensureNotDisposed();
    if (!_isSupported) return;
    try {
      await _channel.invokeMethod<void>('refreshWidgets');
    } on MissingPluginException {
      // No-op on test runners and non-Android embeddings.
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'widgetLaunch') return null;
    final arguments = call.arguments;
    if (arguments is! Map) return false;
    try {
      _acceptAction(Map<Object?, Object?>.from(arguments));
      return true;
    } on FormatException {
      return false;
    }
  }

  void _acceptAction(Map<Object?, Object?> value) {
    final action = WidgetLaunchAction.fromMap(value);
    if (!_seenEventIds.add(action.eventId)) return;
    if (_seenEventIds.length > 64) {
      _seenEventIds.remove(_seenEventIds.first);
    }
    _pendingActions.add(action);
    _launchController.add(action);
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('AndroidWidgetBridge has been disposed.');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _launchController.close();
  }
}

String _requiredString(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Widget payload is missing $field.');
  }
  return value;
}
