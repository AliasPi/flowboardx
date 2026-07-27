import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../diagnostics/diagnostics.dart';
import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../../platform/android_palm_input.dart';
import '../../editor/board_participant_controller.dart';
import '../../editor/editor_controller.dart';
import '../../input/clustered_touch_eraser.dart';
import '../../input/eraser_contact_geometry.dart';
import '../engine/board_viewport.dart';
import '../engine/input_policy.dart';
import 'board_background.dart';
import 'board_navigator.dart';
import 'board_pointer_indicator.dart';
import 'inline_text_editor_overlay.dart';
import 'board_scene_layer.dart';
import 'live_ink_preview_layer.dart';

typedef EmptyBoardLongPress =
    void Function(Offset screenPosition, Offset worldPosition);

class BoardSurface extends StatefulWidget {
  const BoardSurface({
    required this.controller,
    this.onEmptyLongPress,
    this.inputSuppression,
    this.participant,
    this.viewport,
    this.participantId = 'primary',
    this.confineInputToBounds = false,
    this.inputBounds,
    this.horizontalViewportConstraint,
    this.palmInputSource,
    this.fingerDrawingEnabled = false,
    super.key,
  });

  final EditorController controller;
  final EmptyBoardLongPress? onEmptyLongPress;

  /// External gesture arbitration for interactions which are observed above
  /// the board without taking over its hit test, such as radial-menu
  /// five-finger page rotation.
  final ValueListenable<bool>? inputSuppression;

  /// Optional per-person tool configuration. Omitting it preserves the
  /// original single-person controller behaviour.
  final BoardParticipantController? participant;

  /// Optional camera override for isolated board surfaces.
  ///
  /// In the normal two-person workspace each participant controller already
  /// owns an independent viewport. An override remains useful for embedded
  /// surfaces and deterministic tests.
  final BoardViewport? viewport;

  /// Stable namespace for pointer authorship and transform arbitration.
  final String participantId;

  /// Keeps an owned pointer inside its physical split half after it crosses
  /// the divider while still held down.
  final bool confineInputToBounds;

  /// Optional interaction region in this surface's local coordinates.
  ///
  /// Split workspaces keep both surfaces in the full workspace coordinate
  /// system, then clip rendering and pointer ownership to this rectangle.
  /// Their cameras may differ, but neither half rebases screen coordinates at
  /// the divider, so authored world positions remain stable across modes.
  final Rect? inputBounds;

  /// Keeps this participant's visible world on its own side of a stable
  /// split-screen divider while retaining an independent camera.
  final BoardViewportHorizontalConstraint? horizontalViewportConstraint;

  /// Native Android palm-rejection events. Injectable for deterministic tests.
  final PalmInputSource? palmInputSource;

  /// Lets a single, narrow touch contact draw with the configured ink tool.
  ///
  /// A second finger still promotes the provisional stroke into navigation,
  /// so two-finger pan/zoom remains available while this option is enabled.
  final bool fingerDrawingEnabled;

  @override
  State<BoardSurface> createState() => _BoardSurfaceState();
}

class _BoardSurfaceState extends State<BoardSurface> {
  // Native Android palm traces do not carry a Flutter pointer ID. Keeping one
  // reserved ID lets their calibrated contact footprint use the same cursor
  // overlay as ordinary broad touch contacts.
  static const int _nativePalmIndicatorPointer = -0x50414C4D;

  final Map<int, PointerRole> _roles = {};
  final Map<int, PointerDeviceKind> _pointerKinds = {};
  final Map<int, Offset> _pointerLocalPositions = {};
  final Map<int, Offset> _navigationPointers = {};
  final Map<int, Offset> _navigationStartPositions = {};
  bool _navigationGestureHadMultiplePointers = false;
  bool _navigationGestureMovedBeyondTapSlop = false;
  bool _navigationGestureLongPressTriggered = false;
  final Map<int, _EraserPointerState> _eraserPointers = {};
  final Set<int> _priorityEraserPointers = <int>{};
  final Set<int> _globalTouchStartsInside = <int>{};
  final Map<int, _ProvisionalTouchTrace> _provisionalTouchTraces =
      <int, _ProvisionalTouchTrace>{};
  final ClusteredTouchEraserTracker _clusteredTouchEraser =
      ClusteredTouchEraserTracker();
  final Map<int, _GesturePreview> _selectionGestures = {};
  final Map<int, Offset> _selectionStarts = {};
  final Map<int, Offset> _selectionMoveStarts = {};
  final Set<int> _selectionPinchPointers = <int>{};
  double? _selectionPinchStartDistance;
  Offset? _selectionPinchAnchor;
  String? _selectionTransformOwner;
  int _selectionGestureEpoch = 0;
  Size _size = Size.zero;
  final _BoardPointerIndicatorController _pointerIndicators =
      _BoardPointerIndicatorController();
  late String _activePageId;
  String? _inlineTextObjectId;
  Timer? _navigatorHideTimer;
  Timer? _nativePalmCommitTimer;
  StreamSubscription<NativePalmStroke>? _nativePalmSubscription;
  final Set<String> _handledNativePalmSessions = <String>{};
  bool _navigatorVisible = false;
  Offset? _navigatorPosition;
  bool _inputSuppressed = false;
  bool _viewportConstraintScheduled = false;
  bool _isDisposing = false;
  double? _viewportGestureStartScale;
  Offset? _viewportGestureStartOffset;

  EditorController get controller => widget.controller;
  BoardViewport get viewport => widget.viewport ?? controller.viewport;
  BoardTool get activeTool => widget.participant?.tool ?? controller.tool;
  ShapeKind get activeShape =>
      widget.participant?.activeShape ?? controller.activeShape;
  bool get _selectionActiveForParticipant =>
      controller.hasSelection &&
      (widget.participant == null ||
          activeTool == BoardTool.selectRectangle ||
          activeTool == BoardTool.selectLasso ||
          controller.selectedCover != null);

