import 'dart:io';
import 'dart:ui';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/commands/document_commands.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/features/board/engine/board_viewport.dart';
import 'package:flowboard_x/src/features/editor/editor_commands.dart';
import 'package:flowboard_x/src/features/editor/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('interleaved undo and redo stay scoped to their participant', () async {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final pageId = fixture.left.page.id;

    fixture.left.execute(AddStrokeCommand(pageId, _stroke('left-1', 20)));
    fixture.right.execute(AddStrokeCommand(pageId, _stroke('right-1', 80)));

    expect(fixture.left.canUndo, isTrue);
    expect(fixture.right.canUndo, isTrue);
    fixture.left.undo();
    expect(fixture.left.page.strokes.map((stroke) => stroke.id), ['right-1']);
    expect(fixture.left.canRedo, isTrue);
    expect(fixture.right.canUndo, isTrue);

    fixture.right.undo();
    expect(fixture.left.page.strokes, isEmpty);
    expect(fixture.left.canRedo, isTrue);
    expect(fixture.right.canRedo, isTrue);

    fixture.left.redo();
    expect(fixture.left.page.strokes.map((stroke) => stroke.id), ['left-1']);
    fixture.right.redo();
    expect(fixture.left.page.strokes.map((stroke) => stroke.id), [
      'left-1',
      'right-1',
    ]);

    await fixture.left.flush();
    expect(
      fixture.repository.document?.currentPage.strokes.map(
        (stroke) => stroke.id,
      ),
      ['left-1', 'right-1'],
      reason: 'the shared scoped history must still feed the single autosave',
    );
  });

  test('foreign execution does not clear a participant redo branch', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final pageId = fixture.left.page.id;

    fixture.left.execute(AddStrokeCommand(pageId, _stroke('left', 20)));
    fixture.left.undo();
    fixture.right.execute(AddStrokeCommand(pageId, _stroke('right', 80)));

    expect(fixture.left.canRedo, isTrue);
    fixture.left.redo();
    expect(fixture.left.page.strokes.map((stroke) => stroke.id), [
      'left',
      'right',
    ]);
  });

  test('participants share one incremental grouping index', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final pageId = fixture.left.page.id;

    expect(
      identical(fixture.left.groupingEngine, fixture.right.groupingEngine),
      isTrue,
    );
    expect(
      identical(fixture.left.selectionEngine, fixture.right.selectionEngine),
      isTrue,
      reason:
          'split participants must not retain two complete spatial indexes for '
          'the same shared document',
    );
    for (var index = 0; index < 40; index++) {
      final participant = index.isEven ? fixture.left : fixture.right;
      participant.execute(
        AddStrokeAndRegroupCommand(
          pageId: pageId,
          stroke: _stroke('participant-$index', 20.0 + index * 30),
          grouping: participant.groupingEngine,
        ),
      );
    }

    expect(fixture.left.page.strokes, hasLength(40));
    expect(fixture.left.groupingEngine.cachedPageCount, 1);
    expect(
      fixture.left.groupingEngine.debugGroupIndexRebuildCount,
      1,
      reason:
          'alternating participants must advance one shared page index instead '
          'of rebuilding both complete stroke sets',
    );
  });

  test('new pages are global but only their creator navigates', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final originalPageId = fixture.left.page.id;

    fixture.right.addPage();
    final createdPageId = fixture.right.page.id;

    expect(fixture.left.document.pages, hasLength(2));
    expect(fixture.left.page.id, originalPageId);
    expect(fixture.right.page.id, createdPageId);

    fixture.left.nextPage();
    expect(fixture.left.page.id, createdPageId);
    expect(fixture.right.page.id, createdPageId);

    fixture.right.addPage();
    final thirdPageId = fixture.right.page.id;
    expect(fixture.left.document.pages, hasLength(3));
    expect(fixture.left.page.id, createdPageId);
    expect(fixture.right.page.id, thirdPageId);
  });

  test('page deletion keeps participant navigation local and stable', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final firstPageId = fixture.left.page.id;

    fixture.left.addPage();
    final secondPageId = fixture.left.page.id;
    fixture.left.addPage();
    final thirdPageId = fixture.left.page.id;
    fixture.left.goToPage(0);
    fixture.right.goToPage(1);

    expect(fixture.right.deletePage(secondPageId), isTrue);
    expect(fixture.left.document.pages.map((page) => page.id), <String>[
      firstPageId,
      thirdPageId,
    ]);
    expect(fixture.left.page.id, firstPageId);
    expect(
      fixture.right.page.id,
      thirdPageId,
      reason: 'the deleting participant should advance to the local neighbour',
    );

    // Removing a page currently displayed by the other participant repairs
    // that view to its nearest surviving slot rather than the global page.
    expect(fixture.left.deletePage(thirdPageId), isTrue);
    expect(fixture.left.page.id, firstPageId);
    expect(fixture.right.page.id, firstPageId);
  });

  test('the final whiteboard page cannot be deleted', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final onlyPageId = fixture.left.page.id;

    expect(fixture.left.deletePage(onlyPageId), isFalse);
    expect(fixture.left.document.pages, hasLength(1));
    expect(
      fixture.left.lastError,
      'Die letzte verbleibende Seite kann nicht gelöscht werden.',
    );
  });

  test('deleting the owner page restores the neighbour viewport', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    const expectedOffset = Offset(-120, 75);
    fixture.left.viewport.restore(scale: 1.6, offset: expectedOffset);
    fixture.left.commitViewport();

    fixture.left.addPage();
    final secondPageId = fixture.left.page.id;
    fixture.left.viewport.restore(scale: 2.2, offset: const Offset(300, -180));

    expect(fixture.left.deletePage(secondPageId), isTrue);
    expect(fixture.left.viewport.scale, 1.6);
    expect(fixture.left.viewport.offset, expectedOffset);
  });

  test('independent page deletion restores its local neighbour viewport', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    fixture.left.addPage();
    final secondPageId = fixture.left.page.id;

    const expectedOffset = Offset(-70, 44);
    fixture.right.viewport.restore(scale: 1.45, offset: expectedOffset);
    fixture.right.goToPage(1);
    fixture.right.viewport.restore(scale: 2.1, offset: const Offset(210, -90));

    expect(fixture.right.deletePage(secondPageId), isTrue);
    expect(fixture.right.viewport.scale, 1.45);
    expect(fixture.right.viewport.offset, expectedOffset);
  });

  test('split activation synchronizes page and camera from solo view', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final originalPageId = fixture.left.page.id;

    fixture.left.addPage();
    final soloPageId = fixture.left.page.id;
    fixture.left.viewport.restore(scale: 1.65, offset: const Offset(-240, 135));
    expect(fixture.right.page.id, originalPageId);

    fixture.right.synchronizeParticipantViewFrom(fixture.left);
    expect(fixture.right.page.id, soloPageId);
    expect(fixture.right.viewport.scale, 1.65);
    expect(fixture.right.viewport.offset, const Offset(-240, 135));

    fixture.right.previousPage();
    expect(fixture.right.page.id, originalPageId);
    expect(fixture.left.page.id, soloPageId);

    fixture.right.synchronizeParticipantViewFrom(fixture.left);
    expect(fixture.right.page.id, soloPageId);
  });

  test('right undo and redo never restore the stale solo camera', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    fixture.right.synchronizeParticipantViewFrom(fixture.left);
    fixture.right.viewport.alignToHorizontalPartition(
      viewportSize: const Size(1000, 700),
      visibleScreenBounds: const Rect.fromLTWH(500, 0, 500, 700),
      horizontalConstraint: const BoardViewportHorizontalConstraint(
        side: BoardViewportPartitionSide.right,
        worldBoundaryX: 960,
      ),
    );
    final expectedScale = fixture.right.viewport.scale;
    final expectedOffset = fixture.right.viewport.offset;
    expect(expectedOffset, isNot(Offset.zero));

    fixture.right.execute(
      AddStrokeCommand(
        fixture.right.page.id,
        _stroke('right-camera-regression', 1120),
      ),
    );
    fixture.right.undo();
    expect(fixture.right.viewport.scale, expectedScale);
    expect(fixture.right.viewport.offset, expectedOffset);

    fixture.right.redo();
    expect(fixture.right.viewport.scale, expectedScale);
    expect(fixture.right.viewport.offset, expectedOffset);
  });

  test('foreign commits do not replay every accumulated eraser sweep', () {
    final fixture = _ParticipantFixture();
    addTearDown(fixture.dispose);
    final pageId = fixture.left.page.id;
    fixture.left.execute(
      AddStrokeCommand(
        pageId,
        InkStroke(
          id: 'eraser-target',
          points: const <InkPoint>[
            InkPoint(x: 100, y: 100),
            InkPoint(x: 700, y: 100),
          ],
          width: 8,
          authorId: 'left',
        ),
      ),
    );

    for (var index = 0; index < 40; index++) {
      final x = 120.0 + index * 5;
      fixture.left.eraseAlong(Offset(x, 100), Offset(x + 4, 100), radius: 8);
    }
    expect(fixture.left.debugErasePreviewReplayCount, 0);

    fixture.right.execute(
      AddStrokeCommand(pageId, _stroke('right-during-erase', 1100)),
    );

    expect(
      fixture.left.debugErasePreviewReplayCount,
      0,
      reason: 'a remote pen-up must not replay the complete growing gesture',
    );
    fixture.left.commitErase();
    expect(
      fixture.left.debugErasePreviewReplayCount,
      0,
      reason:
          'an append is incorporated incrementally and needs no full replay',
    );
    expect(
      fixture.left.page.strokes.any(
        (stroke) => stroke.id == 'right-during-erase',
      ),
      isTrue,
    );
    expect(
      fixture.left.page.strokes.any((stroke) => stroke.id == 'eraser-target'),
      isTrue,
    );
  });
}

