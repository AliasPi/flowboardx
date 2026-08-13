import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowboard_x/src/data/data.dart';
import 'package:flowboard_x/src/domain/domain.dart';

void main() {
  late Directory temporary;
  late FileDocumentRepository repository;
  final timestamp = DateTime.utc(2026, 7, 21);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'flowboard_repository_test_',
    );
    repository = FileDocumentRepository(temporary);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'atomically saves, loads, lists and deletes documents with assets',
    () async {
      final document = WhiteboardDocument.create(
        id: 'doc / ü',
        title: 'Physik',
        now: timestamp,
      );

      await repository.save(document);
      final loaded = await repository.load(document.id);
      final summaries = await repository.list();
      final assets = await repository.assetDirectory(document.id);

      expect(loaded?.title, 'Physik');
      expect(summaries.single.id, document.id);
      expect(summaries.single.pageCount, 1);
      expect(await repository.documentFileFor(document.id).exists(), isTrue);
      expect(await repository.summaryFileFor(document.id).exists(), isTrue);
      expect(await assets.exists(), isTrue);
      final transactionArtifacts = await repository
          .documentDirectory(document.id)
          .list()
          .where(
            (entity) => entity.uri.pathSegments.last.startsWith(
              'document.flowboard.pending.',
            ),
          )
          .toList();
      expect(
        transactionArtifacts,
        isEmpty,
        reason: 'a completed save must not retain a full pending payload',
      );

      await repository.delete(document.id);
      expect(await repository.load(document.id), isNull);
    },
  );

  test('keeps list metadata compact for ink-heavy documents', () async {
    final base = WhiteboardDocument.create(
      id: 'large-summary',
      title: 'Große Tafel',
      now: timestamp,
    );
    final points = List<InkPoint>.generate(
      6000,
      (index) => InkPoint(
        x: index / 3,
        y: (index % 79).toDouble(),
        timestampMicros: index * 1000,
      ),
      growable: false,
    );
    final document = base.replacePage(
      base.currentPage.copyWith(
        strokes: <InkStroke>[
          InkStroke(id: 'long-stroke', points: points, createdAt: timestamp),
        ],
      ),
      now: timestamp.add(const Duration(seconds: 1)),
    );

    await repository.save(document);

    final primaryLength = await repository
        .documentFileFor(document.id)
        .length();
    final summaryFile = repository.summaryFileFor(document.id);
    final summaryLength = await summaryFile.length();
    final summaryJson =
        jsonDecode(await summaryFile.readAsString()) as Map<String, Object?>;
    final diagnostics = repository.lastSaveDiagnostics;

    expect(primaryLength, greaterThan(200000));
    expect(summaryLength, lessThan(1024));
    expect(summaryLength * 250, lessThan(primaryLength));
    expect(summaryJson['documentId'], document.id);
    expect(summaryJson['pageCount'], 1);
    expect(summaryJson['revision'], 1);
    expect(diagnostics, isNotNull);
    expect(diagnostics!.payloadByteLength, primaryLength);
    expect(
      diagnostics.fullPayloadWrites,
      1,
      reason: 'journal and primary must not duplicate the full JSON write',
    );
    expect(diagnostics.usedBackgroundIsolate, isTrue);
    expect((await repository.list()).single.title, 'Große Tafel');
  });

  test(
    're-encodes only changed pages as a large document keeps growing',
    () async {
      final base = WhiteboardDocument.create(
        id: 'incremental-pages',
        title: 'Mehrseitige Tafel',
        now: timestamp,
      );
      final pages = List<BoardPage>.generate(12, (pageIndex) {
        final points = List<InkPoint>.generate(
          800,
          (pointIndex) => InkPoint(
            x: pointIndex / 2,
            y: pageIndex * 20 + (pointIndex % 41),
            timestampMicros: pointIndex * 1000,
          ),
          growable: false,
        );
        return BoardPage(
          id: 'page-$pageIndex',
          name: 'Seite ${pageIndex + 1}',
          strokes: <InkStroke>[
            InkStroke(
              id: 'stroke-$pageIndex',
              points: points,
              createdAt: timestamp,
            ),
          ],
        );
      }, growable: false);
      final document = base.copyWith(
        pages: pages,
        revision: 1,
        updatedAt: timestamp.add(const Duration(seconds: 1)),
      );

      await repository.save(document);
      expect(repository.lastSaveDiagnostics?.encodedPageCount, pages.length);
      expect(repository.lastSaveDiagnostics?.reusedPageCount, 0);

      final changedPage = pages[7].copyWith(
        strokes: <InkStroke>[
          ...pages[7].strokes,
          InkStroke(
            id: 'new-stroke',
            points: const <InkPoint>[
              InkPoint(x: 10, y: 10, timestampMicros: 1),
              InkPoint(x: 40, y: 40, timestampMicros: 2),
            ],
            createdAt: timestamp,
          ),
        ],
      );
      final updated = document.copyWith(
        title: 'Nur eine Seite geändert',
        pages: <BoardPage>[
          for (var index = 0; index < pages.length; index++)
            index == 7 ? changedPage : pages[index],
        ],
        revision: 2,
        updatedAt: timestamp.add(const Duration(seconds: 2)),
      );

      await repository.save(updated);

      final diagnostics = repository.lastSaveDiagnostics;
      expect(diagnostics?.encodedPageCount, 1);
      expect(diagnostics?.reusedPageCount, pages.length - 1);
      final loaded = await repository.load(updated.id);
      expect(
        loaded?.toJson(schemaVersion: DocumentMigrator.currentVersion),
        updated.toJson(schemaVersion: DocumentMigrator.currentVersion),
      );

      final metadataOnly = updated.copyWith(
        title: 'Nur Metadaten geändert',
        revision: 3,
        updatedAt: timestamp.add(const Duration(seconds: 3)),
      );
      await repository.save(metadataOnly);
      expect(repository.lastSaveDiagnostics?.encodedPageCount, 0);
      expect(repository.lastSaveDiagnostics?.reusedPageCount, pages.length);
      expect(
        (await repository.load(metadataOnly.id))?.title,
        metadataOnly.title,
      );
    },
  );

  test('successful save removes only orphan transaction payloads', () async {
    final document = WhiteboardDocument.create(
      id: 'orphan-cleanup',
      now: timestamp,
    );
    final directory = repository.documentDirectory(document.id);
    await directory.create(recursive: true);
    final orphan = File(
      '${directory.path}${Platform.pathSeparator}'
      'document.flowboard.pending.1.2.3.json',
    );
    final orphanTemporary = File(
      '${directory.path}${Platform.pathSeparator}'
      'document.flowboard.pending.4.5.6.json.tmp.7.8',
    );
    final unrelatedAsset = File(
      '${directory.path}${Platform.pathSeparator}'
      'assets.pending.1.2.3.json',
    );
    await orphan.writeAsString('obsolete');
    await orphanTemporary.writeAsString('obsolete');
    await unrelatedAsset.writeAsString('keep');

    await repository.save(document);

    expect(await orphan.exists(), isFalse);
    expect(await orphanTemporary.exists(), isFalse);
    expect(await unrelatedAsset.exists(), isTrue);
    expect((await repository.load(document.id))?.id, document.id);
  });

  test('list backfills a missing legacy summary cache', () async {
    final document = WhiteboardDocument.create(
      id: 'legacy-summary',
      title: 'Bestand',
      now: timestamp,
    );
    await repository.save(document);
    final cache = repository.summaryFileFor(document.id);
    await cache.delete();

    final summaries = await repository.list();

    expect(summaries.single.title, 'Bestand');
    expect(await cache.exists(), isTrue);
  });

  test(
    'list invalidates stale metadata and refreshes it from primary',
    () async {
      final document = WhiteboardDocument.create(
        id: 'stale-summary',
        title: 'Alt',
        now: timestamp,
      );
      await repository.save(document);
      final externallyUpdated = document.copyWith(
        title: 'Extern aktualisiert und dadurch länger',
        revision: 7,
        updatedAt: timestamp.add(const Duration(hours: 2)),
      );
      await repository
          .documentFileFor(document.id)
          .writeAsString(const DocumentCodec().encode(externallyUpdated));

      final summary = (await repository.list()).single;
      final cachedJson =
          jsonDecode(
                await repository.summaryFileFor(document.id).readAsString(),
              )
              as Map<String, Object?>;

      expect(summary.title, externallyUpdated.title);
      expect(summary.revision, 7);
      expect(cachedJson['title'], externallyUpdated.title);
      expect(cachedJson['revision'], 7);
    },
  );

  test(
    'a failed disposable summary refresh never fails a document save',
    () async {
      final original = WhiteboardDocument.create(
        id: 'summary-promotion',
        title: 'Alt',
        now: timestamp,
      );
      await repository.save(original);
      final cache = repository.summaryFileFor(original.id);
      await cache.delete();
      await Directory(cache.path).create();
      final updated = original.copyWith(
        title: 'Neu',
        revision: 1,
        updatedAt: timestamp.add(const Duration(minutes: 1)),
      );

      await repository.save(updated);

      expect(await repository.journalFileFor(original.id).exists(), isFalse);
      expect((await repository.load(original.id))?.title, 'Neu');
      expect((await repository.list()).single.title, 'Neu');

      await Directory(cache.path).delete();
      expect(await cache.exists(), isFalse);
      expect((await repository.list()).single.title, 'Neu');

      expect(await cache.exists(), isTrue);
    },
  );

  test('serializes concurrent saves in invocation order', () async {
    final base = WhiteboardDocument.create(id: 'ordered', now: timestamp);
    final saves = <Future<void>>[];
    for (var revision = 1; revision <= 8; revision++) {
      saves.add(
        repository.save(
          base.copyWith(
            title: 'Revision $revision',
            revision: revision,
            updatedAt: timestamp.add(Duration(seconds: revision)),
          ),
        ),
      );
    }
    await Future.wait(saves);

    final loaded = await repository.load(base.id);
    expect(loaded?.revision, 8);
    expect(loaded?.title, 'Revision 8');
  });

  test(
    'recovers the newest valid journal and promotes it to primary',
    () async {
      const codec = DocumentCodec();
      final primary = WhiteboardDocument.create(
        id: 'recover',
        now: timestamp,
      ).copyWith(revision: 1);
      final journalDocument = primary.copyWith(
        title: 'Nicht verlorene Stunde',
        revision: 2,
        updatedAt: timestamp.add(const Duration(minutes: 1)),
      );
      await repository.save(primary);
      final payload = codec.encode(journalDocument);
      await repository
          .journalFileFor(primary.id)
          .writeAsString(
            jsonEncode({
              'journalVersion': 1,
              'documentId': primary.id,
              'revision': 2,
              'updatedAt': journalDocument.updatedAt.toIso8601String(),
              'checksum': checksum(payload),
              'payload': payload,
            }),
            flush: true,
          );

      final recovered = await repository.recover(primary.id);
      final reloaded = await repository.load(primary.id);

      expect(recovered?.revision, 2);
      expect(recovered?.title, 'Nicht verlorene Stunde');
      expect(recovered?.metadata.recoveredFromCrash, isTrue);
      expect(reloaded?.revision, 2);
      expect(await repository.journalFileFor(primary.id).exists(), isFalse);
    },
  );

  test(
    'writes one pending payload and recovers it after promotion fails',
    () async {
      final primary = WhiteboardDocument.create(
        id: 'journal-v2',
        title: 'Gespeichert',
        now: timestamp,
      );
      final pending = primary.copyWith(
        title: 'Noch nicht verloren',
        revision: 2,
        updatedAt: timestamp.add(const Duration(minutes: 2)),
      );
      await repository.save(primary);

      // A directory at the backup file path makes the primary promotion fail
      // after the new journal has been atomically written.
      final backupBlocker = Directory(
        repository.backupFileFor(primary.id).path,
      );
      await backupBlocker.create();
      await expectLater(repository.save(pending), throwsA(anything));

      final journal = repository.journalFileFor(primary.id);
      final source = await journal.readAsString();
      final header = jsonDecode(source) as Map<String, Object?>;
      final pendingFile = await repository.pendingPayloadFileFor(primary.id);
      expect(header['journalVersion'], 3);
      expect(header.containsKey('payload'), isFalse);
      expect(header['payloadStorage'], 'pending-file');
      expect(header['payloadFile'], pendingFile?.uri.pathSegments.last);
      expect(pendingFile, isNotNull);
      expect(await pendingFile!.exists(), isTrue);
      final payload = await pendingFile.readAsString();
      expect(header['payloadByteLength'], utf8.encode(payload).length);
      expect(header['checksum'], checksum(payload));
      expect(
        source.length,
        lessThan(512),
        reason: 'The journal is only a compact durable commit marker.',
      );
      expect(
        const DocumentCodec().decode(payload).title,
        'Noch nicht verloren',
      );

      await backupBlocker.delete();
      final recovered = await repository.recover(primary.id);

      expect(recovered?.revision, 2);
      expect(recovered?.title, 'Noch nicht verloren');
      expect(recovered?.metadata.recoveredFromCrash, isTrue);
      expect(await journal.exists(), isFalse);
      expect(await pendingFile.exists(), isFalse);
    },
  );

  test('keeps raw-payload v2 journals backward compatible', () async {
    final primary = WhiteboardDocument.create(
      id: 'journal-v2-compatibility',
      title: 'Alt',
      now: timestamp,
    );
    final pending = primary.copyWith(
      title: 'Aus v2 gerettet',
      revision: 4,
      updatedAt: timestamp.add(const Duration(minutes: 4)),
    );
    await repository.save(primary);
    final payload = const DocumentCodec().encode(pending);
    final header = jsonEncode({
      'journalVersion': 2,
      'documentId': pending.id,
      'revision': pending.revision,
      'updatedAt': pending.updatedAt.toIso8601String(),
      'payloadEncoding': 'utf-8-json',
      'payloadByteLength': utf8.encode(payload).length,
      'checksum': checksum(payload),
    });
    await repository
        .journalFileFor(primary.id)
        .writeAsString('$header\n$payload', flush: true);

    final recovered = await repository.recover(primary.id);

    expect(recovered?.title, 'Aus v2 gerettet');
    expect(recovered?.revision, 4);
    expect(recovered?.metadata.recoveredFromCrash, isTrue);
  });

  test(
    'accepts a v3 commit marker after its payload was promoted already',
    () async {
      final document = WhiteboardDocument.create(
        id: 'journal-v3-promoted',
        title: 'Bereits atomar verschoben',
        now: timestamp,
      ).copyWith(revision: 3);
      await repository.save(document);
      final primary = repository.documentFileFor(document.id);
      final payload = await primary.readAsString();
      const promotedPendingName = 'document.flowboard.pending.1.2.3.json';
      await repository
          .journalFileFor(document.id)
          .writeAsString(
            jsonEncode({
              'journalVersion': 3,
              'documentId': document.id,
              'revision': document.revision,
              'updatedAt': document.updatedAt.toIso8601String(),
              'payloadStorage': 'pending-file',
              'payloadFile': promotedPendingName,
              'payloadByteLength': utf8.encode(payload).length,
              'checksum': checksum(payload),
            }),
            flush: true,
          );

      final recovered = await repository.recover(document.id);

      expect(recovered?.title, document.title);
      expect(recovered?.revision, document.revision);
      expect(recovered?.metadata.recoveredFromCrash, isFalse);
      expect(await repository.journalFileFor(document.id).exists(), isFalse);
      expect(
        await File(
          '${repository.documentDirectory(document.id).path}'
          '${Platform.pathSeparator}$promotedPendingName',
        ).exists(),
        isFalse,
      );
    },
  );

  test('falls back to backup when the primary is corrupt', () async {
    final first = WhiteboardDocument.create(
      id: 'backup',
      title: 'Sicher',
      now: timestamp,
    );
    await repository.save(first);
    await repository.save(
      first.copyWith(
        title: 'Neu',
        revision: 1,
        updatedAt: timestamp.add(const Duration(minutes: 1)),
      ),
    );
    await repository
        .documentFileFor(first.id)
        .writeAsString('{broken', flush: true);

    await expectLater(
      repository.load(first.id),
      throwsA(isA<DocumentStorageException>()),
    );
    final damagedSummary = (await repository.list()).single;
    expect(damagedSummary.title, 'Sicher');
    expect(damagedSummary.recoveryAvailable, isTrue);
    final recovered = await repository.recover(first.id);

    expect(recovered?.title, 'Sicher');
    expect(recovered?.metadata.recoveredFromCrash, isTrue);
    expect((await repository.load(first.id))?.title, 'Sicher');
  });

  test(
    'trash move and restore preserve assets backup journal and folder metadata',
    () async {
      final deletedAt = timestamp.add(const Duration(hours: 3));
      repository = FileDocumentRepository(
        temporary,
        useBackgroundIsolate: false,
        clock: () => deletedAt,
      );
      final original = WhiteboardDocument.create(
        id: 'trash-complete-directory',
        title: 'Erste Fassung',
        now: timestamp,
      );
      final current = original.copyWith(
        title: 'Gespeicherte Fassung',
        revision: 1,
        updatedAt: timestamp.add(const Duration(minutes: 1)),
      );
      final journalDocument = current.copyWith(
        title: 'Noch nicht verlorene Fassung',
        revision: 2,
        updatedAt: timestamp.add(const Duration(minutes: 2)),
      );
      await repository.save(original);
      await repository.save(current);
      final asset = File(
        '${(await repository.assetDirectory(original.id)).path}'
        '${Platform.pathSeparator}photo.bin',
      );
      await asset.writeAsBytes(<int>[0, 17, 128, 255], flush: true);
      final payload = const DocumentCodec().encode(journalDocument);
      await repository
          .journalFileFor(original.id)
          .writeAsString(
            jsonEncode(<String, Object?>{
              'journalVersion': 1,
              'documentId': original.id,
              'revision': journalDocument.revision,
              'updatedAt': journalDocument.updatedAt.toIso8601String(),
              'checksum': checksum(payload),
              'payload': payload,
            }),
            flush: true,
          );
      final backupBytes = await repository
          .backupFileFor(original.id)
          .readAsBytes();
      final journalBytes = await repository
          .journalFileFor(original.id)
          .readAsBytes();
      final assetBytes = await asset.readAsBytes();

      final trashed = await repository.moveToTrash(
        original.id,
        originalFolderId: 'folder-a',
      );

      expect(trashed.deletedAt, deletedAt);
      expect(trashed.originalFolderId, 'folder-a');
      expect(trashed.title, journalDocument.title);
      expect(await repository.documentDirectory(original.id).exists(), isFalse);
      expect((await repository.list()), isEmpty);
      expect((await repository.listTrashed()).single.id, original.id);
      final trashDirectory = repository.trashDocumentDirectory(original.id);
      expect(
        await File(
          '${trashDirectory.path}${Platform.pathSeparator}'
          'document.flowboard.backup.json',
        ).readAsBytes(),
        backupBytes,
      );
      expect(
        await File(
          '${trashDirectory.path}${Platform.pathSeparator}'
          'document.flowboard.journal.json',
        ).readAsBytes(),
        journalBytes,
      );
      expect(
        await File(
          '${trashDirectory.path}${Platform.pathSeparator}'
          'assets${Platform.pathSeparator}photo.bin',
        ).readAsBytes(),
        assetBytes,
      );

      final restored = await repository.restoreFromTrash(original.id);

      expect(restored.document.title, journalDocument.title);
      expect(restored.recoveryAvailable, isTrue);
      expect(restored.originalFolderId, 'folder-a');
      expect(await trashDirectory.exists(), isFalse);
      expect(
        await repository.backupFileFor(original.id).readAsBytes(),
        backupBytes,
      );
      expect(
        await repository.journalFileFor(original.id).readAsBytes(),
        journalBytes,
      );
      expect(await asset.readAsBytes(), assetBytes);
      expect((await repository.list()).single.recoveryAvailable, isTrue);
    },
  );

  test('restore collision leaves trash source complete', () async {
    final original = WhiteboardDocument.create(
      id: 'trash-collision',
      title: 'Im Papierkorb',
      now: timestamp,
    );
    await repository.save(original);
    await repository.moveToTrash(original.id);
    final trashPrimary = File(
      '${repository.trashDocumentDirectory(original.id).path}'
      '${Platform.pathSeparator}document.flowboard.json',
    );
    final trashBytes = await trashPrimary.readAsBytes();
    final active = original.copyWith(
      title: 'Aktive Kollision',
      revision: 7,
      updatedAt: timestamp.add(const Duration(hours: 1)),
    );
    // Simulate an externally created legacy/corrupt collision. Normal
    // repository saves are intentionally blocked by the trash tombstone.
    final activeDirectory = repository.documentDirectory(original.id);
    await activeDirectory.create(recursive: true);
    await repository
        .documentFileFor(original.id)
        .writeAsString(const DocumentCodec().encode(active), flush: true);

    await expectLater(
      repository.restoreFromTrash(original.id),
      throwsA(isA<DocumentStorageException>()),
    );

    expect((await repository.load(original.id))?.title, 'Aktive Kollision');
    expect(await trashPrimary.readAsBytes(), trashBytes);
    expect((await repository.listTrashed()).single.title, 'Im Papierkorb');

    await repository.deletePermanentlyFromTrash(original.id);

    expect(
      await repository.trashDocumentDirectory(original.id).exists(),
      isFalse,
    );
    expect((await repository.load(original.id))?.title, 'Aktive Kollision');
  });

  test(
    'trash tombstone blocks save and asset ghosts but permits queued restore',
    () async {
      final original = WhiteboardDocument.create(
        id: 'trash-tombstone',
        title: 'Im Papierkorb',
        now: timestamp,
      );
      await repository.save(original);
      await repository.moveToTrash(original.id);
      final replacement = original.copyWith(
        title: 'Darf nicht als Ghost entstehen',
        revision: 4,
        updatedAt: timestamp.add(const Duration(hours: 1)),
      );

      await expectLater(
        repository.save(replacement),
        throwsA(isA<DocumentStorageException>()),
      );
      await expectLater(
        repository.assetDirectory(original.id),
        throwsA(isA<DocumentStorageException>()),
      );
      expect(await repository.documentDirectory(original.id).exists(), isFalse);
      expect(
        await repository.trashDocumentDirectory(original.id).exists(),
        isTrue,
      );

      // Creator rollbacks use the legacy active-document delete operation.
      // It must never consume the tombstone that caused creation to abort.
      await repository.delete(original.id);
      expect(
        await repository.trashDocumentDirectory(original.id).exists(),
        isTrue,
      );

      // restoreFromTrash owns the same ID lock. Operations queued during its
      // rename window observe the post-restore state and are allowed.
      final restore = repository.restoreFromTrash(original.id);
      final save = repository.save(replacement);
      final assets = repository.assetDirectory(original.id);
      final results = await Future.wait<Object>(<Future<Object>>[
        restore,
        save.then<Object>((_) => true),
        assets,
      ]);

      expect(results.first, isA<RestoredTrashDocument>());
      expect((await repository.load(original.id))?.title, replacement.title);
      expect((results.last as Directory).existsSync(), isTrue);
      expect(
        await repository.trashDocumentDirectory(original.id).exists(),
        isFalse,
      );
    },
  );

  test('trash-root creation failure removes pre-rename sidecars', () async {
    final document = WhiteboardDocument.create(
      id: 'trash-root-blocked',
      title: 'Bleibt aktiv',
      now: timestamp,
    );
    await repository.save(document);
    await File(
      repository.trashDirectory.path,
    ).writeAsString('blocks directory creation', flush: true);
    final activeDirectory = repository.documentDirectory(document.id);
    final sidecar = File(
      '${activeDirectory.path}${Platform.pathSeparator}'
      'document.flowboard.trash.json',
    );
    final sidecarBackup = File(
      '${activeDirectory.path}${Platform.pathSeparator}'
      'document.flowboard.trash.backup.json',
    );

    await expectLater(
      repository.moveToTrash(document.id),
      throwsA(isA<DocumentStorageException>()),
    );

    expect(await activeDirectory.exists(), isTrue);
    expect((await repository.load(document.id))?.title, 'Bleibt aktiv');
    expect(await sidecar.exists(), isFalse);
    expect(await sidecarBackup.exists(), isFalse);
  });

  test('lists metadata-less and corrupt trash directories', () async {
    final document = WhiteboardDocument.create(
      id: 'trash-without-metadata',
      title: 'Aus Dokument gelesen',
      now: timestamp,
    );
    await repository.save(document);
    await repository.moveToTrash(document.id);
    await repository.trashMetadataFileFor(document.id).delete();
    final corruptDirectory = repository.trashDocumentDirectory('corrupt-entry');
    await corruptDirectory.create(recursive: true);
    await File(
      '${corruptDirectory.path}${Platform.pathSeparator}'
      'document.flowboard.json',
    ).writeAsString('{broken', flush: true);

    final trashed = await repository.listTrashed();

    final readable = trashed.singleWhere((item) => item.id == document.id);
    final corrupt = trashed.singleWhere((item) => item.id == 'corrupt-entry');
    expect(readable.title, 'Aus Dokument gelesen');
    expect(readable.recoverable, isTrue);
    expect(readable.originalFolderId, isNull);
    expect(corrupt.title, 'Beschädigtes Dokument');
    expect(corrupt.pageCount, 0);
    expect(corrupt.recoverable, isFalse);
  });

  test('missing folder index keeps existing documents at the root', () async {
    final document = WhiteboardDocument.create(id: 'legacy', now: timestamp);
    await repository.save(document);

    final organization = await repository.loadOrganization();

    expect(organization.folders, isEmpty);
    expect(organization.documentFolderIds, isEmpty);
    expect((await repository.list()).single.id, document.id);
  });

  test(
    'atomically persists folder assignments and recovers its backup',
    () async {
      final first = LibraryFolder(
        id: 'folder-a',
        name: 'Mathematik',
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      final renamed = first.copyWith(
        name: 'Analysis',
        updatedAt: timestamp.add(const Duration(minutes: 1)),
      );
      await repository.saveOrganization(
        LibraryOrganization(
          folders: <LibraryFolder>[first],
          documentFolderIds: const <String, String>{'doc-a': 'folder-a'},
        ),
      );
      await repository.saveOrganization(
        LibraryOrganization(
          folders: <LibraryFolder>[renamed],
          documentFolderIds: const <String, String>{'doc-a': 'folder-a'},
        ),
      );
      await repository.organizationFile.writeAsString('{broken', flush: true);

      final recovered = await repository.loadOrganization();

      expect(recovered.folders.single.name, 'Mathematik');
      expect(recovered.documentFolderIds, {'doc-a': 'folder-a'});
    },
  );

  test(
    'normalization drops orphan assignments without losing folders',
    () async {
      final folder = LibraryFolder(
        id: 'kept',
        name: 'Klasse 7',
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      final normalized = LibraryOrganization(
        folders: <LibraryFolder>[folder],
        documentFolderIds: const <String, String>{
          'existing': 'kept',
          'orphan': 'missing-folder',
        },
      ).normalized(existingDocumentIds: const <String>{'existing'});

      expect(normalized.folders.single, same(folder));
      expect(normalized.documentFolderIds, {'existing': 'kept'});
    },
  );
}

String checksum(String source) {
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(source)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
