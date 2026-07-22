import 'dart:typed_data';

/// A stable, UI-independent snapshot of a document at export time.
///
/// Each page owns a rasterizer callback instead of referencing the live
/// whiteboard model. This keeps exporting independent from the canvas engine
/// and allows pages to be rendered one at a time, which bounds peak memory for
/// large documents.
final class ExportDocumentSnapshot {
  ExportDocumentSnapshot({
    required this.title,
    required Iterable<ExportPageSnapshot> pages,
    this.author,
    DateTime? createdAt,
    DateTime? modifiedAt,
  }) : pages = List<ExportPageSnapshot>.unmodifiable(pages),
       createdAt = createdAt ?? DateTime.now(),
       modifiedAt = modifiedAt ?? DateTime.now() {
    if (this.pages.isEmpty) {
      throw ArgumentError.value(
        pages,
        'pages',
        'must contain at least one page',
      );
    }
  }

  final String title;
  final String? author;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final List<ExportPageSnapshot> pages;
}

typedef ExportPageRasterizer =
    Future<ExportRaster> Function(ExportRasterRequest request);

/// Immutable information needed to export one page.
final class ExportPageSnapshot {
  ExportPageSnapshot({
    required this.widthPoints,
    required this.heightPoints,
    required this.rasterize,
    double? logicalWidth,
    double? logicalHeight,
    this.label,
  }) : logicalWidth = logicalWidth ?? widthPoints,
       logicalHeight = logicalHeight ?? heightPoints {
    if (!widthPoints.isFinite || widthPoints <= 0 || widthPoints > 14400) {
      throw ArgumentError.value(
        widthPoints,
        'widthPoints',
        'must be in (0, 14400]',
      );
    }
    if (!heightPoints.isFinite || heightPoints <= 0 || heightPoints > 14400) {
      throw ArgumentError.value(
        heightPoints,
        'heightPoints',
        'must be in (0, 14400]',
      );
    }
    if (!this.logicalWidth.isFinite || this.logicalWidth <= 0) {
      throw ArgumentError.value(
        this.logicalWidth,
        'logicalWidth',
        'must be positive',
      );
    }
    if (!this.logicalHeight.isFinite || this.logicalHeight <= 0) {
      throw ArgumentError.value(
        this.logicalHeight,
        'logicalHeight',
        'must be positive',
      );
    }
  }

  /// PDF width in points (72 points are one inch).
  final double widthPoints;

  /// PDF height in points (72 points are one inch).
  final double heightPoints;

  /// Coordinate-space size understood by the page render callback.
  final double logicalWidth;
  final double logicalHeight;
  final String? label;
  final ExportPageRasterizer rasterize;
}

/// Quality and memory limits supplied to a page rasterizer.
final class ExportRasterRequest {
  const ExportRasterRequest({
    required this.logicalWidth,
    required this.logicalHeight,
    required this.pixelRatio,
    required this.maxPixels,
  });

  final double logicalWidth;
  final double logicalHeight;
  final double pixelRatio;
  final int maxPixels;
}

/// Tightly packed, straight-alpha RGBA pixels.
final class ExportRaster {
  ExportRaster({
    required this.width,
    required this.height,
    required Uint8List rgbaBytes,
  }) : rgbaBytes = Uint8List.fromList(rgbaBytes) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Raster dimensions must be positive.');
    }
    final expectedLength = width * height * 4;
    if (expectedLength != this.rgbaBytes.length) {
      throw ArgumentError.value(
        this.rgbaBytes.length,
        'rgbaBytes.length',
        'expected $expectedLength bytes for a ${width}x$height RGBA raster',
      );
    }
  }

  final int width;
  final int height;
  final Uint8List rgbaBytes;
}
