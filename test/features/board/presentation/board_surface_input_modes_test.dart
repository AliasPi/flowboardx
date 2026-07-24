import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/board/engine/input_policy.dart';
import 'package:flowboard_x/src/features/board/presentation/board_pointer_indicator.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<EditorController> pumpBoard(
    WidgetTester tester, {
    bool fingerDrawingEnabled = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    final controller = EditorController(
      document: WhiteboardDocument.create(id: 'input-mode-test'),
      repository: _MemoryRepository(),
      assetDirectory: Directory.current,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardSurface(
            controller: controller,
            fingerDrawingEnabled: fingerDrawingEnabled,
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    return controller;
  }

  testWidgets('finger drawing remains disabled by default', (tester) async {
    final controller = await pumpBoard(tester);
    final gesture = await tester.startGesture(
      const Offset(180, 220),
      pointer: 1,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(const Offset(260, 260));
    await gesture.up();
    await tester.pump();

    expect(controller.page.strokes, isEmpty);
    expect(controller.viewport.offset, isNot(Offset.zero));
    await controller.flush();
  });

  testWidgets('one finger writes when explicitly enabled', (tester) async {
    final controller = await pumpBoard(tester, fingerDrawingEnabled: true);
    final gesture = await tester.startGesture(
      const Offset(180, 220),
      pointer: 11,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(const Offset(280, 260));
    await gesture.up();
    await tester.pump();

    expect(controller.page.strokes, hasLength(1));
    expect(controller.page.strokes.single.points.length, greaterThan(1));
    await controller.flush();
  });

  testWidgets('second finger cancels provisional ink and starts navigation', (
    tester,
  ) async {
    final controller = await pumpBoard(tester, fingerDrawingEnabled: true);
    final first = await tester.startGesture(
      const Offset(180, 260),
      pointer: 21,
      kind: PointerDeviceKind.touch,
    );
    await first.moveTo(const Offset(210, 260));
    expect(controller.inkSessions.sessions, hasLength(1));

    final second = await tester.startGesture(
      const Offset(420, 260),
      pointer: 22,
      kind: PointerDeviceKind.touch,
    );
    expect(controller.inkSessions.sessions, isEmpty);
    await first.moveTo(const Offset(130, 260));
    await second.moveTo(const Offset(480, 260));
    await first.up();
    await second.up();
    await tester.pump();

    expect(controller.page.strokes, isEmpty);
    expect(controller.viewport.scale, greaterThan(1));
    await controller.flush();
  });

  testWidgets('two-finger pinch scales the current selection', (tester) async {
    final controller = await pumpBoard(tester);
    controller.addShape(
      ShapeKind.rectangle,
      const Rect.fromLTWH(200, 180, 220, 140),
    );
    await tester.pump();
    final before = controller.page.objects.single.transform;

    final first = await tester.startGesture(
      const Offset(240, 250),
      pointer: 31,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(380, 250),
      pointer: 32,
      kind: PointerDeviceKind.touch,
    );
    await second.moveTo(const Offset(470, 250));
    await tester.pump();
    await second.up();
    await first.up();
    await tester.pump();

    final after = controller.page.objects.single.transform;
    expect(after.width, greaterThan(before.width));
    expect(after.height, greaterThan(before.height));
    expect(
      after.width / after.height,
      closeTo(before.width / before.height, .02),
    );
    await controller.flush();
  });

  testWidgets('stylus eraser uses pen thickness and removes only its path', (
    tester,
  ) async {
    final controller = await pumpBoard(tester);
    final pen = await tester.startGesture(
      const Offset(120, 280),
      pointer: 41,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(const Offset(520, 280));
    await pen.up();
    await tester.pump();
    expect(controller.page.strokes, hasLength(1));

    controller
      ..updatePen(width: 24)
      ..setTool(BoardTool.eraser);
    final eraser = await tester.startGesture(
      const Offset(320, 230),
      pointer: 42,
      kind: PointerDeviceKind.stylus,
    );
    await eraser.moveTo(const Offset(320, 330));
    await eraser.up();
    await tester.pump();

    expect(controller.page.strokes, hasLength(2));
    final left = controller.page.strokes
        .expand((stroke) => stroke.points)
        .where((point) => point.x < 320)
        .toList();
    final right = controller.page.strokes
        .expand((stroke) => stroke.points)
        .where((point) => point.x > 320)
        .toList();
    expect(left, isNotEmpty);
    expect(right, isNotEmpty);
    final corridorPoints = controller.page.strokes
        .expand((stroke) => stroke.points)
        .where((point) => point.x > 309 && point.x < 331);
    expect(corridorPoints, isEmpty);
    await controller.flush();
  });

  testWidgets(
    'tool indicator follows active stylus for ink eraser and selection',
    (tester) async {
      final controller = await pumpBoard(tester);
      controller.updatePen(width: 24);

      BoardPointerIndicatorPainter painter() {
        final paint = tester.widget<CustomPaint>(
          find.byKey(const ValueKey<String>('board-pointer-indicator')),
        );
        return paint.painter! as BoardPointerIndicatorPainter;
      }

      for (final testCase
          in const <(BoardTool, BoardPointerIndicatorKind, int)>[
            (BoardTool.pen, BoardPointerIndicatorKind.ink, 71),
            (BoardTool.eraser, BoardPointerIndicatorKind.eraser, 72),
            (
              BoardTool.selectRectangle,
              BoardPointerIndicatorKind.selection,
              73,
            ),
          ]) {
        controller.setTool(testCase.$1);
        await tester.pump();
        const start = Offset(160, 180);
        const end = Offset(520, 360);
        final gesture = await tester.startGesture(
          start,
          pointer: testCase.$3,
          kind: PointerDeviceKind.stylus,
        );
        await tester.pump();

        expect(painter().indicators, hasLength(1));
        expect(painter().indicators.single.position, start);
        expect(painter().indicators.single.kind, testCase.$2);

        await gesture.moveTo(end);
        await tester.pump();

        expect(painter().indicators, hasLength(1));
        expect(painter().indicators.single.position, end);
        expect(painter().indicators.single.position, isNot(start));

        await gesture.up();
        await tester.pump();
        expect(painter().indicators, isEmpty);
        expect(painter().hoverPosition, isNull);
      }

      await controller.flush();
    },
  );
}

final class _MemoryRepository implements DocumentRepository {
  WhiteboardDocument? value;

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<void> delete(String documentId) async => value = null;

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => value;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => value;

  @override
  Future<void> save(WhiteboardDocument document) async => value = document;
}
