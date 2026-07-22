import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens Android's system sharesheet for an already exported PDF.
///
/// Quick Share is supplied by Android as one of the sharesheet targets. The
/// native service publishes only a private copy through a read-only
/// `FileProvider`; the original document and all other app files remain hidden.
final class AndroidPdfQuickShare {
  AndroidPdfQuickShare({MethodChannel? channel, bool? isSupported})
    : _channel = channel ?? const MethodChannel(channelName),
      _isSupported =
          isSupported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const channelName = 'de.flowboardx/pdf_quick_share';
  static final instance = AndroidPdfQuickShare();

  final MethodChannel _channel;
  final bool _isSupported;

  bool get isSupported => _isSupported;

  /// Copies [source] to the native sharing cache and opens the sharesheet.
  ///
  /// Completion means that the chooser was opened; Android does not disclose
  /// whether the recipient ultimately accepted or cancelled the share.
  Future<void> share(
    File source, {
    required String suggestedName,
    String chooserTitle = 'PDF teilen',
  }) async {
    if (!_isSupported) {
      throw UnsupportedError(
        'Die Android-Systemfreigabe ist auf dieser Plattform nicht verfügbar.',
      );
    }
    if (!await source.exists() || await source.length() < 5) {
      throw FileSystemException(
        'Die Exportdatei fehlt oder ist leer.',
        source.path,
      );
    }
    final signature = await source
        .openRead(0, 5)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    if (!listEquals(signature, const <int>[0x25, 0x50, 0x44, 0x46, 0x2D])) {
      throw const FormatException(
        'Die Exportdatei ist keine gültige PDF-Datei.',
      );
    }

    try {
      final opened = await _channel.invokeMethod<bool>('sharePdf', {
        'sourcePath': source.absolute.path,
        'suggestedName': _safePdfName(suggestedName),
        'chooserTitle': _safeChooserTitle(chooserTitle),
      });
      if (opened != true) {
        throw const AndroidPdfQuickShareException(
          'share_not_opened',
          'Die Android-Freigabe wurde nicht geöffnet.',
        );
      }
    } on MissingPluginException {
      throw UnsupportedError(
        'Die native Android-Systemfreigabe ist nicht registriert.',
      );
    } on PlatformException catch (error) {
      throw AndroidPdfQuickShareException(
        error.code,
        error.message ?? 'Die Android-Freigabe ist fehlgeschlagen.',
      );
    }
  }

  static String _safePdfName(String value) {
    var result = value.replaceAll(RegExp(r'[\\/\x00-\x1F\x7F]'), '_').trim();
    if (result.isEmpty) result = 'Flowboard.pdf';
    if (!result.toLowerCase().endsWith('.pdf')) result = '$result.pdf';
    return result.length <= 120 ? result : '${result.substring(0, 116)}.pdf';
  }

  static String _safeChooserTitle(String value) {
    final result = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    if (result.isEmpty) return 'PDF teilen';
    return result.length <= 80 ? result : result.substring(0, 80);
  }
}

@immutable
final class AndroidPdfQuickShareException implements Exception {
  const AndroidPdfQuickShareException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}
