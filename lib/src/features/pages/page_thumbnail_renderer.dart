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
import '../../domain/model/scene_order.dart';
import '../board/presentation/board_object_layer.dart';
import '../board/presentation/ink_painter.dart';

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

class PageThumbnailRenderer {
  PageThumbnailRenderer({
    this.width = 192,
    this.height = 108,
    int pdfCacheCapacity = 24,
    int pdfRenderSize = 384,
    PdfThumbnailRasterizer pdfRasterizer = _rasterizePdfThumbnail,
  }) : assert(width > 0),
       assert(height > 0),
       _pdfThumbnails = _PdfThumbnailCache(
         capacity: pdfCacheCapacity,
         renderSize: pdfRenderSize,
         rasterizer: pdfRasterizer,
       );

  final int width;
  final int height;
  final _PdfThumbnailCache _pdfThumbnails;

  /// Releases cached PDF pixels. In-flight renders remain safe and become
  /// collectible as soon as their current thumbnail render has completed.
  void dispose() => _pdfThumbnails.clear();

  Future<ui.Image> render(BoardPage page, BoardAssetResolver assets) async {
    final decoded = <String, ui.Image>{};
    ui.PictureRecorder? recorder;
    ui.Picture? picture;
    var recording = false;
    try {
      for (final object in page.objects) {
        switch (object) {
          case final ImageObject image:
            ui.Codec? codec;
            try {
              final bytes = await assets.readBytes(image.assetId);
              if (bytes == null) continue;
              codec = await ui.instantiateImageCodec(bytes, targetWidth: 400);
              final frame = await codec.getNextFrame();
              decoded[image.id] = frame.image;
            } on Object {
              // A corrupt optional asset does not invalidate the thumbnail.
            } finally {
              codec?.dispose();
            }
          case final PdfObject pdf:
            try {
              final path = assets.localPath(pdf.assetId);
              if (path == null || path.isEmpty) continue;
              decoded[pdf.id] = await _pdfThumbnails.load(
                path,
                pdf.activeSourcePageIndex,
              );
            } on Object {
              // The canvas below draws an explicit unavailable-PDF fallback.
            }
          default:
            break;
        }
      }

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

      final annotations = page.annotationLayers
          .where((layer) => layer.visible)
          .toList(growable: false);
      final scene = orderedBoardSceneItems(
        objects: page.objects,
        strokes: page.strokes,
      );
      for (final item in scene) {
        final stroke = item.stroke;
        if (stroke != null) {
          InkPainter.drawStroke(canvas, stroke);
          continue;
        }
        final object = item.object!;
        _drawObject(canvas, object, decoded[object.id], scale);
        final layer = activeObjectInkLayer(object, annotations);
        if (layer != null) {
          canvas.save();
          _applyObjectOrientation(canvas, object.transform);
          canvas.translate(object.transform.x, object.transform.y);
          final objectSize = Size(
            object.transform.width,
            object.transform.height,
          );
          for (final annotation in layer.strokes) {
            InkPainter.drawObjectLocalStroke(canvas, annotation, objectSize);
          }
          canvas.restore();
        }
      }
      picture = recorder.endRecording();
      recording = false;
      return await picture.toImage(width, height);
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
        final text = TextPainter(
          text: TextSpan(
            text: textObject.text,
            style: TextStyle(
              color: Color(textObject.colorArgb),
              fontSize: textObject.fontSize,
              fontWeight: textObject.bold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: rect.width);
        text.paint(canvas, rect.topLeft);
        text.dispose();
    }
    canvas.restore();
    canvas.restore();
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

typedef _PdfThumbnailKey = ({String path, int sourcePageIndex});

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
