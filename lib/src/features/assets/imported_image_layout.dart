import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'encoded_image_file_probe.dart';

enum ImportedImageValidationFailure {
  unsupportedOrCorrupt,
  axisTooLarge,
  pixelCountTooLarge,
}

/// A user-facing, deterministic rejection raised before an image is persisted
/// or handed to a platform decoder.
final class ImportedImageValidationException implements Exception {
  const ImportedImageValidationException(this.failure, this.message);

  final ImportedImageValidationFailure failure;
  final String message;

  @override
  String toString() => message;
}

/// Reads encoded metadata/descriptor information and derives the initial board
/// size without materialising a full-resolution pixel frame.
///
/// Using [ui.ImageDescriptor] avoids decoding the full-resolution bitmap during
/// import. Large photos therefore do not block the UI isolate or temporarily
/// consume the memory of an unscaled frame merely to obtain their dimensions.
final class ImportedImageLayout {
  const ImportedImageLayout._();

  static const Size defaultBounds = Size(640, 420);

  /// Hard safety limits for encoded images. A 32-MiPixel RGBA frame is already
  /// 128 MiB before codec working memory and transient copies, while 8K UHD
  /// still fits. The independent axis limit rejects pathological panoramas
  /// that can stress Android/native codecs despite a modest total pixel count.
  static const int maximumAxisPixels = 16384;
  static const int maximumPixelCount = 32 * 1024 * 1024;

  /// Upper decode tier for one visible board image.
  ///
  /// A 4096 x 4096 RGBA cache entry occupies about 64 MiB before GPU copies.
  /// Zooming through several tiers, or showing two photos, can then evict ink
  /// pictures and trigger GC/raster churn on classroom hardware. 3072 still
  /// covers a 4K board with high visual fidelity while bounding a square frame
  /// to about 36 MiB. The encoded source remains untouched for export.
  static const int maximumBoardDecodeAxis = 3072;

  /// Fits [intrinsicSize] into the standard insertion footprint while keeping
  /// its exact aspect ratio. Invalid or unsupported images retain the legacy
  /// footprint so import rollback and older platform codecs remain defensive.
  static Size boardSizeFor(Size? intrinsicSize, {Size bounds = defaultBounds}) {
    if (!_isUsable(intrinsicSize) || !_isUsable(bounds)) return bounds;
    final source = intrinsicSize!;
    final scale = math.min(
      bounds.width / source.width,
      bounds.height / source.height,
    );
    if (!scale.isFinite || scale <= 0) return bounds;
    return Size(source.width * scale, source.height * scale);
  }

  /// Wraps an image provider in a bounded, aspect-preserving decode request.
  ///
  /// Flutter's default cache resize policy treats width and height as exact
  /// dimensions. Quantising them independently (for example 1024 x 512 for a
  /// 3:2 photo) would therefore deform the decoded bitmap to 2:1 before it is
  /// painted. [ResizeImagePolicy.fit] interprets the same values as maximum
  /// bounds and lets the codec retain the encoded image ratio.
  static ResizeImage aspectPreservingProvider(
    ImageProvider provider, {
    required Size physicalSize,
  }) {
    final width = _decodeTier(_finitePixels(physicalSize.width));
    final height = _decodeTier(_finitePixels(physicalSize.height));
    return ResizeImage(
      provider,
      width: width,
      height: height,
      policy: ResizeImagePolicy.fit,
    );
  }

  static Future<Size> dimensionsFromBytes(Uint8List bytes) async {
    if (bytes.isEmpty) throw _unsupportedImage();
    final headerSize = dimensionsFromEncodedHeader(bytes);
    if (_isUsable(headerSize)) {
      final validatedHeaderSize = validateDimensions(headerSize!);
      if (kIsWeb) return validatedHeaderSize;
    }

    // A full frame decode just to obtain dimensions can allocate hundreds of
    // megabytes for a large phone photo in a browser. Common browser formats
    // are handled from their encoded header above; an unknown Web format is
    // rejected explicitly instead of risking an OOM or using guessed bounds.
    if (kIsWeb) throw _unsupportedImage();
    final descriptorSize = await _dimensions(
      () => ui.ImmutableBuffer.fromUint8List(bytes),
    );
    if (descriptorSize == null) throw _unsupportedImage();
    return validateDimensions(descriptorSize);
  }

