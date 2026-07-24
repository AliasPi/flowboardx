import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/board_viewport.dart';
import 'package:flowboard_x/src/features/board/presentation/board_scene_layer.dart';
import 'package:flowboard_x/src/features/board/presentation/board_surface.dart';
import 'package:flowboard_x/src/features/editor/board_participant_controller.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('two participants write concurrently with independent ink', (
    tester,
  ) async {
    final fixture = await _pumpSplitBoard(tester);
    addTearDown(fixture.dispose);
    fixture.left.updatePen(
      colorArgb: 0xFFFF0000,
      width: 8,
      type: InkToolType.normal,
    );
    fixture.right.updatePen(
      colorArgb: 0xFF0066FF,
      width: 18,
      type: InkToolType.marker,
    );

    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 101,
        device: 11,
        kind: PointerDeviceKind.stylus,
        position: Offset(100, 180),
      ),
    );
    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 202,
        device: 22,
        kind: PointerDeviceKind.stylus,
        position: Offset(700, 180),
      ),
    );
    expect(fixture.editor.inkSessions.sessions, hasLength(1));
    expect(fixture.rightEditor.inkSessions.sessions, hasLength(1));

    await tester.sendEventToBinding(
      const PointerMoveEvent(
        pointer: 101,
        device: 11,
        kind: PointerDeviceKind.stylus,
        position: Offset(220, 260),
        delta: Offset(120, 80),
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerMoveEvent(
        pointer: 202,
        device: 22,
        kind: PointerDeviceKind.stylus,
        position: Offset(820, 280),
        delta: Offset(120, 100),
        buttons: kPrimaryButton,
      ),
    );
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 101,
        device: 11,
        kind: PointerDeviceKind.stylus,
        position: Offset(220, 260),
      ),
    );
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 202,
        device: 22,
        kind: PointerDeviceKind.stylus,
        position: Offset(820, 280),
      ),
    );
    await tester.pump();

    expect(fixture.editor.page.strokes, hasLength(2));
    final byAuthor = <String, InkStroke>{
      for (final stroke in fixture.editor.page.strokes) stroke.authorId: stroke,
    };
    expect(byAuthor['left-device-11']?.colorArgb, 0xFFFF0000);
    expect(byAuthor['left-device-11']?.width, 8);
    expect(byAuthor['right-device-22']?.colorArgb, 0xFF0066FF);
    expect(byAuthor['right-device-22']?.type, InkToolType.marker);
    expect(byAuthor['left-device-11']!.points.first.x, closeTo(100, .01));
    expect(
      byAuthor['right-device-22']!.points.first.x,
      closeTo(700, .01),
      reason:
          'the right half must use the full workspace coordinate system, not '
          'restart its world coordinates at the divider',
    );
    await fixture.editor.flush();
  });

  testWidgets('each half pans and zooms only its own viewport', (tester) async {
    final fixture = await _pumpSplitBoard(tester);
    addTearDown(fixture.dispose);
    final rightScaleBefore = fixture.rightEditor.viewport.scale;
    final rightOffsetBefore = fixture.rightEditor.viewport.offset;

    final first = await tester.startGesture(
      const Offset(120, 300),
      pointer: 301,
      kind: PointerDeviceKind.touch,
    );
    final second = await tester.startGesture(
      const Offset(320, 300),
      pointer: 302,
      kind: PointerDeviceKind.touch,
    );
    await first.moveTo(const Offset(70, 300));
    await second.moveTo(const Offset(390, 300));
    await tester.pump();

    expect(fixture.editor.viewport.scale, greaterThan(1));
    expect(fixture.rightEditor.viewport.scale, rightScaleBefore);
    expect(fixture.rightEditor.viewport.offset, rightOffsetBefore);
    final layers = tester
        .widgetList<BoardSceneLayer>(find.byType(BoardSceneLayer))
        .toList(growable: false);
    expect(layers, hasLength(2));
    expect(layers[0].scale, fixture.editor.viewport.scale);
    expect(layers[1].scale, fixture.rightEditor.viewport.scale);
    expect(layers[0].offset, fixture.editor.viewport.offset);
    expect(layers[1].offset, fixture.rightEditor.viewport.offset);

    await first.up();
    await second.up();
    await fixture.editor.flush();
  });

  testWidgets(
    'split cameras cannot pan or zoom through the other document half',
    (tester) async {
      final fixture = await _pumpSplitBoard(tester);
      addTearDown(fixture.dispose);
      await _pumpSplitWorkspace(
        tester,
        editor: fixture.editor,
        rightEditor: fixture.rightEditor,
        left: fixture.left,
        right: fixture.right,
        leftSuppression: fixture.leftSuppression,
        constrainHorizontalViewports: true,
      );
      // The post-frame constraint also covers restored/page-switched cameras.
      await tester.pump();

      const dividerWorldX = 960.0;
      expect(
        fixture.editor.viewport.screenToWorld(const Offset(500, 350)).dx,
        lessThanOrEqualTo(dividerWorldX),
      );
      expect(
        fixture.rightEditor.viewport.screenToWorld(const Offset(500, 350)).dx,
        greaterThanOrEqualTo(dividerWorldX),
      );

      fixture.rightEditor.viewport.restore(
        scale: .75,
        offset: const Offset(800, 15),
      );
      await tester.pump();
      await tester.pump();
      expect(
        fixture.rightEditor.viewport.screenToWorld(const Offset(500, 350)).dx,
        closeTo(dividerWorldX, .001),
        reason: 'a restored participant camera is constrained after its frame',
      );

      final rightBeforeLeftGesture = fixture.rightEditor.viewport.offset;
      final leftPan = await tester.startGesture(
        const Offset(480, 300),
        pointer: 351,
        kind: PointerDeviceKind.touch,
      );
      await leftPan.moveTo(const Offset(5, 390));
      await tester.pump();
      await leftPan.up();

      expect(
        fixture.editor.viewport.screenToWorld(const Offset(500, 350)).dx,
        closeTo(dividerWorldX, .001),
      );
      expect(
        fixture.editor.viewport.offset.dy,
        greaterThan(0),
        reason: 'the split only constrains horizontal navigation',
      );
      expect(fixture.rightEditor.viewport.offset, rightBeforeLeftGesture);

      final rightPan = await tester.startGesture(
        const Offset(520, 300),
        pointer: 352,
        kind: PointerDeviceKind.touch,
      );
      await rightPan.moveTo(const Offset(995, 390));
      await tester.pump();
      await rightPan.up();

      expect(
        fixture.rightEditor.viewport.screenToWorld(const Offset(500, 350)).dx,
        closeTo(dividerWorldX, .001),
      );
      expect(
        fixture.rightEditor.viewport.offset.dy,
        greaterThan(0),
        reason: 'the right camera retains independent vertical navigation',
      );

      final rightScaleBefore = fixture.rightEditor.viewport.scale;
      final first = await tester.startGesture(
        const Offset(120, 250),
        pointer: 353,
        kind: PointerDeviceKind.touch,
      );
      final second = await tester.startGesture(
        const Offset(350, 250),
        pointer: 354,
        kind: PointerDeviceKind.touch,
      );
      await first.moveTo(const Offset(70, 250));
      await second.moveTo(const Offset(410, 250));
      await tester.pump();

      expect(fixture.editor.viewport.scale, greaterThan(1));
      expect(fixture.rightEditor.viewport.scale, rightScaleBefore);
      expect(
        fixture.editor.viewport.screenToWorld(const Offset(500, 350)).dx,
        lessThanOrEqualTo(dividerWorldX),
      );

      await first.up();
      await second.up();
      await fixture.editor.flush();
    },
  );

  testWidgets(
    'removing the divider preserves screen positions and stroke z-order',
    (tester) async {
      final fixture = await _pumpSplitBoard(tester);
      addTearDown(fixture.dispose);

      for (final entry in const <(int, Offset, Offset)>[
        (501, Offset(170, 180), Offset(240, 220)),
        (502, Offset(690, 230), Offset(790, 260)),
      ]) {
        final gesture = await tester.startGesture(
          entry.$2,
          pointer: entry.$1,
          kind: PointerDeviceKind.stylus,
        );
        await gesture.moveTo(entry.$3);
        await gesture.up();
      }
      await tester.pump();

      final before = fixture.editor.page.strokes;
      final idsBefore = before.map((stroke) => stroke.id).toList();
      final screenPointsBefore = before
          .map(
            (stroke) => fixture.editor.viewport.worldToScreen(
              Offset(stroke.points.first.x, stroke.points.first.y),
            ),
          )
          .toList();
      expect(screenPointsBefore[0].dx, closeTo(170, .01));
      expect(screenPointsBefore[1].dx, closeTo(690, .01));

      await fixture.pumpSolo(tester);

      final after = fixture.editor.page.strokes;
      expect(after.map((stroke) => stroke.id), idsBefore);
      final screenPointsAfter = after
          .map(
            (stroke) => fixture.editor.viewport.worldToScreen(
              Offset(stroke.points.first.x, stroke.points.first.y),
            ),
          )
          .toList();
      expect(screenPointsAfter, screenPointsBefore);
      expect(find.byKey(const ValueKey('solo-test-board')), findsOneWidget);
      await fixture.editor.flush();
    },
  );

  testWidgets('a pointer remains confined to the half that claimed it', (
    tester,
  ) async {
    final fixture = await _pumpSplitBoard(tester);
    addTearDown(fixture.dispose);

    final gesture = await tester.startGesture(
      const Offset(100, 220),
      pointer: 401,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(const Offset(900, 240));
    await gesture.up();
    await tester.pump();

    final stroke = fixture.editor.page.strokes.single;
    expect(
      stroke.points.map((point) => point.x).reduce((a, b) => a > b ? a : b),
      lessThanOrEqualTo(500),
    );
    await fixture.editor.flush();
  });

  testWidgets('left five-finger suppression never cancels the right eraser', (
    tester,
  ) async {
    final fixture = await _pumpSplitBoard(tester);
    addTearDown(fixture.dispose);
    final pen = await tester.startGesture(
      const Offset(700, 240),
      pointer: 601,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(const Offset(700, 360));
    await pen.up();
    await tester.pump();
    expect(fixture.editor.page.strokes, hasLength(1));

    await tester.sendEventToBinding(
      const PointerDownEvent(
        pointer: 602,
        device: 602,
        kind: PointerDeviceKind.touch,
        position: Offset(700, 300),
        radiusMajor: 30,
        radiusMinor: 18,
        size: .34,
      ),
    );
    await tester.pump();
    expect(fixture.editor.page.strokes, hasLength(1));
    expect(fixture.rightEditor.renderStrokes, hasLength(2));
    expect(fixture.editor.renderStrokes, hasLength(1));

    fixture.leftSuppression.value = true;
    await tester.pump();
    expect(
      fixture.rightEditor.renderStrokes,
      hasLength(2),
      reason: 'the left surface must not clear the shared right erase preview',
    );
    await tester.sendEventToBinding(
      const PointerUpEvent(
        pointer: 602,
        device: 602,
        kind: PointerDeviceKind.touch,
        position: Offset(700, 300),
        radiusMajor: 30,
        radiusMinor: 18,
        size: .34,
      ),
    );
    await tester.pump();
    expect(fixture.editor.page.strokes, hasLength(2));
    fixture.rightEditor.undo();
    expect(fixture.editor.page.strokes, hasLength(1));
    await fixture.editor.flush();
  });

  testWidgets(
    'right page creation and navigation never changes the left page',
    (tester) async {
      final fixture = await _pumpSplitBoard(tester);
      addTearDown(fixture.dispose);
      final leftPageId = fixture.editor.page.id;

      fixture.rightEditor.addPage();
      await tester.pump();

      expect(fixture.editor.document.pages, hasLength(2));
      expect(fixture.editor.page.id, leftPageId);
      expect(fixture.editor.currentPageIndex, 0);
      expect(fixture.rightEditor.currentPageIndex, 1);
      expect(fixture.rightEditor.page.id, isNot(leftPageId));

      final rightNewPageId = fixture.rightEditor.page.id;
      fixture.rightEditor.previousPage();
      expect(fixture.rightEditor.page.id, leftPageId);
      expect(fixture.editor.page.id, leftPageId);
      fixture.rightEditor.nextPage();
      expect(fixture.rightEditor.page.id, rightNewPageId);
      expect(fixture.editor.page.id, leftPageId);
      await fixture.editor.flush();
    },
  );
}

Future<_SplitFixture> _pumpSplitBoard(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 700);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final editor = EditorController(
    document: WhiteboardDocument.create(id: 'two-person-test'),
    repository: _MemoryRepository(),
    assetDirectory: Directory.current,
  );
  final rightEditor = EditorController.participantView(editor);
  final left = BoardParticipantController(
    id: 'left',
    penStyle: editor.penStyle,
  );
  final right = BoardParticipantController(
    id: 'right',
    penStyle: editor.penStyle,
  );
  final leftSuppression = ValueNotifier<bool>(false);
  await _pumpSplitWorkspace(
    tester,
    editor: editor,
    rightEditor: rightEditor,
    left: left,
    right: right,
    leftSuppression: leftSuppression,
  );
  return _SplitFixture(editor, rightEditor, left, right, leftSuppression);
}

