import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../editor/editor_controller.dart';
import '../engine/input_policy.dart';
import 'board_background.dart';
import 'board_navigator.dart';
import 'inline_text_editor_overlay.dart';
import 'board_scene_layer.dart';
import 'ink_painter.dart';

typedef EmptyBoardLongPress =
    void Function(Offset screenPosition, Offset worldPosition);

class BoardSurface extends StatefulWidget {
  const BoardSurface({
    required this.controller,
    this.onEmptyLongPress,
    super.key,
  });

  final EditorController controller;
  final EmptyBoardLongPress? onEmptyLongPress;

  @override
  State<BoardSurface> createState() => _BoardSurfaceState();
}

class _BoardSurfaceState extends State<BoardSurface> {
  final Map<int, PointerRole> _roles = {};
  final Map<int, Offset> _navigationPointers = {};
  final Map<int, _GesturePreview> _selectionGestures = {};
  final Map<int, Offset> _selectionStarts = {};
  final Map<int, Offset> _selectionMoveStarts = {};
  String? _selectionTransformOwner;
  Size _size = Size.zero;
  Offset? _hoverPosition;
  late String _activePageId;
  String? _inlineTextObjectId;
  Timer? _navigatorHideTimer;
  bool _navigatorVisible = false;
  Offset? _navigatorPosition;

