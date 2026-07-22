import 'package:flutter/material.dart';

import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import '../../../domain/model/scene_order.dart';
import 'board_object_layer.dart';
import 'ink_painter.dart';

/// Paints free ink and board objects in one shared z-order. Consecutive ink
/// entries are intentionally batched into one CustomPaint, so a page with many
/// strokes does not create a widget/render-object per stroke.
class BoardSceneLayer extends StatelessWidget {
  const BoardSceneLayer({
    required this.objects,
    required this.strokes,
    required this.annotationLayers,
    required this.scale,
    required this.offset,
    required this.assets,
    this.selectedIds = const <String>{},
    this.worldClip,
    super.key,
  });

  final List<BoardObject> objects;
  final List<InkStroke> strokes;
  final List<ObjectInkLayer> annotationLayers;
  final double scale;
  final Offset offset;
  final BoardAssetResolver assets;
  final Set<String> selectedIds;
  final Rect2? worldClip;

  @override
  Widget build(BuildContext context) {
    final runs = _buildRuns(
      orderedBoardSceneItems(objects: objects, strokes: strokes),
    );
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (var index = 0; index < runs.length; index++)
          switch (runs[index]) {
            final _ObjectRun run => BoardObjectLayer(
              key: ValueKey('scene-objects-$index-${run.signature}'),
              objects: run.objects,
              annotationLayers: annotationLayers,
              scale: scale,
              offset: offset,
              assets: assets,
              selectedIds: selectedIds,
              worldClip: worldClip,
            ),
            final _StrokeRun run => RepaintBoundary(
              key: ValueKey('scene-ink-$index-${run.signature}'),
              child: CustomPaint(
                painter: InkPainter(
                  strokes: run.strokes,
                  worldToScreenScale: scale,
                  worldToScreenOffset: offset,
                  worldClip: worldClip,
                  selectionIds: selectedIds,
                ),
              ),
            ),
          },
      ],
    );
  }
}

List<_SceneRun> _buildRuns(List<BoardSceneItem> scene) {
  final result = <_SceneRun>[];
  for (final item in scene) {
    final object = item.object;
    if (object != null) {
      final previous = result.lastOrNull;
      if (previous is _ObjectRun) {
        previous.objects.add(object);
      } else {
        result.add(_ObjectRun(<BoardObject>[object]));
      }
      continue;
    }
    final previous = result.lastOrNull;
    if (previous is _StrokeRun) {
      previous.strokes.add(item.stroke!);
    } else {
      result.add(_StrokeRun(<InkStroke>[item.stroke!]));
    }
  }
  return result;
}

sealed class _SceneRun {
  String get signature;
}

final class _ObjectRun extends _SceneRun {
  _ObjectRun(this.objects);

  final List<BoardObject> objects;

  @override
  String get signature =>
      '${objects.length}:${objects.first.id}:${objects.last.id}:'
      '${objects.first.zIndex}:${objects.last.zIndex}';
}

final class _StrokeRun extends _SceneRun {
  _StrokeRun(this.strokes);

  final List<InkStroke> strokes;

  @override
  String get signature =>
      '${strokes.length}:${strokes.first.id}:${strokes.last.id}:'
      '${strokes.first.zIndex}:${strokes.last.zIndex}';
}