  @override
  void initState() {
    super.initState();
    _activePageId = controller.page.id;
    controller.addListener(_handleControllerChange);
    _inputSuppressed = widget.inputSuppression?.value ?? false;
    widget.inputSuppression?.addListener(_handleInputSuppressionChange);
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleGlobalPriorityPointerEvent,
    );
    _subscribeToNativePalmInput();
  }

  @override
  void didUpdateWidget(covariant BoardSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      _clearTransientPointers(
        target: oldWidget.controller,
        commitOwnedErase: true,
      );
      _activePageId = controller.page.id;
      controller.addListener(_handleControllerChange);
    }
    if (oldWidget.viewport != widget.viewport ||
        oldWidget.participant != widget.participant ||
        oldWidget.participantId != widget.participantId ||
        oldWidget.inputBounds != widget.inputBounds) {
      _clearTransientPointers(commitOwnedErase: true);
    }
    if (oldWidget.inputSuppression != widget.inputSuppression) {
      oldWidget.inputSuppression?.removeListener(_handleInputSuppressionChange);
      widget.inputSuppression?.addListener(_handleInputSuppressionChange);
      _handleInputSuppressionChange();
    }
    if (oldWidget.palmInputSource != widget.palmInputSource) {
      _subscribeToNativePalmInput();
    }
  }

  @override
  void dispose() {
    _isDisposing = true;
    _navigatorHideTimer?.cancel();
    _nativePalmSubscription?.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleGlobalPriorityPointerEvent,
    );
    widget.inputSuppression?.removeListener(_handleInputSuppressionChange);
    controller.removeListener(_handleControllerChange);
    // A mode/page/layout switch may remove this surface while a pointer is
    // still down. Never leave an ink session or transform preview orphaned in
    // the shared controller.
    _clearTransientPointers(commitOwnedErase: true);
    _pointerIndicators.dispose();
    super.dispose();
  }

  void _subscribeToNativePalmInput() {
    _nativePalmSubscription?.cancel();
    final source = widget.palmInputSource ?? AndroidPalmInputBridge.instance;
    _nativePalmSubscription = source.strokes.listen(
      _handleNativePalmStroke,
      onError: (Object error, StackTrace stackTrace) {
        DiagnosticLogService.instance.recordException(
          event: 'input.palm_bridge_error',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  void _handleNativePalmStroke(NativePalmStroke stroke) {
    if (!mounted ||
        _inputSuppressed ||
        controller.inkSessions.hasActiveStylus) {
      return;
    }
    if (_handledNativePalmSessions.contains(stroke.sessionId)) return;
    final nativeSamples = stroke.samples.isNotEmpty
        ? stroke.samples
        : <NativePalmSample>[
            for (final point in stroke.points)
              NativePalmSample(
                position: point,
                radiusMajor: stroke.radius,
                radiusMinor: stroke.radius,
                orientation: 0,
              ),
          ];
    final localSamples =
        <({Offset center, List<EraserBrushStamp> footprint})>[];
    for (var index = 0; index < nativeSamples.length; index++) {
      final sample = nativeSamples[index];
      final local = _globalToLocal(sample.position);
      if (local == null) continue;
      if (localSamples.isEmpty && !_localBounds.contains(local)) return;
      final bounded = _boundedLocalPosition(local);
      localSamples.add((
        center: bounded,
        footprint: EraserContactGeometry.touchScreenFootprint(
          center: bounded,
          radiusMajor: sample.radiusMajor,
          radiusMinor: sample.radiusMinor,
          orientation: sample.orientation,
          fallbackRadius: stroke.radius,
        ),
      ));
    }
    if (localSamples.isEmpty ||
        !_localBounds.contains(localSamples.first.center)) {
      return;
    }
    _handledNativePalmSessions.add(stroke.sessionId);
    while (_handledNativePalmSessions.length > 64) {
      _handledNativePalmSessions.remove(_handledNativePalmSessions.first);
    }

    // Android reports palm rejection only after provisional touch events. The
    // native signal wins over tools, selection handles, covers and navigator.
    _cancelSelectionTransientsForEraser(-1);
    _rollbackNavigationForEraser(-1);
    List<_WorldEraserStamp>? previous;
    final sweeps = <InkEraserSweep>[];
    for (final sample in localSamples) {
      final current = _screenFootprintToWorld(sample.footprint);
      sweeps.addAll(_eraserSweepsForTransition(previous, current));
      previous = current;
    }
    controller.eraseSweeps(sweeps);
    final lastSample = localSamples.last;
    _updateEraserIndicator(
      pointer: _nativePalmIndicatorPointer,
      position: lastSample.center,
      radius: EraserContactGeometry.enclosingScreenRadius(
        center: lastSample.center,
        footprint: lastSample.footprint,
        fallback: stroke.radius,
      ),
    );
    _scheduleNativePalmCommit();
    DiagnosticLogService.instance.info(
      'input.palm_native',
      fields: <String, Object?>{
        'source': stroke.source,
        'contacts': stroke.contactCount,
        'samples': localSamples.length,
        'radius_bucket': stroke.radius < 28
            ? 'small'
            : stroke.radius < 48
            ? 'medium'
            : 'large',
      },
    );
    if (mounted) setState(() {});
  }

  Rect get _localBounds {
    final surfaceBounds = Offset.zero & _size;
    final requested = widget.inputBounds;
    if (requested == null) return surfaceBounds;
    final clipped = requested.intersect(surfaceBounds);
    return clipped.width > 0 && clipped.height > 0 ? clipped : surfaceBounds;
  }

  Rect get _viewportVisibleBounds =>
      widget.confineInputToBounds ? _localBounds : Offset.zero & _size;

  void _scheduleViewportConstraint() {
    if (_viewportConstraintScheduled ||
        _size.isEmpty ||
        widget.horizontalViewportConstraint == null) {
      return;
    }
    _viewportConstraintScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportConstraintScheduled = false;
      if (!mounted || _size.isEmpty) return;
      viewport.constrain(
        viewportSize: _size,
        visibleScreenBounds: _viewportVisibleBounds,
        horizontalConstraint: widget.horizontalViewportConstraint,
      );
    });
  }

  Offset? _globalToLocal(Offset globalPosition) {
    if (!globalPosition.dx.isFinite || !globalPosition.dy.isFinite) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    final local = renderObject.globalToLocal(globalPosition);
    return local.dx.isFinite && local.dy.isFinite ? local : null;
  }

  void _scheduleNativePalmCommit() {
    _nativePalmCommitTimer?.cancel();
    _nativePalmCommitTimer = Timer(const Duration(milliseconds: 180), () {
      if (_eraserPointers.isNotEmpty) {
        _scheduleNativePalmCommit();
        return;
      }
      _nativePalmCommitTimer = null;
      _pointerIndicators.removePointer(_nativePalmIndicatorPointer);
      controller.commitErase();
    });
  }

  void _handleInputSuppressionChange() {
    final next = widget.inputSuppression?.value ?? false;
    if (_inputSuppressed == next) return;
    _inputSuppressed = next;
    if (next) {
      _inlineTextObjectId = null;
      // The first fingers reach the board before the fifth finger establishes
      // the radial command. Roll those provisional pan/zoom changes back
      // exactly; page rotation must never move the whiteboard underneath it.
      _cancelViewportPreview();
      _clearTransientPointers(commitOwnedErase: true);
      _navigatorHideTimer?.cancel();
      _navigatorVisible = false;
    }
    if (mounted) setState(() {});
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

  void _clearTransientPointers({
    EditorController? target,
    bool commitOwnedErase = false,
  }) {
    final activeController = target ?? controller;
    for (final entry in _roles.entries) {
      if (entry.value == PointerRole.ink) {
        activeController.cancelInk(entry.key);
      }
    }
    final ownsErase =
        _eraserPointers.isNotEmpty || _nativePalmCommitTimer?.isActive == true;
    _nativePalmCommitTimer?.cancel();
    _nativePalmCommitTimer = null;
    if (ownsErase) {
      if (commitOwnedErase) {
        activeController.commitErase();
      } else {
        activeController.cancelErase();
      }
    }
    if (_selectionTransformOwner != null) {
      activeController.cancelSelectionTransform();
    }
    _roles.clear();
    _pointerKinds.clear();
    _pointerLocalPositions.clear();
    _navigationPointers.clear();
    _resetNavigationGesture();
    _eraserPointers.clear();
    _priorityEraserPointers.clear();
    _globalTouchStartsInside.clear();
    _provisionalTouchTraces.clear();
    _clusteredTouchEraser.clear();
    _selectionGestures.clear();
    _selectionStarts.clear();
    _selectionMoveStarts.clear();
    _selectionPinchPointers.clear();
    _selectionPinchStartDistance = null;
    _selectionPinchAnchor = null;
    _pointerIndicators.clear(notify: !_isDisposing);
    final owner = _selectionTransformOwner;
    if (owner != null) {
      activeController.releaseSelectionInteraction(
        _globalTransformOwner(owner),
      );
    }
    _selectionTransformOwner = null;
    _viewportGestureStartScale = null;
    _viewportGestureStartOffset = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        _scheduleViewportConstraint();
        return AnimatedBuilder(
          animation: Listenable.merge([
            controller,
            viewport,
            ?widget.participant,
          ]),
          builder: (context, _) {
            // Page changes and viewport restores notify the merged listenable
            // without necessarily rebuilding the surrounding LayoutBuilder.
            // Re-assert the split constraint after that frame as well.
            _scheduleViewportConstraint();
            final worldClip = _worldClip();
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: MouseRegion(
                    cursor: _cursor,
                    onHover: (event) => _pointerIndicators.updateHover(
                      _boundedLocalPosition(event.localPosition),
                    ),
                    onExit: (_) => _pointerIndicators.clearHover(),
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
                                  viewportScale: viewport.scale,
                                  viewportOffset: viewport.offset,
                                ),
                              ),
                            ),
                            BoardSceneLayer(
                              objects: controller.renderObjects,
                              strokes: controller.renderStrokes,
                              annotationLayers:
                                  controller.renderAnnotationLayers,
                              scale: viewport.scale,
                              offset: viewport.offset,
                              assets: controller.assetResolver,
                              selectedIds: controller.selectedSceneItemIds,
                              worldClip: worldClip,
                            ),
                            LiveInkPreviewLayer(
                              sessions: controller.inkSessions,
                              worldToScreenScale: viewport.scale,
                              worldToScreenOffset: viewport.offset,
                              worldClip: worldClip,
                            ),
                            IgnorePointer(
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  painter: _GestureOverlayPainter(
                                    gestures: _selectionGestures.values.toList(
                                      growable: false,
                                    ),
                                    viewportScale: viewport.scale,
                                    viewportOffset: viewport.offset,
                                  ),
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: RepaintBoundary(
                                child: AnimatedBuilder(
                                  animation: _pointerIndicators,
                                  builder: (context, _) => CustomPaint(
                                    key: const ValueKey<String>(
                                      'board-pointer-indicator',
                                    ),
                                    painter: BoardPointerIndicatorPainter(
                                      indicators: _pointerIndicators.indicators,
                                      hoverPosition:
                                          _pointerIndicators.hoverPosition,
                                      tool: activeTool,
                                      brushWidth:
                                          widget.participant?.penStyle.width ??
                                          controller.penStyle.width,
                                      viewportScale: viewport.scale,
                                    ),
                                  ),
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
                  IgnorePointer(
                    ignoring: _inputSuppressed || _eraserPointers.isNotEmpty,
                    child: _SelectionOverlay(
                      key: ValueKey<(bool, int)>((
                        _inputSuppressed,
                        _selectionGestureEpoch,
                      )),
                      controller: controller,
                      viewport: viewport,
                      inlineTextEditing: _inlineTextObjectId != null,
                      onEditText: _beginInlineTextEditing,
                      onClaimTransform: _claimSelectionTransform,
                      onReleaseTransform: _releaseSelectionTransform,
                    ),
                  ),
                if (_inlineTextObjectId case final objectId?)
                  Positioned.fill(
                    child: InlineTextEditorOverlay(
                      key: ValueKey('inline-text-editor-$objectId'),
                      controller: controller,
                      viewport: viewport,
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
                      child: IgnorePointer(
                        ignoring: _eraserPointers.isNotEmpty,
                        child: BoardNavigator(
                          viewport: viewport,
                          viewportSize: _size,
                          visibleScreenBounds: _viewportVisibleBounds,
                          objects: controller.renderObjects,
                          strokes: controller.renderStrokes,
                          onNavigate: (world) {
                            if (_eraserPointers.isEmpty) {
                              viewport.centerOn(
                                world,
                                _size,
                                visibleScreenBounds: _viewportVisibleBounds,
                                horizontalConstraint:
                                    widget.horizontalViewportConstraint,
                              );
                            }
                          },
                          onMovePanel: _moveNavigator,
                          onInteractionStart: _beginNavigatorInteraction,
                          onInteractionEnd: _endNavigatorInteraction,
                        ),
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

  MouseCursor get _cursor => switch (activeTool) {
    BoardTool.pen ||
    BoardTool.marker ||
    BoardTool.dashedPen ||
    BoardTool.straightLine ||
    BoardTool.eraser => SystemMouseCursors.precise,
    BoardTool.selectRectangle ||
    BoardTool.selectLasso => SystemMouseCursors.basic,
    BoardTool.shape => SystemMouseCursors.precise,
  };

  bool _claimSelectionTransform(String owner) {
    if (_inputSuppressed ||
        _eraserPointers.isNotEmpty ||
        _nativePalmCommitTimer?.isActive == true ||
        _selectionTransformOwner != null) {
      return false;
    }
    if (!controller.claimSelectionInteraction(_globalTransformOwner(owner))) {
      return false;
    }
    _selectionTransformOwner = owner;
    return true;
  }

  void _releaseSelectionTransform(String owner) {
    if (_selectionTransformOwner != owner) return;
    _selectionTransformOwner = null;
    controller.releaseSelectionInteraction(_globalTransformOwner(owner));
  }

  String _globalTransformOwner(String owner) =>
      '${widget.participantId}:$owner';

  void _handleGlobalPriorityPointerEvent(PointerEvent event) {
    if ((event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus) &&
        event is PointerDownEvent) {
      final local = _globalToLocal(event.position);
      if (local != null && _localBounds.contains(local)) {
        // This route also sees a pen-down when a selection handle is the
        // hit-tested widget. Palm arbitration therefore cannot be bypassed by
        // the overlay sitting above the board listener.
        _neutralizeActiveTouchesForStylus();
      }
      return;
    }
    if (event.kind != PointerDeviceKind.touch) return;
    final local = _globalToLocal(event.position);
    if (event is PointerDownEvent) {
      if (local == null || !_localBounds.contains(local)) return;
      _globalTouchStartsInside.add(event.pointer);
      final trace =
          _ProvisionalTouchTrace(
            pointer: event.pointer,
            initialViewportScale: viewport.scale,
            initialViewportOffset: viewport.offset,
          )..add(
            local,
            controller.pointerPolicy.eraserRadiusFor(event),
            footprint: controller.pointerPolicy.eraserFootprintFor(
              event,
              center: local,
            ),
          );
      trace.routedToBoard = _roles.containsKey(event.pointer);
      trace.suppressedByStylus = controller.inkSessions.hasActiveStylus;
      _provisionalTouchTraces[event.pointer] = trace;
      if (!_inputSuppressed &&
          !controller.inkSessions.hasActiveStylus &&
          !_roles.containsKey(event.pointer) &&
          controller.pointerPolicy.isEraserContact(event)) {
        _startPriorityErase(event, local, trace);
      }
      return;
    }
    if (!_globalTouchStartsInside.contains(event.pointer) || local == null) {
      return;
    }
    final trace = _provisionalTouchTraces[event.pointer];
    trace?.add(
      local,
      controller.pointerPolicy.eraserRadiusFor(event),
      footprint: controller.pointerPolicy.eraserFootprintFor(
        event,
        center: local,
      ),
    );
    if (event is PointerMoveEvent) {
      if (controller.inkSessions.hasActiveStylus) {
        if (trace != null) trace.suppressedByStylus = true;
        _neutralizeActiveTouchesForStylus();
      } else if (_priorityEraserPointers.contains(event.pointer)) {
        _continuePriorityErase(event, local);
      } else if (!_inputSuppressed &&
          !_roles.containsKey(event.pointer) &&
          controller.pointerPolicy.isEraserContact(event) &&
          trace != null) {
        _startPriorityErase(event, local, trace);
      }
      return;
    }
    if (event is! PointerUpEvent && event is! PointerCancelEvent) return;

    if (_priorityEraserPointers.contains(event.pointer)) {
      _continuePriorityErase(event, local);
      _roles.remove(event.pointer);
      _finishErase(event.pointer);
    } else if (!_inputSuppressed &&
        !controller.inkSessions.hasActiveStylus &&
        trace != null &&
        !trace.becameEraser &&
        !trace.suppressedByStylus &&
        controller.pointerPolicy.isEraserContact(event)) {
      _eraseBufferedTouchTrace(trace);
      _roles[event.pointer] = PointerRole.ignored;
    }
    // Global routes can run before or after the hit-tested board route. Keep
    // the ownership marker through the current dispatch microtask so either
    // ordering remains idempotent.
    scheduleMicrotask(() {
      _priorityEraserPointers.remove(event.pointer);
      _globalTouchStartsInside.remove(event.pointer);
      _provisionalTouchTraces.remove(event.pointer);
      _pointerKinds.remove(event.pointer);
      _pointerLocalPositions.remove(event.pointer);
      if (_roles[event.pointer] == PointerRole.ignored) {
        _roles.remove(event.pointer);
      }
    });
  }

  /// Gives a newly arriving pen exclusive ownership of this participant's
  /// surface without touching the other participant controller/surface.
  ///
  /// A hand can reach the glass a few milliseconds before the pen and initially
  /// look like a tap, selection drag, pan, finger stroke, or fist eraser.
  /// Merely changing its role to [PointerRole.ignored] would orphan the preview
  /// and let its eventual UP replay an action. Roll every provisional touch
  /// operation back first, then latch those pointers as ignored until they
  /// leave the glass.
  void _neutralizeActiveTouchesForStylus() {
    final touchPointers = <int>{
      for (final entry in _pointerKinds.entries)
        if (entry.value == PointerDeviceKind.touch) entry.key,
      ..._globalTouchStartsInside,
      ..._provisionalTouchTraces.keys,
    };
    final hasTouchSelection =
        touchPointers.any(
          (pointer) =>
              _roles[pointer] == PointerRole.select ||
              _selectionPinchPointers.contains(pointer) ||
              _selectionStarts.containsKey(pointer) ||
              _selectionMoveStarts.containsKey(pointer) ||
              _selectionGestures.containsKey(pointer),
        ) ||
        (_selectionTransformOwner != null && touchPointers.isNotEmpty);
    final hasTouchNavigation = touchPointers.any(
      _navigationPointers.containsKey,
    );
    final hasTouchErase = touchPointers.any(
      (pointer) =>
          _eraserPointers[pointer]?.touchContact == true ||
          _priorityEraserPointers.contains(pointer),
    );
    final hasFingerInk = touchPointers.any(
      (pointer) => _roles[pointer] == PointerRole.ink,
    );
    if (touchPointers.isEmpty &&
        !hasTouchSelection &&
        !hasTouchNavigation &&
        !hasTouchErase &&
        !hasFingerInk) {
      return;
    }

    if (hasTouchNavigation) {
      _cancelViewportPreview();
      _navigatorHideTimer?.cancel();
      _navigatorVisible = false;
    }
    if (hasTouchErase) {
      // Erasing is staged until pointer-up, so rollback is lossless.
      controller.cancelErase();
    }
    if (hasTouchSelection) {
      controller.cancelSelectionTransform();
      final owner = _selectionTransformOwner;
      if (owner != null) _releaseSelectionTransform(owner);
      // Recreate handle recognizers on the next frame. A recognizer that was
      // already holding a touch must not publish another preview after the pen
      // has claimed the surface.
      _selectionGestureEpoch++;
    }

    for (final pointer in touchPointers) {
      if (_roles[pointer] == PointerRole.ink) {
        controller.cancelInk(pointer);
      }
      _roles[pointer] = PointerRole.ignored;
      _navigationPointers.remove(pointer);
      _navigationStartPositions.remove(pointer);
      _eraserPointers.remove(pointer);
      _priorityEraserPointers.remove(pointer);
      _selectionStarts.remove(pointer);
      _selectionMoveStarts.remove(pointer);
      _selectionGestures.remove(pointer);
      _selectionPinchPointers.remove(pointer);
      _clusteredTouchEraser.remove(pointer);
      _pointerIndicators.removePointer(pointer);
      final trace = _provisionalTouchTraces[pointer];
      if (trace != null) {
        trace.suppressedByStylus = true;
        trace.becameEraser = trace.becameEraser || hasTouchErase;
      }
    }
    if (_navigationPointers.isEmpty) _resetNavigationGesture();
    if (_selectionPinchPointers.isEmpty) {
      _selectionPinchStartDistance = null;
      _selectionPinchAnchor = null;
    }
    _clusteredTouchEraser.clear();
    if (mounted) setState(() {});
  }

  void _startPriorityErase(
    PointerEvent event,
    Offset local,
    _ProvisionalTouchTrace trace,
  ) {
    _priorityEraserPointers.add(event.pointer);
    _roles[event.pointer] = PointerRole.erase;
    trace.becameEraser = true;
    _clusteredTouchEraser.clear();
    _beginErase(
      event,
      viewport.screenToWorld(_boundedLocalPosition(local)),
      localPosition: local,
    );
    if (mounted) setState(() {});
  }

  void _continuePriorityErase(PointerEvent event, Offset local) {
    final world = viewport.screenToWorld(_boundedLocalPosition(local));
    _continueErase(event, world, localPosition: local);
  }

  void _eraseBufferedTouchTrace(_ProvisionalTouchTrace trace) {
    if (trace.points.isEmpty) return;
    _cancelSelectionTransientsForEraser(trace.pointer);
    _rollbackNavigationForEraser(trace.pointer);
    final viewportChanged =
        (viewport.scale - trace.initialViewportScale).abs() > .0001 ||
        (viewport.offset - trace.initialViewportOffset).distance > .01;
    if (viewportChanged) {
      viewport.restore(
        scale: trace.initialViewportScale,
        offset: trace.initialViewportOffset,
      );
      if (identical(viewport, controller.viewport)) controller.commitViewport();
    }
    List<_WorldEraserStamp>? previous;
    for (var index = 0; index < trace.points.length; index++) {
      final screenFootprint = index < trace.footprints.length
          ? trace.footprints[index]
          : <EraserBrushStamp>[
              EraserBrushStamp(
                center: trace.points[index],
                radius: trace.maximumScreenRadius,
              ),
            ];
      final current = _screenFootprintToWorld(screenFootprint);
      _eraseStampTransition(previous, current);
      previous = current;
    }
    trace.becameEraser = true;
    _scheduleNativePalmCommit();
    if (mounted) setState(() {});
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_roles.containsKey(event.pointer)) return;
    _pointerKinds[event.pointer] = event.kind;
    final existingTrace = _provisionalTouchTraces[event.pointer];
    if (existingTrace != null) existingTrace.routedToBoard = true;
    if (_inputSuppressed) {
      _roles[event.pointer] = PointerRole.ignored;
      return;
    }
    final localPosition = _boundedLocalPosition(event.localPosition);
    _pointerLocalPositions[event.pointer] = localPosition;
    final world = viewport.screenToWorld(localPosition);
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _neutralizeActiveTouchesForStylus();
    }
    if (_inlineTextObjectId != null) {
      _inlineTextObjectId = null;
      setState(() {});
    }
    // Palm/fist classification must precede cover and shape shortcuts. A broad
    // contact also outranks an existing selection owner: a multi-contact fist
    // must roll that preview back rather than being ignored behind it.
    final stylusCurrentlyActive = controller.inkSessions.hasActiveStylus;
    if (event.kind == PointerDeviceKind.touch &&
        stylusCurrentlyActive &&
        existingTrace != null) {
      existingTrace.suppressedByStylus = true;
    }
    final isReportedEraser =
        !(event.kind == PointerDeviceKind.touch && stylusCurrentlyActive) &&
        controller.pointerPolicy.isEraserContact(event);
    if (event.kind == PointerDeviceKind.touch &&
        !stylusCurrentlyActive &&
        !isReportedEraser) {
      _clusteredTouchEraser.add(event, localPosition);
    }
    if (isReportedEraser) {
      _clusteredTouchEraser.clear();
      _roles[event.pointer] = PointerRole.erase;
      _beginErase(event, world, localPosition: localPosition);
      return;
    }
    if (_tryBeginSelectionPinch(event, localPosition, world)) return;
    if (_selectionTransformOwner != null) {
      // Selection transforms are atomic. A second ordinary pen/touch must not
      // clear or overwrite the shared preview while its owner is still down.
      _roles[event.pointer] = PointerRole.ignored;
      return;
    }
    final selectedCover = controller.selectedCover;
    if (_isInkTool(activeTool) &&
        selectedCover != null &&
        selectedCover.transform.containsWorld(
          Vec2(world.dx, world.dy),
          tolerance: 10 / viewport.scale,
        )) {
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
      _trackPointerIndicator(
        event,
        localPosition,
        BoardPointerIndicatorKind.selection,
      );
      setState(() {});
      return;
    }
    if (activeTool == BoardTool.shape) {
      _roles[event.pointer] = PointerRole.select;
      _selectionStarts[event.pointer] = world;
      _selectionGestures[event.pointer] = _GesturePreview(
        tool: BoardTool.shape,
        shape: activeShape,
        points: <Offset>[world, world],
      );
      _trackPointerIndicator(
        event,
        localPosition,
        BoardPointerIndicatorKind.shape,
      );
      setState(() {});
      return;
    }
    if (event.kind == PointerDeviceKind.touch && widget.fingerDrawingEnabled) {
      _promoteFingerInkToNavigation();
    }
    var role = controller.pointerPolicy.classifyDown(
      event,
      tool: activeTool,
      selectionActive: _selectionActiveForParticipant,
      stylusCurrentlyActive: controller.inkSessions.hasActiveStylus,
      activeNavigationTouches: _navigationPointers.length,
      fingerDrawingEnabled: widget.fingerDrawingEnabled,
    );
    // In the normal editor a participant controller is present even in
    // one-person mode. Its pen tool deliberately keeps ordinary touches in
    // navigation so a finger can pan while the stylus writes. Once the user
    // has selected content with a stationary finger tap, however, another
    // touch directly on that selection must own a move immediately. Re-route
    // only this hit-tested navigation contact; a touch elsewhere still pans,
    // a resting hand while a stylus is active remains ignored by the policy,
    // and a second touch can still promote the move into selection pinch.
    if (role == PointerRole.navigate &&
        event.kind == PointerDeviceKind.touch &&
        !widget.fingerDrawingEnabled &&
        controller.hasSelection &&
        controller.selectionContains(world, tolerance: 12 / viewport.scale)) {
      role = PointerRole.select;
    }
    _roles[event.pointer] = role;
    switch (role) {
      case PointerRole.ink:
        if (!controller.beginInk(
          event,
          world,
          samplingPosition: localPosition,
          style: widget.participant?.penStyle,
          authorId: widget.participant == null
              ? null
              : '${widget.participantId}-device-${event.device}',
        )) {
          _roles[event.pointer] = PointerRole.ignored;
        } else {
          _trackPointerIndicator(
            event,
            localPosition,
            BoardPointerIndicatorKind.ink,
          );
        }
      case PointerRole.erase:
        _beginErase(event, world, localPosition: localPosition);
      case PointerRole.navigate:
        _beginNavigation(event.pointer, localPosition);
      case PointerRole.select:
        if (_selectionTransformOwner != null) {
          _roles[event.pointer] = PointerRole.ignored;
          break;
        }
        _selectionStarts[event.pointer] = world;
        final insideSelection =
            controller.hasSelection &&
            controller.selectionContains(world, tolerance: 12 / viewport.scale);
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
            tool: activeTool,
            shape: activeShape,
            points: <Offset>[world, world],
          );
        }
        if (_roles[event.pointer] == PointerRole.select) {
          _trackPointerIndicator(
            event,
            localPosition,
            BoardPointerIndicatorKind.selection,
          );
        }
        setState(() {});
      case PointerRole.ignored:
        break;
    }
  }

  bool _tryBeginSelectionPinch(
    PointerDownEvent event,
    Offset localPosition,
    Offset worldPosition,
  ) {
    if (event.kind != PointerDeviceKind.touch ||
        !controller.hasSelection ||
        !controller.selectionContains(
          worldPosition,
          tolerance: 12 / viewport.scale,
        )) {
      return false;
    }
    int? firstPointer;
    for (final entry in _roles.entries) {
      if (entry.value != PointerRole.select ||
          _pointerKinds[entry.key] != PointerDeviceKind.touch) {
        continue;
      }
      final firstLocal = _pointerLocalPositions[entry.key];
      if (firstLocal == null) continue;
      final firstWorld = viewport.screenToWorld(firstLocal);
      if (controller.selectionContains(
        firstWorld,
        tolerance: 12 / viewport.scale,
      )) {
        firstPointer = entry.key;
        break;
      }
    }
    if (firstPointer == null) return false;
    final firstLocal = _pointerLocalPositions[firstPointer];
    if (firstLocal == null) return false;
    final distance = (localPosition - firstLocal).distance;
    if (!distance.isFinite || distance < 12) return false;

    // The first finger may already own a provisional move. Convert that
    // gesture atomically into one uniform scale operation before the second
    // pointer is routed through the ordinary selection path.
    final previousOwner = _selectionTransformOwner;
    if (previousOwner != null) {
      controller.cancelSelectionTransform();
      _releaseSelectionTransform(previousOwner);
    }
    _selectionMoveStarts.remove(firstPointer);
    _selectionStarts.remove(firstPointer);
    _selectionGestures.remove(firstPointer);
    if (!_claimSelectionTransform('selection-pinch')) return false;

    _roles[firstPointer] = PointerRole.select;
    _roles[event.pointer] = PointerRole.select;
    _selectionPinchPointers
      ..clear()
      ..add(firstPointer)
      ..add(event.pointer);
    _selectionPinchStartDistance = distance;
    final bounds = controller.selectionBounds;
    _selectionPinchAnchor = Offset(bounds.center.x, bounds.center.y);
    _trackPointerIndicator(
      event,
      localPosition,
      BoardPointerIndicatorKind.selection,
    );
    if (mounted) setState(() {});
    return true;
  }

  void _updateSelectionPinch() {
    if (_selectionPinchPointers.length != 2) return;
    final pointers = _selectionPinchPointers.toList(growable: false);
    final first = _pointerLocalPositions[pointers[0]];
    final second = _pointerLocalPositions[pointers[1]];
    final baseline = _selectionPinchStartDistance;
    final anchor = _selectionPinchAnchor;
    if (first == null ||
        second == null ||
        baseline == null ||
        baseline < 12 ||
        anchor == null) {
      return;
    }
    final current = (second - first).distance;
    if (!current.isFinite || current <= 0) return;
    controller.previewScaleSelection(
      (current / baseline).clamp(.05, 20.0),
      anchor: anchor,
    );
    if (mounted) setState(() {});
  }

  void _finishSelectionPinch({
    required bool commit,
    required int liftedPointer,
  }) {
    if (_selectionPinchPointers.isEmpty) return;
    final pointers = _selectionPinchPointers.toList(growable: false);
    if (commit) {
      controller.commitSelectionTransform();
    } else {
      controller.cancelSelectionTransform();
    }
    _releaseSelectionTransform('selection-pinch');
    for (final pointer in pointers) {
      _selectionStarts.remove(pointer);
      _selectionMoveStarts.remove(pointer);
      _selectionGestures.remove(pointer);
      _pointerIndicators.removePointer(pointer);
      if (pointer == liftedPointer) {
        _roles.remove(pointer);
      } else {
        // The remaining finger must lift before it can start another gesture;
        // otherwise the just-committed pinch would immediately become a move.
        _roles[pointer] = PointerRole.ignored;
      }
    }
    _selectionPinchPointers.clear();
    _selectionPinchStartDistance = null;
    _selectionPinchAnchor = null;
    if (mounted) setState(() {});
  }

  void _promoteFingerInkToNavigation() {
    if (_navigationPointers.isNotEmpty) return;
    final inkPointers = _roles.entries
        .where(
          (entry) =>
              entry.value == PointerRole.ink &&
              _pointerKinds[entry.key] == PointerDeviceKind.touch,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    if (inkPointers.isEmpty) return;
    for (final pointer in inkPointers) {
      controller.cancelInk(pointer);
      _roles[pointer] = PointerRole.navigate;
      _pointerIndicators.removePointer(pointer);
      final local = _pointerLocalPositions[pointer];
      if (local != null) _beginNavigation(pointer, local);
    }
  }

  static const double _navigationTapSlop = 10;

  void _beginNavigation(int pointer, Offset localPosition) {
    if (_navigationPointers.isEmpty) {
      _resetNavigationGesture();
      _viewportGestureStartScale = viewport.scale;
      _viewportGestureStartOffset = viewport.offset;
    }
    _navigationPointers[pointer] = localPosition;
    _navigationStartPositions[pointer] = localPosition;
    if (_navigationPointers.length > 1) {
      _navigationGestureHadMultiplePointers = true;
    }
  }

  void _resetNavigationGesture() {
    _navigationStartPositions.clear();
    _navigationGestureHadMultiplePointers = false;
    _navigationGestureMovedBeyondTapSlop = false;
    _navigationGestureLongPressTriggered = false;
  }

  bool _isInkTool(BoardTool tool) =>
      tool == BoardTool.pen ||
      tool == BoardTool.marker ||
      tool == BoardTool.dashedPen ||
      tool == BoardTool.straightLine;

  void _trackPointerIndicator(
    PointerEvent event,
    Offset localPosition,
    BoardPointerIndicatorKind kind,
  ) {
    final radius = switch (kind) {
      BoardPointerIndicatorKind.ink => EraserContactGeometry.cursorScreenRadius(
        logicalWidth:
            widget.participant?.penStyle.width ?? controller.penStyle.width,
        viewportScale: viewport.scale,
      ),
      BoardPointerIndicatorKind.eraser =>
        event.kind == PointerDeviceKind.touch
            ? controller.pointerPolicy.eraserRadiusFor(event)
            : EraserContactGeometry.cursorScreenRadius(
                logicalWidth:
                    widget.participant?.penStyle.width ??
                    controller.penStyle.width,
                viewportScale: viewport.scale,
              ),
      BoardPointerIndicatorKind.selection ||
      BoardPointerIndicatorKind.shape => 7.0,
    };
    _pointerIndicators.updatePointer(
      BoardPointerIndicator(
        pointer: event.pointer,
        position: _boundedLocalPosition(localPosition),
        kind: kind,
        radius: radius,
      ),
    );
  }

  void _updateEraserIndicator({
    required int pointer,
    required Offset position,
    required double radius,
  }) {
    _pointerIndicators.updatePointer(
      BoardPointerIndicator(
        pointer: pointer,
        position: _boundedLocalPosition(position),
        kind: BoardPointerIndicatorKind.eraser,
        radius: radius,
      ),
    );
  }

  void _updatePointerIndicator(
    PointerMoveEvent event,
    Offset localPosition,
    PointerRole? role,
  ) {
    final kind = switch (role) {
      PointerRole.ink => BoardPointerIndicatorKind.ink,
      // Erasing computes one calibrated footprint for both mutation and UI.
      // Updating it here with a scalar fallback would briefly show a different
      // size and, for a clustered fist, permanently shrink the cursor.
      PointerRole.erase => null,
      PointerRole.select =>
        _selectionGestures[event.pointer]?.tool == BoardTool.shape
            ? BoardPointerIndicatorKind.shape
            : BoardPointerIndicatorKind.selection,
      PointerRole.navigate || PointerRole.ignored || null => null,
    };
    if (kind != null) {
      _trackPointerIndicator(event, localPosition, kind);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_priorityEraserPointers.contains(event.pointer)) return;
    if (_inputSuppressed) return;
    var role = _roles[event.pointer];
    final localPosition = _boundedLocalPosition(event.localPosition);
    _pointerLocalPositions[event.pointer] = localPosition;
    _updatePointerIndicator(event, localPosition, role);
    var world = viewport.screenToWorld(localPosition);
    if (_selectionPinchPointers.contains(event.pointer)) {
      _updateSelectionPinch();
      return;
    }
    if (event.kind == PointerDeviceKind.touch &&
        controller.inkSessions.hasActiveStylus) {
      // Covers the driver ordering where the touch was delivered before the
      // stylus DOWN reached the global route. Cleanup must remove ownership,
      // not only relabel the pointer, otherwise its UP can replay a tap.
      _neutralizeActiveTouchesForStylus();
      return;
    }
    if (event.kind == PointerDeviceKind.touch && role != PointerRole.erase) {
      final cluster = _clusteredTouchEraser.update(event, localPosition);
      if (cluster != null) {
        _promoteTouchClusterToEraser(cluster);
        return;
      }
    }
    if (role != null &&
        controller.pointerPolicy.shouldPromoteToEraser(
          event,
          currentRole: role,
          activeNavigationTouches: _navigationPointers.length,
          stylusCurrentlyActive: controller.inkSessions.hasActiveStylus,
        )) {
      if (role == PointerRole.navigate) {
        // A fist can initially look like two or more ordinary fingertips and
        // therefore begin a pinch. Once one contact becomes unambiguously
        // broad, the whole provisional navigation loses arbitration: restore
        // the persisted viewport and neutralise its companion contacts.
        _rollbackNavigationForEraser(event.pointer);
        world = viewport.screenToWorld(localPosition);
      }
      if (role == PointerRole.select) {
        final ownedMove = _selectionMoveStarts.remove(event.pointer) != null;
        _selectionGestures.remove(event.pointer);
        _selectionStarts.remove(event.pointer);
        if (ownedMove) {
          controller.cancelSelectionTransform();
          _releaseSelectionTransform('body-${event.pointer}');
        }
        if (mounted) setState(() {});
      }
      role = PointerRole.erase;
      _roles[event.pointer] = role;
      _clusteredTouchEraser.clear();
      _beginErase(event, world, localPosition: localPosition);
      return;
    }
    switch (role) {
      case PointerRole.ink:
        controller.updateInk(event, world, samplingPosition: localPosition);
      case PointerRole.erase:
        _continueErase(event, world, localPosition: localPosition);
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
          if ((preview.points.last - world).distance > 1.5 / viewport.scale) {
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
    if (_priorityEraserPointers.contains(event.pointer)) return;
    _clusteredTouchEraser.remove(event.pointer);
    _pointerLocalPositions[event.pointer] = _boundedLocalPosition(
      event.localPosition,
    );
    if (_selectionPinchPointers.contains(event.pointer)) {
      _finishSelectionPinch(commit: true, liftedPointer: event.pointer);
      _pointerKinds.remove(event.pointer);
      _pointerLocalPositions.remove(event.pointer);
      _pointerIndicators.removePointer(event.pointer);
      return;
    }
    final role = _roles.remove(event.pointer);
    final world = viewport.screenToWorld(
      _boundedLocalPosition(event.localPosition),
    );
    switch (role) {
      case PointerRole.ink:
        controller.endInk(
          event,
          world,
          samplingPosition: _boundedLocalPosition(event.localPosition),
        );
      case PointerRole.erase:
        _finishErase(event.pointer);
      case PointerRole.navigate:
        final shouldSelect =
            event.kind == PointerDeviceKind.touch &&
            !widget.fingerDrawingEnabled &&
            _navigationPointers.length == 1 &&
            !_navigationGestureHadMultiplePointers &&
            !_navigationGestureMovedBeyondTapSlop &&
            !_navigationGestureLongPressTriggered;
        _navigationPointers.remove(event.pointer);
        _navigationStartPositions.remove(event.pointer);
        if (_navigationPointers.isEmpty) {
          if (shouldSelect) {
            // Restore the exact persisted camera before hit testing. Small
            // sensor jitter during a tap must neither pan the page nor offset
            // the selected object.
            _cancelViewportPreview();
            final tapWorld = viewport.screenToWorld(
              _boundedLocalPosition(event.localPosition),
            );
            controller.selectAt(tapWorld, viewportScale: viewport.scale);
          } else {
            _commitViewportPreview();
          }
          _resetNavigationGesture();
          _scheduleNavigatorHide();
        }
      case PointerRole.select:
        _finishSelection(event.pointer, world);
      case PointerRole.ignored || null:
        break;
    }
    _pointerKinds.remove(event.pointer);
    _pointerLocalPositions.remove(event.pointer);
    _pointerIndicators.removePointer(event.pointer);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_priorityEraserPointers.contains(event.pointer)) return;
    _clusteredTouchEraser.remove(event.pointer);
    if (_selectionPinchPointers.contains(event.pointer)) {
      _finishSelectionPinch(commit: false, liftedPointer: event.pointer);
      _pointerKinds.remove(event.pointer);
      _pointerLocalPositions.remove(event.pointer);
      _pointerIndicators.removePointer(event.pointer);
      return;
    }
    final role = _roles.remove(event.pointer);
    if (role == PointerRole.ink) controller.cancelInk(event.pointer);
    if (role == PointerRole.erase) _finishErase(event.pointer);
    if (role == PointerRole.navigate) {
      _navigationPointers.remove(event.pointer);
      _navigationStartPositions.remove(event.pointer);
      if (_navigationPointers.isEmpty) {
        // Android palm rejection and interrupted system gestures surface as a
        // cancellation. A canceled provisional camera must never be persisted.
        _cancelViewportPreview();
        _resetNavigationGesture();
        _scheduleNavigatorHide();
      }
    }
    if (_selectionMoveStarts.remove(event.pointer) != null) {
      controller.cancelSelectionTransform();
      _releaseSelectionTransform('body-${event.pointer}');
    }
    _selectionGestures.remove(event.pointer);
    _selectionStarts.remove(event.pointer);
    _pointerKinds.remove(event.pointer);
    _pointerLocalPositions.remove(event.pointer);
    _pointerIndicators.removePointer(event.pointer);
    if (mounted) setState(() {});
  }

  void _updateNavigation(PointerMoveEvent event) {
    final previous = _navigationPointers[event.pointer];
    if (previous == null) return;
    final localPosition = _boundedLocalPosition(event.localPosition);
    final start = _navigationStartPositions[event.pointer];
    if (start != null &&
        (localPosition - start).distance > _navigationTapSlop) {
      _navigationGestureMovedBeyondTapSlop = true;
    }
    if (_navigationPointers.length == 1) {
      viewport.panBy(
        localPosition - previous,
        _size,
        visibleScreenBounds: _viewportVisibleBounds,
        horizontalConstraint: widget.horizontalViewportConstraint,
      );
      _navigationPointers[event.pointer] = localPosition;
      return;
    }
    final entries = _navigationPointers.entries.take(2).toList();
    final firstId = entries[0].key;
    final secondId = entries[1].key;
    final oldFirst = entries[0].value;
    final oldSecond = entries[1].value;
    final newFirst = firstId == event.pointer ? localPosition : oldFirst;
    final newSecond = secondId == event.pointer ? localPosition : oldSecond;
    final oldCentroid = (oldFirst + oldSecond) / 2;
    final newCentroid = (newFirst + newSecond) / 2;
    final oldDistance = (oldFirst - oldSecond).distance;
    final newDistance = (newFirst - newSecond).distance;
    final zoomFactor =
        oldDistance > 4 && newDistance > 4 && !_selectionActiveForParticipant
        ? newDistance / oldDistance
        : null;
    viewport.applyGestureTransform(
      panDelta: newCentroid - oldCentroid,
      focalPoint: newCentroid,
      viewportSize: _size,
      zoomFactor: zoomFactor,
      visibleScreenBounds: _viewportVisibleBounds,
      horizontalConstraint: widget.horizontalViewportConstraint,
    );
    if (zoomFactor != null) {
      _showNavigatorDuringGesture();
    }
    _navigationPointers[event.pointer] = localPosition;
  }

  Offset _boundedLocalPosition(Offset value) {
    if (!widget.confineInputToBounds || _size.isEmpty) return value;
    final bounds = _localBounds;
    return Offset(
      value.dx.clamp(bounds.left, bounds.right),
      value.dy.clamp(bounds.top, bounds.bottom),
    );
  }

  void _commitViewportPreview() {
    if (identical(viewport, controller.viewport)) controller.commitViewport();
    _viewportGestureStartScale = null;
    _viewportGestureStartOffset = null;
  }

  void _cancelViewportPreview() {
    final scale = _viewportGestureStartScale;
    final offset = _viewportGestureStartOffset;
    if (scale != null && offset != null) {
      viewport.restore(scale: scale, offset: offset);
    } else if (identical(viewport, controller.viewport)) {
      controller.cancelViewportPreview();
    }
    _viewportGestureStartScale = null;
    _viewportGestureStartOffset = null;
  }

  void _beginErase(PointerEvent event, Offset world, {Offset? localPosition}) {
    final trace = _provisionalTouchTraces[event.pointer];
    if (trace != null) trace.becameEraser = true;
    _cancelSelectionTransientsForEraser(event.pointer);
    var effectiveWorld = world;
    if (_rollbackNavigationForEraser(event.pointer)) {
      effectiveWorld = viewport.screenToWorld(
        _boundedLocalPosition(localPosition ?? event.localPosition),
      );
    }
    final effectiveLocal = _boundedLocalPosition(
      localPosition ?? event.localPosition,
    );
    final geometry = _eraserGeometry(
      event,
      localPosition: effectiveLocal,
      fallbackWorld: effectiveWorld,
    );
    _updateEraserIndicator(
      pointer: event.pointer,
      position: effectiveLocal,
      radius: geometry.screenRadius,
    );
    _eraserPointers[event.pointer] = _EraserPointerState(
      stamps: geometry.stamps,
      touchContact: event.kind == PointerDeviceKind.touch,
    );
    _eraseStampTransition(null, geometry.stamps);
    if (mounted) setState(() {});
  }

  void _promoteTouchClusterToEraser(ClusteredTouchEraserMatch cluster) {
    final pointers = cluster.positions.keys
        .where(_roles.containsKey)
        .toList(growable: false);
    if (pointers.length < 3) return;
    _clusteredTouchEraser.removeAll(pointers);

    // The first contacts may already have produced a provisional pan, zoom,
    // lasso, shape, or selection move. The cluster wins arbitration as one
    // physical fist, so every transient preview must be rolled back first.
    _cancelSelectionTransientsForEraser(pointers.first);
    _rollbackNavigationForEraser(pointers.first);

    final scale = viewport.scale;
    final worldRadius =
        cluster.brushRadius / (scale.isFinite && scale > 0 ? scale : 1);
    final sweeps = <InkEraserSweep>[];
    for (final pointer in pointers) {
      final previousRole = _roles[pointer];
      if (previousRole == PointerRole.ink) controller.cancelInk(pointer);
      _roles[pointer] = PointerRole.erase;
      _navigationPointers.remove(pointer);
      _selectionStarts.remove(pointer);
      _selectionMoveStarts.remove(pointer);
      _selectionGestures.remove(pointer);
      final local = cluster.positions[pointer];
      if (local == null) continue;
      final boundedLocal = _boundedLocalPosition(local);
      final world = viewport.screenToWorld(boundedLocal);
      _pointerIndicators.updatePointer(
        BoardPointerIndicator(
          pointer: pointer,
          position: boundedLocal,
          kind: BoardPointerIndicatorKind.eraser,
          radius: cluster.brushRadius,
        ),
      );
      _eraserPointers[pointer] = _EraserPointerState(
        stamps: <_WorldEraserStamp>[
          _WorldEraserStamp(center: world, radius: worldRadius),
        ],
        fixedScreenRadius: cluster.brushRadius,
        touchContact: true,
      );
      sweeps.add((start: world, end: world, radius: worldRadius));
    }
    controller.eraseSweeps(sweeps);
    if (mounted) setState(() {});
  }

  void _cancelSelectionTransientsForEraser(int eraserPointer) {
    var changed =
        _selectionTransformOwner != null ||
        _selectionGestures.isNotEmpty ||
        _selectionStarts.isNotEmpty ||
        _selectionMoveStarts.isNotEmpty;
    for (final entry in _roles.entries.toList(growable: false)) {
      if (entry.key != eraserPointer && entry.value == PointerRole.select) {
        _roles[entry.key] = PointerRole.ignored;
        _pointerIndicators.removePointer(entry.key);
        changed = true;
      }
    }
    if (!changed) return;
    controller.cancelSelectionTransform();
    _selectionGestures.clear();
    _selectionStarts.clear();
    _selectionMoveStarts.clear();
    final owner = _selectionTransformOwner;
    if (owner != null) _releaseSelectionTransform(owner);
    if (mounted) setState(() {});
  }

  bool _rollbackNavigationForEraser(int eraserPointer) {
    if (_navigationPointers.isEmpty) return false;
    for (final pointer in _navigationPointers.keys) {
      if (pointer != eraserPointer) _roles[pointer] = PointerRole.ignored;
    }
    _navigationPointers.clear();
    _resetNavigationGesture();
    _cancelViewportPreview();
    _navigatorHideTimer?.cancel();
    _navigatorVisible = false;
    if (mounted) setState(() {});
    return true;
  }

  void _continueErase(
    PointerEvent event,
    Offset world, {
    Offset? localPosition,
  }) {
    final previous = _eraserPointers[event.pointer];
    if (previous == null) {
      _beginErase(event, world, localPosition: localPosition);
      return;
    }
    final effectiveLocal = _boundedLocalPosition(
      localPosition ?? event.localPosition,
    );
    final geometry = _eraserGeometry(
      event,
      localPosition: effectiveLocal,
      fallbackWorld: world,
      fixedScreenRadius: previous.fixedScreenRadius,
    );
    _updateEraserIndicator(
      pointer: event.pointer,
      position: effectiveLocal,
      radius: geometry.screenRadius,
    );
    _eraseStampTransition(previous.stamps, geometry.stamps);
    _eraserPointers[event.pointer] = _EraserPointerState(
      stamps: geometry.stamps,
      fixedScreenRadius: previous.fixedScreenRadius,
      touchContact: previous.touchContact,
    );
  }

  ({List<_WorldEraserStamp> stamps, double screenRadius}) _eraserGeometry(
    PointerEvent event, {
    required Offset localPosition,
    required Offset fallbackWorld,
    double? fixedScreenRadius,
  }) {
    if (event.kind != PointerDeviceKind.touch) {
      final width =
          widget.participant?.penStyle.width ?? controller.penStyle.width;
      return (
        stamps: <_WorldEraserStamp>[
          _WorldEraserStamp(
            center: fallbackWorld,
            radius: EraserContactGeometry.stylusWorldRadius(width),
          ),
        ],
        screenRadius: EraserContactGeometry.cursorScreenRadius(
          logicalWidth: width,
          viewportScale: viewport.scale,
        ),
      );
    }
    final fixedRadius =
        fixedScreenRadius != null &&
            fixedScreenRadius.isFinite &&
            fixedScreenRadius > 0
        ? fixedScreenRadius.clamp(1.0, 96.0)
        : null;
    final footprint = fixedRadius == null
        ? controller.pointerPolicy.eraserFootprintFor(
            event,
            center: localPosition,
          )
        : <EraserBrushStamp>[
            EraserBrushStamp(center: localPosition, radius: fixedRadius),
          ];
    return (
      stamps: _screenFootprintToWorld(footprint),
      screenRadius: EraserContactGeometry.enclosingScreenRadius(
        center: localPosition,
        footprint: footprint,
        fallback:
            fixedRadius ?? controller.pointerPolicy.eraserRadiusFor(event),
      ),
    );
  }

  List<_WorldEraserStamp> _screenFootprintToWorld(
    List<EraserBrushStamp> footprint,
  ) {
    final safeScale = viewport.scale.isFinite && viewport.scale > 0
        ? viewport.scale
        : 1.0;
    return <_WorldEraserStamp>[
      for (final stamp in footprint)
        if (stamp.center.dx.isFinite &&
            stamp.center.dy.isFinite &&
            stamp.radius.isFinite &&
            stamp.radius > 0)
          _WorldEraserStamp(
            center: viewport.screenToWorld(stamp.center),
            radius: (stamp.radius / safeScale).clamp(.25, 96.0),
          ),
    ];
  }

  void _eraseStampTransition(
    List<_WorldEraserStamp>? previous,
    List<_WorldEraserStamp> current,
  ) => controller.eraseSweeps(_eraserSweepsForTransition(previous, current));

  List<InkEraserSweep> _eraserSweepsForTransition(
    List<_WorldEraserStamp>? previous,
    List<_WorldEraserStamp> current,
  ) {
    if (current.isEmpty) return const <InkEraserSweep>[];
    final sweeps = <InkEraserSweep>[];
    if (previous == null || previous.isEmpty) {
      for (final stamp in current) {
        sweeps.add((
          start: stamp.center,
          end: stamp.center,
          radius: stamp.radius,
        ));
      }
      return sweeps;
    }
    if (previous.length == current.length) {
      for (var index = 0; index < current.length; index++) {
        final from = previous[index];
        final to = current[index];
        sweeps.add((
          start: from.center,
          end: to.center,
          radius: math.max(from.radius, to.radius),
        ));
      }
      return sweeps;
    }
    // Hardware can start reporting calibrated axes midway through a gesture,
    // changing a circular fallback into an ellipse. Stamp the new footprint
    // and bridge its centre so coalesced move events cannot leave a gap.
    for (final stamp in current) {
      sweeps.add((
        start: stamp.center,
        end: stamp.center,
        radius: stamp.radius,
      ));
    }
    final from = previous[previous.length ~/ 2];
    final to = current[current.length ~/ 2];
    sweeps.add((
      start: from.center,
      end: to.center,
      radius: math.max(from.radius, to.radius),
    ));
    return sweeps;
  }

  void _finishErase(int pointer) {
    _eraserPointers.remove(pointer);
    _pointerIndicators.removePointer(pointer);
    // A fist/hand edge can be reported as multiple neighbouring contacts.
    // Commit only after the last one lifts so the whole wipe is one Undo and
    // one Auto-Save operation.
    if (_eraserPointers.isEmpty) {
      _nativePalmCommitTimer?.cancel();
      _nativePalmCommitTimer = null;
      _pointerIndicators.removePointer(_nativePalmIndicatorPointer);
      controller.commitErase();
      if (mounted) setState(() {});
    }
  }

  Offset get _navigatorTopLeft {
    final panel = BoardNavigator.preferredSize;
    final bounds = _localBounds;
    final fallback = Offset(
      bounds.right - panel.width - 18,
      bounds.bottom - panel.height - 18,
    );
    return _clampNavigatorPosition(_navigatorPosition ?? fallback);
  }

  Offset _clampNavigatorPosition(Offset value) {
    final panel = BoardNavigator.preferredSize;
    final bounds = _localBounds;
    return Offset(
      value.dx.clamp(
        bounds.left + 8,
        math.max(bounds.left + 8, bounds.right - panel.width - 8),
      ),
      value.dy.clamp(
        bounds.top + 8,
        math.max(bounds.top + 8, bounds.bottom - panel.height - 8),
      ),
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
    if (_eraserPointers.isNotEmpty) return;
    _navigatorHideTimer?.cancel();
    _viewportGestureStartScale ??= viewport.scale;
    _viewportGestureStartOffset ??= viewport.offset;
  }

  void _endNavigatorInteraction() {
    if (_eraserPointers.isNotEmpty) {
      _cancelViewportPreview();
      return;
    }
    _commitViewportPreview();
    _showNavigator();
  }

  void _moveNavigator(Offset delta) {
    if (_eraserPointers.isNotEmpty) return;
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
        if (distance > 3 / viewport.scale) {
          controller.commitSelectionTransform();
        } else {
          controller.cancelSelectionTransform();
          controller.selectAt(end, viewportScale: viewport.scale);
        }
      } finally {
        _releaseSelectionTransform('body-$pointer');
      }
    } else if (preview?.tool == BoardTool.shape) {
      var shapeEnd = end;
      final shape = preview?.shape ?? activeShape;
      if (shape == ShapeKind.circle) {
        final delta = end - start;
        final side = math.max(delta.dx.abs(), delta.dy.abs());
        shapeEnd = Offset(
          start.dx + (delta.dx < 0 ? -side : side),
          start.dy + (delta.dy < 0 ? -side : side),
        );
      }
      controller.addShape(shape, Rect.fromPoints(start, shapeEnd));
      widget.participant?.setTool(BoardTool.selectRectangle);
    } else if (distance < 8 / viewport.scale) {
      controller.selectAt(end, viewportScale: viewport.scale);
    } else if (preview?.tool == BoardTool.selectLasso) {
      controller.selectLasso([...path, end]);
    } else {
      controller.selectRectangle(Rect.fromPoints(start, end));
    }
    if (mounted) setState(() {});
  }

  void _handleLongPress(LongPressStartDetails details) {
    if (_inputSuppressed ||
        controller.inkSessions.isWriting ||
        _eraserPointers.isNotEmpty ||
        _navigationPointers.length > 1 ||
        _navigationGestureHadMultiplePointers ||
        _navigationGestureMovedBeyondTapSlop) {
      return;
    }
    if (_navigationPointers.length == 1) {
      _navigationGestureLongPressTriggered = true;
    }
    final world = viewport.screenToWorld(
      _boundedLocalPosition(details.localPosition),
    );
    if (controller.selectionEngine
        .candidatesAt(
          controller.page,
          Vec2(world.dx, world.dy),
          tolerance: 12 / viewport.scale,
        )
        .isEmpty) {
      widget.onEmptyLongPress?.call(details.localPosition, world);
    }
  }

  Rect2 _worldClip() {
    final bounds = _localBounds;
    final topLeft = viewport.screenToWorld(bounds.topLeft);
    final bottomRight = viewport.screenToWorld(bounds.bottomRight);
    return Rect2(
      left: topLeft.dx,
      top: topLeft.dy,
      width: bottomRight.dx - topLeft.dx,
      height: bottomRight.dy - topLeft.dy,
    ).inflate(80 / viewport.scale);
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
    required this.viewport,
    required this.inlineTextEditing,
    required this.onEditText,
    required this.onClaimTransform,
    required this.onReleaseTransform,
    super.key,
  });
  final EditorController controller;
  final BoardViewport viewport;
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
  Offset? _rotationAnchor;
  double? _rotationStartAngle;
  bool _ownsRotation = false;

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
    if (_ownsRotation) {
      widget.controller.cancelSelectionTransform();
      widget.onReleaseTransform('selection-rotation');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final world = controller.selectionBounds;
    if (world.isEmpty) return const SizedBox.shrink();
    final topLeft = widget.viewport.worldToScreen(
      Offset(world.left, world.top),
    );
    final bottomRight = widget.viewport.worldToScreen(
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
        if (!widget.inlineTextEditing)
          Positioned(
            left: rect.left,
            top: math.max(8, rect.top - 62),
            child: _SelectionActions(
              controller: controller,
              onEditText: widget.onEditText,
            ),
          ),
        if (!widget.inlineTextEditing)
          Positioned(
            key: const ValueKey('selection-rotation-handle'),
            left: rect.left - 24,
            top: rect.bottom - 24,
            child: Semantics(
              label: 'Auswahl drehen',
              button: true,
              hint: 'Ziehen zum freien Drehen, halten für feste Winkel',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: _beginRotation,
                onPanUpdate: _updateRotation,
                onPanEnd: (_) => _finishRotation(commit: true),
                onPanCancel: () => _finishRotation(commit: false),
                onLongPressStart: _showRotationMenu,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: FlowboardColors.panel,
                    shape: BoxShape.circle,
                    border: Border.all(color: FlowboardColors.mint, width: 3),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 8),
                    ],
                  ),
                  child: const Icon(
                    Icons.rotate_left_rounded,
                    size: 24,
                    color: FlowboardColors.mint,
                  ),
                ),
              ),
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
              viewport: widget.viewport,
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
                widget.viewport.worldToScreen(
                  Offset(cover.transform.x, cover.transform.y),
                ),
                widget.viewport.worldToScreen(
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
                viewport: widget.viewport,
                cover: cover,
                onClaim: (edge) =>
                    _claimCoverControl('resize-${cover.id}-${edge.name}'),
                onRelease: (edge) =>
                    _releaseCoverControl('resize-${cover.id}-${edge.name}'),
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

  Offset _worldFromGlobal(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    return widget.viewport.screenToWorld(box.globalToLocal(global));
  }

  void _beginRotation(DragStartDetails details) {
    _ownsRotation = widget.onClaimTransform('selection-rotation');
    if (!_ownsRotation) return;
    final bounds = widget.controller.selectionBounds;
    final center = Offset(bounds.center.x, bounds.center.y);
    final pointer = _worldFromGlobal(details.globalPosition);
    _rotationAnchor = center;
    _rotationStartAngle = math.atan2(
      pointer.dy - center.dy,
      pointer.dx - center.dx,
    );
  }

  void _updateRotation(DragUpdateDetails details) {
    if (!_ownsRotation) return;
    final center = _rotationAnchor;
    final start = _rotationStartAngle;
    if (center == null || start == null) return;
    final pointer = _worldFromGlobal(details.globalPosition);
    final current = math.atan2(pointer.dy - center.dy, pointer.dx - center.dx);
    widget.controller.previewRotateSelection(
      _normalizedAngle(current - start),
      anchor: center,
    );
  }

  void _finishRotation({required bool commit}) {
    if (!_ownsRotation) return;
    if (commit) {
      widget.controller.commitSelectionTransform();
    } else {
      widget.controller.cancelSelectionTransform();
    }
    _rotationAnchor = null;
    _rotationStartAngle = null;
    _ownsRotation = false;
    widget.onReleaseTransform('selection-rotation');
  }

  Future<void> _showRotationMenu(LongPressStartDetails details) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(details.globalPosition);
    final action = await showMenu<_SelectionRotationAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: const <PopupMenuEntry<_SelectionRotationAction>>[
        PopupMenuItem(
          value: _SelectionRotationAction.degrees30,
          child: Text('30°'),
        ),
        PopupMenuItem(
          value: _SelectionRotationAction.degrees45,
          child: Text('45°'),
        ),
        PopupMenuItem(
          value: _SelectionRotationAction.degrees60,
          child: Text('60°'),
        ),
        PopupMenuItem(
          value: _SelectionRotationAction.degrees90,
          child: Text('90°'),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: _SelectionRotationAction.mirror,
          child: ListTile(
            leading: Icon(Icons.flip_rounded),
            title: Text('Horizontal spiegeln'),
          ),
        ),
        PopupMenuItem(
          value: _SelectionRotationAction.manual,
          child: ListTile(
            leading: Icon(Icons.tune_rounded),
            title: Text('Winkel manuell festlegen'),
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SelectionRotationAction.degrees30:
        widget.controller.setSelectionRotationDegrees(30);
      case _SelectionRotationAction.degrees45:
        widget.controller.setSelectionRotationDegrees(45);
      case _SelectionRotationAction.degrees60:
        widget.controller.setSelectionRotationDegrees(60);
      case _SelectionRotationAction.degrees90:
        widget.controller.setSelectionRotationDegrees(90);
      case _SelectionRotationAction.mirror:
        widget.controller.mirrorSelectionHorizontally();
      case _SelectionRotationAction.manual:
        await _showManualRotationDialog();
    }
  }

  Future<void> _showManualRotationDialog() async {
    var value = widget.controller.selectionRotationDegrees
        .clamp(-180.0, 180.0)
        .roundToDouble();
    final selected = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Drehwinkel'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${value.round()}°',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Slider(
                  value: value,
                  min: -180,
                  max: 180,
                  divisions: 360,
                  label: '${value.round()}°',
                  onChanged: (next) => setDialogState(() => value = next),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Ein Grad zurück',
                      onPressed: () => setDialogState(
                        () => value = (value - 1).clamp(-180, 180),
                      ),
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    TextButton(
                      onPressed: () => setDialogState(() => value = 0),
                      child: const Text('0°'),
                    ),
                    IconButton(
                      tooltip: 'Ein Grad vor',
                      onPressed: () => setDialogState(
                        () => value = (value + 1).clamp(-180, 180),
                      ),
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, value),
              child: const Text('Übernehmen'),
            ),
          ],
        ),
      ),
    );
    if (mounted && selected != null) {
      widget.controller.setSelectionRotationDegrees(selected);
    }
  }
}

enum _SelectionRotationAction {
  degrees30,
  degrees45,
  degrees60,
  degrees90,
  mirror,
  manual,
}

double _normalizedAngle(double value) {
  var angle = value;
  while (angle > math.pi) {
    angle -= math.pi * 2;
  }
  while (angle < -math.pi) {
    angle += math.pi * 2;
  }
  return angle;
}

enum _CoverResizeEdge { left, top, right, bottom }

class _SelectionEdgeResizeHandles extends StatefulWidget {
  const _SelectionEdgeResizeHandles({
    required this.controller,
    required this.viewport,
    required this.objectRect,
    required this.onClaim,
    required this.onRelease,
  });

  final EditorController controller;
  final BoardViewport viewport;
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
            final viewportScale = widget.viewport.scale;
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
    required this.viewport,
    required this.cover,
    required this.onClaim,
    required this.onRelease,
  });

  final EditorController controller;
  final BoardViewport viewport;
  final CoverObject cover;
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
          viewport: viewport,
          cover: cover,
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
    required this.viewport,
    required this.cover,
    required this.edge,
    required this.onClaim,
    required this.onRelease,
    super.key,
  });

  final EditorController controller;
  final BoardViewport viewport;
  final CoverObject cover;
  final _CoverResizeEdge edge;
  final ValueGetter<bool> onClaim;
  final VoidCallback onRelease;

  @override
  State<_CoverResizeHandle> createState() => _CoverResizeHandleState();
}

