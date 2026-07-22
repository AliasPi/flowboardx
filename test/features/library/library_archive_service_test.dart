import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flowboard_x/src/data/document_repository.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/features/library/library_archive_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

void main() {
  late Directory temporary;
  late _ArchiveRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'flowboard-archive-test-',
    );
    repository = _ArchiveRepository(temporary);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'ZIP keeps equal document names collision-free and includes assets',
    () async {
      final first = WhiteboardDocument.create(id: 'first-id', title: 'Gleich');
      final second = WhiteboardDocument.create(
        id: 'second-id',
        title: 'Gleich',
      );
      repository.documents
        ..[first.id] = first
        ..[second.id] = second;
      await File(
        p.join((await repository.assetDirectory(first.id)).path, 'bild.png'),
      ).writeAsBytes(<int>[1, 2, 3]);
      final service = LibraryArchiveService(
        repository: repository,
        temporaryDirectoryProvider: () async => temporary,
        clock: () => DateTime.utc(2026, 7, 22, 12, 30),
      );

      final file = await service.createArchive(
        documentIds: <String>[first.id, second.id],
        collectionName: 'Klasse 7',
      );
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      final names = archive.files.map((entry) => entry.name).toList();

      expect(file.path, endsWith('.zip'));
      expect(names, contains('flowboard-bundle.json'));
      expect(
        names.where((name) => name.endsWith('document.flowboard.json')),
        hasLength(2),
      );
      expect(
        names.any((name) => name.contains('first-id/assets/bild.png')),
        isTrue,
      );
      expect(names.toSet(), hasLength(names.length));
    },
  );

  test(
    'createAndShare delegates exactly one finished ZIP to the platform',
    () async {
      final document = WhiteboardDocument.create(
        id: 'shared',
        title: 'Biologie',
      );
      repository.documents[document.id] = document;
      File? shared;
      final service = LibraryArchiveService(
        repository: repository,
        temporaryDirectoryProvider: () async => temporary,
        systemShare: (archive, _) async {
          shared = archive;
          expect(await archive.length(), greaterThan(0));
          return ShareResult('test', ShareResultStatus.success);
        },
      );

      final result = await service.createAndShare(
        documentIds: <String>['shared'],
      );

      expect(result.status, ShareResultStatus.success);
      expect(shared, isNotNull);
    },
  );

  test(
    'saveArchiveLocally copies to the chosen path and enforces ZIP suffix',
    () async {
      final document = WhiteboardDocument.create(id: 'local', title: 'Lokal');
      repository.documents[document.id] = document;
      final selectedPath = p.join(temporary.path, 'gespeichert', 'Klasse-9');
      final service = LibraryArchiveService(
        repository: repository,
        temporaryDirectoryProvider: () async => temporary,
        saveDestination: (suggestedName) async {
          expect(suggestedName, endsWith('.zip'));
          return selectedPath;
        },
      );
      final archive = await service.createArchive(
        documentIds: <String>['local'],
      );

      final saved = await service.saveArchiveLocally(archive);

      expect(saved, isNotNull);
      expect(saved!.path, '$selectedPath.zip');
      expect(await saved.readAsBytes(), await archive.readAsBytes());
    },
  );

  test('unavailable system share is reported as a storage error', () async {
    final archive = File(p.join(temporary.path, 'share.zip'));
    await archive.writeAsBytes(const <int>[1, 2, 3]);
    final service = LibraryArchiveService(
      repository: repository,
      systemShare: (_, _) async =>
          ShareResult('unavailable', ShareResultStatus.unavailable),
    );

    await expectLater(
      service.shareArchive(archive),
      throwsA(
        isA<DocumentStorageException>().having(
          (error) => error.message,
          'message',
          contains('nicht verfügbar'),
        ),
      ),
    );
  });
}

class _ArchiveRepository implements DocumentRepository {
  _ArchiveRepository(this.root);

  final Directory root;
  final Map<String, WhiteboardDocument> documents =
      <String, WhiteboardDocument>{};

  @override
  Future<Directory> assetDirectory(String documentId) async {
    final directory = Directory(p.join(root.path, documentId, 'assets'));
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<void> delete(String documentId) async => documents.remove(documentId);

  @override
  Future<List<DocumentSummary>> list() async => documents.values
      .map(DocumentSummary.fromDocument)
      .toList(growable: false);

  @override
  Future<WhiteboardDocument?> load(String documentId) async =>
      documents[documentId];

  @override
  Future<WhiteboardDocument?> recover(String documentId) async =>
      documents[documentId];

  @override
  Future<void> save(WhiteboardDocument document) async =>
      documents[document.id] = document;
}
