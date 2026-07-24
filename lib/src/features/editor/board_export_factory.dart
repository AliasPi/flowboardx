import 'dart:async';
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
import '../export_share/export_share.dart';

class PreparedBoardExport {
  PreparedBoardExport(this.snapshot);

  final ExportDocumentSnapshot snapshot;

  void dispose() {}
}

typedef BoardPdfPageRenderer =
    Future<ui.Image> Function(String path, PdfObject object);

/// A user-actionable failure while materializing board content for export.
///
/// PDF pages must never silently turn into a placeholder in an otherwise
/// successful export. Keeping this exception distinct also lets callers show
/// the concise German message without leaking a native PDFium exception.
final class BoardExportException implements Exception {
  const BoardExportException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class BoardExportFactory {
  const BoardExportFactory({BoardPdfPageRenderer? pdfPageRenderer})
    : _pdfPageRenderer = pdfPageRenderer;

  final BoardPdfPageRenderer? _pdfPageRenderer;

  Future<PreparedBoardExport> prepare(
    WhiteboardDocument document,
    BoardAssetResolver assets,
  ) async {
    final pages = <ExportPageSnapshot>[];
    for (final page in document.pages) {
      final frozenPage = page;
      pages.add(
        ExportPageSnapshot(
          widthPoints: 960,
          heightPoints: 540,
          logicalWidth: 1920,
          logicalHeight: 1080,
          label: page.name,
          rasterize: (request) => _rasterizePage(frozenPage, assets, request),
        ),
      );
    }
    return PreparedBoardExport(
      ExportDocumentSnapshot(
        title: document.title,
        author: document.metadata.author,
        createdAt: document.createdAt,
        modifiedAt: document.updatedAt,
        pages: pages,
      ),
    );
  }

  Future<ExportRaster> _rasterizePage(
    BoardPage page,
    BoardAssetResolver assets,
    ExportRasterRequest request,
  ) async {
    final images = <String, ui.Image>{};
    try {
      for (final object in page.objects) {
        ui.Image? decoded;
        if (object is ImageObject) {
          decoded = await _decodeAsset(await assets.readBytes(object.assetId));
        } else if (object is PdfObject) {
          decoded = await _loadPdfPage(page, object, assets);
        }
        if (decoded != null) images[object.id] = decoded;
      }
      final rasterizer = FlutterPageRasterizer.fromPainter(
        logicalSize: const ui.Size(1920, 1080),
        widthPoints: 960,
        heightPoints: 540,
        label: page.name,
        painter: (canvas, size) => _paintPage(canvas, size, page, images),
      );
      return rasterizer.rasterize(request);
    } finally {
      for (final image in images.values) {
        image.dispose();
      }
    }
  }

  Future<ui.Image?> _decodeAsset(Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1600);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } on Object {
      return null;
    }
  }

  Future<ui.Image> _loadPdfPage(
    BoardPage boardPage,
    PdfObject object,
    BoardAssetResolver assets,
  ) async {
    final sourcePageNumber = object.activeSourcePageIndex + 1;
    late final String? path;
    try {
      path = assets.localPath(object.assetId);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        BoardExportException(
          'Die PDF-Seite $sourcePageNumber auf Whiteboard-Seite '
          '„${boardPage.name}“ konnte nicht geladen werden. Prüfe, ob die '
          'PDF-Datei noch vorhanden und lesbar ist.',
          cause: error,
        ),
        stack,
      );
    }
    if (path == null || path.isEmpty) {
      throw BoardExportException(
        'Die PDF auf Whiteboard-Seite „${boardPage.name}“ ist nicht mehr '
        'verfügbar. Füge die Datei erneut ein und starte den Export noch einmal.',
      );
    }

    try {
      return await (_pdfPageRenderer ?? _renderPdfPage)(path, object);
    } on BoardExportException {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        BoardExportException(
          'Die PDF-Seite $sourcePageNumber auf Whiteboard-Seite '
          '„${boardPage.name}“ konnte nicht gerendert werden. Prüfe, ob die '
          'PDF-Datei noch vorhanden und lesbar ist.',
          cause: error,
        ),
        stack,
      );
    }
  }

  Future<ui.Image> _renderPdfPage(String path, PdfObject object) async {
    PdfDocument? document;
    PdfImage? rendered;
    try {
      await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);
      document = await PdfDocument.openFile(path);
      if (document.pages.isEmpty) {
        throw StateError('Das PDF enthält keine darstellbare Seite.');
      }
      final index = object.activeSourcePageIndex;
      if (index < 0 || index >= document.pages.length) {
        throw RangeError.index(index, document.pages, 'sourcePageIndex');
      }
      final page = document.pages[index];
      final ratio = page.height <= 0 ? 1.0 : page.width / page.height;
      final renderWidth = 1200;
      final renderHeight = (renderWidth / ratio).round().clamp(1, 2000);
      rendered = await page.render(
        fullWidth: renderWidth.toDouble(),
        fullHeight: renderHeight.toDouble(),
      );
      if (rendered == null) {
        throw StateError('PDFium hat keine Seitengrafik erzeugt.');
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rendered.pixels,
        rendered.width,
        rendered.height,
        ui.PixelFormat.bgra8888,
        completer.complete,
      );
      return await completer.future;
    } finally {
      rendered?.dispose();
      await document?.dispose();
    }
  }

  static void _paintPage(
    ui.Canvas canvas,
    ui.Size size,
    BoardPage page,
    Map<String, ui.Image> images,
  ) {
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFFF8F7F2),
    );
    canvas.save();
    canvas.scale(1 / 3);
    canvas.translate(1920, 1080);
    final world = const ui.Rect.fromLTWH(-1920, -1080, 5760, 3240);
    canvas.drawRect(world, ui.Paint()..color = const ui.Color(0xFFF8F7F2));
    final grid = ui.Paint()
      ..color = const ui.Color(0xFFCCD1CE)
      ..strokeWidth = 2.5;
    for (var x = -1920.0; x <= 3840; x += 1920) {
      canvas.drawLine(ui.Offset(x, -1080), ui.Offset(x, 2160), grid);
    }
    for (var y = -1080.0; y <= 2160; y += 1080) {
      canvas.drawLine(ui.Offset(-1920, y), ui.Offset(3840, y), grid);
    }
    final annotations = page.annotationLayers
        .where((candidate) => candidate.visible)
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
      _paintObject(canvas, object, images[object.id]);
      final layer = activeObjectInkLayer(object, annotations);
      if (layer != null) {
        canvas.save();
        _applyObjectOrientation(canvas, object.transform);
        canvas.translate(object.transform.x, object.transform.y);
        final objectSize = ui.Size(
          object.transform.width,
          object.transform.height,
        );
        for (final annotation in layer.strokes) {
          InkPainter.drawObjectLocalStroke(canvas, annotation, objectSize);
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  static void _paintObject(
    ui.Canvas canvas,
    BoardObject object,
    ui.Image? image,
  ) {
    final t = object.transform;
    final rect = ui.Rect.fromLTWH(t.x, t.y, t.width, t.height);
    canvas.save();
    _applyObjectOrientation(canvas, t);
    canvas.saveLayer(
      rect,
      ui.Paint()
        ..color = const ui.Color(0xFFFFFFFF).withValues(alpha: object.opacity),
    );
    switch (object) {
      case final ShapeObject shape:
        final path = switch (shape.shape) {
          ShapeKind.rectangle => ui.Path()..addRect(rect),
          ShapeKind.circle || ShapeKind.ellipse => ui.Path()..addOval(rect),
          ShapeKind.triangle =>
            ui.Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.bottom)
              ..lineTo(rect.left, rect.bottom)
              ..close(),
        };
        canvas.drawPath(path, ui.Paint()..color = ui.Color(shape.fillArgb));
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = ui.Color(shape.strokeArgb)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = shape.strokeWidth,
        );
      case ImageObject() || PdfObject():
        canvas.drawRect(rect, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
        if (image != null) {
          paintImage(
            canvas: canvas,
            rect: rect,
            image: image,
            fit: BoxFit.contain,
          );
        } else if (object is PdfObject) {
          throw const BoardExportException(
            'Eine PDF-Seite konnte nicht in die Exportgrafik übernommen '
            'werden. Der Export wurde abgebrochen.',
          );
        }
      case final TableObject table:
        canvas.drawRect(rect, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
        final grid = ui.Paint()
          ..color = ui.Color(table.gridColorArgb)
          ..strokeWidth = table.gridWidth;
        for (var column = 1; column < table.columns; column++) {
          final x = rect.left + rect.width * column / table.columns;
          canvas.drawLine(
            ui.Offset(x, rect.top),
            ui.Offset(x, rect.bottom),
            grid,
          );
        }
        for (var row = 1; row < table.rows; row++) {
          final y = rect.top + rect.height * row / table.rows;
          canvas.drawLine(
            ui.Offset(rect.left, y),
            ui.Offset(rect.right, y),
            grid,
          );
        }
        for (var row = 0; row < table.rows; row++) {
          for (var column = 0; column < table.columns; column++) {
            final cell = table.cellAt(row, column);
            if (cell.text.isNotEmpty) {
              final cellRect = ui.Rect.fromLTWH(
                rect.left + rect.width * column / table.columns,
                rect.top + rect.height * row / table.rows,
                rect.width / table.columns,
                rect.height / table.rows,
              );
              _paintLabel(
                canvas,
                cellRect.deflate(6),
                cell.text,
                ui.Color(cell.textArgb),
                size: 18,
              );
            }
          }
        }
      case final CoverObject cover:
        final reveal = cover.reveal.clamp(0.0, 1.0);
        final covered = switch (cover.direction) {
          RevealDirection.leftToRight => ui.Rect.fromLTWH(
            rect.left + rect.width * reveal,
            rect.top,
            rect.width * (1 - reveal),
            rect.height,
          ),
          RevealDirection.rightToLeft => ui.Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width * (1 - reveal),
            rect.height,
          ),
          RevealDirection.topToBottom => ui.Rect.fromLTWH(
            rect.left,
            rect.top + rect.height * reveal,
            rect.width,
            rect.height * (1 - reveal),
          ),
          RevealDirection.bottomToTop => ui.Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width,
            rect.height * (1 - reveal),
          ),
        };
        canvas.drawRect(covered, ui.Paint()..color = ui.Color(cover.colorArgb));
      case final TextObject text:
        _paintLabel(
          canvas,
          rect,
          text.text,
          ui.Color(text.colorArgb),
          size: text.fontSize,
        );
    }
    canvas.restore();
    canvas.restore();
  }

  static void _applyObjectOrientation(
    ui.Canvas canvas,
    ObjectTransform transform,
  ) {
    if (transform.rotationRadians.abs() < .0000001 &&
        !transform.flipX &&
        !transform.flipY) {
      return;
    }
    final center = ui.Offset(
      transform.x + transform.width / 2,
      transform.y + transform.height / 2,
    );
    canvas
      ..translate(center.dx, center.dy)
      ..rotate(transform.rotationRadians)
      ..scale(transform.flipX ? -1 : 1, transform.flipY ? -1 : 1)
      ..translate(-center.dx, -center.dy);
  }

  static void _paintLabel(
    ui.Canvas canvas,
    ui.Rect rect,
    String label,
    ui.Color color, {
    double size = 56,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 4,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    painter.paint(canvas, rect.topLeft);
    painter.dispose();
  }
}
