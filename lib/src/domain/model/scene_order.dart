import 'dart:math' as math;

import 'board_object.dart';
import 'ink.dart';

/// The two kinds of top-level content participating in a board page's shared
/// paint and hit-test order. Object-local annotation ink deliberately does not
/// participate: it remains part of its owning object.
enum BoardSceneItemKind { object, stroke }

/// A lightweight, immutable reference to one item in the shared page scene.
final class BoardSceneItem {
  const BoardSceneItem.object(this.object, {required this.stableOrder})
    : stroke = null,
      kind = BoardSceneItemKind.object;

  const BoardSceneItem.stroke(this.stroke, {required this.stableOrder})
    : object = null,
      kind = BoardSceneItemKind.stroke;

  final BoardSceneItemKind kind;
  final BoardObject? object;
  final InkStroke? stroke;

  /// Fallback order used when legacy content shares the same [zIndex]. Objects
  /// are inserted before strokes to preserve the renderer used before ink had
  /// a z-index.
  final int stableOrder;

  String get id => object?.id ?? stroke!.id;
  int get zIndex => object?.zIndex ?? stroke!.zIndex;

  BoardSceneItem withZIndex(int value) {
    if (value == zIndex) return this;
    return switch (kind) {
      BoardSceneItemKind.object => BoardSceneItem.object(
        copyBoardObjectWithZIndex(object!, value),
        stableOrder: stableOrder,
      ),
      BoardSceneItemKind.stroke => BoardSceneItem.stroke(
        stroke!.copyWith(zIndex: value),
        stableOrder: stableOrder,
      ),
    };
  }
}

enum SceneArrangement { oneForward, oneBackward, toFront, toBack }

/// Describes a fixed-length, immutable sparse overlay over a scene list.
///
/// Live transforms usually replace only one or a handful of objects/strokes.
/// Renderers can use this contract to update those entries directly instead
/// of comparing or copying the complete page on every pointer packet.
abstract interface class FixedSceneListOverlay<T> {
  List<T> get sceneSource;
  Map<int, T> get sceneReplacements;
}

/// An immutable list that can prove it was produced by appending exactly one
/// item to another list.
///
/// Renderers may skip an otherwise linear prefix-identity check only when this
/// contract returns true. Implementations must therefore compare immutable
/// revision ancestry, not merely list lengths or value equality.
abstract interface class SingleAppendSceneList<T> {
  bool isSingleAppendOf(List<T> previous);
}

/// Returns a stable, back-to-front scene order shared by painting and hit
/// testing. Equal z-indices intentionally retain the historic list order.
List<BoardSceneItem> orderedBoardSceneItems({
  required Iterable<BoardObject> objects,
  required Iterable<InkStroke> strokes,
}) {
  final objectList = objects is List<BoardObject>
      ? objects
      : objects.toList(growable: false);
  final strokeList = strokes is List<InkStroke>
      ? strokes
      : strokes.toList(growable: false);
  if (_hasMonotonicZOrder(objectList, (object) => object.zIndex) &&
      _hasMonotonicZOrder(strokeList, (stroke) => stroke.zIndex)) {
    // Normal editing keeps each source list in z-order: appends use the next
    // top index and layer commands rewrite both lists from the ordered scene.
    // Merging those two runs is O(N); sorting the complete page for every tap,
    // thumbnail and cold scene rebuild was O(N log N) despite that invariant.
    final result = <BoardSceneItem>[];
    var objectIndex = 0;
    var strokeIndex = 0;
    while (objectIndex < objectList.length || strokeIndex < strokeList.length) {
      if (strokeIndex >= strokeList.length ||
          (objectIndex < objectList.length &&
              objectList[objectIndex].zIndex <=
                  strokeList[strokeIndex].zIndex)) {
        result.add(
          BoardSceneItem.object(
            objectList[objectIndex],
            stableOrder: objectIndex,
          ),
        );
        objectIndex++;
      } else {
        result.add(
          BoardSceneItem.stroke(
            strokeList[strokeIndex],
            stableOrder: objectList.length + strokeIndex,
          ),
        );
        strokeIndex++;
      }
    }
    return result;
  }

  // Crafted/legacy documents can contain independently unsorted source lists.
  // Retain the original stable-sort fallback for those inputs.
  final result = <BoardSceneItem>[];
  var stableOrder = 0;
  for (final object in objectList) {
    result.add(BoardSceneItem.object(object, stableOrder: stableOrder++));
  }
  for (final stroke in strokeList) {
    result.add(BoardSceneItem.stroke(stroke, stableOrder: stableOrder++));
  }
  result.sort((first, second) {
    final byLayer = first.zIndex.compareTo(second.zIndex);
    return byLayer != 0
        ? byLayer
        : first.stableOrder.compareTo(second.stableOrder);
  });
  return result;
}