  static Future<Size> dimensionsFromFile(String path) async {
    final headerBytes = await readEncodedImageHeader(path, _maximumHeaderScan);
    if (headerBytes != null) {
      final headerSize = dimensionsFromEncodedHeader(headerBytes);
      if (_isUsable(headerSize)) {
        final validatedHeaderSize = validateDimensions(headerSize!);
        if (kIsWeb) return validatedHeaderSize;
      }
    }
    if (kIsWeb) throw _unsupportedImage();
    final descriptorSize = await _dimensions(
      () => ui.ImmutableBuffer.fromFilePath(path),
    );
    if (descriptorSize == null) throw _unsupportedImage();
    return validateDimensions(descriptorSize);
  }

  /// Applies the same limit to header metadata and native descriptors.
  @visibleForTesting
  static Size validateDimensions(Size size) {
    if (!_isUsable(size)) throw _unsupportedImage();
    final width = size.width.round();
    final height = size.height.round();
    if (width > maximumAxisPixels || height > maximumAxisPixels) {
      throw ImportedImageValidationException(
        ImportedImageValidationFailure.axisTooLarge,
        'Das Bild ist mit $width × $height px zu groß. Pro Seite sind '
        'höchstens $maximumAxisPixels px zulässig.',
      );
    }
    if (width * height > maximumPixelCount) {
      throw ImportedImageValidationException(
        ImportedImageValidationFailure.pixelCountTooLarge,
        'Das Bild ist mit $width × $height px zu groß. Zulässig sind '
        'höchstens ${maximumPixelCount ~/ (1024 * 1024)} Megapixel.',
      );
    }
    return Size(width.toDouble(), height.toDouble());
  }

  static Future<Size?> _dimensions(
    Future<ui.ImmutableBuffer> Function() createBuffer,
  ) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await createBuffer();
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final result = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      return _isUsable(result) ? result : null;
    } catch (_) {
      // Rendering already has a broken-image fallback. Keeping this probe
      // best-effort makes import resilient when a platform codec lacks a
      // format that another target platform can nevertheless display.
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// Reads dimensions without decoding pixels.
  ///
  /// PNG, JPEG (including EXIF orientation), GIF, WebP, BMP, ICO and the
  /// `ispe` metadata used by AVIF/HEIF are supported. Malformed and truncated
  /// input is rejected defensively.
  @visibleForTesting
  static Size? dimensionsFromEncodedHeader(Uint8List bytes) {
    try {
      return _pngSize(bytes) ??
          _jpegSize(bytes) ??
          _gifSize(bytes) ??
          _webpSize(bytes) ??
          _bmpSize(bytes) ??
          _icoSize(bytes) ??
          _ispeSize(bytes);
    } catch (_) {
      return null;
    }
  }

  static bool _isUsable(Size? size) =>
      size != null &&
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;
}

ImportedImageValidationException _unsupportedImage() =>
    const ImportedImageValidationException(
      ImportedImageValidationFailure.unsupportedOrCorrupt,
      'Das Bildformat ist beschädigt oder kann nicht sicher geprüft werden. '
      'Unterstützt werden PNG, JPEG, GIF, WebP, BMP, ICO und HEIF/AVIF.',
    );

int _finitePixels(double value) => value.isFinite ? value.round() : 512;

int _decodeTier(int requested) {
  if (requested <= 0) return 128;
  for (final tier in const [
    128,
    256,
    512,
    1024,
    2048,
    ImportedImageLayout.maximumBoardDecodeAxis,
  ]) {
    if (requested <= tier) return tier;
  }
  return ImportedImageLayout.maximumBoardDecodeAxis;
}

