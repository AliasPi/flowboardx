import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/diagnostics.dart';

abstract interface class SmartBoardCompatibility {
  Future<SmartBoardCompatibilityStatus> getStatus();

  Future<bool> openSettings();

  Future<bool> acknowledgeSetup();
}

/// Supported bridge for SMART iQ compatibility.
///
/// SMART exposes no public API for changing its privileged per-app annotation
/// setting. The bridge therefore applies safe Android hardening natively and
/// guides the user through the documented device setting.
final class SmartBoardCompatibilityBridge implements SmartBoardCompatibility {
  SmartBoardCompatibilityBridge({MethodChannel? channel, bool? isSupported})
    : _channel = channel ?? const MethodChannel(channelName),
      _isSupported =
          isSupported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (_isSupported) _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'de.flowboardx/smart_board_compatibility';
  static final SmartBoardCompatibilityBridge instance =
      SmartBoardCompatibilityBridge();

  final MethodChannel _channel;
  final bool _isSupported;

  @override
  Future<SmartBoardCompatibilityStatus> getStatus() async {
    if (!_isSupported) return SmartBoardCompatibilityStatus.unsupported;
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
        'getStatus',
      );
      return SmartBoardCompatibilityStatus.tryParse(value) ??
          SmartBoardCompatibilityStatus.unsupported;
    } on MissingPluginException {
      return SmartBoardCompatibilityStatus.unsupported;
    } on PlatformException catch (error, stackTrace) {
      DiagnosticLogService.instance.recordException(
        event: 'smart_board.status_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return SmartBoardCompatibilityStatus.unsupported;
    }
  }

  @override
  Future<bool> openSettings() => _invokeBoolean('openSettings');

  @override
  Future<bool> acknowledgeSetup() => _invokeBoolean('acknowledgeSetup');

  Future<bool> _invokeBoolean(String method) async {
    if (!_isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.recordException(
        event: 'smart_board.action_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{'action': method},
      );
      return false;
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'stylusObserved') return;
    final arguments = call.arguments;
    final tool = arguments is Map ? arguments['tool'] : null;
    DiagnosticLogService.instance.info(
      'input.smart_board_stylus_received',
      fields: <String, Object?>{'tool': tool == 'eraser' ? 'eraser' : 'stylus'},
    );
  }

  @visibleForTesting
  void close() {
    if (_isSupported) _channel.setMethodCallHandler(null);
  }
}

@immutable
final class SmartBoardCompatibilityStatus {
  const SmartBoardCompatibilityStatus({
    required this.isSmartBoard,
    required this.setupAcknowledged,
    required this.manufacturer,
    required this.model,
    required this.androidSdk,
  });

  static const unsupported = SmartBoardCompatibilityStatus(
    isSmartBoard: false,
    setupAcknowledged: true,
    manufacturer: '',
    model: '',
    androidSdk: 0,
  );

  final bool isSmartBoard;
  final bool setupAcknowledged;
  final String manufacturer;
  final String model;
  final int androidSdk;

  String get deviceLabel {
    final parts = <String>[
      if (manufacturer.trim().isNotEmpty) manufacturer.trim(),
      if (model.trim().isNotEmpty) model.trim(),
    ];
    return parts.join(' · ');
  }

  static SmartBoardCompatibilityStatus? tryParse(Map<String, Object?>? value) {
    if (value == null ||
        value['isSmartBoard'] is! bool ||
        value['setupAcknowledged'] is! bool) {
      return null;
    }
    final rawSdk = value['androidSdk'];
    return SmartBoardCompatibilityStatus(
      isSmartBoard: value['isSmartBoard']! as bool,
      setupAcknowledged: value['setupAcknowledged']! as bool,
      manufacturer: _boundedLabel(value['manufacturer']),
      model: _boundedLabel(value['model']),
      androidSdk: rawSdk is num ? rawSdk.toInt().clamp(0, 1000) : 0,
    );
  }

  static String _boundedLabel(Object? value) {
    if (value is! String) return '';
    final safe = value.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '').trim();
    return safe.length <= 80 ? safe : safe.substring(0, 80);
  }
}
