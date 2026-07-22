import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flowboard_x/src/app/app_theme.dart';
import 'package:flowboard_x/src/features/editor/pen_color_picker_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PenColorPickerMath', () {
    test('normalizes hue and follows clockwise wheel cardinals', () {
      const center = Offset(100, 100);

      expect(PenColorPickerMath.normalizeHue(-30), 330);
      expect(PenColorPickerMath.normalizeHue(725), 5);
      expect(PenColorPickerMath.normalizeHue(double.nan), 0);
      expect(
        PenColorPickerMath.hueForPosition(const Offset(100, 0), center),
        0,
      );
      expect(
        PenColorPickerMath.hueForPosition(const Offset(200, 100), center),
        closeTo(90, 1e-9),
      );
      expect(
        PenColorPickerMath.hueForPosition(const Offset(100, 200), center),
        closeTo(180, 1e-9),
      );
      expect(
        PenColorPickerMath.hueForPosition(const Offset(0, 100), center),
        closeTo(270, 1e-9),
      );
    });

    test('circular mapping round-trips complete saturation/value range', () {
      const samples = <PenSaturationValue>[
        PenSaturationValue(saturation: 0, value: 0),
        PenSaturationValue(saturation: 0, value: 1),
        PenSaturationValue(saturation: 1, value: 0),
        PenSaturationValue(saturation: 1, value: 1),
        PenSaturationValue(saturation: .27, value: .81),
        PenSaturationValue(saturation: .83, value: .38),
      ];

      for (final sample in samples) {
        final point = PenColorPickerMath.pointForSaturationValue(
          saturation: sample.saturation,
          value: sample.value,
          radius: 140,
        );
        expect(point.distance, lessThanOrEqualTo(140.000001));
        final restored = PenColorPickerMath.saturationValueForPoint(
          point: point,
          radius: 140,
        );
        expect(restored.saturation, closeTo(sample.saturation, 1e-7));
        expect(restored.value, closeTo(sample.value, 1e-7));
      }
    });

    test('opposite color rotates hue while retaining saturation and value', () {
      const source = HSVColor.fromAHSV(.72, 214, .67, .82);
      final opposite = HSVColor.fromColor(
        PenColorPickerMath.oppositeColor(source),
      );

      // RGB's 8-bit conversion introduces a small HSV round-trip quantization.
      expect(opposite.hue, closeTo(34, .2));
      expect(opposite.saturation, closeTo(source.saturation, .01));
      expect(opposite.value, closeTo(source.value, .01));
      expect(opposite.alpha, closeTo(source.alpha, .01));
    });
  });

  for (final deviceKind in <PointerDeviceKind>[
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
  ]) {
    testWidgets('wheel follows ${deviceKind.name} drag on hue and inner disc', (
      tester,
    ) async {
      var value = const HSVColor.fromAHSV(1, 0, .5, .5);
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFlowboardTheme(),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return PenColorWheel(
                    key: const ValueKey('tested-wheel'),
                    value: value,
                    size: 320,
                    onChanged: (next) => rebuild(() => value = next),
                  );
                },
              ),
            ),
          ),
        ),
      );

      final rect = tester.getRect(find.byKey(const ValueKey('tested-wheel')));
      final center = rect.center;
      final hueGesture = await tester.startGesture(
        center + const Offset(0, -135),
        kind: deviceKind,
      );
      await hueGesture.moveTo(center + const Offset(135, 0));
      await tester.pump();
      await hueGesture.up();

      expect(value.hue, closeTo(90, .01));

      // Geometry for a 320 px wheel: 156 outer, 56 ring, 88.8 inner.
      final desiredPoint = PenColorPickerMath.pointForSaturationValue(
        saturation: .82,
        value: .76,
        radius: 88.8,
      );
      final svGesture = await tester.startGesture(
        center + desiredPoint,
        kind: deviceKind,
      );
      await tester.pump();
      await svGesture.up();

      expect(value.saturation, closeTo(.82, .01));
      expect(value.value, closeTo(.76, .01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('inner disc renders white, black and the selected pure hue', (
    tester,
  ) async {
    const boundaryKey = ValueKey('wheel-boundary');
    const size = 320.0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: const Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: PenColorWheel(
                value: HSVColor.fromAHSV(1, 0, .5, .5),
                size: size,
                onChanged: _ignoreColor,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    late ui.Image image;
    late ByteData bytes;
    await tester.runAsync(() async {
      image = await boundary.toImage();
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    addTearDown(image.dispose);

    // Geometry for a 320 px wheel: 156 outer, 56 ring, 88.8 inner.
    const center = Offset(size / 2, size / 2);
    const radius = 88.8;
    final nearWhite = _pixelAt(
      bytes,
      image.width,
      center +
          PenColorPickerMath.pointForSaturationValue(
            saturation: .06,
            value: .94,
            radius: radius,
          ),
    );
    final nearBlack = _pixelAt(
      bytes,
      image.width,
      center +
          PenColorPickerMath.pointForSaturationValue(
            saturation: .55,
            value: .06,
            radius: radius,
          ),
    );
    final nearRed = _pixelAt(
      bytes,
      image.width,
      center +
          PenColorPickerMath.pointForSaturationValue(
            saturation: .94,
            value: .94,
            radius: radius,
          ),
    );
    const ringRadius = 128.0;
    final ringTop = _pixelAt(
      bytes,
      image.width,
      center + const Offset(0, -ringRadius),
    );
    final ringRight = _pixelAt(
      bytes,
      image.width,
      center + const Offset(ringRadius, 0),
    );
    final ringBottom = _pixelAt(
      bytes,
      image.width,
      center + const Offset(0, ringRadius),
    );
    final ringLeft = _pixelAt(
      bytes,
      image.width,
      center + const Offset(-ringRadius, 0),
    );

    expect(nearWhite.r, greaterThan(.8));
    expect(nearWhite.g, greaterThan(.8));
    expect(nearWhite.b, greaterThan(.8));
    expect(nearBlack.r, lessThan(.2));
    expect(nearBlack.g, lessThan(.2));
    expect(nearBlack.b, lessThan(.2));
    expect(nearRed.r, greaterThan(.7));
    expect(nearRed.g, lessThan(.3));
    expect(nearRed.b, lessThan(.3));
    // Visual wheel orientation matches pointer math: red starts at 12 o'clock
    // and hue increases clockwise through green, cyan and blue/magenta.
    expect(ringTop.r, greaterThan(.7));
    expect(ringTop.g, lessThan(.3));
    expect(ringTop.b, lessThan(.3));
    expect(ringRight.r, inInclusiveRange(.25, .75));
    expect(ringRight.g, greaterThan(.7));
    expect(ringRight.b, lessThan(.3));
    expect(ringBottom.r, lessThan(.3));
    expect(ringBottom.g, greaterThan(.7));
    expect(ringBottom.b, greaterThan(.7));
    expect(ringLeft.r, inInclusiveRange(.25, .75));
    expect(ringLeft.g, lessThan(.3));
    expect(ringLeft.b, greaterThan(.7));
  });

  testWidgets('dialog is overflow-free on compact viewport and large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 520);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    Color? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showDialog<Color>(
                    context: context,
                    builder: (_) => const PenColorPickerDialog(
                      initialColor: Color(0xFF336699),
                    ),
                  );
                },
                child: const Text('Öffnen'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('pen-color-picker-dialog')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pen-color-wheel')), findsOneWidget);
    expect(find.text('Gegenfarbe'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('pen-color-apply')));
    await tester.pumpAndSettle();
    expect(result?.toARGB32(), const Color(0xFF336699).toARGB32());
    expect(tester.takeException(), isNull);
  });

  testWidgets('opposite swatch selects complementary hue', (tester) async {
    Color? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<Color>(
                  context: context,
                  builder: (_) => const PenColorPickerDialog(
                    initialColor: Color(0xFFFF0000),
                  ),
                );
              },
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    final opposite = find.byKey(const ValueKey('pen-color-opposite-swatch'));
    await tester.ensureVisible(opposite);
    await tester.pumpAndSettle();
    await tester.tap(opposite);
    await tester.pump();
    expect(find.textContaining('Farbton 180°'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pen-color-apply')));
    await tester.pumpAndSettle();
    final hsv = HSVColor.fromColor(result!);
    expect(hsv.hue, closeTo(180, .01));
    expect(hsv.saturation, closeTo(1, .01));
    expect(hsv.value, closeTo(1, .01));
  });

  testWidgets('shows at most ten recent colors and selects one', (
    tester,
  ) async {
    Color? result;
    final recent = <Color>[
      const Color(0xFF123456),
      const Color(0xFFABCDEF),
      const Color(0xFF123456),
      for (var index = 0; index < 12; index++) Color(0xFF330000 | index),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await showDialog<Color>(
                  context: context,
                  builder: (_) => PenColorPickerDialog(
                    initialColor: const Color(0xFF000000),
                    recentColors: recent,
                  ),
                );
              },
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Zuletzt verwendet'), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-pen-color-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-pen-color-9')), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-pen-color-10')), findsNothing);

    final second = find.byKey(const ValueKey('recent-pen-color-1'));
    await tester.ensureVisible(second);
    await tester.tap(second);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pen-color-apply')));
    await tester.pumpAndSettle();
    expect(result?.toARGB32(), 0xFFABCDEF);
  });
}

void _ignoreColor(HSVColor _) {}

Color _pixelAt(ByteData data, int width, Offset point) {
  final x = point.dx.round();
  final y = point.dy.round();
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
}