const int _maximumHeaderScan = 2 * 1024 * 1024;

Size? _encodedSize(int width, int height) {
  if (width <= 0 || height <= 0) return null;
  return Size(width.toDouble(), height.toDouble());
}

bool _matches(Uint8List bytes, int offset, List<int> signature) {
  if (offset < 0 || offset + signature.length > bytes.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}

int _uint16(Uint8List bytes, int offset, Endian endian) =>
    ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, endian);

int _uint24Little(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

int _uint32(Uint8List bytes, int offset, Endian endian) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, endian);

int _int32(Uint8List bytes, int offset, Endian endian) =>
    ByteData.sublistView(bytes, offset, offset + 4).getInt32(0, endian);

Size? _pngSize(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 24 || !_matches(bytes, 0, signature)) return null;
  return _encodedSize(
    _uint32(bytes, 16, Endian.big),
    _uint32(bytes, 20, Endian.big),
  );
}

Size? _gifSize(Uint8List bytes) {
  if (bytes.length < 10 ||
      !(_matches(bytes, 0, const [71, 73, 70, 56, 55, 97]) ||
          _matches(bytes, 0, const [71, 73, 70, 56, 57, 97]))) {
    return null;
  }
  return _encodedSize(
    _uint16(bytes, 6, Endian.little),
    _uint16(bytes, 8, Endian.little),
  );
}

Size? _bmpSize(Uint8List bytes) {
  if (bytes.length < 26 || !_matches(bytes, 0, const [66, 77])) return null;
  final dibSize = _uint32(bytes, 14, Endian.little);
  if (dibSize == 12) {
    return _encodedSize(
      _uint16(bytes, 18, Endian.little),
      _uint16(bytes, 20, Endian.little),
    );
  }
  if (dibSize < 40) return null;
  return _encodedSize(
    _int32(bytes, 18, Endian.little).abs(),
    _int32(bytes, 22, Endian.little).abs(),
  );
}

Size? _icoSize(Uint8List bytes) {
  if (bytes.length < 22 ||
      !_matches(bytes, 0, const [0, 0, 1, 0]) ||
      _uint16(bytes, 4, Endian.little) == 0) {
    return null;
  }
  final width = bytes[6] == 0 ? 256 : bytes[6];
  final height = bytes[7] == 0 ? 256 : bytes[7];
  return _encodedSize(width, height);
}

