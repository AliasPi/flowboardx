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

  BoardSceneItem withZIndex(int value) => switch (kind) {
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

enum SceneArrangement { oneForward, oneBackward, toFront, toBack }

/// Returns a stable, back-to-front scene order shared by painting and hit
/// testing. Equal z-indices intentionally retain the historic list order.
List<BoardSceneItem> orderedBoardSceneItems({
  required Iterable<BoardObject> objects,
  required Iterable<InkStroke> strokes,
}) {
  final result = <BoardSceneItem>[];
  var stableOrder = 0;
  for (final object in objects) {
    result.add(BoardSceneItem.object(object, stableOrder: stableOrder++));
  }
  for (final stroke in strokes) {
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
  if (values.length > 1 &&
      values.any((item) => selectedIds.contains(item.id))) {
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
