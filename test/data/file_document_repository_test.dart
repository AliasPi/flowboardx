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
      expect(await assets.exists(), isTrue);

      await repository.delete(document.id);
      expect(await repository.load(document.id), isNull);
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
    final recovered = await repository.recover(first.id);

    expect(recovered?.title, 'Sicher');
    expect(recovered?.metadata.recoveredFromCrash, isTrue);
    expect((await repository.load(first.id))?.title, 'Sicher');
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