bool _isJpegStartOfFrame(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;

Size? _jpegSize(Uint8List bytes) {
  if (bytes.length < 4 || !_matches(bytes, 0, const [0xFF, 0xD8])) {
    return null;
  }
  Size? size;
  var orientation = 1;
  var offset = 2;
  final scanEnd = math.min(bytes.length, _maximumHeaderScan);
  while (offset + 1 < scanEnd) {
    while (offset < scanEnd && bytes[offset] != 0xFF) {
      offset++;
    }
    while (offset < scanEnd && bytes[offset] == 0xFF) {
      offset++;
    }
    if (offset >= scanEnd) break;
    final marker = bytes[offset++];
    if (marker == 0xD9 || marker == 0xDA) break;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    if (offset + 2 > bytes.length) return null;
    final segmentLength = _uint16(bytes, offset, Endian.big);
    if (segmentLength < 2 || offset + segmentLength > bytes.length) {
      return null;
    }
    if (_isJpegStartOfFrame(marker) && segmentLength >= 7) {
      size = _encodedSize(
        _uint16(bytes, offset + 5, Endian.big),
        _uint16(bytes, offset + 3, Endian.big),
      );
    } else if (marker == 0xE1) {
      orientation = _jpegExifOrientation(bytes, offset + 2, segmentLength - 2);
    }
    offset += segmentLength;
  }
  if (size == null) return null;
  return orientation >= 5 && orientation <= 8
      ? Size(size.height, size.width)
      : size;
}

int _jpegExifOrientation(Uint8List bytes, int start, int length) {
  const exif = [69, 120, 105, 102, 0, 0];
  if (length < 14 || !_matches(bytes, start, exif)) return 1;
  final tiff = start + exif.length;
  final little = _matches(bytes, tiff, const [73, 73]);
  final big = _matches(bytes, tiff, const [77, 77]);
  if (!little && !big) return 1;
  final endian = little ? Endian.little : Endian.big;
  final end = start + length;
  if (tiff + 8 > end || _uint16(bytes, tiff + 2, endian) != 42) return 1;
  final ifd = tiff + _uint32(bytes, tiff + 4, endian);
  if (ifd < tiff || ifd + 2 > end) return 1;
  final entryCount = _uint16(bytes, ifd, endian);
  for (var index = 0; index < entryCount; index++) {
    final entry = ifd + 2 + index * 12;
    if (entry + 12 > end) return 1;
    if (_uint16(bytes, entry, endian) == 0x0112 &&
        _uint16(bytes, entry + 2, endian) == 3 &&
        _uint32(bytes, entry + 4, endian) >= 1) {
      final value = _uint16(bytes, entry + 8, endian);
      return value >= 1 && value <= 8 ? value : 1;
    }
  }
  return 1;
}

Size? _webpSize(Uint8List bytes) {
  if (bytes.length < 20 ||
      !_matches(bytes, 0, const [82, 73, 70, 70]) ||
      !_matches(bytes, 8, const [87, 69, 66, 80])) {
    return null;
  }
  var offset = 12;
  final scanEnd = math.min(bytes.length, _maximumHeaderScan);
  while (offset + 8 <= scanEnd) {
    final payloadSize = _uint32(bytes, offset + 4, Endian.little);
    final payload = offset + 8;
    if (payloadSize > bytes.length - payload) return null;
    if (_matches(bytes, offset, const [86, 80, 56, 88]) && payloadSize >= 10) {
      return _encodedSize(
        _uint24Little(bytes, payload + 4) + 1,
        _uint24Little(bytes, payload + 7) + 1,
      );
    }
    if (_matches(bytes, offset, const [86, 80, 56, 32]) &&
        payloadSize >= 10 &&
        _matches(bytes, payload + 3, const [0x9D, 0x01, 0x2A])) {
      return _encodedSize(
        _uint16(bytes, payload + 6, Endian.little) & 0x3FFF,
        _uint16(bytes, payload + 8, Endian.little) & 0x3FFF,
      );
    }
    if (_matches(bytes, offset, const [86, 80, 56, 76]) &&
        payloadSize >= 5 &&
        bytes[payload] == 0x2F) {
      final b1 = bytes[payload + 1];
      final b2 = bytes[payload + 2];
      final b3 = bytes[payload + 3];
      final b4 = bytes[payload + 4];
      return _encodedSize(
        1 + b1 + ((b2 & 0x3F) << 8),
        1 + (b2 >> 6) + (b3 << 2) + ((b4 & 0x0F) << 10),
      );
    }
    offset = payload + payloadSize + (payloadSize.isOdd ? 1 : 0);
  }
  return null;
}

Size? _ispeSize(Uint8List bytes) {
  if (bytes.length < 20 || !_matches(bytes, 4, const [102, 116, 121, 112])) {
    return null;
  }
  Size? largest;
  var largestArea = 0;
  final scanEnd = math.min(bytes.length, _maximumHeaderScan);
  for (var offset = 4; offset + 16 <= scanEnd; offset++) {
    if (!_matches(bytes, offset, const [105, 115, 112, 101])) continue;
    final boxSize = _uint32(bytes, offset - 4, Endian.big);
    if (boxSize < 20 || offset - 4 + boxSize > bytes.length) continue;
    final candidate = _encodedSize(
      _uint32(bytes, offset + 8, Endian.big),
      _uint32(bytes, offset + 12, Endian.big),
    );
    if (candidate == null) continue;
    final area = candidate.width.toInt() * candidate.height.toInt();
    if (area > largestArea) {
      largest = candidate;
      largestArea = area;
    }
  }
  return largest;
}
