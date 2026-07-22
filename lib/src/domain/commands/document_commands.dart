import 'dart:math' as math;

import '../model/board_object.dart';
import '../model/document.dart';
import '../model/geometry.dart';
import '../model/ink.dart';
import '../model/scene_order.dart';
import 'document_command.dart';

final class AddStrokeCommand implements DocumentCommand {
  const AddStrokeCommand(
    this.pageId,
    this.stroke, {
    this.objectId,
    this.pdfPageIndex,
    this.now,
  });

  final String pageId;
  final InkStroke stroke;
  final String? objectId;
  final int? pdfPageIndex;
  final DateTime? now;

  @override
  String get label => 'Strich hinzufügen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    if (_allStrokeIds(page).contains(stroke.id)) {
      throw StateError('Strich-ID ${stroke.id} ist bereits vorhanden.');
    }
    if (objectId == null) {
      final topmost = stroke.copyWith(
        zIndex: nextBoardSceneZIndex(
          objects: page.objects,
          strokes: page.strokes,
        ),
      );
      return document.replacePage(
        page.copyWith(strokes: [...page.strokes, topmost]),
        now: now,
      );
    }
    if (page.objectById(objectId!) == null) {
      throw StateError('Annotationsziel $objectId existiert nicht.');
    }
    final layers = page.annotationLayers.toList();
    var index = layers.indexWhere(
      (layer) =>
          layer.objectId == objectId && layer.pdfPageIndex == pdfPageIndex,
    );
    if (index < 0 && pdfPageIndex != null) {
      index = layers.indexWhere(
        (layer) => layer.objectId == objectId && layer.pdfPageIndex == null,
      );
    }
    if (index < 0) {
      layers.add(
        ObjectInkLayer(
          id: pdfPageIndex == null
              ? '${objectId!}.annotations'
              : '${objectId!}.pdf.$pdfPageIndex.annotations',
          objectId: objectId!,
          pdfPageIndex: pdfPageIndex,
          strokes: [stroke.copyWith(zIndex: 0)],
        ),
      );
    } else {
      final layer = layers[index];
      final maximum = layer.strokes.fold<int>(
        -1,
        (value, candidate) =>
            candidate.zIndex > value ? candidate.zIndex : value,
      );
      layers[index] = layers[index].copyWith(
        pdfPageIndex: pdfPageIndex,
        strokes: [
          ...layer.strokes,
          stroke.copyWith(zIndex: maximum + 1),
        ],
      );
    }
    return document.replacePage(
      page.copyWith(annotationLayers: layers),
      now: now,
    );
  }
}

final class AddObjectCommand implements DocumentCommand {
  const AddObjectCommand(this.pageId, this.object, {this.now});

  final String pageId;
  final BoardObject object;
  final DateTime? now;

  @override
  String get label => 'Objekt hinzufügen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    if (_allItemIds(page).contains(object.id)) {
      throw StateError('Objekt-ID ${object.id} ist bereits vorhanden.');
    }
    final topmost = copyBoardObjectWithZIndex(
      object,
      nextBoardSceneZIndex(objects: page.objects, strokes: page.strokes),
    );
    return document.replacePage(
      page.copyWith(objects: [...page.objects, topmost]),
      now: now,
    );
  }
}

enum ClearPageScope { all, handwriting }

final class ClearPageCommand implements DocumentCommand {
  const ClearPageCommand(
    this.pageId, {
    this.scope = ClearPageScope.all,
    this.now,
  });

  final String pageId;
  final ClearPageScope scope;
  final DateTime? now;

  @override
  String get label =>
      scope == ClearPageScope.all ? 'Seite leeren' : 'Handschrift leeren';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    final next = switch (scope) {
      ClearPageScope.all => BoardPage(
        id: page.id,
        name: page.name,
        viewport: page.viewport,
        thumbnailAssetId: page.thumbnailAssetId,
      ),
      ClearPageScope.handwriting => page.copyWith(
        strokes: page.strokes.where((stroke) => stroke.authorId == 'template'),
        annotationLayers: page.annotationLayers.map(
          (layer) => layer.copyWith(strokes: const []),
        ),
        groups: const [],
        contentGroups: _repairContentGroups(page.contentGroups, const {}, {
          for (final object in page.objects) object.id: object,
        }),
        selection: SelectionState.empty,
      ),
    };
    return document.replacePage(next, now: now);
  }
}

final class DeleteItemsCommand implements DocumentCommand {
  DeleteItemsCommand(this.pageId, Iterable<String> itemIds, {this.now})
    : itemIds = Set.unmodifiable(itemIds);

