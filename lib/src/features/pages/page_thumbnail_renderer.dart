import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/geometry.dart';
import '../../domain/model/ink.dart';
import '../../domain/model/scene_order.dart';
import '../assets/imported_image_layout.dart';
import '../board/presentation/board_object_layer.dart';
import '../board/presentation/ink_painter.dart';
import '../editor/text_object_layout.dart';

typedef PdfThumbnailRasterizer =
    Future<PdfThumbnailRaster> Function(
      String path,
      int sourcePageIndex,
      int maxDimension,
    );

/// Small, renderer-independent BGRA image used by the PDF thumbnail cache.
final class PdfThumbnailRaster {
  PdfThumbnailRaster({
    required this.width,
    required this.height,
    required Uint8List bgraBytes,
  }) : _bgraBytes = Uint8List.fromList(bgraBytes) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('PDF thumbnail dimensions must be positive.');
    }
    if (_bgraBytes.length != width * height * 4) {
      throw ArgumentError.value(
        _bgraBytes.length,
        'bgraBytes.length',
        'expected ${width * height * 4} bytes',
      );
    }
  }

  final int width;
  final int height;
  final Uint8List _bgraBytes;
}

final class PageThumbnailRenderCancelled implements Exception {
  const PageThumbnailRenderCancelled();
}

class PageThumbnailRenderer {
  PageThumbnailRenderer({
    this.width = 192,
    this.height = 108,
    int pdfCacheCapacity = 24,
    int pdfRenderSize = 384,
    int imageCacheCapacity = 32,
    PdfThumbnailRasterizer pdfRasterizer = _rasterizePdfThumbnail,
  }) : assert(width > 0),
       assert(height > 0),
       _pdfThumbnails = _PdfThumbnailCache(
         capacity: pdfCacheCapacity,
         renderSize: pdfRenderSize,
         rasterizer: pdfRasterizer,
       ),
       _imageThumbnails = _ImageThumbnailCache(capacity: imageCacheCapacity);

  final int width;
  final int height;
  final _PdfThumbnailCache _pdfThumbnails;
  final _ImageThumbnailCache _imageThumbnails;
  static const int maximumThumbnailStrokePoints = 512;
  static const int maximumThumbnailTotalStrokePoints = 32768;

  /// Releases cached PDF pixels. In-flight renders remain safe and become
  /// collectible as soon as their current thumbnail render has completed.
  void dispose() {
    _pdfThumbnails.clear();
    _imageThumbnails.clear();
  }

  Future<ui.Image> render(
    BoardPage page,
    BoardAssetResolver assets, {
    bool Function()? shouldCancel,
  }) async {
    final decoded = <String, ui.Image>{};
    ui.PictureRecorder? recorder;
    ui.Picture? picture;
    var recording = false;
    try {
      _throwIfCancelled(shouldCancel);
      for (final object in page.objects) {
        _throwIfCancelled(shouldCancel);
        switch (object) {
          case final ImageObject image:
            try {
              final decodedImage = await _imageThumbnails.load(
                assets,
                image.assetId,
              );
              if (shouldCancel?.call() ?? false) {
                decodedImage?.dispose();
                throw const PageThumbnailRenderCancelled();
              }
              if (decodedImage == null) continue;
              decoded[image.id] = decodedImage;
            } on PageThumbnailRenderCancelled {
              rethrow;
            } on Object {
              // A corrupt optional asset does not invalidate the thumbnail.
            }
          case final PdfObject pdf:
            try {
              final path = assets.localPath(pdf.assetId);
              if (path == null || path.isEmpty) continue;
              final image = await _pdfThumbnails.load(
                path,
                pdf.activeSourcePageIndex,
              );
              if (shouldCancel?.call() ?? false) {
                image.dispose();
                throw const PageThumbnailRenderCancelled();
              }
              decoded[pdf.id] = image;
            } on PageThumbnailRenderCancelled {
              rethrow;
            } on Object {
              // The canvas below draws an explicit unavailable-PDF fallback.
            }
          default:
            break;
        }
      }

      _throwIfCancelled(shouldCancel);
      recorder = ui.PictureRecorder();
      recording = true;
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xFFF8F7F2),
      );
      const world = Rect.fromLTWH(-1920, -1080, 5760, 3240);
      final scale = width / world.width;
      canvas
        ..scale(scale)
        ..translate(-world.left, -world.top);
      final grid = Paint()
        ..color = const Color(0xFFD5D9D6)
        ..strokeWidth = 3 / scale;
      for (var x = world.left; x <= world.right; x += 1920) {
        canvas.drawLine(Offset(x, world.top), Offset(x, world.bottom), grid);
      }
      for (var y = world.top; y <= world.bottom; y += 1080) {
        canvas.drawLine(Offset(world.left, y), Offset(world.right, y), grid);
      }

