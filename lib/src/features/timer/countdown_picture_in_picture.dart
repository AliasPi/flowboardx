import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android Picture-in-Picture state for the running countdown.
///
/// The native activity owns the transition because Android, rather than
/// Flutter, knows whether the user is actually leaving for Home or another
/// app. Flutter only publishes whether a running timer (or an unacknowledged
/// alarm) currently makes that transition useful.
final class AndroidCountdownPictureInPicture extends ChangeNotifier {
  AndroidCountdownPictureInPicture({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel(channelName),
      _isAndroid =
          isAndroid ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (_isAndroid) _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const String channelName =
      'de.flowboardx/countdown_picture_in_picture';

  final MethodChannel _channel;
  final bool _isAndroid;

  bool _isSupported = false;
  bool _isInPictureInPictureMode = false;
  bool? _lastRequestedTimerActive;
  bool _disposed = false;
  int _requestGeneration = 0;

  bool get isSupported => _isSupported;
  bool get isInPictureInPictureMode => _isInPictureInPictureMode;

  /// Refreshes native capability and mode state after an activity transition.
  Future<void> refresh() async {
    if (!_isAndroid || _disposed) return;
    final generation = ++_requestGeneration;
    try {
      final state = await _channel.invokeMapMethod<String, Object?>('getState');
      if (_disposed || generation != _requestGeneration) return;
      _applyState(state);
    } on MissingPluginException {
      // The feature is optional on non-Android hosts and older app embeddings.
    } on PlatformException catch (error, stackTrace) {
      _report(error, stackTrace, 'while reading Android PiP state');
    }
  }

  /// Enables automatic PiP only while the countdown must remain visible.
  Future<void> setTimerActive(bool active) async {
    if (!_isAndroid || _disposed) return;
    if (_lastRequestedTimerActive == active) return;
    _lastRequestedTimerActive = active;
    final generation = ++_requestGeneration;
    try {
      final state = await _channel.invokeMapMethod<String, Object?>(
        'setTimerActive',
        <String, Object?>{'active': active},
      );
      if (_disposed || generation != _requestGeneration) return;
      _applyState(state);
    } on MissingPluginException {
      // A missing channel degrades to the normal in-app presentation.
      _lastRequestedTimerActive = null;
    } on PlatformException catch (error, stackTrace) {
      _lastRequestedTimerActive = null;
      _report(error, stackTrace, 'while synchronizing Android PiP state');
    }
  }

  /// Explicitly minimizes the active timer when the user leaves via Back.
  ///
  /// Home and app switching use Android's automatic transition instead. A
  /// `false` result means PiP is unavailable, so callers can keep the large
  /// in-app display open rather than silently destroying the countdown.
  Future<bool> enterNow() async {
    if (!_isAndroid || _disposed) return false;
    try {
      return await _channel.invokeMethod<bool>('enterNow') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error, stackTrace) {
      _report(error, stackTrace, 'while entering Android PiP');
      return false;
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (_disposed || call.method != 'pictureInPictureChanged') return;
    final arguments = call.arguments;
    final next = arguments is bool
        ? arguments
        : arguments is Map && arguments['inPictureInPicture'] == true;
    _setPictureInPictureMode(next);
  }

  void _applyState(Map<String, Object?>? state) {
    if (state == null) return;
    _isSupported = state['supported'] == true;
    _setPictureInPictureMode(state['inPictureInPicture'] == true);
  }

  void _setPictureInPictureMode(bool value) {
    if (_isInPictureInPictureMode == value || _disposed) return;
    _isInPictureInPictureMode = value;
    notifyListeners();
  }

  static void _report(Object error, StackTrace stackTrace, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'FlowboardX countdown picture-in-picture',
        context: ErrorDescription(context),
      ),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _requestGeneration++;
    if (_isAndroid) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
