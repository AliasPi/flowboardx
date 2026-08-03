import '../model/board_object.dart';
import '../model/document.dart';
import '../model/geometry.dart';
import '../model/ink.dart';
import 'document_command.dart';

/// Atomically persists the fragments produced by one continuous eraser gesture.
///
/// One command is used for free ink and object-bound annotation ink together,
/// so Undo restores the exact pre-gesture page. References held by automatic
/// ink groups, persistent content groups, and direct selections are rebased to
/// all surviving fragments.
final class ReplaceErasedStrokeSegmentsCommand implements DocumentCommand {
  ReplaceErasedStrokeSegmentsCommand({
    required this.pageId,
    required Map<String, Iterable<InkStroke>> replacements,
    this.now,
  }) : replacements = Map<String, List<InkStroke>>.unmodifiable({
         for (final entry in replacements.entries)
           entry.key: List<InkStroke>.unmodifiable(entry.value),
       });

  final String pageId;
  final Map<String, List<InkStroke>> replacements;
  final DateTime? now;

  @override
  String get label => 'Teilweise radieren';

  @override
  WhiteboardDocument apply(WhiteboardDocument document) {
    final page = document.pageById(pageId);
    if (page == null) throw StateError('Seite $pageId existiert nicht.');
    if (replacements.isEmpty) return document;

    final locations = _locateReplacementSources(page);
    final appliedSourceIds = <String>{
      ...locations.topLevel,
      for (final ids in locations.annotationByLayerId.values) ...ids,
    };
    if (appliedSourceIds.isEmpty) return document;
    _validateReplacementIds(page, appliedSourceIds);

    final strokes = locations.topLevel.isEmpty
        ? page.strokes
        : _replaceStrokes(page.strokes, locations.topLevel);
    final annotationLayers = locations.annotationByLayerId.isEmpty
        ? page.annotationLayers
        : <ObjectInkLayer>[
            for (final layer in page.annotationLayers)
              if (locations.annotationByLayerId[layer.id] case final sourceIds?)
                layer.copyWith(
                  strokes: _replaceStrokes(layer.strokes, sourceIds),
                )
              else
                layer,
          ];

    List<String> rebaseIds(Iterable<String> ids) => <String>[
      for (final id in ids)
        if (appliedSourceIds.contains(id))
          ...replacements[id]!.map((stroke) => stroke.id)
        else
          id,
    ];

    final strokeById = <String, InkStroke>{
      for (final stroke in strokes) stroke.id: stroke,
    };
    final groups = <InkGroup>[];
    for (final group in page.groups) {
      if (!group.strokeIds.any(appliedSourceIds.contains)) {
        groups.add(group);
        continue;
      }
      final members = rebaseIds(
        group.strokeIds,
      ).where(strokeById.containsKey).toSet().toList(growable: false);
      if (members.isEmpty) continue;
      groups.add(
        group.copyWith(
          strokeIds: members,
          bounds: _strokeBounds(members, strokeById),
        ),
      );
    }

    final objectById = <String, BoardObject>{
      for (final object in page.objects) object.id: object,
    };
    final contentGroups = <ContentGroup>[];
    final dissolvedContentGroupMembers = <String, List<String>>{};
    for (final group in page.contentGroups) {
      if (!group.memberIds.any(appliedSourceIds.contains)) {
        contentGroups.add(group);
        continue;
      }
      final members = rebaseIds(group.memberIds)
          .where(
            (id) => strokeById.containsKey(id) || objectById.containsKey(id),
          )
          .toSet()
          .toList(growable: false);
      if (members.length < 2) {
        dissolvedContentGroupMembers[group.id] = members;
        continue;
      }
      contentGroups.add(
        group.copyWith(
          memberIds: members,
          bounds: _contentBounds(members, strokeById, objectById),
        ),
      );
    }

    var selection = page.selection;
    if (selection.selectedItemIds.isNotEmpty) {
      final validSelectionIds = <String>{
        ...strokeById.keys,
        ...objectById.keys,
        ...groups.map((group) => group.id),
        ...contentGroups.map((group) => group.id),
      };
      final selected = <String>{};
      for (final id in selection.selectedItemIds) {
        if (dissolvedContentGroupMembers.containsKey(id)) {
          selected.addAll(dissolvedContentGroupMembers[id]!);
        } else if (appliedSourceIds.contains(id)) {
          selected.addAll(replacements[id]!.map((stroke) => stroke.id));
        } else if (validSelectionIds.contains(id)) {
          selected.add(id);
        }
      }
      selection = selection.copyWith(selectedItemIds: selected);
    }

    return document.replacePage(
      page.copyWith(
        strokes: strokes,
        annotationLayers: annotationLayers,
        groups: groups,
        contentGroups: contentGroups,
        selection: selection,
      ),
      now: now,
    );
  }

  ({Set<String> topLevel, Map<String, Set<String>> annotationByLayerId})
  _locateReplacementSources(BoardPage page) {
    final remaining = replacements.keys.toSet();
    final topLevel = <String>{};
    for (final id in replacements.keys) {
      if (page.containsTopLevelStrokeId(id)) {
        topLevel.add(id);
        remaining.remove(id);
      }
    }
    final annotationByLayerId = <String, Set<String>>{};
    if (remaining.isNotEmpty) {
      for (final layer in page.annotationLayers) {
        Set<String>? matches;
        for (final stroke in layer.strokes) {
          if (!remaining.remove(stroke.id)) continue;
          (matches ??= <String>{}).add(stroke.id);
        }
        if (matches != null) annotationByLayerId[layer.id] = matches;
        if (remaining.isEmpty) break;
      }
    }
    return (topLevel: topLevel, annotationByLayerId: annotationByLayerId);
  }

  List<InkStroke> _replaceStrokes(
    List<InkStroke> source,
    Set<String> appliedSourceIds,
  ) => <InkStroke>[
    for (final stroke in source)
      if (appliedSourceIds.contains(stroke.id))
        ...replacements[stroke.id]!
      else
        stroke,
  ];

  void _validateReplacementIds(BoardPage page, Set<String> appliedSourceIds) {
    final usedIds = <String>{
      ...page.objects.map((object) => object.id),
      ...page.groups.map((group) => group.id),
      ...page.contentGroups.map((group) => group.id),
      ...page.annotationLayers.map((layer) => layer.id),
      ...page.strokes
          .where((stroke) => !appliedSourceIds.contains(stroke.id))
          .map((stroke) => stroke.id),
      ...page.annotationLayers.expand(
        (layer) => layer.strokes
            .where((stroke) => !appliedSourceIds.contains(stroke.id))
            .map((stroke) => stroke.id),
      ),
    };
    for (final sourceId in appliedSourceIds) {
      for (final fragment in replacements[sourceId]!) {
        if (fragment.id.isEmpty || fragment.points.isEmpty) {
          throw StateError(
            'Radierfragment für $sourceId ist leer oder ungültig.',
          );
        }
        if (!usedIds.add(fragment.id)) {
          throw StateError(
            'Radierfragment-ID ${fragment.id} ist bereits vorhanden.',
          );
        }
      }
    }
  }
}

Rect2 _strokeBounds(
  Iterable<String> memberIds,
  Map<String, InkStroke> strokes,
) {
  Rect2? bounds;
  for (final id in memberIds) {
    final next = strokes[id]?.bounds;
    if (next != null) bounds = bounds == null ? next : bounds.union(next);
  }
  return bounds ?? const Rect2.zero();
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
  return bounds ?? const Rect2.zero();
}