class _CoverResizeHandleState extends State<_CoverResizeHandle> {
  ObjectTransform? _baseTransform;
  Offset _accumulatedWorldDelta = Offset.zero;
  bool _ownsGesture = false;

  bool get _horizontal =>
      widget.edge == _CoverResizeEdge.left ||
      widget.edge == _CoverResizeEdge.right;

  Offset get _screenCenter {
    final transform = widget.cover.transform;
    final local = switch (widget.edge) {
      _CoverResizeEdge.left => Offset(0, transform.height / 2),
      _CoverResizeEdge.top => Offset(transform.width / 2, 0),
      _CoverResizeEdge.right => Offset(transform.width, transform.height / 2),
      _CoverResizeEdge.bottom => Offset(transform.width / 2, transform.height),
    };
    return widget.viewport.worldToScreen(_framePointToWorld(transform, local));
  }

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
            _baseTransform = widget.cover.transform;
            _accumulatedWorldDelta = Offset.zero;
          },
          onPanUpdate: (details) {
            if (!_ownsGesture) return;
            final base = _baseTransform;
            final scale = widget.viewport.scale;
            if (base == null || !scale.isFinite || scale <= 0) return;
            _accumulatedWorldDelta += _worldVectorToFrame(
              details.delta / scale,
              base.rotationRadians,
            );
            final minWidth = math.min(48.0, base.width);
            final minHeight = math.min(48.0, base.height);
            var scaleX = 1.0;
            var scaleY = 1.0;
            late final Offset anchor;
            switch (widget.edge) {
              case _CoverResizeEdge.left:
                scaleX = ((base.width - _accumulatedWorldDelta.dx) / base.width)
                    .clamp(minWidth / base.width, 20.0);
                anchor = _framePointToWorld(
                  base,
                  Offset(base.width, base.height / 2),
                );
              case _CoverResizeEdge.top:
                scaleY =
                    ((base.height - _accumulatedWorldDelta.dy) / base.height)
                        .clamp(minHeight / base.height, 20.0);
                anchor = _framePointToWorld(
                  base,
                  Offset(base.width / 2, base.height),
                );
              case _CoverResizeEdge.right:
                scaleX = ((base.width + _accumulatedWorldDelta.dx) / base.width)
                    .clamp(minWidth / base.width, 20.0);
                anchor = _framePointToWorld(base, Offset(0, base.height / 2));
              case _CoverResizeEdge.bottom:
                scaleY =
                    ((base.height + _accumulatedWorldDelta.dy) / base.height)
                        .clamp(minHeight / base.height, 20.0);
                anchor = _framePointToWorld(base, Offset(base.width / 2, 0));
            }
            widget.controller.previewResizeSelection(
              scaleX: scaleX,
              scaleY: scaleY,
              anchor: anchor,
              scaleAxisRadians: base.rotationRadians,
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
    _baseTransform = null;
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

Offset _framePointToWorld(ObjectTransform transform, Offset local) {
  final unrotated = Offset(transform.x + local.dx, transform.y + local.dy);
  final center = Offset(
    transform.x + transform.width / 2,
    transform.y + transform.height / 2,
  );
  final cosine = math.cos(transform.rotationRadians);
  final sine = math.sin(transform.rotationRadians);
  final delta = unrotated - center;
  return center +
      Offset(
        delta.dx * cosine - delta.dy * sine,
        delta.dx * sine + delta.dy * cosine,
      );
}

Offset _worldVectorToFrame(Offset vector, double rotationRadians) {
  final cosine = math.cos(rotationRadians);
  final sine = math.sin(rotationRadians);
  return Offset(
    vector.dx * cosine + vector.dy * sine,
    -vector.dx * sine + vector.dy * cosine,
  );
}

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
    final localRect = Offset.zero & objectRect.size;
    final guidePosition = switch (cover.direction) {
      RevealDirection.leftToRight => Offset(
        localRect.left + localRect.width * value,
        localRect.center.dy,
      ),
      RevealDirection.rightToLeft => Offset(
        localRect.right - localRect.width * value,
        localRect.center.dy,
      ),
      RevealDirection.topToBottom => Offset(
        localRect.center.dx,
        localRect.top + localRect.height * value,
      ),
      RevealDirection.bottomToTop => Offset(
        localRect.center.dx,
        localRect.bottom - localRect.height * value,
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
            height: localRect.height,
          )
        : Rect.fromCenter(
            center: guidePosition,
            width: localRect.width,
            height: 44,
          );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fromRect(
          rect: objectRect,
          child: Transform.rotate(
            angle: cover.transform.rotationRadians,
            child: Transform.flip(
              flipX: cover.transform.flipX,
              flipY: cover.transform.flipY,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
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
                                ? localRect.width
                                : localRect.height;
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

final class _ProvisionalTouchTrace {
  _ProvisionalTouchTrace({
    required this.pointer,
    required this.initialViewportScale,
    required this.initialViewportOffset,
  });

  static const int _maximumSamples = 128;
  final int pointer;
  final double initialViewportScale;
  final Offset initialViewportOffset;
  final List<Offset> points = <Offset>[];
  final List<List<EraserBrushStamp>> footprints = <List<EraserBrushStamp>>[];
  double maximumScreenRadius = 18;
  bool routedToBoard = false;
  bool becameEraser = false;
  bool suppressedByStylus = false;

  void add(
    Offset point,
    double screenRadius, {
    required List<EraserBrushStamp> footprint,
  }) {
    if (!point.dx.isFinite || !point.dy.isFinite) return;
    if (screenRadius.isFinite && screenRadius > maximumScreenRadius) {
      maximumScreenRadius = screenRadius.clamp(18.0, 96.0);
    }
    final previous = points.lastOrNull;
    if (previous != null && (previous - point).distance < .75) {
      points[points.length - 1] = point;
      footprints[footprints.length - 1] = footprint;
      return;
    }
    if (points.length >= _maximumSamples) {
      final compacted = <Offset>[points.first];
      final compactedFootprints = <List<EraserBrushStamp>>[footprints.first];
      for (var index = 2; index < points.length - 1; index += 2) {
        compacted.add(points[index]);
        compactedFootprints.add(footprints[index]);
      }
      compacted.add(points.last);
      compactedFootprints.add(footprints.last);
      points
        ..clear()
        ..addAll(compacted);
      footprints
        ..clear()
        ..addAll(compactedFootprints);
    }
    points.add(point);
    footprints.add(List<EraserBrushStamp>.unmodifiable(footprint));
  }
}

final class _EraserPointerState {
  const _EraserPointerState({
    required this.stamps,
    required this.touchContact,
    this.fixedScreenRadius,
  });

  final List<_WorldEraserStamp> stamps;
  final bool touchContact;
  final double? fixedScreenRadius;
}

final class _WorldEraserStamp {
  const _WorldEraserStamp({required this.center, required this.radius});

  final Offset center;
  final double radius;
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

final class _BoardPointerIndicatorController extends ChangeNotifier {
  final Map<int, BoardPointerIndicator> _active =
      <int, BoardPointerIndicator>{};
  Offset? _hoverPosition;

  List<BoardPointerIndicator> get indicators =>
      List<BoardPointerIndicator>.unmodifiable(_active.values);

  Offset? get hoverPosition => _active.isEmpty ? _hoverPosition : null;

  void updateHover(Offset position) {
    if (!position.dx.isFinite ||
        !position.dy.isFinite ||
        _hoverPosition == position) {
      return;
    }
    _hoverPosition = position;
    if (_active.isEmpty) notifyListeners();
  }

  void clearHover() {
    if (_hoverPosition == null) return;
    _hoverPosition = null;
    if (_active.isEmpty) notifyListeners();
  }

  void updatePointer(BoardPointerIndicator indicator) {
    if (!indicator.position.dx.isFinite || !indicator.position.dy.isFinite) {
      return;
    }
    if (_active[indicator.pointer] == indicator) return;
    _active[indicator.pointer] = indicator;
    notifyListeners();
  }

  void removePointer(int pointer) {
    if (_active.remove(pointer) == null) return;
    if (_active.isEmpty) _hoverPosition = null;
    notifyListeners();
  }

  void clear({bool notify = true}) {
    if (_active.isEmpty && _hoverPosition == null) return;
    _active.clear();
    _hoverPosition = null;
    if (notify) notifyListeners();
  }
}

class _GestureOverlayPainter extends CustomPainter {
  const _GestureOverlayPainter({
    required this.gestures,
    required this.viewportScale,
    required this.viewportOffset,
  });

  final List<_GesturePreview> gestures;
  final double viewportScale;
  final Offset viewportOffset;

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