bool _hasMonotonicZOrder<T>(List<T> values, int Function(T value) zIndexOf) {
  for (var index = 1; index < values.length; index++) {
    if (zIndexOf(values[index - 1]) > zIndexOf(values[index])) return false;
  }
  return true;
}

/// Finds the next free top-level z-index. Starting at zero keeps newly created
/// content compact even when a page is empty or contains only negative values
/// from imported documents.
int nextBoardSceneZIndex({
  required Iterable<BoardObject> objects,
  required Iterable<InkStroke> strokes,
}) {
  var maximum = -1;
  for (final object in objects) {
    maximum = math.max(maximum, object.zIndex);
  }
  for (final stroke in strokes) {
    maximum = math.max(maximum, stroke.zIndex);
  }
  return maximum + 1;
}

/// Reorders selected items as one mixed object/ink scene and normalizes the
/// result to compact, unique z-indices. Relative order inside the selection is
/// retained.
List<BoardSceneItem> arrangeBoardSceneItems({
  required Iterable<BoardObject> objects,
  required Iterable<InkStroke> strokes,
  required Set<String> selectedIds,
  required SceneArrangement arrangement,
}) {
  final values = orderedBoardSceneItems(objects: objects, strokes: strokes);
  if (values.length <= 1 ||
      !values.any((item) => selectedIds.contains(item.id))) {
    return values;
  }
  final originalOrder = values.map((item) => item.id).toList(growable: false);
  {
    bool selected(BoardSceneItem item) => selectedIds.contains(item.id);
    switch (arrangement) {
      case SceneArrangement.toFront:
        final moving = values.where(selected).toList(growable: false);
        values
          ..removeWhere(selected)
          ..addAll(moving);
      case SceneArrangement.toBack:
        final moving = values.where(selected).toList(growable: false);
        values
          ..removeWhere(selected)
          ..insertAll(0, moving);
      case SceneArrangement.oneForward:
        for (var index = values.length - 2; index >= 0; index--) {
          if (selected(values[index]) && !selected(values[index + 1])) {
            final next = values[index + 1];
            values[index + 1] = values[index];
            values[index] = next;
          }
        }
      case SceneArrangement.oneBackward:
        for (var index = 1; index < values.length; index++) {
          if (selected(values[index]) && !selected(values[index - 1])) {
            final previous = values[index - 1];
            values[index - 1] = values[index];
            values[index] = previous;
          }
        }
    }
  }
  var orderChanged = false;
  for (var index = 0; index < values.length; index++) {
    if (values[index].id != originalOrder[index]) {
      orderChanged = true;
      break;
    }
  }
  if (!orderChanged) return values;
  return <BoardSceneItem>[
    for (var index = 0; index < values.length; index++)
      values[index].withZIndex(index),
  ];
}

/// Board objects are sealed and validated by their factory, so rebuilding from
/// JSON keeps all subtype-specific fields intact while changing only z-order.
BoardObject copyBoardObjectWithZIndex(BoardObject object, int zIndex) =>
    BoardObject.fromJson(<String, Object?>{
      ...object.toJson(),
      'zIndex': zIndex,
    });
