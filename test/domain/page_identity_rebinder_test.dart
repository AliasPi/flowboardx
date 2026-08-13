import 'package:flowboard_x/src/domain/model/board_object.dart';
import 'package:flowboard_x/src/domain/model/document.dart';
import 'package:flowboard_x/src/domain/model/geometry.dart';
import 'package:flowboard_x/src/domain/model/ink.dart';
import 'package:flowboard_x/src/domain/model/page_identity_rebinder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('page duplicate rebinds every nested identity and reference', () {
    final stroke = InkStroke(
      id: 'stroke',
      points: const <InkPoint>[InkPoint(x: 10, y: 20)],
      pointerId: 99,
    );
    final text = TextObject(
      id: 'text',
      transform: _transform,
      text: 'Text',
      sourceStrokeIds: const <String>['stroke'],
    );
    final pdf = PdfObject(
      id: 'pdf',
      transform: _transform,
      assetId: 'pdf-asset',
      pageIndices: const <int>[1, 4],
      activePageIndex: 1,
    );
    final page = BoardPage(
      id: 'page',
      name: 'Quelle',
      strokes: <InkStroke>[stroke],
      objects: <BoardObject>[text, pdf],
      annotationLayers: <ObjectInkLayer>[
        ObjectInkLayer(
          id: 'layer',
          objectId: 'pdf',
          pdfPageIndex: 4,
          strokes: <InkStroke>[
            InkStroke(
              id: 'annotation-stroke',
              points: const <InkPoint>[InkPoint(x: .2, y: .3)],
              pointerId: 100,
            ),
          ],
        ),
      ],
      groups: <InkGroup>[
        InkGroup(
          id: 'ink-group',
          kind: InkGroupKind.word,
          strokeIds: const <String>['stroke'],
          bounds: stroke.bounds,
        ),
      ],
      contentGroups: <ContentGroup>[
        ContentGroup(
          id: 'content-group',
          memberIds: const <String>['stroke', 'text'],
          bounds: const Rect2(left: 0, top: 0, width: 300, height: 200),
        ),
      ],
      selection: SelectionState(
        selectedItemIds: const <String>['stroke', 'text'],
      ),
      template: TemplateInstance(
        id: 'template',
        kind: TemplateKind.primarySchoolLines,
      ),
      thumbnailAssetId: 'thumbnail',
    );
    var next = 0;
    final duplicate = PageIdentityRebinder(
      reservedIds: _ownedIds(page),
      newId: () => 'fresh-${next++}',
    ).clone(page, name: 'Quelle – Kopie', resolveAssetId: (assetId) => assetId);

    expect(_ownedIds(page).intersection(_ownedIds(duplicate)), isEmpty);
    expect(duplicate.name, 'Quelle – Kopie');
    expect(duplicate.selection.isEmpty, true);
    expect(duplicate.strokes.single.pointerId, isNull);
    final duplicateText = duplicate.objects.whereType<TextObject>().single;
    final duplicatePdf = duplicate.objects.whereType<PdfObject>().single;
    expect(duplicateText.sourceStrokeIds, <String>[
      duplicate.strokes.single.id,
    ]);
    expect(duplicatePdf.assetId, 'pdf-asset');
    expect(duplicate.annotationLayers.single.objectId, duplicatePdf.id);
    expect(duplicate.annotationLayers.single.pdfPageIndex, 4);
    expect(duplicate.annotationLayers.single.strokes.single.pointerId, isNull);
    expect(duplicate.groups.single.strokeIds, <String>[
      duplicate.strokes.single.id,
    ]);
    expect(duplicate.contentGroups.single.memberIds, <String>[
      duplicate.strokes.single.id,
      duplicateText.id,
    ]);
    expect(
      duplicate.thumbnailAssetId,
      isNull,
      reason: 'A persisted preview cache belongs to the source page identity.',
    );
  });
}

const _transform = ObjectTransform(x: 0, y: 0, width: 300, height: 200);

Set<String> _ownedIds(BoardPage page) => <String>{
  page.id,
  if (page.template != null) page.template!.id,
  for (final stroke in page.strokes) stroke.id,
  for (final object in page.objects) object.id,
  for (final layer in page.annotationLayers) ...<String>{
    layer.id,
    for (final stroke in layer.strokes) stroke.id,
  },
  for (final group in page.groups) group.id,
  for (final group in page.contentGroups) group.id,
};