  EditorController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _activePageId = controller.page.id;
    controller.addListener(_handleControllerChange);
  }

  @override
  void didUpdateWidget(covariant BoardSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChange);
    _clearTransientPointers(oldWidget.controller);
    _activePageId = controller.page.id;
    controller.addListener(_handleControllerChange);
  }

  @override
  void dispose() {
    _navigatorHideTimer?.cancel();
    controller.removeListener(_handleControllerChange);
    super.dispose();
  }

  void _handleControllerChange() {
    final pageId = controller.page.id;
    if (pageId != _activePageId) {
      _activePageId = pageId;
      _inlineTextObjectId = null;
      _clearTransientPointers();
      return;
    }
    final editingId = _inlineTextObjectId;
    if (editingId != null && controller.selectedTextObject?.id != editingId) {
      _inlineTextObjectId = null;
      if (mounted) setState(() {});
    }
  }

  void _clearTransientPointers([EditorController? target]) {
    final activeController = target ?? controller;
    for (final entry in _roles.entries) {
      if (entry.value == PointerRole.ink) {
        activeController.cancelInk(entry.key);
      }
    }
    activeController
      ..cancelErase()
      ..cancelSelectionTransform();
    _roles.clear();
    _navigationPointers.clear();
    _selectionGestures.clear();
    _selectionStarts.clear();
    _selectionMoveStarts.clear();
    _selectionTransformOwner = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return AnimatedBuilder(
          animation: Listenable.merge([controller, controller.viewport]),
          builder: (context, _) {
            final worldClip = _worldClip();
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: MouseRegion(
                    cursor: _cursor,
                    onHover: (event) =>
                        setState(() => _hoverPosition = event.localPosition),
                    onExit: (_) => setState(() => _hoverPosition = null),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPressStart: _handleLongPress,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _onPointerDown,
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerUp,
                        onPointerCancel: _onPointerCancel,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(
                                painter: BoardBackgroundPainter(
                                  viewportScale: controller.viewport.scale,
                                  viewportOffset: controller.viewport.offset,
                                ),
                              ),
                            ),
                            BoardSceneLayer(
                              objects: controller.renderObjects,
                              strokes: controller.renderStrokes,
                              annotationLayers:
                                  controller.page.annotationLayers,
                              scale: controller.viewport.scale,
                              offset: controller.viewport.offset,
                              assets: controller.assetResolver,
                              selectedIds: controller.selectedSceneItemIds,
                              worldClip: worldClip,
                            ),
                            RepaintBoundary(
                              child: AnimatedBuilder(
                                animation: controller.inkSessions,
                                builder: (context, _) => Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    for (final stroke
                                        in controller.renderInkPreviews)
                                      Positioned.fill(
                                        key: ValueKey(stroke.id),
                                        child: RepaintBoundary(
                                          child: CustomPaint(
                                            painter: InkPainter(
                                              strokes: [stroke],
                                              worldToScreenScale:
                                                  controller.viewport.scale,
                                              worldToScreenOffset:
                                                  controller.viewport.offset,
                                              worldClip: worldClip,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _GestureOverlayPainter(
                                  gestures: _selectionGestures.values.toList(
                                    growable: false,
                                  ),
                                  viewportScale: controller.viewport.scale,
                                  viewportOffset: controller.viewport.offset,
                                  tool: controller.tool,
                                  hoverPosition: _hoverPosition,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (controller.hasSelection)
                  _SelectionOverlay(
                    controller: controller,
                    inlineTextEditing: _inlineTextObjectId != null,
                    onEditText: _beginInlineTextEditing,
                    onClaimTransform: _claimSelectionTransform,
                    onReleaseTransform: _releaseSelectionTransform,
                  ),
                if (_inlineTextObjectId case final objectId?)
                  Positioned.fill(
                    child: InlineTextEditorOverlay(
                      key: ValueKey('inline-text-editor-$objectId'),
                      controller: controller,
                      objectId: objectId,
                      onDone: _endInlineTextEditing,
                    ),
                  ),
                if (_navigatorVisible)
                  Positioned(
                    left: _navigatorTopLeft.dx,
                    top: _navigatorTopLeft.dy,
                    child: TweenAnimationBuilder<double>(
                      key: const ValueKey('board-navigator-entrance'),
                      duration: const Duration(milliseconds: 150),
                      tween: Tween(begin: 0, end: 1),
                      builder: (context, value, child) => Opacity(
                        opacity: value,
                        child: Transform.scale(
                          scale: .96 + value * .04,
                          alignment: Alignment.bottomRight,
                          child: child,
                        ),
                      ),
                      child: BoardNavigator(
                        viewport: controller.viewport,
                        viewportSize: _size,
                        objects: controller.renderObjects,
                        strokes: controller.renderStrokes,
                        onNavigate: (world) =>
                            controller.viewport.centerOn(world, _size),
                        onMovePanel: _moveNavigator,
                        onInteractionStart: _beginNavigatorInteraction,
                        onInteractionEnd: _endNavigatorInteraction,
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  MouseCursor get _cursor => switch (controller.tool) {
    BoardTool.pen ||
    BoardTool.marker ||
    BoardTool.dashedPen ||
    BoardTool.straightLine => SystemMouseCursors.precise,
    BoardTool.selectRectangle ||
    BoardTool.selectLasso => SystemMouseCursors.basic,
    BoardTool.shape => SystemMouseCursors.precise,
  };

  bool _claimSelectionTransform(String owner) {
    if (_selectionTransformOwner != null) return false;
    _selectionTransformOwner = owner;
    return true;
  }

  void _releaseSelectionTransform(String owner) {
    if (_selectionTransformOwner == owner) _selectionTransformOwner = null;
  }

  void _onPointerDown(PointerDownEvent event) {
    final world = controller.viewport.screenToWorld(event.localPosition);
    if (_inlineTextObjectId != null) {
      _inlineTextObjectId = null;
      setState(() {});
    }
    if (_selectionTransformOwner != null) {
      // Selection transforms are atomic. A second pen/touch must not clear or
      // overwrite the shared preview while the owning pointer is still down.
      _roles[event.pointer] = PointerRole.ignored;
      return;
    }
    final selectedCover = controller.selectedCover;
    if (_isInkTool(controller.tool) &&
        selectedCover != null &&
        selectedCover.transform.bounds
            .inflate(10 / controller.viewport.scale)
            .contains(Vec2(world.dx, world.dy))) {
      // A newly inserted cover is a transient direct selection: its body and
      // handles stay manipulable even though the pen is already the active
      // tool. A pointer outside follows the normal ink path, whose beginInk
      // clears this selection and resumes writing immediately.
      final owner = 'body-${event.pointer}';
      if (!_claimSelectionTransform(owner)) {
        _roles[event.pointer] = PointerRole.ignored;
        return;
      }
      _roles[event.pointer] = PointerRole.select;
      _selectionStarts[event.pointer] = world;
      _selectionMoveStarts[event.pointer] = world;
      setState(() {});
      return;
    }
    if (controller.tool == BoardTool.shape) {
      _roles[event.pointer] = PointerRole.select;
      _selectionStarts[event.pointer] = world;
      _selectionGestures[event.pointer] = _GesturePreview(
        tool: BoardTool.shape,
        shape: controller.activeShape,
        points: <Offset>[world, world],
      );
      setState(() {});
      return;
    }
    final role = controller.pointerPolicy.classifyDown(
      event,
      tool: controller.tool,
      selectionActive: controller.hasSelection,
      stylusCurrentlyActive: controller.inkSessions.sessions.isNotEmpty,
      activeNavigationTouches: _navigationPointers.length,
    );
    _roles[event.pointer] = role;
    switch (role) {
      case PointerRole.ink:
        if (!controller.beginInk(event, world)) {
          _roles[event.pointer] = PointerRole.ignored;
        }
      case PointerRole.erase:
        controller.eraseAt(
          world,
          radius: math.max(18, event.radiusMajor) / controller.viewport.scale,
        );
      case PointerRole.navigate:
        _navigationPointers[event.pointer] = event.localPosition;
      case PointerRole.select:
        if (_selectionTransformOwner != null) {
          _roles[event.pointer] = PointerRole.ignored;
          break;
        }
        _selectionStarts[event.pointer] = world;
        final insideSelection =
            controller.hasSelection &&
            controller.selectionBounds
                .inflate(12 / controller.viewport.scale)
                .contains(Vec2(world.dx, world.dy));
        if (insideSelection) {
          final owner = 'body-${event.pointer}';
          if (_claimSelectionTransform(owner)) {
            _selectionMoveStarts[event.pointer] = world;
          } else {
            _roles[event.pointer] = PointerRole.ignored;
            _selectionStarts.remove(event.pointer);
          }
        } else {
          _selectionGestures[event.pointer] = _GesturePreview(
            tool: controller.tool,
            shape: controller.activeShape,
            points: <Offset>[world, world],
          );
        }
        setState(() {});
      case PointerRole.ignored:
        break;
    }
  }

  bool _isInkTool(BoardTool tool) =>
      tool == BoardTool.pen ||
      tool == BoardTool.marker ||
      tool == BoardTool.dashedPen ||
      tool == BoardTool.straightLine;

  void _onPointerMove(PointerMoveEvent event) {
    final role = _roles[event.pointer];
    final world = controller.viewport.screenToWorld(event.localPosition);
    switch (role) {
      case PointerRole.ink:
        controller.updateInk(event, world);
      case PointerRole.erase:
        controller.eraseAt(
          world,
          radius: math.max(18, event.radiusMajor) / controller.viewport.scale,
        );
      case PointerRole.navigate:
        _updateNavigation(event);
      case PointerRole.select:
        final moveStart = _selectionMoveStarts[event.pointer];
        if (moveStart != null) {
          controller.previewMoveSelection(world - moveStart);
          break;
        }
        final preview = _selectionGestures[event.pointer];
        if (preview == null) break;
        if (preview.tool == BoardTool.selectLasso) {
          if ((preview.points.last - world).distance >
              1.5 / controller.viewport.scale) {
            if (preview.points.length < 4096) {
              preview.points.add(world);
            } else {
              preview.points[preview.points.length - 1] = world;
            }
            setState(() {});
          }
        } else {
          final gestureStart = preview.points.isEmpty
              ? world
              : preview.points.first;
          preview.points
            ..clear()
            ..addAll(<Offset>[gestureStart, world]);
          setState(() {});
        }
      case PointerRole.ignored || null:
        break;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final role = _roles.remove(event.pointer);
    final world = controller.viewport.screenToWorld(event.localPosition);
    switch (role) {
      case PointerRole.ink:
        controller.endInk(event, world);
      case PointerRole.erase:
        controller.commitErase();
      case PointerRole.navigate:
        _navigationPointers.remove(event.pointer);
        if (_navigationPointers.isEmpty) {
          controller.commitViewport();
          _scheduleNavigatorHide();
        }
      case PointerRole.select:
        _finishSelection(event.pointer, world);
      case PointerRole.ignored || null:
        break;
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    final role = _roles.remove(event.pointer);
    if (role == PointerRole.ink) controller.cancelInk(event.pointer);
    if (role == PointerRole.erase) controller.commitErase();
    if (role == PointerRole.navigate) {
      _navigationPointers.remove(event.pointer);
      if (_navigationPointers.isEmpty) {
        controller.commitViewport();
        _scheduleNavigatorHide();
      }
    }
    if (_selectionMoveStarts.remove(event.pointer) != null) {
      controller.cancelSelectionTransform();
      _releaseSelectionTransform('body-${event.pointer}');
    }
    _selectionGestures.remove(event.pointer);
    _selectionStarts.remove(event.pointer);
    if (mounted) setState(() {});
  }

  void _updateNavigation(PointerMoveEvent event) {
    final previous = _navigationPointers[event.pointer];
    if (previous == null) return;
    if (_navigationPointers.length == 1) {
      controller.viewport.panBy(event.localPosition - previous, _size);
      _navigationPointers[event.pointer] = event.localPosition;
      return;
    }
    final entries = _navigationPointers.entries.take(2).toList();
    final firstId = entries[0].key;
    final secondId = entries[1].key;
    final oldFirst = entries[0].value;
    final oldSecond = entries[1].value;
    final newFirst = firstId == event.pointer ? event.localPosition : oldFirst;
    final newSecond = secondId == event.pointer
        ? event.localPosition
        : oldSecond;
    final oldCentroid = (oldFirst + oldSecond) / 2;
    final newCentroid = (newFirst + newSecond) / 2;
    controller.viewport.panBy(newCentroid - oldCentroid, _size);
    final oldDistance = (oldFirst - oldSecond).distance;
    final newDistance = (newFirst - newSecond).distance;
    if (oldDistance > 4 && newDistance > 4 && !controller.hasSelection) {
      controller.viewport.zoomAt(
        factor: newDistance / oldDistance,
        focalPoint: newCentroid,
        viewportSize: _size,
      );
      _showNavigatorDuringGesture();
    }
    _navigationPointers[event.pointer] = event.localPosition;
  }

  Offset get _navigatorTopLeft {
    final panel = BoardNavigator.preferredSize;
    final fallback = Offset(
      _size.width - panel.width - 18,
      _size.height - panel.height - 18,
    );
    return _clampNavigatorPosition(_navigatorPosition ?? fallback);
  }

  Offset _clampNavigatorPosition(Offset value) {
    final panel = BoardNavigator.preferredSize;
    return Offset(
      value.dx.clamp(8.0, math.max(8.0, _size.width - panel.width - 8)),
      value.dy.clamp(8.0, math.max(8.0, _size.height - panel.height - 8)),
    );
  }

  void _showNavigator() {
    _showNavigatorDuringGesture();
    _scheduleNavigatorHide();
  }

  void _showNavigatorDuringGesture() {
    _navigatorHideTimer?.cancel();
    _navigatorHideTimer = null;
    if (!_navigatorVisible && mounted) {
      setState(() => _navigatorVisible = true);
    }
  }

  void _scheduleNavigatorHide() {
    _navigatorHideTimer?.cancel();
    _navigatorHideTimer = null;
    if (!_navigatorVisible) return;
    _navigatorHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _navigatorVisible = false);
    });
  }

  void _beginNavigatorInteraction() {
    _navigatorHideTimer?.cancel();
  }

  void _endNavigatorInteraction() {
    controller.commitViewport();
    _showNavigator();
  }

  void _moveNavigator(Offset delta) {
    if (!delta.dx.isFinite || !delta.dy.isFinite) return;
    setState(() {
      _navigatorPosition = _clampNavigatorPosition(_navigatorTopLeft + delta);
    });
  }

  void _finishSelection(int pointer, Offset end) {
    final start = _selectionStarts.remove(pointer);
    final moveStart = _selectionMoveStarts.remove(pointer);
    final preview = _selectionGestures.remove(pointer);
    final path = preview?.points ?? const <Offset>[];
    if (start == null) {
      _releaseSelectionTransform('body-$pointer');
      return;
    }
    final distance = (end - start).distance;
    if (moveStart != null) {
      try {
        if (distance > 3 / controller.viewport.scale) {
          controller.commitSelectionTransform();
        } else {
          controller.cancelSelectionTransform();
          controller.selectAt(end);
        }
      } finally {
        _releaseSelectionTransform('body-$pointer');
      }
    } else if (preview?.tool == BoardTool.shape) {
      var shapeEnd = end;
      final shape = preview?.shape ?? controller.activeShape;
      if (shape == ShapeKind.circle) {
        final delta = end - start;
        final side = math.max(delta.dx.abs(), delta.dy.abs());
        shapeEnd = Offset(
          start.dx + (delta.dx < 0 ? -side : side),
          start.dy + (delta.dy < 0 ? -side : side),
        );
      }
      controller.addShape(shape, Rect.fromPoints(start, shapeEnd));
    } else if (distance < 8 / controller.viewport.scale) {
      controller.selectAt(end);
    } else if (preview?.tool == BoardTool.selectLasso) {
      controller.selectLasso([...path, end]);
    } else {
      controller.selectRectangle(Rect.fromPoints(start, end));
    }
    if (mounted) setState(() {});
  }

  void _handleLongPress(LongPressStartDetails details) {
    if (controller.inkSessions.isWriting) return;
    final world = controller.viewport.screenToWorld(details.localPosition);
    if (controller.selectionEngine
        .candidatesAt(
          controller.page,
          Vec2(world.dx, world.dy),
          tolerance: 12 / controller.viewport.scale,
        )
        .isEmpty) {
      widget.onEmptyLongPress?.call(details.localPosition, world);
    }
  }

  Rect2 _worldClip() {
    final topLeft = controller.viewport.screenToWorld(Offset.zero);
    final bottomRight = controller.viewport.screenToWorld(
      Offset(_size.width, _size.height),
    );
    return Rect2(
      left: topLeft.dx,
      top: topLeft.dy,
      width: bottomRight.dx - topLeft.dx,
      height: bottomRight.dy - topLeft.dy,
    ).inflate(80 / controller.viewport.scale);
  }

  void _beginInlineTextEditing() {
    final value = controller.selectedTextObject;
    if (value == null) return;
    setState(() => _inlineTextObjectId = value.id);
  }

  void _endInlineTextEditing() {
    if (!mounted || _inlineTextObjectId == null) return;
    setState(() => _inlineTextObjectId = null);
  }
}

class _SelectionOverlay extends StatefulWidget {
  const _SelectionOverlay({
    required this.controller,
    required this.inlineTextEditing,
    required this.onEditText,
    required this.onClaimTransform,
    required this.onReleaseTransform,
  });
  final EditorController controller;
  final bool inlineTextEditing;
  final VoidCallback onEditText;
  final bool Function(String owner) onClaimTransform;
  final void Function(String owner) onReleaseTransform;

  @override
  State<_SelectionOverlay> createState() => _SelectionOverlayState();
}

class _SelectionOverlayState extends State<_SelectionOverlay> {
  double _pendingScale = 1;
  Offset? _scaleAnchor;
  bool _ownsDiagonalScale = false;

  bool _claimCoverControl(String owner) =>
      widget.onClaimTransform('cover-$owner');

  void _releaseCoverControl(String owner) {
    widget.onReleaseTransform('cover-$owner');
  }

  @override
  void dispose() {
    if (_ownsDiagonalScale) {
      widget.controller.cancelSelectionTransform();
      widget.onReleaseTransform('selection-diagonal');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final world = controller.selectionBounds;
    if (world.isEmpty) return const SizedBox.shrink();
    final topLeft = controller.viewport.worldToScreen(
      Offset(world.left, world.top),
    );
    final bottomRight = controller.viewport.worldToScreen(
      Offset(world.right, world.bottom),
    );
    final rect = Rect.fromPoints(topLeft, bottomRight).inflate(5);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: FlowboardColors.mint, width: 3),
                color: FlowboardColors.mint.withValues(alpha: .075),
                boxShadow: [
                  BoxShadow(
                    color: FlowboardColors.mint.withValues(alpha: .24),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!widget.inlineTextEditing && controller.selectedCover == null)
          Positioned(
            left: rect.left,
            top: math.max(8, rect.top - 62),
            child: _SelectionActions(
              controller: controller,
              onEditText: widget.onEditText,
            ),
          ),
        // Covers have one dedicated resize handle in the centre of each edge.
        // The generic diagonal handle would add a fifth (and, at the bottom
        // right, visually overlapping) size control.
        if (!widget.inlineTextEditing && controller.selectedCover == null)
          Positioned(
            left: rect.right - 24,
            top: rect.bottom - 24,
            child: Semantics(
              label: 'Auswahl skalieren',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  _ownsDiagonalScale = widget.onClaimTransform(
                    'selection-diagonal',
                  );
                  if (!_ownsDiagonalScale) return;
                  _pendingScale = 1;
                  _scaleAnchor = Offset(world.left, world.top);
                },
                onPanUpdate: (details) {
                  if (!_ownsDiagonalScale) return;
                  final baseline = math.max(40, rect.size.longestSide);
                  _pendingScale =
                      (_pendingScale +
                              (details.delta.dx + details.delta.dy) / baseline)
                          .clamp(.15, 6);
                  final anchor = _scaleAnchor;
                  if (anchor != null) {
                    widget.controller.previewScaleSelection(
                      _pendingScale,
                      anchor: anchor,
                    );
                  }
                },
                onPanEnd: (_) {
                  if (!_ownsDiagonalScale) return;
                  widget.controller.commitSelectionTransform();
                  _pendingScale = 1;
                  _scaleAnchor = null;
                  _ownsDiagonalScale = false;
                  widget.onReleaseTransform('selection-diagonal');
                },
                onPanCancel: () {
                  if (!_ownsDiagonalScale) return;
                  widget.controller.cancelSelectionTransform();
                  _pendingScale = 1;
                  _scaleAnchor = null;
                  _ownsDiagonalScale = false;
                  widget.onReleaseTransform('selection-diagonal');
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: FlowboardColors.mint,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 8),
                    ],
                  ),
                  child: const Icon(
                    Icons.open_in_full_rounded,
                    size: 22,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        if (!widget.inlineTextEditing && controller.selectedCover == null)
          Positioned.fill(
            child: _SelectionEdgeResizeHandles(
              controller: controller,
              objectRect: rect,
              onClaim: (edge) =>
                  widget.onClaimTransform('selection-edge-${edge.name}'),
              onRelease: (edge) =>
                  widget.onReleaseTransform('selection-edge-${edge.name}'),
            ),
          ),
        if (controller.selectedCover case final cover?)
          Positioned.fill(
            child: _CoverRevealControl(
              controller: controller,
              cover: cover,
              onClaim: () => _claimCoverControl('reveal-${cover.id}'),
              onRelease: () => _releaseCoverControl('reveal-${cover.id}'),
              objectRect: Rect.fromPoints(
                controller.viewport.worldToScreen(
                  Offset(cover.transform.x, cover.transform.y),
                ),
                controller.viewport.worldToScreen(
                  Offset(
                    cover.transform.x + cover.transform.width,
                    cover.transform.y + cover.transform.height,
                  ),
                ),
              ),
            ),
          ),
        if (!widget.inlineTextEditing)
          if (controller.selectedCover case final cover?)
            Positioned.fill(
              child: _CoverResizeHandles(
                controller: controller,
                cover: cover,
                onClaim: (edge) =>
                    _claimCoverControl('resize-${cover.id}-${edge.name}'),
                onRelease: (edge) =>
                    _releaseCoverControl('resize-${cover.id}-${edge.name}'),
                objectRect: Rect.fromPoints(
                  controller.viewport.worldToScreen(
                    Offset(cover.transform.x, cover.transform.y),
                  ),
                  controller.viewport.worldToScreen(
                    Offset(
                      cover.transform.x + cover.transform.width,
                      cover.transform.y + cover.transform.height,
                    ),
                  ),
                ),
              ),
            ),
        if (controller.selectedPdf case final pdf?)
          Positioned(
            left: math.max(8, rect.left),
            top: rect.bottom + 12,
            child: _PdfPageControl(controller: controller, pdf: pdf),
          ),
      ],
    );
  }
}

enum _CoverResizeEdge { left, top, right, bottom }

class _SelectionEdgeResizeHandles extends StatefulWidget {
  const _SelectionEdgeResizeHandles({
    required this.controller,
    required this.objectRect,
    required this.onClaim,
    required this.onRelease,
  });

  final EditorController controller;
  final Rect objectRect;
  final bool Function(_CoverResizeEdge edge) onClaim;
  final void Function(_CoverResizeEdge edge) onRelease;

  @override
  State<_SelectionEdgeResizeHandles> createState() =>
      _SelectionEdgeResizeHandlesState();
}

class _SelectionEdgeResizeHandlesState
    extends State<_SelectionEdgeResizeHandles> {
  _CoverResizeEdge? _activeEdge;
  Rect2? _baseBounds;
  Offset _worldDelta = Offset.zero;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [for (final edge in _CoverResizeEdge.values) _handle(edge)],
  );

  Widget _handle(_CoverResizeEdge edge) {
    final center = switch (edge) {
      _CoverResizeEdge.left => widget.objectRect.centerLeft,
      _CoverResizeEdge.top => widget.objectRect.topCenter,
      _CoverResizeEdge.right => widget.objectRect.centerRight,
      _CoverResizeEdge.bottom => widget.objectRect.bottomCenter,
    };
    final vertical =
        edge == _CoverResizeEdge.left || edge == _CoverResizeEdge.right;
    return Positioned(
      left: center.dx - 22,
      top: center.dy - 22,
      width: 44,
      height: 44,
      child: Semantics(
        label: 'Auswahl ${_edgeLabel(edge)} frei skalieren',
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            if (_activeEdge != null || !widget.onClaim(edge)) return;
            _activeEdge = edge;
            _baseBounds = widget.controller.selectionBounds;
            _worldDelta = Offset.zero;
          },
          onPanUpdate: (details) {
            if (_activeEdge != edge) return;
            final base = _baseBounds;
            final viewportScale = widget.controller.viewport.scale;
            if (base == null ||
                base.isEmpty ||
                !viewportScale.isFinite ||
                viewportScale <= 0) {
              return;
            }
            _worldDelta += details.delta / viewportScale;
            final minimumWorldSize = math.max(8.0, 28 / viewportScale);
            var scaleX = 1.0;
            var scaleY = 1.0;
            late final Offset anchor;
            switch (edge) {
              case _CoverResizeEdge.left:
                scaleX = ((base.width - _worldDelta.dx) / base.width).clamp(
                  math.min(1.0, minimumWorldSize / base.width),
                  20.0,
                );
                anchor = Offset(base.right, base.top);
              case _CoverResizeEdge.top:
                scaleY = ((base.height - _worldDelta.dy) / base.height).clamp(
                  math.min(1.0, minimumWorldSize / base.height),
                  20.0,
                );
                anchor = Offset(base.left, base.bottom);
              case _CoverResizeEdge.right:
                scaleX = ((base.width + _worldDelta.dx) / base.width).clamp(
                  math.min(1.0, minimumWorldSize / base.width),
                  20.0,
                );
                anchor = Offset(base.left, base.top);
              case _CoverResizeEdge.bottom:
                scaleY = ((base.height + _worldDelta.dy) / base.height).clamp(
                  math.min(1.0, minimumWorldSize / base.height),
                  20.0,
                );
                anchor = Offset(base.left, base.top);
            }
            widget.controller.previewResizeSelection(
              scaleX: scaleX,
              scaleY: scaleY,
              anchor: anchor,
            );
          },
          onPanEnd: (_) => _finish(edge, commit: true),
          onPanCancel: () => _finish(edge, commit: false),
          child: Center(
            child: Container(
              width: vertical ? 9 : 27,
              height: vertical ? 27 : 9,
              decoration: BoxDecoration(
                color: FlowboardColors.mint,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 5),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _finish(_CoverResizeEdge edge, {required bool commit}) {
    if (_activeEdge != edge) return;
    if (commit) {
      widget.controller.commitSelectionTransform();
    } else {
      widget.controller.cancelSelectionTransform();
    }
    _activeEdge = null;
    _baseBounds = null;
    _worldDelta = Offset.zero;
    widget.onRelease(edge);
  }

  @override
  void dispose() {
    final edge = _activeEdge;
    if (edge != null) {
      widget.controller.cancelSelectionTransform();
      widget.onRelease(edge);
    }
    super.dispose();
  }
}

class _CoverResizeHandles extends StatelessWidget {
  const _CoverResizeHandles({
    required this.controller,
    required this.cover,
    required this.objectRect,
    required this.onClaim,
    required this.onRelease,
  });

  final EditorController controller;
  final CoverObject cover;
  final Rect objectRect;
  final bool Function(_CoverResizeEdge edge) onClaim;
  final void Function(_CoverResizeEdge edge) onRelease;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      for (final edge in _CoverResizeEdge.values)
        _CoverResizeHandle(
          key: ValueKey('cover-resize-${edge.name}-${cover.id}'),
          controller: controller,
          cover: cover,
          objectRect: objectRect,
          edge: edge,
          onClaim: () => onClaim(edge),
          onRelease: () => onRelease(edge),
        ),
    ],
  );
}

class _CoverResizeHandle extends StatefulWidget {
  const _CoverResizeHandle({
    required this.controller,
    required this.cover,
    required this.objectRect,
    required this.edge,
    required this.onClaim,
    required this.onRelease,
    super.key,
  });

  final EditorController controller;
  final CoverObject cover;
  final Rect objectRect;
  final _CoverResizeEdge edge;
  final ValueGetter<bool> onClaim;
  final VoidCallback onRelease;

  @override
  State<_CoverResizeHandle> createState() => _CoverResizeHandleState();
}

class _CoverResizeHandleState extends State<_CoverResizeHandle> {
  Rect2? _baseBounds;
  Offset _accumulatedWorldDelta = Offset.zero;
  bool _ownsGesture = false;

  bool get _horizontal =>
      widget.edge == _CoverResizeEdge.left ||
      widget.edge == _CoverResizeEdge.right;

  Offset get _screenCenter => switch (widget.edge) {
    _CoverResizeEdge.left => widget.objectRect.centerLeft,
    _CoverResizeEdge.top => widget.objectRect.topCenter,
    _CoverResizeEdge.right => widget.objectRect.centerRight,
    _CoverResizeEdge.bottom => widget.objectRect.bottomCenter,
  };

  @override
  Widget build(BuildContext context) {
    final center = _screenCenter;
    return Positioned(
      left: center.dx - 23,
      top: center.dy - 23,
      width: 46,
      height: 46,
      child: Semantics(
        label: 'Abdeckung ${_edgeLabel(widget.edge)} skalieren',
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            _ownsGesture = widget.onClaim();
            if (!_ownsGesture) return;
            final transform = widget.cover.transform;
            _baseBounds = Rect2(
              left: transform.x,
              top: transform.y,
              width: transform.width,
              height: transform.height,
            );
            _accumulatedWorldDelta = Offset.zero;
          },
          onPanUpdate: (details) {
            if (!_ownsGesture) return;
            final base = _baseBounds;
            final scale = widget.controller.viewport.scale;
            if (base == null || !scale.isFinite || scale <= 0) return;
            _accumulatedWorldDelta += details.delta / scale;
            final minWidth = math.min(48.0, base.width);
            final minHeight = math.min(48.0, base.height);
            var scaleX = 1.0;
            var scaleY = 1.0;
            late final Offset anchor;
            switch (widget.edge) {
              case _CoverResizeEdge.left:
                scaleX = ((base.width - _accumulatedWorldDelta.dx) / base.width)
                    .clamp(minWidth / base.width, 20.0);
                anchor = Offset(base.right, base.top);
              case _CoverResizeEdge.top:
                scaleY =
                    ((base.height - _accumulatedWorldDelta.dy) / base.height)
                        .clamp(minHeight / base.height, 20.0);
                anchor = Offset(base.left, base.bottom);
              case _CoverResizeEdge.right:
                scaleX = ((base.width + _accumulatedWorldDelta.dx) / base.width)
                    .clamp(minWidth / base.width, 20.0);
                anchor = Offset(base.left, base.top);
              case _CoverResizeEdge.bottom:
                scaleY =
                    ((base.height + _accumulatedWorldDelta.dy) / base.height)
                        .clamp(minHeight / base.height, 20.0);
                anchor = Offset(base.left, base.top);
            }
            widget.controller.previewResizeSelection(
              scaleX: scaleX,
              scaleY: scaleY,
              anchor: anchor,
            );
          },
          onPanEnd: (_) => _finish(commit: true),
          onPanCancel: () => _finish(commit: false),
          child: Center(
            child: Container(
              width: _horizontal ? 9 : 27,
              height: _horizontal ? 27 : 9,
              decoration: BoxDecoration(
                color: FlowboardColors.mint,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 5),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _finish({required bool commit}) {
    if (!_ownsGesture) return;
    if (commit) {
      widget.controller.commitSelectionTransform();
    } else {
      widget.controller.cancelSelectionTransform();
    }
    _baseBounds = null;
    _accumulatedWorldDelta = Offset.zero;
    _ownsGesture = false;
    widget.onRelease();
  }

  @override
  void dispose() {
    if (_ownsGesture) {
      widget.controller.cancelSelectionTransform();
      widget.onRelease();
    }
    super.dispose();
  }
}

String _edgeLabel(_CoverResizeEdge edge) => switch (edge) {
  _CoverResizeEdge.left => 'links',
  _CoverResizeEdge.top => 'oben',
  _CoverResizeEdge.right => 'rechts',
  _CoverResizeEdge.bottom => 'unten',
};

class _CoverRevealControl extends StatefulWidget {
  const _CoverRevealControl({
    required this.controller,
    required this.cover,
    required this.objectRect,
    required this.onClaim,
    required this.onRelease,
  });

  final EditorController controller;
  final CoverObject cover;
  final Rect objectRect;
  final ValueGetter<bool> onClaim;
  final VoidCallback onRelease;

  @override
  State<_CoverRevealControl> createState() => _CoverRevealControlState();
}

class _CoverRevealControlState extends State<_CoverRevealControl> {
  bool _ownsGesture = false;

  EditorController get controller => widget.controller;
  CoverObject get cover => widget.cover;
  Rect get objectRect => widget.objectRect;

  @override
  Widget build(BuildContext context) {
    final horizontal =
        cover.direction == RevealDirection.leftToRight ||
        cover.direction == RevealDirection.rightToLeft;
    final value = controller.coverRevealValue(cover.id, cover.reveal);
    final guidePosition = switch (cover.direction) {
      RevealDirection.leftToRight => Offset(
        objectRect.left + objectRect.width * value,
        objectRect.center.dy,
      ),
      RevealDirection.rightToLeft => Offset(
        objectRect.right - objectRect.width * value,
        objectRect.center.dy,
      ),
      RevealDirection.topToBottom => Offset(
        objectRect.center.dx,
        objectRect.top + objectRect.height * value,
      ),
      RevealDirection.bottomToTop => Offset(
        objectRect.center.dx,
        objectRect.bottom - objectRect.height * value,
      ),
    };
    // The blue reveal boundary itself is the drag target. It deliberately has
    // no second knob: selected covers must show exactly one size control per
    // edge. The resize controls are painted after this target and therefore
    // retain priority at the four edge centres when both hit regions cross.
    final guideHitRect = horizontal
        ? Rect.fromCenter(
            center: guidePosition,
            width: 44,
            height: objectRect.height,
          )
        : Rect.fromCenter(
            center: guidePosition,
            width: objectRect.width,
            height: 44,
          );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fromRect(
          rect: objectRect,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _CoverRevealGuidePainter(
                direction: cover.direction,
                reveal: value,
              ),
            ),
          ),
        ),
        Positioned(
          key: ValueKey('cover-reveal-guide-${cover.id}'),
          left: guideHitRect.left,
          top: guideHitRect.top,
          width: guideHitRect.width,
          height: guideHitRect.height,
          child: Semantics(
            label: 'Abdeckung freilegen',
            slider: true,
            value: '${(value * 100).round()} Prozent',
            increasedValue:
                '${((value + .1).clamp(0.0, 1.0) * 100).round()} Prozent',
            decreasedValue:
                '${((value - .1).clamp(0.0, 1.0) * 100).round()} Prozent',
            onIncrease: () => _adjustSemantics(.1),
            onDecrease: () => _adjustSemantics(-.1),
            child: MouseRegion(
              cursor: horizontal
                  ? SystemMouseCursors.resizeLeftRight
                  : SystemMouseCursors.resizeUpDown,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => _ownsGesture = widget.onClaim(),
                onPanUpdate: (details) {
                  if (!_ownsGesture) return;
                  final extent = horizontal
                      ? objectRect.width
                      : objectRect.height;
                  if (!extent.isFinite || extent <= 0) return;
                  final signedDelta = switch (cover.direction) {
                    RevealDirection.leftToRight => details.delta.dx,
                    RevealDirection.rightToLeft => -details.delta.dx,
                    RevealDirection.topToBottom => details.delta.dy,
                    RevealDirection.bottomToTop => -details.delta.dy,
                  };
                  final current = controller.coverRevealValue(
                    cover.id,
                    cover.reveal,
                  );
                  controller.previewCoverReveal(
                    cover.id,
                    (current + signedDelta / extent).clamp(0.0, 1.0),
                  );
                },
                onPanEnd: (_) => _finish(commit: true),
                onPanCancel: () => _finish(commit: false),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _adjustSemantics(double delta) {
    if (_ownsGesture || !widget.onClaim()) return;
    _ownsGesture = true;
    final current = controller.coverRevealValue(cover.id, cover.reveal);
    controller.previewCoverReveal(cover.id, (current + delta).clamp(0.0, 1.0));
    _finish(commit: true);
  }

  void _finish({required bool commit}) {
    if (!_ownsGesture) return;
    if (commit) {
      controller.commitCoverReveal(
        cover.id,
        controller.coverRevealValue(cover.id, cover.reveal),
      );
    } else {
      controller.cancelCoverReveal(cover.id);
    }
    _ownsGesture = false;
    widget.onRelease();
  }

  @override
  void dispose() {
    if (_ownsGesture) {
      controller.cancelCoverReveal(cover.id);
      widget.onRelease();
    }
    super.dispose();
  }
}

class _CoverRevealGuidePainter extends CustomPainter {
  const _CoverRevealGuidePainter({
    required this.direction,
    required this.reveal,
  });

  final RevealDirection direction;
  final double reveal;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = FlowboardColors.blue
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final value = reveal.clamp(0.0, 1.0);
    switch (direction) {
      case RevealDirection.leftToRight:
        final x = size.width * value;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      case RevealDirection.rightToLeft:
        final x = size.width * (1 - value);
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      case RevealDirection.topToBottom:
        final y = size.height * value;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      case RevealDirection.bottomToTop:
        final y = size.height * (1 - value);
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CoverRevealGuidePainter oldDelegate) =>
      oldDelegate.direction != direction || oldDelegate.reveal != reveal;
}

class _PdfPageControl extends StatelessWidget {
  const _PdfPageControl({required this.controller, required this.pdf});

  final EditorController controller;
  final PdfObject pdf;

  @override
  Widget build(BuildContext context) {
    final count = math.max(1, pdf.pageIndices.length);
    final index = pdf.activePageIndex.clamp(0, count - 1);
    return Material(
      color: FlowboardColors.panel,
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Vorherige PDF-Seite',
            onPressed: index > 0
                ? () => controller.setPdfActivePage(pdf.id, index - 1)
                : null,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('PDF ${index + 1} / $count'),
          ),
          IconButton(
            tooltip: 'Nächste PDF-Seite',
            onPressed: index + 1 < count
                ? () => controller.setPdfActivePage(pdf.id, index + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
    );
  }
}

class _SelectionActions extends StatelessWidget {
  const _SelectionActions({required this.controller, required this.onEditText});
  final EditorController controller;
  final VoidCallback onEditText;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FlowboardColors.panel,
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _action(
              Icons.copy_all_rounded,
              'Duplizieren',
              controller.duplicateSelection,
            ),
            _action(
              Icons.content_copy_rounded,
              'Kopieren',
              controller.copySelection,
            ),
            _action(
              Icons.content_cut_rounded,
              'Ausschneiden',
              controller.cutSelection,
            ),
            if (controller.canGroupSelection)
              _action(
                Icons.group_work_outlined,
                'Gruppieren',
                controller.groupSelection,
              ),
            if (controller.selectedContentGroup != null)
              _action(
                Icons.call_split_rounded,
                'Gruppierung aufheben',
                controller.ungroupSelection,
              ),
            if (controller.canArrangeSelection)
              PopupMenuButton<LayerArrangement>(
                tooltip: 'Anordnung ändern',
                icon: const Icon(Icons.layers_outlined),
                onSelected: controller.arrangeSelection,
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: LayerArrangement.oneForward,
                    child: ListTile(
                      leading: Icon(Icons.flip_to_front_outlined),
                      title: Text('Eine Ebene nach vorn'),
                    ),
                  ),
                  PopupMenuItem(
                    value: LayerArrangement.oneBackward,
                    child: ListTile(
                      leading: Icon(Icons.flip_to_back_outlined),
                      title: Text('Eine Ebene nach hinten'),
                    ),
                  ),
                  PopupMenuItem(
                    value: LayerArrangement.toFront,
                    child: ListTile(
                      leading: Icon(Icons.vertical_align_top_rounded),
                      title: Text('Ganz nach vorn'),
                    ),
                  ),
                  PopupMenuItem(
                    value: LayerArrangement.toBack,
                    child: ListTile(
                      leading: Icon(Icons.vertical_align_bottom_rounded),
                      title: Text('Ganz nach hinten'),
                    ),
                  ),
                ],
              ),
            if (controller.hasSelectedHandwriting)
              _action(
                Icons.text_fields_rounded,
                'Handschrift in Text umwandeln',
                () => unawaited(controller.convertSelectedHandwritingToText()),
              ),
            if (controller.selectedTextObject case final text?)
              PopupMenuButton<double>(
                tooltip: 'Schriftgröße ändern',
                icon: const Icon(Icons.format_size_rounded),
                onSelected: (size) => controller.updateTextObject(
                  objectId: text.id,
                  text: text.text,
                  fontSize: size,
                ),
                itemBuilder: (context) => <PopupMenuEntry<double>>[
                  PopupMenuItem<double>(
                    value: math.max(12, text.fontSize - 4),
                    child: Text(
                      'Kleiner · ${math.max(12, text.fontSize - 4).round()} px',
                    ),
                  ),
                  PopupMenuItem<double>(
                    value: math.min(160, text.fontSize + 4),
                    child: Text(
                      'Größer · ${math.min(160, text.fontSize + 4).round()} px',
                    ),
                  ),
                  const PopupMenuDivider(),
                  for (final size in const <double>[
                    16,
                    24,
                    32,
                    40,
                    48,
                    64,
                    80,
                    96,
                    120,
                    160,
                  ])
                    PopupMenuItem<double>(
                      value: size,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Icon(
                              (text.fontSize - size).abs() < .1
                                  ? Icons.check_rounded
                                  : null,
                              color: FlowboardColors.mint,
                            ),
                          ),
                          Text('${size.round()} px'),
                        ],
                      ),
                    ),
                ],
              ),
            if (controller.selectedTextObject != null)
              _action(
                Icons.draw_rounded,
                'Text mit Stift korrigieren',
                onEditText,
              ),
            _action(
              Icons.delete_outline_rounded,
              'Löschen',
              controller.deleteSelection,
              danger: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(
    IconData icon,
    String label,
    VoidCallback action, {
    bool danger = false,
  }) {
    return Tooltip(
      message: label,
      child: IconButton(
        onPressed: action,
        icon: Icon(
          icon,
          color: danger ? FlowboardColors.danger : FlowboardColors.textPrimary,
        ),
      ),
    );
  }
}

final class _GesturePreview {
  _GesturePreview({
    required this.tool,
    required this.shape,
    required this.points,
  });

  final BoardTool tool;
  final ShapeKind shape;
  final List<Offset> points;
}

class _GestureOverlayPainter extends CustomPainter {
  const _GestureOverlayPainter({
    required this.gestures,
    required this.viewportScale,
    required this.viewportOffset,
    required this.tool,
    required this.hoverPosition,
  });

  final List<_GesturePreview> gestures;
  final double viewportScale;
  final Offset viewportOffset;
  final BoardTool tool;
  final Offset? hoverPosition;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = FlowboardColors.blue.withValues(alpha: .85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final gesture in gestures) {
      final path = gesture.points;
      if (path.isEmpty) continue;
      if (gesture.tool == BoardTool.selectLasso) {
        final lasso = Path()
          ..moveTo(
            path.first.dx * viewportScale + viewportOffset.dx,
            path.first.dy * viewportScale + viewportOffset.dy,
          );
        for (final point in path.skip(1)) {
          lasso.lineTo(
            point.dx * viewportScale + viewportOffset.dx,
            point.dy * viewportScale + viewportOffset.dy,
          );
        }
        canvas.drawPath(lasso, paint);
      } else if (path.length > 1) {
        final first = path.first * viewportScale + viewportOffset;
        final last = path.last * viewportScale + viewportOffset;
        if (gesture.tool == BoardTool.shape) {
          _paintShapePreview(canvas, gesture.shape, first, last, paint);
        } else {
          canvas.drawRect(Rect.fromPoints(first, last), paint);
        }
      }
    }
    if (hoverPosition case final position?) {
      if (tool == BoardTool.pen ||
          tool == BoardTool.marker ||
          tool == BoardTool.dashedPen ||
          tool == BoardTool.straightLine) {
        canvas.drawCircle(
          position,
          4,
          paint..color = FlowboardColors.mint.withValues(alpha: .7),
        );
      }
    }
  }

  void _paintShapePreview(
    Canvas canvas,
    ShapeKind shape,
    Offset first,
    Offset last,
    Paint outline,
  ) {
    var shapeEnd = last;
    if (shape == ShapeKind.circle) {
      final delta = last - first;
      final side = math.max(delta.dx.abs(), delta.dy.abs());
      shapeEnd = Offset(
        first.dx + (delta.dx < 0 ? -side : side),
        first.dy + (delta.dy < 0 ? -side : side),
      );
    }
    final rect = Rect.fromPoints(first, shapeEnd);
    final fill = Paint()
      ..color = FlowboardColors.mint.withValues(alpha: .16)
      ..style = PaintingStyle.fill;
    final shapeOutline = Paint()
      ..color = FlowboardColors.mint.withValues(alpha: .95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, outline.strokeWidth)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (shape) {
      case ShapeKind.rectangle:
        final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(3));
        canvas.drawRRect(rounded, fill);
        canvas.drawRRect(rounded, shapeOutline);
      case ShapeKind.circle || ShapeKind.ellipse:
        canvas.drawOval(rect, fill);
        canvas.drawOval(rect, shapeOutline);
      case ShapeKind.triangle:
        final triangle = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.bottom)
          ..lineTo(rect.left, rect.bottom)
          ..close();
        canvas.drawPath(triangle, fill);
        canvas.drawPath(triangle, shapeOutline);
    }
  }

  @override
  bool shouldRepaint(covariant _GestureOverlayPainter oldDelegate) => true;
}