Future<void> _pumpSplitWorkspace(
  WidgetTester tester, {
  required EditorController editor,
  required EditorController rightEditor,
  required BoardParticipantController left,
  required BoardParticipantController right,
  required ValueNotifier<bool> leftSuppression,
  bool constrainHorizontalViewports = false,
}) async {
  const leftRegion = Rect.fromLTWH(0, 0, 500, 700);
  const rightRegion = Rect.fromLTWH(500, 0, 500, 700);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: ClipRect(
                clipper: const _TestRegionClipper(leftRegion),
                child: BoardSurface(
                  controller: editor,
                  participant: left,
                  participantId: left.id,
                  confineInputToBounds: true,
                  inputBounds: leftRegion,
                  inputSuppression: leftSuppression,
                  horizontalViewportConstraint: constrainHorizontalViewports
                      ? const BoardViewportHorizontalConstraint(
                          side: BoardViewportPartitionSide.left,
                          worldBoundaryX: 960,
                        )
                      : null,
                ),
              ),
            ),
            Positioned.fill(
              child: ClipRect(
                clipper: const _TestRegionClipper(rightRegion),
                child: BoardSurface(
                  controller: rightEditor,
                  participant: right,
                  participantId: right.id,
                  confineInputToBounds: true,
                  inputBounds: rightRegion,
                  horizontalViewportConstraint: constrainHorizontalViewports
                      ? const BoardViewportHorizontalConstraint(
                          side: BoardViewportPartitionSide.right,
                          worldBoundaryX: 960,
                        )
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

final class _SplitFixture {
  const _SplitFixture(
    this.editor,
    this.rightEditor,
    this.left,
    this.right,
    this.leftSuppression,
  );

  final EditorController editor;
  final EditorController rightEditor;
  final BoardParticipantController left;
  final BoardParticipantController right;
  final ValueNotifier<bool> leftSuppression;

  Future<void> pumpSolo(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardSurface(
            key: const ValueKey('solo-test-board'),
            controller: editor,
            participant: left,
            participantId: left.id,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> dispose() async {
    await rightEditor.close();
    await editor.close();
    rightEditor.dispose();
    left.dispose();
    right.dispose();
    leftSuppression.dispose();
    editor.dispose();
  }
}

final class _TestRegionClipper extends CustomClipper<Rect> {
  const _TestRegionClipper(this.region);

  final Rect region;

  @override
  Rect getClip(Size size) => region;

  @override
  bool shouldReclip(covariant _TestRegionClipper oldClipper) =>
      oldClipper.region != region;
}

final class _MemoryRepository implements DocumentRepository {
  WhiteboardDocument? value;

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<void> delete(String documentId) async => value = null;

  @override
  Future<List<DocumentSummary>> list() async => const [];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => value;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => value;

  @override
  Future<void> save(WhiteboardDocument document) async => value = document;
}
