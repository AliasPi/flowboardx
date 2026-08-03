import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowboard_x/src/data/data.dart';
import 'package:flowboard_x/src/domain/domain.dart';

void main() {
  test('coalesces changes and flushes the newest document', () async {
    final repository = _MemoryRepository();
    final base = WhiteboardDocument.create(id: 'doc', now: DateTime.utc(2026));
    final autosave = AutosaveController(
      repository,
      base.id,
      debounce: const Duration(seconds: 1),
    );
    autosave.schedule(base.copyWith(title: 'one', revision: 1));
    autosave.schedule(base.copyWith(title: 'two', revision: 2));
    autosave.schedule(base.copyWith(title: 'three', revision: 3));

    await autosave.flush();

    expect(repository.saved, hasLength(1));
    expect(repository.saved.single.title, 'three');
    expect(autosave.hasPendingChanges, isFalse);
    await autosave.dispose();
  });

  test('retains a failed save for an explicit retry', () async {
    final repository = _MemoryRepository()..failuresRemaining = 1;
    final document = WhiteboardDocument.create(
      id: 'doc',
      now: DateTime.utc(2026),
    );
    final autosave = AutosaveController(repository, document.id);
    autosave.schedule(document);

    await expectLater(autosave.flush(), throwsStateError);
    expect(autosave.hasPendingChanges, isTrue);
    await Future<void>.delayed(Duration.zero);
    await autosave.flush();

    expect(repository.saved.single.id, 'doc');
    expect(autosave.hasPendingChanges, isFalse);
    await autosave.dispose();
  });

  test(
    'retries a transient save failure without requiring another edit',
    () async {
      final repository = _MemoryRepository()..failuresRemaining = 1;
      final document = WhiteboardDocument.create(
        id: 'automatic-retry',
        now: DateTime.utc(2026),
      );
      final autosave = AutosaveController(
        repository,
        document.id,
        debounce: const Duration(milliseconds: 1),
        retryBaseDelay: const Duration(milliseconds: 5),
        retryMaximumDelay: const Duration(milliseconds: 20),
      );

      autosave.schedule(document);
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (repository.saved.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(repository.saved.single.id, document.id);
      expect(autosave.hasPendingChanges, isFalse);
      await autosave.dispose();
    },
  );

  test('dispose without flushing cancels a scheduled retry', () async {
    final repository = _MemoryRepository()..failuresRemaining = 10;
    final document = WhiteboardDocument.create(
      id: 'cancel-retry',
      now: DateTime.utc(2026),
    );
    final autosave = AutosaveController(
      repository,
      document.id,
      debounce: const Duration(milliseconds: 1),
      retryBaseDelay: const Duration(milliseconds: 80),
      retryMaximumDelay: const Duration(milliseconds: 80),
    );

    autosave.schedule(document);
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (repository.saveAttempts == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(repository.saveAttempts, 1);

    await autosave.dispose(flushPending: false);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(repository.saveAttempts, 1);
    expect(autosave.hasPendingChanges, isFalse);
  });

  test('hard latency saves even while changes keep arriving', () async {
    final repository = _MemoryRepository();
    final base = WhiteboardDocument.create(id: 'doc', now: DateTime.utc(2026));
    final autosave = AutosaveController(
      repository,
      base.id,
      debounce: const Duration(seconds: 5),
      maxLatency: const Duration(milliseconds: 30),
    );
    for (var revision = 1; revision <= 6; revision++) {
      autosave.schedule(base.copyWith(revision: revision));
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (repository.saved.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(repository.saved, isNotEmpty);
    await autosave.dispose();
  });

  test('never starts a full save during latency-sensitive ink input', () async {
    final repository = _MemoryRepository();
    final base = WhiteboardDocument.create(
      id: 'interactive',
      now: DateTime.utc(2026),
    );
    final autosave = AutosaveController(
      repository,
      base.id,
      debounce: const Duration(milliseconds: 1),
      maxLatency: const Duration(milliseconds: 12),
      interactionIdleDelay: const Duration(milliseconds: 15),
    );

    autosave.beginInteraction();
    autosave.schedule(base.copyWith(revision: 1));
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(
      repository.saveAttempts,
      0,
      reason: 'document encoding must not compete with active stylus frames',
    );

    autosave.endInteraction();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(repository.saved.single.revision, 1);
    await autosave.dispose();
  });

  test(
    'queued pointer-down cancels save before repository snapshot work',
    () async {
      final repository = _MemoryRepository();
      final document = WhiteboardDocument.create(
        id: 'preflight-race',
        now: DateTime.utc(2026),
      );
      final autosave = AutosaveController(
        repository,
        document.id,
        debounce: Duration.zero,
        interactionIdleDelay: const Duration(milliseconds: 15),
      );

      autosave.schedule(document);
      Timer.run(autosave.beginInteraction);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        repository.saveAttempts,
        0,
        reason: 'queued input must win before an isolate snapshot is captured',
      );

      autosave.endInteraction();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(repository.saved.single.id, document.id);
      await autosave.dispose();
    },
  );

  test(
    'lifecycle flush remains durable during an active interaction',
    () async {
      final repository = _MemoryRepository();
      final document = WhiteboardDocument.create(
        id: 'interactive-flush',
        now: DateTime.utc(2026),
      );
      final autosave = AutosaveController(repository, document.id);

      autosave.beginInteraction();
      autosave.schedule(document);
      await autosave.flush();

      expect(repository.saved.single.id, document.id);
      autosave.endInteraction();
      await autosave.dispose();
    },
  );
}

final class _MemoryRepository implements DocumentRepository {
  final List<WhiteboardDocument> saved = [];
  int failuresRemaining = 0;
  int saveAttempts = 0;

  @override
  Future<void> save(WhiteboardDocument document) async {
    saveAttempts++;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('simulierter Schreibfehler');
    }
    saved.add(document);
  }

  @override
  Future<void> delete(String documentId) async {}

  @override
  Future<WhiteboardDocument?> load(String documentId) async =>
      saved.where((document) => document.id == documentId).lastOrNull;

  @override
  Future<WhiteboardDocument?> recover(String documentId) => load(documentId);

  @override
  Future<List<DocumentSummary>> list() async =>
      saved.map(DocumentSummary.fromDocument).toList();

  @override
  Future<Directory> assetDirectory(String documentId) =>
      Directory.systemTemp.createTemp('flowboard_assets_');
}
