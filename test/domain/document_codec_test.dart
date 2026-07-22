import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowboard_x/src/domain/domain.dart';

void main() {
  group('DocumentCodec', () {
    test('round-trips the complete document model', () {
      final timestamp = DateTime.utc(2026, 7, 21, 12);
      final stroke = InkStroke(
        id: 'stroke-1',
        points: const [
          InkPoint(x: 10, y: 20, pressure: 0.4, timestampMicros: 10),
          InkPoint(x: 30, y: 40, pressure: 0.8, timestampMicros: 20),
        ],
        colorArgb: 0xFF123456,
        width: 7,
        type: InkToolType.dashed,
        createdAt: timestamp,
        authorId: 'pen-a',
        pointerId: 41,
      );
      final objects = <BoardObject>[
        ShapeObject(
          id: 'shape',
          transform: const ObjectTransform(x: 1, y: 2, width: 30, height: 40),
          shape: ShapeKind.triangle,
          createdAt: timestamp,
        ),
        ImageObject(
          id: 'image',
          transform: const ObjectTransform(
            x: 10,
            y: 20,
            width: 300,
            height: 200,
          ),
          assetId: 'asset-image',
          originalFileName: 'bild.webp',
          fit: ImageFitMode.cover,
          createdAt: timestamp,
        ),
        PdfObject(
          id: 'pdf',
          transform: const ObjectTransform(x: 5, y: 7, width: 500, height: 700),
          assetId: 'asset-pdf',
          pageIndices: const [0, 2, 3],
          importMode: PdfImportMode.pageRange,
          activePageIndex: 2,
          createdAt: timestamp,
        ),
        TableObject(
          id: 'table',
          transform: const ObjectTransform(x: 4, y: 8, width: 400, height: 200),
          rows: 2,
          columns: 3,
          cells: const {'0:1': TableCellData(text: 'Wert', bold: true)},
          createdAt: timestamp,
        ),
        CoverObject(
          id: 'cover',
          transform: const ObjectTransform(x: 2, y: 3, width: 200, height: 100),
          direction: RevealDirection.topToBottom,
          reveal: 0.45,
          createdAt: timestamp,
        ),
        TextObject(
          id: 'text',
          transform: const ObjectTransform(x: 2, y: 3, width: 200, height: 100),
          text: 'Erkannter Text',
          sourceStrokeIds: const ['stroke-1'],
          createdAt: timestamp,
        ),
      ];
      final page = BoardPage(
        id: 'page-1',
        name: 'Tafelbild',
        viewport: const ViewportState(offsetX: -120, offsetY: 80, zoom: 1.75),
        strokes: [stroke],
        objects: objects,
        annotationLayers: [
          ObjectInkLayer(
            id: 'image-ink',
            objectId: 'image',
            strokes: [stroke.copyWith(id: 'local')],
          ),
        ],
        groups: [
          InkGroup(
            id: 'word-1',
            kind: InkGroupKind.word,
            strokeIds: const ['stroke-1'],
            bounds: stroke.bounds,
            createdAt: timestamp,
          ),
        ],
        contentGroups: [
          ContentGroup(
            id: 'mixed-group',
            memberIds: const ['stroke-1', 'image'],
            bounds: stroke.bounds.union(objects[1].transform.bounds),
            createdAt: timestamp,
          ),
        ],
        selection: SelectionState(
          selectedItemIds: const ['stroke-1', 'image'],
          mode: SelectionMode.lasso,
        ),
        template: TemplateInstance(
          id: 'template-1',
          kind: TemplateKind.mindMap,
          properties: const {'nodes': 6},
        ),
        thumbnailAssetId: 'thumb-page',
      );
      final document = WhiteboardDocument(
        id: 'doc-1',
        title: 'Biologie',
        createdAt: timestamp,
        updatedAt: timestamp.add(const Duration(minutes: 4)),
        pages: [page],
        presets: const [
          PenPreset(id: 'black', name: 'Schwarz'),
          PenPreset(
            id: 'green-marker',
            name: 'Grün',
            colorArgb: 0x8011CC55,
            width: 22,
            type: InkToolType.marker,
          ),
        ],
        activePresetId: 'green-marker',
        assets: [
          DocumentAsset(
            id: 'asset-image',
            type: DocumentAssetType.image,
            relativePath: 'assets/image.webp',
            mimeType: 'image/webp',
            byteLength: 1234,
            sha256: 'abc',
            createdAt: timestamp,
          ),
        ],
        metadata: DocumentMetadata(
          author: 'Klasse 5a',
          deviceId: 'board-7',
          custom: const {'subject': 'biology'},
        ),
        thumbnailAssetId: 'thumb-document',
        revision: 8,
      );

      const codec = DocumentCodec();
      final encoded = codec.encode(document);
      final decoded = codec.decode(encoded);

      expect(
        jsonDecode(encoded)['schemaVersion'],
        DocumentMigrator.currentVersion,
      );
      expect(decoded.id, 'doc-1');
      expect(decoded.revision, 8);
      expect(decoded.currentPage.viewport.zoom, 1.75);
      expect(
        decoded.currentPage.objects.map((object) => object.type),
        BoardObjectType.values,
      );
      expect((decoded.currentPage.objects[2] as PdfObject).pageIndices, [
        0,
        2,
        3,
      ]);
      expect(
        (decoded.currentPage.objects[3] as TableObject).cellAt(0, 1).text,
        'Wert',
      );
      expect(
        decoded.currentPage.annotationFor('image')!.strokes.single.id,
        'local',
      );
      expect(decoded.currentPage.contentGroups.single.memberIds, [
        'stroke-1',
        'image',
      ]);
      expect(decoded.currentPage.selection.selectedItemIds, [
        'stroke-1',
        'image',
      ]);
      expect(decoded.assets.single.sha256, 'abc');
      expect(decoded.metadata.custom['subject'], 'biology');
    });

    test('migrates legacy v1 ink, viewport, presets and objects', () {
      final source = jsonEncode({
        'id': 'legacy',
        'title': 'Alt',
        'createdAt': '2025-01-01T00:00:00Z',
        'updatedAt': '2025-01-02T00:00:00Z',
        'currentPage': 0,
        'presets': [
          {
            'id': 'legacy-pen',
            'name': 'Rot',
            'color': '#CC1122',
            'thickness': 9,
            'tool': 'pen',
          },
        ],
        'pages': [
          {
            'id': 'p1',
            'viewport': {'x': 12, 'y': -8, 'scale': 2},
            'ink': [
              {
                'id': 's1',
                'color': '#112233',
                'thickness': 5,
                'tool': 'highlighter',
                'points': [
                  {'x': 1, 'y': 2, 'p': 0.5, 't': 123},
                ],
              },
            ],
            'items': [
              {
                'id': 'o1',
                'kind': 'circle',
                'x': 1,
                'y': 2,
                'width': 3,
                'height': 4,
              },
            ],
          },
        ],
      });

      final document = const DocumentCodec().decode(source);

      expect(
        document.currentPage.viewport,
        const ViewportState(offsetX: 12, offsetY: -8, zoom: 2),
      );
      expect(document.currentPage.strokes.single.type, InkToolType.marker);
      expect(document.currentPage.strokes.single.colorArgb, 0xFF112233);
      expect(document.currentPage.strokes.single.points.single.pressure, 0.5);
      expect(document.currentPage.objects.single, isA<ShapeObject>());
      expect(
        (document.currentPage.objects.single as ShapeObject).shape,
        ShapeKind.circle,
      );
      expect(
        document.presets
            .singleWhere((preset) => preset.id == 'legacy-pen')
            .colorArgb,
        0xFFCC1122,
      );
      expect(document.presets.any((preset) => preset.id == 'black'), isTrue);
    });

    test('rejects future schema versions and invalid roots', () {
      const codec = DocumentCodec();
      expect(
        () => codec.decode('{"schemaVersion":999,"pages":[]}'),
        throwsFormatException,
      );
      expect(() => codec.decode('[]'), throwsFormatException);
      expect(() => codec.decode('{broken'), throwsFormatException);
    });

    test('enforces one to one hundred pages', () {
      final now = DateTime.utc(2026);
      expect(
        () => WhiteboardDocument(
          id: 'too-many',
          title: 'Too many',
          createdAt: now,
          updatedAt: now,
          pages: List.generate(101, (index) => BoardPage.empty(id: 'p$index')),
        ),
        throwsArgumentError,
      );
    });
  });
}
