import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flowboard_x/src/features/radial_menu/radial_eraser_glyph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('eraser body is a stable scalable block silhouette', () {
    final compact = RadialEraserGlyph.bodyPath(28).getBounds();
    final large = RadialEraserGlyph.bodyPath(56).getBounds();

    expect(compact, const Rect.fromLTRB(-10, -6, 10, 6));
    expect(large.left, closeTo(compact.left * 2, .001));
    expect(large.top, closeTo(compact.top * 2, .001));
    expect(large.width, closeTo(compact.width * 2, .001));
    expect(large.height, closeTo(compact.height * 2, .001));
  });

  testWidgets('eraser glyph paints with the supplied active-state tint', (
    tester,
  ) async {
    const active = Color(0xFF55E0B4);
    const inactive = Color(0xFFD0D6D4);

    final activePixels = (await tester.runAsync(() => _paintGlyph(active)))!;
    final inactivePixels = (await tester.runAsync(
      () => _paintGlyph(inactive),
    ))!;

    expect(_opaquePixelCount(activePixels), greaterThan(350));
    expect(_opaquePixelCount(inactivePixels), greaterThan(350));
    expect(_containsOpaqueColor(activePixels, active), isTrue);
    expect(_containsOpaqueColor(inactivePixels, inactive), isTrue);
    expect(activePixels, isNot(equals(inactivePixels)));
  });
}

Future<Uint8List> _paintGlyph(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  RadialEraserGlyph.paint(
    canvas,
    center: const Offset(48, 48),
    size: 56,
    color: color,
  );
  final image = await recorder.endRecording().toImage(96, 96);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

int _opaquePixelCount(Uint8List pixels) {
  var count = 0;
  for (var index = 3; index < pixels.length; index += 4) {
    if (pixels[index] != 0) count++;
  }
  return count;
}

bool _containsOpaqueColor(Uint8List pixels, Color color) {
  final red = (color.r * 255).round();
  final green = (color.g * 255).round();
  final blue = (color.b * 255).round();
  for (var index = 0; index < pixels.length; index += 4) {
    if (pixels[index] == red &&
        pixels[index + 1] == green &&
        pixels[index + 2] == blue &&
        pixels[index + 3] == 255) {
      return true;
    }
  }
  return false;
}
