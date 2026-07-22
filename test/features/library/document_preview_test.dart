import 'dart:ui' as ui;

import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/library/document_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('caps every preview stroke width after applying scale minimum', () {
    expect(
      DocumentPagePreviewPainter.safePreviewStrokeWidth(1e100, .25),
      DocumentPagePreviewPainter.maxPreviewStrokeWidth,
    );
    expect(
      DocumentPagePreviewPainter.safePreviewStrokeWidth(8, 0),
      DocumentPagePreviewPainter.maxPreviewStrokeWidth,
    );
    expect(DocumentPagePreviewPainter.safePreviewStrokeWidth(double.nan, 1), 1);
    expect(DocumentPagePreviewPainter.safePreviewStrokeWidth(2, .1), 8.5);
  });

  test('rasterizes a recovered huge-width dashed preview safely', () async {
    final page = BoardPage(
      id: 'recovered',
      name: 'Wiederhergestellt',
      strokes: <InkStroke>[
        InkStroke(
          id: 'huge-dash',
          type: InkToolType.dashed,
          width: 1e100,
          points: const <InkPoint>[
            InkPoint(x: 10, y: 10),
            InkPoint(x: 300, y: 100),
          ],
        ),
      ],
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final painter = DocumentPagePreviewPainter(page: page);

    expect(
      () => painter.paint(canvas, const ui.Size(320, 180)),
      returnsNormally,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(320, 180);
    expect(image.width, 320);
    expect(image.height, 180);
    image.dispose();
    picture.dispose();
  });
}