  final String pageId;
  final Set<String> itemIds;
  final DateTime? now;

  @override
  String get label => 'Auswahl löschen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    if (itemIds.isEmpty) return document;
    final expandedIds = _expandItemIds(page, itemIds);
    final strokeIds = page.strokes
        .where((stroke) => expandedIds.contains(stroke.id))
        .map((stroke) => stroke.id)
        .toSet();
    final objectIds = page.objects
        .where((object) => expandedIds.contains(object.id))
        .map((object) => object.id)
        .toSet();
    final nextStrokes = page.strokes
        .where((stroke) => !strokeIds.contains(stroke.id))
        .toList();
    final nextObjects = page.objects
        .where((object) => !objectIds.contains(object.id))
        .toList();
    final nextAnnotations = page.annotationLayers
        .where((layer) => !objectIds.contains(layer.objectId))
        .map(
          (layer) => layer.copyWith(
            strokes: layer.strokes.where(
              (stroke) => !itemIds.contains(stroke.id),
            ),
          ),
        )
        .toList();
    final byStrokeId = {for (final stroke in nextStrokes) stroke.id: stroke};
    final nextGroups = _repairGroups(
      page.groups,
      byStrokeId,
      removedGroupIds: itemIds,
    );
    final nextContentGroups = _repairContentGroups(
      page.contentGroups,
      byStrokeId,
      {for (final object in nextObjects) object.id: object},
      removedGroupIds: itemIds,
    );
    final remainingIds = {
      ...nextStrokes.map((stroke) => stroke.id),
      ...nextObjects.map((object) => object.id),
      ...nextGroups.map((group) => group.id),
      ...nextContentGroups.map((group) => group.id),
    };
    final nextSelection = page.selection.copyWith(
      selectedItemIds: page.selection.selectedItemIds.where(
        remainingIds.contains,
      ),
    );
    return document.replacePage(
      page.copyWith(
        strokes: nextStrokes,
        objects: nextObjects,
        annotationLayers: nextAnnotations,
        groups: nextGroups,
        contentGroups: nextContentGroups,
        selection: nextSelection,
      ),
      now: now,
    );
  }
}

final class TransformItemsCommand implements DocumentCommand {
  TransformItemsCommand(
    this.pageId,
    Iterable<String> itemIds,
    this.delta, {
    this.now,
  }) : itemIds = Set.unmodifiable(itemIds);

  final String pageId;
  final Set<String> itemIds;
  final TransformDelta delta;
  final DateTime? now;

  @override
  String get label => 'Auswahl transformieren';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    if (itemIds.isEmpty) return document;
    final expandedIds = _expandItemIds(page, itemIds);
    final strokes = page.strokes
        .map(
          (stroke) => expandedIds.contains(stroke.id)
              ? stroke.transformed(delta)
              : stroke,
        )
        .toList();
    final objects = page.objects
        .map(
          (object) => expandedIds.contains(object.id)
              ? _transformObject(object, delta)
              : object,
        )
        .toList();
    final byStrokeId = {for (final stroke in strokes) stroke.id: stroke};
    final groups = _repairGroups(page.groups, byStrokeId);
    final contentGroups = _repairContentGroups(page.contentGroups, byStrokeId, {
      for (final object in objects) object.id: object,
    });
    return document.replacePage(
      page.copyWith(
        strokes: strokes,
        objects: objects,
        groups: groups,
        contentGroups: contentGroups,
      ),
      now: now,
    );
  }

  BoardObject _transformObject(BoardObject object, TransformDelta delta) {
    final transform = object.transform.apply(delta);
    if (object is! TextObject) return object.copyWithTransform(transform);
    final areaScale = delta.scaleX.abs() * delta.scaleY.abs();
    final fontScale = areaScale.isFinite
        ? math.sqrt(areaScale.clamp(0.0001, 10000.0))
        : 1.0;
    return object.copyWith(
      transform: transform,
      fontSize: (object.fontSize * fontScale).clamp(1.0, 512.0),
    );
  }
}

final class GroupItemsCommand implements DocumentCommand {
  GroupItemsCommand(
    this.pageId,
    this.groupId,
    Iterable<String> itemIds, {
    this.now,
  }) : itemIds = Set.unmodifiable(itemIds);

  final String pageId;
  final String groupId;
  final Set<String> itemIds;
  final DateTime? now;

