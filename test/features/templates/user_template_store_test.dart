import 'dart:io';

import 'package:flowboard_x/src/domain/domain.dart';
import 'package:flowboard_x/src/features/templates/templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;
  final timestamp = DateTime.utc(2026, 7, 22, 10, 30);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'flowboard_user_templates_test_',
    );
  });

  tearDown(() async {
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  UserTemplateStore createStore({
    DateTime Function()? clock,
    String Function()? uuid,
  }) => UserTemplateStore(
    directory: temporary,
    clock: clock ?? () => timestamp,
    uuid: uuid ?? () => 'template-1',
    useBackgroundIsolate: false,
  );

  test('empty store loads without creating files', () async {
    final store = createStore();

    expect(await store.load(), isEmpty);
    expect(await store.primaryFile.exists(), isFalse);
    expect(await store.backupFile.exists(), isFalse);
  });

  test('production background codec round-trips the template model', () async {
    final store = UserTemplateStore(
      directory: temporary,
      clock: () => timestamp,
      uuid: () => 'background-template',
    );

    await store.save(name: 'Isolate', page: _simplePage());

    expect((await store.load()).single.id, 'background-template');
  });

  test(
    'save and materialize preserve image/PDF files and annotations',
    () async {
      final generatedIds = <String>[
        'template-1',
        'document-image',
        'document-pdf',
      ].iterator;
      final store = createStore(
        uuid: () {
          generatedIds.moveNext();
          return generatedIds.current;
        },
      );
      final source = _mixedPage();
      final sourceDirectory = Directory('${temporary.path}/source-assets');
      await sourceDirectory.create();
      await File(
        '${sourceDirectory.path}/gleich.png',
      ).writeAsBytes([1, 2, 3, 4]);
      final nested = Directory('${sourceDirectory.path}/pdf')..createSync();
      await File('${nested.path}/gleich.pdf').writeAsBytes([5, 6, 7, 8, 9]);

      final saved = await store.save(
        name: '  Unterricht  ',
        page: source,
        sourceAssetDirectory: sourceDirectory,
        sourceAssets: [
          DocumentAsset(
            id: 'image-asset',
            type: DocumentAssetType.image,
            relativePath: 'gleich.png',
            mimeType: 'image/png',
            originalFileName: 'gleich.png',
          ),
          DocumentAsset(
            id: 'pdf-asset',
            type: DocumentAssetType.pdf,
            relativePath: 'pdf/gleich.pdf',
            mimeType: 'application/pdf',
            originalFileName: 'gleich.pdf',
          ),
        ],
      );
      final loaded = (await store.load()).single;

      expect(saved.id, 'template-1');
      expect(saved.name, 'Unterricht');
      expect(saved.createdAt, timestamp);
      expect(saved.page.id, 'user-template-template-1-page');
      expect(saved.page.name, 'Unterricht');
      expect(saved.page.viewport, const ViewportState());
      expect(saved.page.selection.isEmpty, isTrue);
      expect(saved.page.selection.mode, SelectionMode.direct);
      expect(saved.page.template, isNull);
      expect(saved.page.thumbnailAssetId, isNull);
      expect(saved.page.strokes.map((stroke) => stroke.id), ['free-ink']);
      expect(saved.page.strokes.single.pointerId, isNull);
      expect(
        saved.page.objects.map((object) => object.type),
        unorderedEquals([
          BoardObjectType.shape,
          BoardObjectType.image,
          BoardObjectType.pdf,
          BoardObjectType.table,
          BoardObjectType.cover,
          BoardObjectType.text,
        ]),
      );
      expect(saved.page.objects.whereType<ImageObject>(), hasLength(1));
      expect(saved.page.objects.whereType<PdfObject>(), hasLength(1));
      expect(saved.assets, hasLength(2));
      expect(saved.assets.map((asset) => asset.byteLength), [4, 5]);
      expect(saved.assets.map((asset) => asset.originalFileName), [
        'gleich.png',
        'gleich.pdf',
      ]);
      expect(
        saved.page.annotationLayers.map((layer) => layer.objectId),
        unorderedEquals(['shape', 'image', 'pdf', 'table']),
      );
      expect(
        saved.page.annotationFor('table')!.strokes.single.pointerId,
        isNull,
      );
      expect(
        saved.page.contentGroups.map((group) => group.id),
        unorderedEquals(['retained', 'media-only-after-filter']),
      );
      expect(saved.page.groups.single.strokeIds, ['free-ink']);

      expect(loaded.toJson(), saved.toJson());
      expect(source.objects.whereType<ImageObject>(), hasLength(1));
      expect(source.objects.whereType<PdfObject>(), hasLength(1));
      expect(source.selection.isEmpty, isFalse);

      final targetDirectory = Directory('${temporary.path}/target-assets');
      final materialized = await store.materialize(
        templateId: loaded.id,
        targetAssetDirectory: targetDirectory,
        existingDocumentAssetIds: const ['already-used'],
        pageId: 'document-page-9',
        pageName: 'Neue Seite',
      );
      final instantiated = materialized.page;
      expect(instantiated.id, 'document-page-9');
      expect(instantiated.name, 'Neue Seite');
      expect(instantiated.viewport, const ViewportState());
      expect(instantiated.selection.isEmpty, isTrue);
      expect(instantiated.objects.whereType<ImageObject>(), hasLength(1));
      expect(instantiated.objects.whereType<PdfObject>(), hasLength(1));
      expect(instantiated.annotationFor('image'), isNotNull);
      expect(instantiated.annotationFor('pdf'), isNotNull);
      expect(materialized.assets.map((asset) => asset.id), [
        'document-image',
        'document-pdf',
      ]);
      expect(
        instantiated.objects.whereType<ImageObject>().single.assetId,
        'document-image',
      );
      expect(
        instantiated.objects.whereType<PdfObject>().single.assetId,
        'document-pdf',
      );
      expect(
        await targetDirectory.list().where((entry) => entry is File).length,
        2,
      );
      expect(
        materialized.assets.map((asset) => asset.relativePath).toSet(),
        hasLength(2),
      );
    },
  );

  test('media save fails closed when a source asset is missing', () async {
    final store = createStore();

    await expectLater(
      store.save(name: 'Unvollständig', page: _mixedPage()),
      throwsA(isA<UserTemplateStorageException>()),
    );

    expect(await store.load(), isEmpty);
    if (await store.assetRootDirectory.exists()) {
      expect(await store.assetRootDirectory.list().toList(), isEmpty);
    }
  });

  test(
    'corrupt media is rejected and destination files are rolled back',
    () async {
      final ids = ['template-corrupt', 'document-asset'].iterator;
      final store = createStore(
        uuid: () {
          ids.moveNext();
          return ids.current;
        },
      );
      final sourceDirectory = Directory('${temporary.path}/corrupt-source');
      await sourceDirectory.create();
      await File('${sourceDirectory.path}/image.png').writeAsBytes([1, 2, 3]);
      final page = BoardPage(
        id: 'media-page',
        name: 'Medien',
        objects: [
          ImageObject(
            id: 'image',
            transform: const ObjectTransform(
              x: 0,
              y: 0,
              width: 100,
              height: 80,
            ),
            assetId: 'source-image',
          ),
        ],
      );
      final template = await store.save(
        name: 'Medien',
        page: page,
        sourceAssetDirectory: sourceDirectory,
        sourceAssets: [
          DocumentAsset(
            id: 'source-image',
            type: DocumentAssetType.image,
            relativePath: 'image.png',
            mimeType: 'image/png',
          ),
        ],
      );
      final storedFiles = await store
          .templateAssetDirectory(template.id)
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      expect(storedFiles, hasLength(1));
      await storedFiles.single.writeAsBytes([9, 9, 9], flush: true);
      final target = Directory('${temporary.path}/corrupt-target');

      await expectLater(
        store.materialize(
          templateId: template.id,
          targetAssetDirectory: target,
          existingDocumentAssetIds: const [],
          pageId: 'new-page',
          pageName: 'Neu',
        ),
        throwsA(isA<UserTemplateStorageException>()),
      );
      expect(await target.list().toList(), isEmpty);
    },
  );

  test(
    'delete and startup cleanup remove unreferenced template assets',
    () async {
      final store = createStore(uuid: () => 'template-with-file');
      final sourceDirectory = Directory('${temporary.path}/delete-source');
      await sourceDirectory.create();
      await File('${sourceDirectory.path}/image.png').writeAsBytes([4, 5, 6]);
      final template = await store.save(
        name: 'Löschbar',
        page: BoardPage(
          id: 'delete-page',
          name: 'Löschbar',
          objects: [
            ImageObject(
              id: 'image',
              transform: const ObjectTransform(
                x: 0,
                y: 0,
                width: 100,
                height: 80,
              ),
              assetId: 'source-image',
            ),
          ],
        ),
        sourceAssetDirectory: sourceDirectory,
        sourceAssets: [
          DocumentAsset(
            id: 'source-image',
            type: DocumentAssetType.image,
            relativePath: 'image.png',
            mimeType: 'image/png',
          ),
        ],
      );
      final owned = store.templateAssetDirectory(template.id);
      expect(await owned.exists(), isTrue);

      expect(await store.delete(template.id), isTrue);
      expect(await owned.exists(), isFalse);

      final orphan = Directory(
        '${store.assetRootDirectory.path}/${List.filled(64, 'a').join()}',
      );
      await orphan.create(recursive: true);
      await File('${orphan.path}/orphan.bin').writeAsBytes([1]);
      expect(await orphan.exists(), isTrue);

      expect(await store.load(), isEmpty);
      expect(await orphan.exists(), isFalse);
    },
  );

  test(
    'duplicate names retain distinct UUID identity and delete precisely',
    () async {
      final ids = ['template-a', 'template-a', 'template-b'].iterator;
      final store = createStore(
        uuid: () {
          ids.moveNext();
          return ids.current;
        },
      );

      final first = await store.save(
        name: 'Meine Vorlage',
        page: _simplePage(),
      );
      final second = await store.save(
        name: 'Meine Vorlage',
        page: _simplePage(id: 'source-2'),
      );

      expect(first.id, 'template-a');
      expect(second.id, 'template-b');
      expect((await store.load()).map((item) => item.name), [
        'Meine Vorlage',
        'Meine Vorlage',
      ]);

      expect(await store.delete(first.id), isTrue);
      final remaining = await store.load();
      expect(remaining.single.id, second.id);
      expect(await store.delete('does-not-exist'), isFalse);
    },
  );

  test('concurrent saves are serialized without lost updates', () async {
    var nextId = 0;
    var nextTime = 0;
    final store = createStore(
      uuid: () => 'template-${nextId++}',
      clock: () => timestamp.add(Duration(seconds: nextTime++)),
    );

    await Future.wait([
      for (var index = 0; index < 12; index++)
        store.save(
          name: 'Vorlage $index',
          page: _simplePage(id: 'source-$index'),
        ),
    ]);

    final templates = await store.load();
    expect(templates, hasLength(12));
    expect(templates.map((item) => item.id).toSet(), hasLength(12));
    expect(templates.map((item) => item.name).toSet(), {
      for (var index = 0; index < 12; index++) 'Vorlage $index',
    });
  });

  test(
    'atomic update rotates the prior valid file and leaves no temp file',
    () async {
      var nextId = 1;
      final store = createStore(uuid: () => 'template-${nextId++}');
      await store.save(name: 'Erste', page: _simplePage());
      final firstVersion = await store.primaryFile.readAsString();

      await store.save(
        name: 'Zweite',
        page: _simplePage(id: 'source-2'),
      );

      expect(await store.backupFile.readAsString(), firstVersion);
      expect((await store.load()).map((item) => item.name), [
        'Zweite',
        'Erste',
      ]);
      final leftovers = await temporary
          .list()
          .where((entry) => entry.path.contains('.tmp.'))
          .toList();
      expect(leftovers, isEmpty);
    },
  );

  test(
    'corrupt primary is recovered from backup and repaired atomically',
    () async {
      var nextId = 1;
      final store = createStore(uuid: () => 'template-${nextId++}');
      await store.save(name: 'Sichere Version', page: _simplePage());
      final safeVersion = await store.primaryFile.readAsString();
      await store.save(
        name: 'Neuere Version',
        page: _simplePage(id: 'newer'),
      );
      await store.primaryFile.writeAsString('{broken', flush: true);

      final recovered = await store.load();

      expect(recovered.single.name, 'Sichere Version');
      expect(await store.primaryFile.readAsString(), safeVersion);
      expect(await store.backupFile.readAsString(), safeVersion);
    },
  );

  test(
    'two corrupt copies report a typed error without overwriting evidence',
    () async {
      var nextId = 1;
      final store = createStore(uuid: () => 'template-${nextId++}');
      await store.save(name: 'Erste', page: _simplePage());
      await store.save(
        name: 'Zweite',
        page: _simplePage(id: 'source-2'),
      );
      await store.primaryFile.writeAsString('{bad-primary', flush: true);
      await store.backupFile.writeAsString('{bad-backup', flush: true);

      await expectLater(
        store.load(),
        throwsA(isA<UserTemplateStorageException>()),
      );
      expect(await store.primaryFile.readAsString(), '{bad-primary');
      expect(await store.backupFile.readAsString(), '{bad-backup');
    },
  );

  test('a failed operation does not poison the store lock', () async {
    var calls = 0;
    final store = createStore(
      uuid: () {
        calls++;
        return calls <= 32 ? '' : 'healthy-id';
      },
    );

    await expectLater(
      store.save(name: 'Fehlschlag', page: _simplePage()),
      throwsA(isA<UserTemplateStorageException>()),
    );
    final saved = await store.save(name: 'Danach', page: _simplePage());

    expect(saved.id, 'healthy-id');
    expect((await store.load()).single.name, 'Danach');
  });
}

BoardPage _simplePage({String id = 'source'}) =>
    BoardPage(id: id, name: 'Quelle', strokes: [_stroke('simple-stroke')]);

BoardPage _mixedPage() {
  final freeInk = _stroke('free-ink', pointerId: 42);
  const transform = ObjectTransform(x: 20, y: 30, width: 160, height: 90);
  final objects = <BoardObject>[
    ShapeObject(id: 'shape', transform: transform),
    ImageObject(id: 'image', transform: transform, assetId: 'image-asset'),
    PdfObject(
      id: 'pdf',
      transform: transform,
      assetId: 'pdf-asset',
      pageIndices: const [0, 1],
    ),
    TableObject(id: 'table', transform: transform, rows: 2, columns: 3),
    CoverObject(id: 'cover', transform: transform),
    TextObject(id: 'text', transform: transform, text: 'Merksatz'),
  ];
  return BoardPage(
    id: 'source-page',
    name: 'Quellseite',
    viewport: const ViewportState(offsetX: 500, offsetY: -200, zoom: 2.5),
    strokes: [freeInk],
    objects: objects,
    annotationLayers: [
      ObjectInkLayer(
        id: 'shape-layer',
        objectId: 'shape',
        strokes: [_stroke('shape-ink', pointerId: 1)],
      ),
      ObjectInkLayer(
        id: 'image-layer',
        objectId: 'image',
        strokes: [_stroke('image-ink', pointerId: 2)],
      ),
      ObjectInkLayer(
        id: 'pdf-layer',
        objectId: 'pdf',
        strokes: [_stroke('pdf-ink', pointerId: 3)],
      ),
      ObjectInkLayer(
        id: 'table-layer',
        objectId: 'table',
        strokes: [_stroke('table-ink', pointerId: 4)],
      ),
    ],
    groups: [
      InkGroup(
        id: 'ink-group',
        kind: InkGroupKind.word,
        strokeIds: const ['free-ink'],
        bounds: freeInk.bounds,
      ),
    ],
    contentGroups: [
      ContentGroup(
        id: 'retained',
        memberIds: const ['free-ink', 'shape', 'table'],
        bounds: const Rect2(left: 0, top: 0, width: 200, height: 200),
      ),
      ContentGroup(
        id: 'media-only-after-filter',
        memberIds: const ['image', 'shape'],
        bounds: const Rect2(left: 0, top: 0, width: 200, height: 200),
      ),
    ],
    selection: SelectionState(
      selectedItemIds: const ['image', 'shape'],
      mode: SelectionMode.lasso,
    ),
    template: TemplateInstance(
      id: 'built-in-template',
      kind: TemplateKind.mindMap,
    ),
    thumbnailAssetId: 'thumbnail-asset',
  );
}

InkStroke _stroke(String id, {int? pointerId}) => InkStroke(
  id: id,
  points: const [
    InkPoint(x: 10, y: 20, timestampMicros: 1),
    InkPoint(x: 30, y: 40, timestampMicros: 2),
  ],
  pointerId: pointerId,
);