InkStroke _stroke(String id, double x) => InkStroke(
  id: id,
  points: <InkPoint>[
    InkPoint(x: x, y: 40),
    InkPoint(x: x + 20, y: 60),
  ],
  width: 8,
  authorId: id.startsWith('left') ? 'left' : 'right',
);

final class _ParticipantFixture {
  _ParticipantFixture() : repository = _MemoryRepository() {
    left = EditorController(
      document: WhiteboardDocument.create(id: 'participant-history'),
      repository: repository,
      assetDirectory: Directory.current,
    );
    right = EditorController.participantView(left, participantId: 'right');
  }

  final _MemoryRepository repository;
  late EditorController left;
  late EditorController right;

  Future<void> dispose() async {
    await right.close();
    right.dispose();
    await left.close();
    left.dispose();
  }
}

final class _MemoryRepository implements DocumentRepository {
  WhiteboardDocument? document;

  @override
  Future<Directory> assetDirectory(String documentId) async =>
      Directory.current;

  @override
  Future<void> delete(String documentId) async => document = null;

  @override
  Future<List<DocumentSummary>> list() async => const <DocumentSummary>[];

  @override
  Future<WhiteboardDocument?> load(String documentId) async => document;

  @override
  Future<WhiteboardDocument?> recover(String documentId) async => document;

  @override
  Future<void> save(WhiteboardDocument document) async {
    this.document = document;
  }
}
