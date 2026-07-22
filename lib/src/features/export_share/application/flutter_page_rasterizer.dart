import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../domain/export_snapshot.dart';

typedef ExportScenePainter =
    void Function(ui.Canvas canvas, ui.Size logicalSize);

/// Adapts a CustomPainter-style callback to an [ExportPageSnapshot].
///
/// The callback should paint a frozen document snapshot, not read mutable UI
/// state. Rendering is deliberately page-by-page so a 100-page document does
/// not keep 100 bitmaps in memory.
abstract final class FlutterPageRasterizer {
  static ExportPageSnapshot fromPainter({
    required ui.Size logicalSize,
    required ExportScenePainter painter,
    double? widthPoints,
    double? heightPoints,
    String? label,
    ui.Color background = const ui.Color(0xFFFFFFFF),
  }) {
    if (logicalSize.isEmpty ||
        !logicalSize.width.isFinite ||
        !logicalSize.height.isFinite) {
      throw ArgumentError.value(
        logicalSize,
        'logicalSize',
        'must be finite and non-empty',
      );
    }

    return ExportPageSnapshot(
      widthPoints: widthPoints ?? logicalSize.width,
      heightPoints: heightPoints ?? logicalSize.height,
      logicalWidth: logicalSize.width,
      logicalHeight: logicalSize.height,
      label: label,
      rasterize: (request) => _paint(
        logicalSize: logicalSize,
        painter: painter,
        background: background,
        request: request,
      ),
    );
  }

  static Future<ExportRaster> _paint({
    required ui.Size logicalSize,
    required ExportScenePainter painter,
    required ui.Color background,
    required ExportRasterRequest request,
  }) async {
    var ratio = request.pixelRatio.clamp(0.25, 8.0);
    final requestedPixels =
        logicalSize.width * logicalSize.height * ratio * ratio;
    if (requestedPixels > request.maxPixels) {
      ratio *= math.sqrt(request.maxPixels / requestedPixels);
    }

    final width = math.max(1, (logicalSize.width * ratio).ceil());
    final height = math.max(1, (logicalSize.height * ratio).ceil());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Offset.zero & ui.Size(width.toDouble(), height.toDouble()),
      ui.Paint()..color = background,
    );
    canvas.scale(width / logicalSize.width, height / logicalSize.height);
    painter(canvas, logicalSize);

    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(width, height);
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (byteData == null) {
        throw StateError(
          'Flutter did not return pixel data for the export page.',
        );
      }
      return ExportRaster(
        width: width,
        height: height,
        rgbaBytes: Uint8List.sublistView(byteData),
      );
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }
}