  @override
  String get label => 'Auswahl gruppieren';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    if (_allItemIds(page).contains(groupId)) {
      throw StateError('Gruppen-ID $groupId ist bereits vorhanden.');
    }
    final baseIds = {
      ...page.strokes.map((stroke) => stroke.id),
      ...page.objects.map((object) => object.id),
    };
    final members = _expandItemIds(
      page,
      itemIds,
    ).where(baseIds.contains).toSet();
    // Existing persistent groups are atomic. If an API caller supplies one of
    // their members directly, include the complete group and replace the old
    // group instead of creating overlapping group definitions.
    final consumedGroups = <String>{};
    var expandedExistingGroup = true;
    while (expandedExistingGroup) {
      expandedExistingGroup = false;
      for (final existing in page.contentGroups) {
        if (!existing.memberIds.any(members.contains)) continue;
        consumedGroups.add(existing.id);
        for (final memberId in existing.memberIds) {
          if (members.add(memberId)) expandedExistingGroup = true;
        }
      }
    }
    if (members.length < 2) {
      throw StateError(
        'Eine Gruppe benötigt mindestens zwei gültige Elemente.',
      );
    }
    final group = ContentGroup(
      id: groupId,
      memberIds: members,
      bounds: _contentBounds(
        members,
        {for (final stroke in page.strokes) stroke.id: stroke},
        {for (final object in page.objects) object.id: object},
      ),
      createdAt: now,
    );
    return document.replacePage(
      page.copyWith(
        contentGroups: [
          ...page.contentGroups.where(
            (existing) => !consumedGroups.contains(existing.id),
          ),
          group,
        ],
        selection: SelectionState(selectedItemIds: [groupId]),
      ),
      now: now,
    );
  }
}

final class UngroupItemsCommand implements DocumentCommand {
  const UngroupItemsCommand(this.pageId, this.groupId, {this.now});

  final String pageId;
  final String groupId;
  final DateTime? now;

  @override
  String get label => 'Gruppierung aufheben';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    final group = page.contentGroups
        .where((candidate) => candidate.id == groupId)
        .firstOrNull;
    if (group == null) throw StateError('Gruppe $groupId existiert nicht.');
    return document.replacePage(
      page.copyWith(
        contentGroups: page.contentGroups.where(
          (candidate) => candidate.id != groupId,
        ),
        selection: SelectionState(selectedItemIds: group.memberIds),
      ),
      now: now,
    );
  }
}

final class ReplacePageCommand implements DocumentCommand {
  const ReplacePageCommand(this.page, {this.now});

  final BoardPage page;
  final DateTime? now;

  @override
  String get label => 'Seite aktualisieren';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) =>
      document.replacePage(page.sanitized(), now: now);
}

final class UpdateViewportCommand implements DocumentCommand {
  const UpdateViewportCommand(this.pageId, this.viewport, {this.now});

  final String pageId;
  final ViewportState viewport;
  final DateTime? now;

  @override
  String get label => 'Ansicht ändern';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = _page(document, pageId);
    return document.replacePage(
      page.copyWith(viewport: viewport.normalized()),
      now: now,
    );
  }
}

final class AddPageCommand implements DocumentCommand {
  const AddPageCommand(
    this.page, {
    this.insertAt,
    this.selectNewPage = true,
    this.now,
  });

  final BoardPage page;
  final int? insertAt;
  final bool selectNewPage;
  final DateTime? now;

  @override
  String get label => 'Seite hinzufügen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    if (document.pages.length >= WhiteboardDocument.maxPageCount) {
      throw StateError(
        'Maximal ${WhiteboardDocument.maxPageCount} Seiten sind erlaubt.',
      );
    }
    if (document.pageById(page.id) != null) {
      throw StateError('Seite ${page.id} existiert bereits.');
    }
    final index = (insertAt ?? document.currentPageIndex + 1).clamp(
      0,
      document.pages.length,
    );
    final pages = document.pages.toList();
    pages.insert(index, page.sanitized());
    final current = selectNewPage
        ? index
        : document.currentPageIndex >= index
        ? document.currentPageIndex + 1
        : document.currentPageIndex;
    return document.copyWith(
      pages: pages,
      currentPageIndex: current,
      updatedAt: now ?? DateTime.now().toUtc(),
      revision: document.revision + 1,
    );
  }
}

final class RemovePageCommand implements DocumentCommand {
  const RemovePageCommand(this.pageId, {this.now});

  final String pageId;
  final DateTime? now;

