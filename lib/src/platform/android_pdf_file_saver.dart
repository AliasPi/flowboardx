import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Streams an already generated PDF through Android's Storage Access Framework.
///
/// Keeping generation and destination selection separate means even a 100-page
/// document never has to be materialized as one in-memory byte array.
final class AndroidPdfFileSaver {
  AndroidPdfFileSaver({MethodChannel? channel, bool? isSupported})
    : _channel = channel ?? const MethodChannel(channelName),
      _isSupported =
          isSupported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const channelName = 'de.flowboardx/pdf_file_saver';
  static final instance = AndroidPdfFileSaver();

  final MethodChannel _channel;
  final bool _isSupported;

  bool get isSupported => _isSupported;

  /// Returns the selected content URI, or `null` when the user cancels.
  Future<Uri?> save(File source, {required String suggestedName}) async {
    if (!_isSupported) {
      throw UnsupportedError('Android SAF is not available on this platform.');
    }
    if (!await source.exists() || await source.length() == 0) {
      throw FileSystemException(
        'Die Exportdatei fehlt oder ist leer.',
        source.path,
      );
    }
    final result = await _channel.invokeMethod<String>('savePdf', {
      'sourcePath': source.absolute.path,
      'suggestedName': _safePdfName(suggestedName),
    });
    return result == null ? null : Uri.parse(result);
  }

  static String _safePdfName(String value) {
    var result = value.replaceAll(RegExp(r'[\\/\x00-\x1F\x7F]'), '_').trim();
    if (result.isEmpty) result = 'Flowboard.pdf';
    if (!result.toLowerCase().endsWith('.pdf')) result = '$result.pdf';
    return result.length <= 120 ? result : '${result.substring(0, 116)}.pdf';
  }
}