      final annotationIndex = VisibleObjectInkLayerIndex(page.annotationLayers);
      var activeAnnotationStrokeCount = 0;
      for (final object in page.objects) {
        activeAnnotationStrokeCount +=
            annotationIndex.layerFor(object)?.strokes.length ?? 0;
      }
      final inkBudget = _ThumbnailInkBudget(
        strokeCount: page.strokes.length + activeAnnotationStrokeCount,
        totalPointBudget: maximumThumbnailTotalStrokePoints,
        maximumPointsPerStroke: maximumThumbnailStrokePoints,
      );
      _throwIfCancelled(shouldCancel);
      final scene = orderedBoardSceneItems(
        objects: page.objects,
        strokes: page.strokes,
      );
      _throwIfCancelled(shouldCancel);
      for (final item in scene) {
        _throwIfCancelled(shouldCancel);
        final stroke = item.stroke;
        if (stroke != null) {
          InkPainter.drawStroke(
            canvas,
            _thumbnailStroke(
              stroke,
              shouldCancel,
              maximumPoints: inkBudget.take(stroke.points.length),
            ),
          );
          continue;
        }
        final object = item.object!;
        _drawObject(canvas, object, decoded[object.id], scale);
        final layer = annotationIndex.layerFor(object);
        if (layer != null) {
          canvas.save();
          _applyObjectOrientation(canvas, object.transform);
          canvas.translate(object.transform.x, object.transform.y);
          final objectSize = Size(
            object.transform.width,
            object.transform.height,
          );
          for (final annotation in layer.strokes) {
            _throwIfCancelled(shouldCancel);
            InkPainter.drawObjectLocalStroke(
              canvas,
              _thumbnailStroke(
                annotation,
                shouldCancel,
                maximumPoints: inkBudget.take(annotation.points.length),
              ),
              objectSize,
            );
          }
          canvas.restore();
        }
      }
      picture = recorder.endRecording();
      recording = false;
      _throwIfCancelled(shouldCancel);
      final image = await picture.toImage(width, height);
      if (shouldCancel?.call() ?? false) {
        image.dispose();
        throw const PageThumbnailRenderCancelled();
      }
      return image;
    } finally {
      if (recording && recorder != null) {
        try {
          recorder.endRecording().dispose();
        } on Object {
          // Best-effort cleanup after a failed canvas operation.
        }
      }
      picture?.dispose();
      for (final entry in decoded.values) {
        entry.dispose();
      }
    }
  }

  static void _throwIfCancelled(bool Function()? shouldCancel) {
    if (shouldCancel?.call() ?? false) {
      throw const PageThumbnailRenderCancelled();
    }
  }

  static InkStroke _thumbnailStroke(
    InkStroke stroke,
    bool Function()? shouldCancel, {
    int maximumPoints = maximumThumbnailStrokePoints,
  }) {
    final points = stroke.points;
    if (points.isEmpty) return stroke;
    if (maximumPoints <= 0) {
      return stroke.copyWith(points: const <InkPoint>[]);
    }
    if (points.length <= maximumPoints) return stroke;
    if (maximumPoints == 1) {
      return stroke.copyWith(points: <InkPoint>[points.first]);
    }
    final sampled = stroke.type == InkToolType.straightLine
        ? <InkPoint>[points.first, points.last]
        : sampleStrokePoints(
            points,
            maximumPoints: maximumPoints,
            shouldCancel: shouldCancel,
          );
    return stroke.copyWith(points: sampled);
  }

  /// Computes the same bounded streaming allocation used by [render].
  ///
  /// Exposed for stress tests: page complexity may increase without allowing
  /// the 192x108 preview to consume an unbounded number of path commands.
  @visibleForTesting
  static List<int> allocateStrokePointBudgets(
    Iterable<int> pointCounts, {
    int totalPointBudget = maximumThumbnailTotalStrokePoints,
    int maximumPointsPerStroke = maximumThumbnailStrokePoints,
  }) {
    final counts = pointCounts.toList(growable: false);
    final budget = _ThumbnailInkBudget(
      strokeCount: counts.length,
      totalPointBudget: totalPointBudget,
      maximumPointsPerStroke: maximumPointsPerStroke,
    );
    return <int>[for (final count in counts) budget.take(math.max(0, count))];
  }

  /// Reduces persisted input to a thumbnail-sized command budget while
  /// retaining both endpoints and the strongest turn in each temporal bucket.
  ///
  /// A 192 px preview cannot display tens of thousands of distinct samples.
  /// Bounding every stroke also prevents one recovered/very long circle from
  /// monopolizing the UI isolate after the ink quiet period.
  @visibleForTesting
  static List<InkPoint> sampleStrokePoints(
    List<InkPoint> source, {
    int maximumPoints = maximumThumbnailStrokePoints,
    bool Function()? shouldCancel,
  }) {
    if (maximumPoints < 2) {
      throw ArgumentError.value(
        maximumPoints,
        'maximumPoints',
        'must be at least two',
      );
    }
    if (source.length <= maximumPoints) return source;
    if (maximumPoints == 2) return <InkPoint>[source.first, source.last];

    final result = <InkPoint>[source.first];
    final interiorCount = source.length - 2;
    final bucketCount = maximumPoints - 2;
    for (var bucket = 0; bucket < bucketCount; bucket++) {
      _throwIfCancelled(shouldCancel);
      final start = 1 + bucket * interiorCount ~/ bucketCount;
      final endExclusive = 1 + (bucket + 1) * interiorCount ~/ bucketCount;
      final chordStart = source[start - 1];
      final chordEnd = source[math.min(source.length - 1, endExclusive)];
      final chordX = chordEnd.x - chordStart.x;
      final chordY = chordEnd.y - chordStart.y;
      final chordLengthSquared = chordX * chordX + chordY * chordY;
      var selectedIndex = start;
      var greatestDeviation = -1.0;
      for (var index = start; index < endExclusive; index++) {
        if ((index & 255) == 0) _throwIfCancelled(shouldCancel);
        final point = source[index];
        final relativeX = point.x - chordStart.x;
        final relativeY = point.y - chordStart.y;
        final cross = relativeX * chordY - relativeY * chordX;
        final deviation = chordLengthSquared <= 1e-12
            ? relativeX * relativeX + relativeY * relativeY
            : cross * cross / chordLengthSquared;
        if (deviation > greatestDeviation) {
          greatestDeviation = deviation;
          selectedIndex = index;
        }
      }
      result.add(source[selectedIndex]);
    }
    result.add(source.last);
    return result;
  }

  void _drawObject(
    Canvas canvas,
    BoardObject object,
    ui.Image? image,
    double scale,
  ) {
    final t = object.transform;
    final rect = Rect.fromLTWH(t.x, t.y, t.width, t.height);
    canvas.save();
    _applyObjectOrientation(canvas, t);
    canvas.saveLayer(
      rect,
      Paint()..color = Colors.white.withValues(alpha: object.opacity),
    );
    switch (object) {
      case final ShapeObject shape:
        final path = switch (shape.shape) {
          ShapeKind.rectangle => Path()..addRect(rect),
          ShapeKind.circle || ShapeKind.ellipse => Path()..addOval(rect),
          ShapeKind.triangle =>
            Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.bottom)
              ..lineTo(rect.left, rect.bottom)
              ..close(),
        };
        canvas.drawPath(path, Paint()..color = Color(shape.fillArgb));
        canvas.drawPath(
          path,
          Paint()
            ..color = Color(shape.strokeArgb)
            ..style = PaintingStyle.stroke
            ..strokeWidth = shape.strokeWidth,
        );
      case final ImageObject _:
        if (image != null) {
          paintImage(
            canvas: canvas,
            rect: rect,
            image: image,
            fit: BoxFit.contain,
          );
        } else {
          canvas.drawRect(rect, Paint()..color = const Color(0xFFDCE1E0));
        }
      case PdfObject():
        canvas.drawRect(rect, Paint()..color = Colors.white);
        if (image != null) {
          paintImage(
            canvas: canvas,
            rect: rect,
            image: image,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          );
        } else {
          _drawUnavailablePdf(canvas, rect, scale);
        }
      case final TableObject table:
        canvas.drawRect(rect, Paint()..color = Colors.white);
        final paint = Paint()
          ..color = Color(table.gridColorArgb)
          ..strokeWidth = table.gridWidth;
        for (var column = 1; column < table.columns; column++) {
          final x = rect.left + rect.width * column / table.columns;
          canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), paint);
        }
        for (var row = 1; row < table.rows; row++) {
          final y = rect.top + rect.height * row / table.rows;
          canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
        }
      case final CoverObject cover:
        canvas.drawRect(rect, Paint()..color = Color(cover.colorArgb));
      case final TextObject textObject:
        _paintTextObject(canvas, rect, textObject);
    }
    canvas.restore();
    canvas.restore();
  }

  void _paintTextObject(Canvas canvas, Rect rect, TextObject value) {
    if (value.text.isEmpty || rect.isEmpty) return;
    final insets = TextObjectLayout.contentInsetsFor(value);
    final content = Rect.fromLTRB(
      rect.left + insets.left,
      rect.top + insets.top,
      rect.right - insets.right,
      rect.bottom - insets.bottom,
    );
    if (content.isEmpty) return;
    final painter = TextObjectLayout.createPainter(value)
      ..layout(maxWidth: content.width);
    final x = switch (value.alignment) {
      BoardTextAlign.left => content.left,
      BoardTextAlign.center => content.center.dx - painter.width / 2,
      BoardTextAlign.right => content.right - painter.width,
    };
    canvas.save();
    canvas.clipRect(rect);
    painter.paint(canvas, Offset(x, content.top));
    canvas.restore();
    painter.dispose();
  }

  void _applyObjectOrientation(Canvas canvas, ObjectTransform transform) {
    if (transform.rotationRadians.abs() < .0000001 &&
        !transform.flipX &&
        !transform.flipY) {
      return;
    }
    final center = Offset(
      transform.x + transform.width / 2,
      transform.y + transform.height / 2,
    );
    canvas
      ..translate(center.dx, center.dy)
      ..rotate(transform.rotationRadians)
      ..scale(transform.flipX ? -1 : 1, transform.flipY ? -1 : 1)
      ..translate(-center.dx, -center.dy);
  }

  void _drawUnavailablePdf(Canvas canvas, Rect rect, double scale) {
    final border = Paint()
      ..color = const Color(0xFFB8BEBC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / scale;
    canvas.drawRect(rect, border);
    canvas.drawLine(rect.topLeft, rect.bottomRight, border);
    canvas.drawLine(rect.topRight, rect.bottomLeft, border);

    final text = TextPainter(
      text: TextSpan(
        text: 'PDF',
        style: TextStyle(
          color: const Color(0xFF9D3C3C),
          fontSize: (math.min(rect.width, rect.height) * .16).clamp(24, 160),
          fontWeight: FontWeight.w700,
          backgroundColor: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);
    text.paint(canvas, rect.center - Offset(text.width / 2, text.height / 2));
    text.dispose();
  }
}

/// Fair, streaming point allocation for a complete page thumbnail.
///
/// Every remaining stroke gets an equal share of the remaining page budget.
/// Short strokes return their unused share to later strokes. This keeps dots
/// and short handwriting intact while bounding pathological pages containing
/// thousands of long circular gestures.
final class _ThumbnailInkBudget {
  _ThumbnailInkBudget({
    required int strokeCount,
    required int totalPointBudget,
    required this.maximumPointsPerStroke,
  }) : _remainingStrokes = math.max(0, strokeCount),
       _remainingPoints = math.max(0, totalPointBudget),
       assert(maximumPointsPerStroke > 0);

  final int maximumPointsPerStroke;
  int _remainingStrokes;
  int _remainingPoints;

  int take(int pointCount) {
    if (_remainingStrokes <= 0 || pointCount <= 0) {
      if (_remainingStrokes > 0) _remainingStrokes--;
      return 0;
    }
    final fairShare = _remainingPoints <= 0
        ? 0
        : (_remainingPoints / _remainingStrokes).ceil();
    final allocated = math.min(
      pointCount,
      math.min(maximumPointsPerStroke, fairShare),
    );
    _remainingStrokes--;
    _remainingPoints = math.max(0, _remainingPoints - allocated);
    return allocated;
  }
}

typedef _PdfThumbnailKey = ({String path, int sourcePageIndex});

typedef _ImageThumbnailKey = ({BoardAssetResolver assets, String assetId});

/// Retains one bounded decode per immutable document asset.
///
/// Adding ink invalidates the page preview but not the image bytes. Re-reading
/// and decoding every embedded photo after each quiet period previously moved
/// that unrelated work back onto the raster pipeline. The cache owns the
/// original image and hands each render a cheap clone that it may dispose.
final class _ImageThumbnailCache {
  _ImageThumbnailCache({required this.capacity}) : assert(capacity >= 0);

  final int capacity;
  final LinkedHashMap<_ImageThumbnailKey, _ImageThumbnailCacheEntry> _entries =
      LinkedHashMap<_ImageThumbnailKey, _ImageThumbnailCacheEntry>();

  Future<ui.Image?> load(BoardAssetResolver assets, String assetId) async {
    final key = (assets: assets, assetId: assetId);
    if (capacity == 0) {
      return _decodeImageThumbnail(assets, assetId);
    }

    var entry = _entries.remove(key);
    entry ??= _ImageThumbnailCacheEntry(_decodeImageThumbnail(assets, assetId));
    _entries[key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first)?.evict();
    }

    entry.acquire();
    try {
      final image = await entry.image;
      return image?.clone();
    } on Object {
      if (identical(_entries[key], entry)) {
        _entries.remove(key);
        entry.evict();
      }
      rethrow;
    } finally {
      entry.release();
    }
  }

  void clear() {
    final entries = _entries.values.toSet();
    _entries.clear();
    for (final entry in entries) {
      entry.evict();
    }
  }
}

/// Owns one cached image while allowing concurrent callers to clone it.
///
/// LRU eviction may happen while the decode is in flight. Deferring disposal
/// until every borrower has cloned the result prevents both use-after-dispose
/// failures and the previous "first N assets stay forever" cache behaviour.
final class _ImageThumbnailCacheEntry {
  _ImageThumbnailCacheEntry(this.image);

  final Future<ui.Image?> image;
  int _borrowers = 0;
  bool _evicted = false;
  bool _disposalScheduled = false;

  void acquire() => _borrowers++;

  void release() {
    assert(_borrowers > 0);
    _borrowers--;
    _scheduleDisposalIfReady();
  }

  void evict() {
    _evicted = true;
    _scheduleDisposalIfReady();
  }

  void _scheduleDisposalIfReady() {
    if (!_evicted || _borrowers != 0 || _disposalScheduled) return;
    _disposalScheduled = true;
    unawaited(
      image.then<void>(
        (value) => value?.dispose(),
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
}

Future<ui.Image?> _decodeImageThumbnail(
  BoardAssetResolver assets,
  String assetId,
) async {
  final bytes = await assets.readBytes(assetId);
  if (bytes == null || bytes.isEmpty) return null;
  final intrinsic = await ImportedImageLayout.dimensionsFromBytes(bytes);
  final longest = math.max(intrinsic.width, intrinsic.height);
  final factor = longest > 400 ? 400 / longest : 1.0;
  final targetWidth = math.max(1, (intrinsic.width * factor).round());
  final targetHeight = math.max(1, (intrinsic.height * factor).round());
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec?.dispose();
  }
}

final class _PdfThumbnailCache {
  _PdfThumbnailCache({
    required this.capacity,
    required this.renderSize,
    required this.rasterizer,
  }) : assert(capacity > 0),
       assert(renderSize > 0);

  final int capacity;
  final int renderSize;
  final PdfThumbnailRasterizer rasterizer;
  final LinkedHashMap<_PdfThumbnailKey, Future<PdfThumbnailRaster>> _entries =
      LinkedHashMap<_PdfThumbnailKey, Future<PdfThumbnailRaster>>();

  Future<ui.Image> load(String path, int sourcePageIndex) async {
    final key = (path: path, sourcePageIndex: sourcePageIndex);
    var pending = _entries.remove(key);
    pending ??= rasterizer(path, sourcePageIndex, renderSize);
    _entries[key] = pending;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }

    try {
      final raster = await pending;
      return await _decodePdfThumbnail(raster);
    } on Object {
      if (identical(_entries[key], pending)) _entries.remove(key);
      rethrow;
    }
  }

  void clear() => _entries.clear();
}

Future<PdfThumbnailRaster> _rasterizePdfThumbnail(
  String path,
  int sourcePageIndex,
  int maxDimension,
) async {
  PdfDocument? document;
  PdfImage? rendered;
  try {
    await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);
    document = await PdfDocument.openFile(path);
    if (document.pages.isEmpty) {
      throw StateError('Das PDF enthält keine darstellbare Seite.');
    }
    if (sourcePageIndex < 0 || sourcePageIndex >= document.pages.length) {
      throw RangeError.index(
        sourcePageIndex,
        document.pages,
        'sourcePageIndex',
      );
    }

    final page = document.pages[sourcePageIndex];
    if (!page.width.isFinite ||
        !page.height.isFinite ||
        page.width <= 0 ||
        page.height <= 0) {
      throw StateError('Die PDF-Seite hat keine gültige Größe.');
    }
    final factor = maxDimension / math.max(page.width, page.height);
    final renderWidth = math.max(1, (page.width * factor).round());
    final renderHeight = math.max(1, (page.height * factor).round());
    rendered = await page.render(
      fullWidth: renderWidth.toDouble(),
      fullHeight: renderHeight.toDouble(),
    );
    if (rendered == null) {
      throw StateError('PDFium hat keine Seitengrafik erzeugt.');
    }
    return PdfThumbnailRaster(
      width: rendered.width,
      height: rendered.height,
      bgraBytes: rendered.pixels,
    );
  } finally {
    rendered?.dispose();
    await document?.dispose();
  }
}

Future<ui.Image> _decodePdfThumbnail(PdfThumbnailRaster raster) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    raster._bgraBytes,
    raster.width,
    raster.height,
    ui.PixelFormat.bgra8888,
    completer.complete,
  );
  return completer.future;
}
