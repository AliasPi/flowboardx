import 'dart:io';

import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/commands/document_commands.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
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