  @override
  String get label => 'Seite löschen';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    if (document.pages.length == 1) {
      throw StateError('Die letzte Seite kann nicht gelöscht werden.');
    }
    final index = document.pages.indexWhere((page) => page.id == pageId);
    if (index < 0) throw StateError('Seite $pageId existiert nicht.');
    final pages = document.pages.toList()..removeAt(index);
    var current = document.currentPageIndex;
    if (index < current) current--;
    if (current >= pages.length) current = pages.length - 1;
    return document.copyWith(
      pages: pages,
      currentPageIndex: current,
      updatedAt: now ?? DateTime.now().toUtc(),
      revision: document.revision + 1,
    );
  }
}

final class SelectPageCommand implements DocumentCommand {
  const SelectPageCommand(this.pageId, {this.now});

  final String pageId;
  final DateTime? now;

  @override
  String get label => 'Seite wechseln';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final index = document.pages.indexWhere((page) => page.id == pageId);
    if (index < 0) throw StateError('Seite $pageId existiert nicht.');
    if (index == document.currentPageIndex) return document;
    return document.copyWith(
      currentPageIndex: index,
      updatedAt: now ?? DateTime.now().toUtc(),
      revision: document.revision + 1,
    );
  }
}

BoardPage _page(WhiteboardDocument document, String pageId) {
  final page = document.pageById(pageId);
  if (page == null) throw StateError('Seite $pageId existiert nicht.');
  return page;
}

Set<String> _allItemIds(BoardPage page) => {
  ...page.strokes.map((stroke) => stroke.id),
  ...page.objects.map((object) => object.id),
  ...page.groups.map((group) => group.id),
  ...page.contentGroups.map((group) => group.id),
  ...page.annotationLayers.map((layer) => layer.id),
  ...page.annotationLayers
      .expand((layer) => layer.strokes)
      .map((stroke) => stroke.id),
};

Set<String> _allStrokeIds(BoardPage page) => {
  ...page.strokes.map((stroke) => stroke.id),
  ...page.annotationLayers
      .expand((layer) => layer.strokes)
      .map((stroke) => stroke.id),
};

Set<String> _expandItemIds(BoardPage page, Iterable<String> selectedIds) {
  final result = selectedIds.toSet();
  var changed = true;
  while (changed) {
    changed = false;
    for (final group in page.groups) {
      if (result.contains(group.id)) {
        for (final id in group.strokeIds) {
          if (result.add(id)) changed = true;
        }
      }
    }
    for (final group in page.contentGroups) {
      if (result.contains(group.id)) {
        for (final id in group.memberIds) {
          if (result.add(id)) changed = true;
        }
      }
    }
  }
  return result;
}

List<InkGroup> _repairGroups(
  Iterable<InkGroup> groups,
  Map<String, InkStroke> strokes, {
  Set<String> removedGroupIds = const {},
}) {
  final result = <InkGroup>[];
  for (final group in groups) {
    if (removedGroupIds.contains(group.id)) continue;
    final members = group.strokeIds.where(strokes.containsKey).toList();
    if (members.isEmpty) continue;
    Rect2? bounds;
    for (final id in members) {
      bounds = bounds == null
          ? strokes[id]!.bounds
          : bounds.union(strokes[id]!.bounds);
    }
    result.add(group.copyWith(strokeIds: members, bounds: bounds));
  }
  return result;
}

List<ContentGroup> _repairContentGroups(
  Iterable<ContentGroup> groups,
  Map<String, InkStroke> strokes,
  Map<String, BoardObject> objects, {
  Set<String> removedGroupIds = const {},
}) {
  final validIds = {...strokes.keys, ...objects.keys};
  final result = <ContentGroup>[];
  for (final group in groups) {
    if (removedGroupIds.contains(group.id)) continue;
    final members = group.memberIds.where(validIds.contains).toList();
    if (members.length < 2) continue;
    result.add(
      group.copyWith(
        memberIds: members,
        bounds: _contentBounds(members, strokes, objects),
      ),
    );
  }
  return result;
}

Rect2 _contentBounds(
  Iterable<String> memberIds,
  Map<String, InkStroke> strokes,
  Map<String, BoardObject> objects,
) {
  Rect2? bounds;
  for (final id in memberIds) {
    final next = strokes[id]?.bounds ?? objects[id]?.transform.bounds;
    if (next != null) bounds = bounds == null ? next : bounds.union(next);
  }
  if (bounds == null) {
    throw StateError('Für die Gruppe konnten keine Grenzen bestimmt werden.');
  }
  return bounds;
}
