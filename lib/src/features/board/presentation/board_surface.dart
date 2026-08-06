import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../app/app_theme.dart';
import '../../../diagnostics/diagnostics.dart';
import '../../../domain/model/board_object.dart';
import '../../../domain/model/geometry.dart';
import '../../../domain/model/ink.dart';
import '../../../platform/android_palm_input.dart';
import '../../editor/board_participant_controller.dart';
import '../../editor/editor_controller.dart';
import '../../input/clustered_touch_eraser.dart';
import '../../input/eraser_contact_geometry.dart';
import '../../input/touch_interaction_ownership.dart';
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

/// Identity-based subset of controller state consumed by [BoardSurface].
///
/// A shared history notifies both participant controllers for every command.
/// Most of those commands can target a page that is not visible on one side.
/// Comparing this compact snapshot prevents such an event (and metadata-only
/// Auto-Save settings commits) from rebuilding an otherwise unchanged board.
final class _BoardSurfaceRenderSnapshot {
  _BoardSurfaceRenderSnapshot.from(EditorController controller)
    : pageId = controller.page.id,
      objects = controller.renderObjects,
      strokes = controller.renderStrokes,
      annotationLayers = controller.renderAnnotationLayers,
      selectedIds = controller.selectedSceneItemIds,
      hasSelection = controller.hasSelection,
      selectionBounds = controller.hasSelection
          ? controller.selectionBounds
          : null,
      selectedContentGroupId = controller.selectedContentGroup?.id,
      selectedCoverId = controller.selectedCover?.id,
      selectedPdfId = controller.selectedPdf?.id,
      selectedTextId = controller.selectedTextObject?.id,
      canGroupSelection = controller.canGroupSelection,
      canArrangeSelection = controller.canArrangeSelection,
      hasSelectedHandwriting = controller.hasSelectedHandwriting,
      handwritingConversionInProgress =
          controller.isHandwritingConversionInProgress,
      tool = controller.tool,
      shape = controller.activeShape,
      penColor = controller.penStyle.colorArgb,
      penWidth = controller.penStyle.width,
      penType = controller.penStyle.type;

  final String pageId;
  final List<BoardObject> objects;
  final List<InkStroke> strokes;
  final List<ObjectInkLayer> annotationLayers;
  final Set<String> selectedIds;
  final bool hasSelection;
  final Rect2? selectionBounds;
  final String? selectedContentGroupId;
  final String? selectedCoverId;
  final String? selectedPdfId;
  final String? selectedTextId;
  final bool canGroupSelection;
  final bool canArrangeSelection;
  final bool hasSelectedHandwriting;
  final bool handwritingConversionInProgress;
  final BoardTool tool;
  final ShapeKind shape;
  final int penColor;
  final double penWidth;
  final InkToolType penType;

  @override
  bool operator ==(Object other) =>
      other is _BoardSurfaceRenderSnapshot &&
      other.pageId == pageId &&
      identical(other.objects, objects) &&
      identical(other.strokes, strokes) &&
      identical(other.annotationLayers, annotationLayers) &&
      identical(other.selectedIds, selectedIds) &&
      other.hasSelection == hasSelection &&
      other.selectionBounds == selectionBounds &&
      other.selectedContentGroupId == selectedContentGroupId &&
      other.selectedCoverId == selectedCoverId &&
      other.selectedPdfId == selectedPdfId &&
      other.selectedTextId == selectedTextId &&
      other.canGroupSelection == canGroupSelection &&
      other.canArrangeSelection == canArrangeSelection &&
      other.hasSelectedHandwriting == hasSelectedHandwriting &&
      other.handwritingConversionInProgress ==
          handwritingConversionInProgress &&
      other.tool == tool &&
      other.shape == shape &&
      other.penColor == penColor &&
      other.penWidth == penWidth &&
      other.penType == penType;

  @override
  int get hashCode => Object.hash(
    pageId,
    identityHashCode(objects),
    identityHashCode(strokes),
    identityHashCode(annotationLayers),
    identityHashCode(selectedIds),
    hasSelection,
    selectionBounds,
    selectedContentGroupId,
    selectedCoverId,
    selectedPdfId,
    selectedTextId,
    canGroupSelection,
    canArrangeSelection,
    hasSelectedHandwriting,
    handwritingConversionInProgress,
    tool,
    shape,
    penColor,
    penWidth,
    penType,
  );
}

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
  static const int _clusterPalmIndicatorPointer = -0x434C5354;
  // Applied only after the conservative broad-touch latch, the coherent
  // three-contact fallback, or the native palm gate has positively identified
  // a fist. The board-scale minimum remains clearly visible and useful on
  // classroom panels whose firmware reports a quantized 18-30 px radius.
  static const double _confirmedFistMinimumScreenRadius =
      EraserContactGeometry.minimumRecognizedFistScreenRadius;
  static const double _confirmedFistMaximumScreenRadius =
      EraserContactGeometry.maximumRecognizedFistScreenRadius;
  final Map<int, PointerRole> _roles = {};
  final Map<int, PointerDeviceKind> _pointerKinds = {};
  final Map<int, Offset> _pointerLocalPositions = {};
  final Map<int, Offset> _navigationPointers = {};
  final Map<int, Offset> _navigationStartPositions = {};
  bool _navigationGestureHadMultiplePointers = false;
  bool _navigationGestureMovedBeyondTapSlop = false;
  bool _navigationGestureLongPressTriggered = false;
  final Map<int, _EraserPointerState> _eraserPointers = {};
  final Set<int> _globalTouchStartsInside = <int>{};
  final Set<int> _stylusSuppressedTouchPointers = <int>{};
  final TouchInteractionOwnershipGate _touchInteractionOwnership =
      TouchInteractionOwnershipGate();
  final ClusteredTouchEraserTracker _clusteredTouchEraser =
      ClusteredTouchEraserTracker();
  _ClusterEraserSession? _clusterEraserSession;
  final Map<int, _GesturePreview> _selectionGestures = {};
  int _selectionGestureRevision = 0;
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
  late _BoardSurfaceRenderSnapshot _renderSnapshot;
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
  Duration _latestPointerTimeStamp = Duration.zero;
  Duration _activePagePointerEpoch = Duration.zero;

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
    _renderSnapshot = _BoardSurfaceRenderSnapshot.from(controller);
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
      _renderSnapshot = _BoardSurfaceRenderSnapshot.from(controller);
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
    _touchInteractionOwnership.clear();
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
    final explicitNativePalm = stroke.source == 'tool_type_palm';
    final coherentMultiContact =
        stroke.source == 'system_canceled' && stroke.contactCount >= 3;
    if (!explicitNativePalm && !coherentMultiContact) {
      // A canceled TOOL_TYPE_FINGER trace is still just a finger interaction.
      // Some SMART-class drivers report a very large TOUCH_MAJOR for it. The
      // native service already enforces this invariant; repeat the gate here
      // so malformed/stale platform packets can never erase a selection.
      DiagnosticLogService.instance.info(
        'input.palm_native_rejected',
        fields: <String, Object?>{
          'source': stroke.source,
          'contacts': stroke.contactCount,
        },
      );
      _rememberHandledNativePalmSession(stroke.sessionId);
      return;
    }
    final usefulStrokeTimes = stroke.samples
        .map((sample) => sample.timeStamp)
        .where((value) => value > Duration.zero)
        .toList(growable: false);
    if (_activePagePointerEpoch > Duration.zero &&
        usefulStrokeTimes.isNotEmpty &&
        usefulStrokeTimes.reduce((a, b) => a <= b ? a : b) <=
            _activePagePointerEpoch) {
      // The Android bridge emits a completed palm trace only on UP/CANCEL. If
      // its DOWN predates the page switch, replaying it against controller.page
      // would erase the newly opened page rather than the page it touched.
      _rememberHandledNativePalmSession(stroke.sessionId);
      DiagnosticLogService.instance.info(
        'input.palm_native_stale_page',
        fields: <String, Object?>{'page': controller.page.id},
      );
      return;
    }
    final ownershipPositions = stroke.samples.isNotEmpty
        ? stroke.samples.map((sample) => sample.position)
        : stroke.points;
    final nativePalmOwnsIntent = stroke.startedAsPalm || coherentMultiContact;
    if (!nativePalmOwnsIntent &&
        _touchInteractionOwnership.blocksNativeReplay(
          globalPositions: ownershipPositions,
          timeStamps: stroke.samples.map((sample) => sample.timeStamp),
        )) {
      // Android can promote TOOL_TYPE_FINGER to TOOL_TYPE_PALM only after
      // Flutter has already selected or transformed content. That late side
      // channel is not a second interaction: the existing non-destructive
      // owner wins for the complete pointer lifecycle, including after UP or
      // ACTION_CANCEL. Remember rejected ids so a duplicate platform packet
      // cannot become destructive after the ownership grace period expires.
      _rememberHandledNativePalmSession(stroke.sessionId);
      DiagnosticLogService.instance.info(
        'input.palm_native_selection_owned',
        fields: <String, Object?>{
          'source': stroke.source,
          'contacts': stroke.contactCount,
        },
      );
      return;
    }
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
        <
          ({
            Offset center,
            List<EraserBrushStamp> footprint,
            double screenRadius,
          })
        >[];
    double? previousScreenRadius;
    Duration? previousTimeStamp;
    for (var index = 0; index < nativeSamples.length; index++) {
      final sample = nativeSamples[index];
      final local = _globalToLocal(sample.position);
      if (local == null) continue;
      if (localSamples.isEmpty && !_localBounds.contains(local)) return;
      final bounded = _boundedLocalPosition(local);
      // New bridge packets carry a fused physical radius for every sample.
      // The stroke-level radius is only the legacy/trace-wide fallback; using
      // it for every sample would inflate the complete gesture to the largest
      // contact ever seen instead of following the live resting area.
      final sampleFallbackRadius =
          sample.radiusMajor.isFinite && sample.radiusMajor > 0
          ? sample.radiusMajor
          : stroke.radius;
      final measuredFootprint = EraserContactGeometry.touchScreenFootprint(
        center: bounded,
        radiusMajor: sample.radiusMajor,
        radiusMinor: sample.radiusMinor,
        orientation: sample.orientation,
        fallbackRadius: sampleFallbackRadius,
      );
      final geometry = _confirmedFistScreenGeometry(
        center: bounded,
        measuredFootprint: measuredFootprint,
        fallbackRadius: sampleFallbackRadius,
        previousScreenRadius: previousScreenRadius,
        elapsed:
            previousTimeStamp == null || sample.timeStamp <= previousTimeStamp
            ? const Duration(milliseconds: 16)
            : sample.timeStamp - previousTimeStamp,
      );
      previousScreenRadius = geometry.screenRadius;
      previousTimeStamp = sample.timeStamp;
      localSamples.add((
        center: bounded,
        footprint: geometry.footprint,
        screenRadius: geometry.screenRadius,
      ));
    }
    if (localSamples.isEmpty ||
        !_localBounds.contains(localSamples.first.center)) {
      return;
    }
    _rememberHandledNativePalmSession(stroke.sessionId);

    // Android reports palm rejection only after provisional touch events. The
    // native signal wins over the selection interaction at the same physical
    // location. A separate user's distant handle drag remains independent.
    _hideNavigatorForContentInteraction();
    final touchesSelectionInteraction = localSamples.any(
      (sample) => _nativePalmTouchesSelectionInteraction(
        sample.center,
        sample.screenRadius,
      ),
    );
    if (touchesSelectionInteraction) {
      _cancelSelectionTransientsForEraser(-1);
    }
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
      radius: lastSample.screenRadius,
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

  bool _nativePalmTouchesSelectionInteraction(Offset center, double radius) {
    final safeRadius = radius.isFinite && radius > 0 ? radius : 30.0;
    if (controller.hasSelection) {
      final bounds = controller.selectionBounds;
      final screenBounds = Rect.fromPoints(
        viewport.worldToScreen(Offset(bounds.left, bounds.top)),
        viewport.worldToScreen(Offset(bounds.right, bounds.bottom)),
      ).inflate(safeRadius);
      if (screenBounds.contains(center)) return true;
    }
    final toleranceSquared = math.pow(safeRadius + 30, 2).toDouble();
    for (final pointer in <int>{
      ..._selectionStarts.keys,
      ..._selectionMoveStarts.keys,
      ..._selectionGestures.keys,
      ..._selectionPinchPointers,
    }) {
      final position = _pointerLocalPositions[pointer];
      if (position != null &&
          (position - center).distanceSquared <= toleranceSquared) {
        return true;
      }
    }
    return false;
  }

  void _rememberHandledNativePalmSession(String sessionId) {
    _handledNativePalmSessions.add(sessionId);
    while (_handledNativePalmSessions.length > 64) {
      _handledNativePalmSessions.remove(_handledNativePalmSessions.first);
    }
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
    _nativePalmCommitTimer = null;
    if (_eraserPointers.isNotEmpty) {
      // The ordinary pointer-UP path commits when the final physical contact
      // leaves. Polling every 180 ms while a hand rests on the board created
      // an unbounded timer chain beside stylus input without changing when the
      // erase could safely be committed.
      return;
    }
    _nativePalmCommitTimer = Timer(const Duration(milliseconds: 180), () {
      if (_eraserPointers.isNotEmpty) {
        // A contact appeared during the grace period. Its final UP owns the
        // commit; no recurring timer is necessary.
        _nativePalmCommitTimer = null;
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
      _activePagePointerEpoch = _latestPointerTimeStamp;
      _inlineTextObjectId = null;
      _clearTransientPointers();
    }
    final editingId = _inlineTextObjectId;
    if (editingId != null && controller.selectedTextObject?.id != editingId) {
      _inlineTextObjectId = null;
    }
    final next = _BoardSurfaceRenderSnapshot.from(controller);
    if (next == _renderSnapshot) return;
    _renderSnapshot = next;
    if (mounted) setState(() {});
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
    _globalTouchStartsInside.clear();
    _stylusSuppressedTouchPointers.clear();
    _touchInteractionOwnership.completeAll();
    _clusteredTouchEraser.clear();
    _clusterEraserSession = null;
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
          animation: Listenable.merge([viewport, ?widget.participant]),
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
                                    gestureRevision: _selectionGestureRevision,
                                    viewportScale: viewport.scale,
                                    viewportOffset: viewport.offset,
                                  ),
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: AnimatedBuilder(
                                animation: _pointerIndicators,
                                builder: (context, _) =>
                                    _buildPointerIndicatorOverlay(),
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
                      onClaimPointerDown: _claimTouchSelection,
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

  Widget _buildPointerIndicatorOverlay() {
    final indicators = _pointerIndicators.indicators;
    final hover = _pointerIndicators.hoverPosition;
    final brushWidth =
        widget.participant?.penStyle.width ?? controller.penStyle.width;
    if (indicators.isEmpty && hover == null) {
      // Keep the stable key available for diagnostics and widget tests without
      // retaining a full-board raster layer while no pointer is visible.
      return Align(
        alignment: Alignment.topLeft,
        child: SizedBox.square(
          dimension: 1,
          child: CustomPaint(
            key: const ValueKey<String>('board-pointer-indicator'),
            painter: BoardPointerIndicatorPainter(
              indicators: const <BoardPointerIndicator>[],
              hoverPosition: null,
              tool: activeTool,
              brushWidth: brushWidth,
              viewportScale: viewport.scale,
            ),
          ),
        ),
      );
    }

    final entries = indicators.isNotEmpty
        ? indicators
        : <BoardPointerIndicator>[
            BoardPointerIndicator(
              pointer: -1,
              position: hover!,
              kind: switch (activeTool) {
                BoardTool.eraser => BoardPointerIndicatorKind.eraser,
                BoardTool.selectRectangle ||
                BoardTool.selectLasso => BoardPointerIndicatorKind.selection,
                BoardTool.shape => BoardPointerIndicatorKind.shape,
                BoardTool.pen ||
                BoardTool.marker ||
                BoardTool.dashedPen ||
                BoardTool.straightLine => BoardPointerIndicatorKind.ink,
              },
              radius:
                  activeTool == BoardTool.selectRectangle ||
                      activeTool == BoardTool.selectLasso ||
                      activeTool == BoardTool.shape
                  ? 7
                  : EraserContactGeometry.cursorScreenRadius(
                      logicalWidth: brushWidth,
                      viewportScale: viewport.scale,
                    ),
            ),
          ];
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        for (var index = 0; index < entries.length; index++)
          _buildBoundedPointerIndicator(
            entries[index],
            index: index,
            hoverOnly: indicators.isEmpty,
            brushWidth: brushWidth,
          ),
      ],
    );
  }

  Widget _buildBoundedPointerIndicator(
    BoardPointerIndicator indicator, {
    required int index,
    required bool hoverOnly,
    required double brushWidth,
  }) {
    final radius = indicator.radius.isFinite
        ? indicator.radius.clamp(.5, 160.0)
        : 7.0;
    final extent = radius + 6;
    final origin = indicator.position - Offset(extent, extent);
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: extent * 2,
      height: extent * 2,
      child: RepaintBoundary(
        child: CustomPaint(
          key: index == 0
              ? const ValueKey<String>('board-pointer-indicator')
              : ValueKey<String>(
                  'board-pointer-indicator-${indicator.pointer}',
                ),
          painter: BoardPointerIndicatorPainter(
            // Preserve global coordinates in the painter snapshot for
            // diagnostics while translating only its tiny paint surface.
            indicators: hoverOnly
                ? const <BoardPointerIndicator>[]
                : <BoardPointerIndicator>[indicator],
            hoverPosition: hoverOnly ? indicator.position : null,
            tool: activeTool,
            brushWidth: brushWidth,
            viewportScale: viewport.scale,
            paintOrigin: origin,
          ),
        ),
      ),
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

  void _claimTouchSelection(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touchInteractionOwnership.claimSelection(
      pointer: event.pointer,
      globalPosition: event.position,
      timeStamp: event.timeStamp,
    );
  }

  void _handleGlobalPriorityPointerEvent(PointerEvent event) {
    if (event.timeStamp > _latestPointerTimeStamp) {
      _latestPointerTimeStamp = event.timeStamp;
    }
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
      _touchInteractionOwnership.observeDown(
        pointer: event.pointer,
        globalPosition: event.position,
        timeStamp: event.timeStamp,
      );
      if (controller.inkSessions.hasActiveStylus) {
        _stylusSuppressedTouchPointers.add(event.pointer);
      }
      return;
    }
    if (!_globalTouchStartsInside.contains(event.pointer)) {
      return;
    }
    final stylusActive = controller.inkSessions.hasActiveStylus;
    final suppressedByStylus = _stylusSuppressedTouchPointers.contains(
      event.pointer,
    );
    if (event is PointerMoveEvent) {
      _touchInteractionOwnership.observe(
        pointer: event.pointer,
        globalPosition: event.position,
        timeStamp: event.timeStamp,
      );
      if (stylusActive) {
        _stylusSuppressedTouchPointers.add(event.pointer);
        _neutralizeActiveTouchesForStylus();
      } else if (suppressedByStylus) {
        // The contact remains palm-rejected for its complete lifetime, even
        // if the pen happens to lift first.
        return;
      }
      return;
    }
    if (event is! PointerUpEvent && event is! PointerCancelEvent) return;

    _touchInteractionOwnership.observe(
      pointer: event.pointer,
      globalPosition: event.position,
      timeStamp: event.timeStamp,
    );

    // Global routes can run before or after the hit-tested board route. Keep
    // the ownership marker through the current dispatch microtask so either
    // ordering remains idempotent.
    scheduleMicrotask(() {
      _touchInteractionOwnership.complete(
        pointer: event.pointer,
        globalPosition: event.position,
        timeStamp: event.timeStamp,
      );
      _globalTouchStartsInside.remove(event.pointer);
      _stylusSuppressedTouchPointers.remove(event.pointer);
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
      ..._stylusSuppressedTouchPointers,
    };
    final hasUnlatchedTouch = touchPointers.any(
      (pointer) => _roles[pointer] != PointerRole.ignored,
    );
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
          _roles[pointer] == PointerRole.erase,
    );
    final hasFingerInk = touchPointers.any(
      (pointer) => _roles[pointer] == PointerRole.ink,
    );
    if (!hasUnlatchedTouch &&
        !hasTouchSelection &&
        !hasTouchNavigation &&
        !hasTouchErase &&
        !hasFingerInk) {
      // A resting palm keeps sending MOVE packets on real smartboards. Once
      // every contact is latched as ignored there is no visible state left to
      // roll back. Re-entering the cleanup (from both the global route and the
      // hit-tested board route) used to call setState for every palm packet,
      // rebuilding the complete board while the stylus was writing.
      for (final pointer in touchPointers) {
        _stylusSuppressedTouchPointers.add(pointer);
      }
      return;
    }

    // A global pointer route can observe the touch DOWN before the board
    // listener. Latch contacts that have not acquired any interaction yet
    // without scheduling a frame; the later hit-tested DOWN then remains
    // idempotently ignored.
    if (!hasTouchSelection &&
        !hasTouchNavigation &&
        !hasTouchErase &&
        !hasFingerInk) {
      for (final pointer in touchPointers) {
        _roles[pointer] = PointerRole.ignored;
        _stylusSuppressedTouchPointers.add(pointer);
      }
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
      _selectionStarts.remove(pointer);
      _selectionMoveStarts.remove(pointer);
      _selectionGestures.remove(pointer);
      _selectionPinchPointers.remove(pointer);
      _clusteredTouchEraser.remove(pointer);
      _pointerIndicators.removePointer(pointer);
      _stylusSuppressedTouchPointers.add(pointer);
    }
    if (_navigationPointers.isEmpty) _resetNavigationGesture();
    if (_selectionPinchPointers.isEmpty) {
      _selectionPinchStartDistance = null;
      _selectionPinchAnchor = null;
    }
    _clusteredTouchEraser.clear();
    _clusterEraserSession = null;
    _eraserPointers.remove(_clusterPalmIndicatorPointer);
    _pointerIndicators.removePointer(_clusterPalmIndicatorPointer);
    if (mounted) setState(() {});
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_roles.containsKey(event.pointer)) return;
    _pointerKinds[event.pointer] = event.kind;
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
    // Explicit stylus erasers are handled here. Touch erasing is deliberately
    // isolated in the native TOOL_TYPE_PALM and coherent 3+ cluster paths.
    final stylusCurrentlyActive = controller.inkSessions.hasActiveStylus;
    if (event.kind == PointerDeviceKind.touch && stylusCurrentlyActive) {
      _stylusSuppressedTouchPointers.add(event.pointer);
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
      _hideNavigatorForContentInteraction();
      _clusteredTouchEraser.clear();
      _roles[event.pointer] = PointerRole.erase;
      _beginErase(event, world, localPosition: localPosition);
      return;
    }
    if (_tryBeginSelectionPinch(event, localPosition, world)) return;
    if (_tryBeginTouchNavigationPinch(event, localPosition)) return;
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
      _hideNavigatorForContentInteraction();
      final owner = 'body-${event.pointer}';
      if (!_claimSelectionTransform(owner)) {
        _roles[event.pointer] = PointerRole.ignored;
        return;
      }
      _claimTouchSelection(event);
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
    if (activeTool == BoardTool.shape &&
        (event.kind != PointerDeviceKind.touch ||
            widget.fingerDrawingEnabled)) {
      _hideNavigatorForContentInteraction();
      _claimTouchSelection(event);
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
    if (event.kind == PointerDeviceKind.touch &&
        role == PointerRole.erase &&
        !isReportedEraser) {
      // PointerPolicy deliberately accepts a wider range for isolated
      // low-level use. On a complete board surface that permissive answer
      // must not bypass the stable broad-contact latch above: ordinary
      // fingers frequently report a 20x13 or elongated 26x10 ellipse while
      // pressing, selecting, or pinching. Route such a contact exactly like
      // an ordinary touch until consecutive unmistakable fist packets promote
      // it in the global priority route.
      role = _ordinaryTouchRole(stylusCurrentlyActive);
    }
    // This is the final gate before beginInk. Touch must never author ink
    // while the user-facing finger-drawing switch is off, even if a future
    // pointer-policy change accidentally classifies it as ink.
    if (event.kind == PointerDeviceKind.touch &&
        role == PointerRole.ink &&
        !widget.fingerDrawingEnabled) {
      role = PointerRole.navigate;
    }
    // Keep an ordinary unselected touch in navigation for its complete
    // lifecycle. UP turns a stationary contact into selection, while movement
    // beyond tap slop stays a camera pan. Only a selection that existed before
    // DOWN may be promoted to a body move below.
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
    if (role == PointerRole.ink ||
        role == PointerRole.erase ||
        role == PointerRole.select) {
      _hideNavigatorForContentInteraction();
    }
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
        _claimTouchSelection(event);
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
    _touchInteractionOwnership.claimSelection(pointer: firstPointer);
    _claimTouchSelection(event);
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

  /// Promotes the second ordinary touch to camera navigation when the pair
  /// was not claimed by [_tryBeginSelectionPinch].
  ///
  /// Selection tools intentionally route their first touch to a rectangle,
  /// lasso, body move, or provisional finger stroke. Waiting for a second
  /// touch lets one-finger interaction retain that behavior while still
  /// making pinch-to-zoom universally available. A pinch fully inside content
  /// that was already selected is handled first and continues to resize it.
  bool _tryBeginTouchNavigationPinch(
    PointerDownEvent event,
    Offset localPosition,
  ) {
    if (event.kind != PointerDeviceKind.touch) return false;
    final selectionPointers = <int>[
      for (final entry in _roles.entries)
        if (entry.value == PointerRole.select &&
            _pointerKinds[entry.key] == PointerDeviceKind.touch)
          entry.key,
    ];
    final navigationPointers = <int>[
      for (final pointer in _navigationPointers.keys)
        if (_pointerKinds[pointer] == PointerDeviceKind.touch) pointer,
    ];
    final inkPointers = <int>[
      for (final entry in _roles.entries)
        if (entry.value == PointerRole.ink &&
            _pointerKinds[entry.key] == PointerDeviceKind.touch)
          entry.key,
    ];
    if (selectionPointers.isEmpty &&
        navigationPointers.isEmpty &&
        inkPointers.isEmpty) {
      return false;
    }

    // The second finger irrevocably establishes navigation intent. Remove a
    // provisional first-finger stroke before either pointer can add another
    // ink sample or commit it on UP.
    for (final pointer in inkPointers) {
      controller.cancelInk(pointer);
      _pointerIndicators.removePointer(pointer);
      _roles[pointer] = PointerRole.navigate;
      final position = _pointerLocalPositions[pointer];
      if (position != null) _beginNavigation(pointer, position);
    }

    if (selectionPointers.isNotEmpty) {
      final owner = _selectionTransformOwner;
      if (owner != null) {
        controller.cancelSelectionTransform();
        _releaseSelectionTransform(owner);
      }
      for (final pointer in selectionPointers) {
        _selectionStarts.remove(pointer);
        _selectionMoveStarts.remove(pointer);
        _selectionGestures.remove(pointer);
        _pointerIndicators.removePointer(pointer);
        _roles[pointer] = PointerRole.navigate;
        final position = _pointerLocalPositions[pointer];
        if (position != null) _beginNavigation(pointer, position);
      }
    }

    _roles[event.pointer] = PointerRole.navigate;
    _pointerIndicators.removePointer(event.pointer);
    _beginNavigation(event.pointer, localPosition);
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

  PointerRole _ordinaryTouchRole(bool stylusCurrentlyActive) {
    if (stylusCurrentlyActive) return PointerRole.ignored;
    if (activeTool == BoardTool.selectRectangle ||
        activeTool == BoardTool.selectLasso ||
        _selectionActiveForParticipant) {
      return PointerRole.select;
    }
    if (widget.fingerDrawingEnabled &&
        _navigationPointers.isEmpty &&
        _isInkTool(activeTool)) {
      return PointerRole.ink;
    }
    return PointerRole.navigate;
  }

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
    if (_inputSuppressed) return;
    final role = _roles[event.pointer];
    if (event.kind == PointerDeviceKind.touch &&
        role == PointerRole.ignored &&
        _stylusSuppressedTouchPointers.contains(event.pointer)) {
      // The global route owns cleanup for this latched palm. Avoid coordinate
      // transforms, clustered-fist classification and indicator work in the
      // hit-tested route while the user continues writing with the pen.
      return;
    }
    final localPosition = _boundedLocalPosition(event.localPosition);
    _pointerLocalPositions[event.pointer] = localPosition;
    _updatePointerIndicator(event, localPosition, role);
    final world = viewport.screenToWorld(localPosition);
    if (event.kind == PointerDeviceKind.touch &&
        controller.inkSessions.hasActiveStylus) {
      // Covers the driver ordering where the touch was delivered before the
      // stylus DOWN reached the global route. Cleanup must remove ownership,
      // not only relabel the pointer, otherwise its UP can replay a tap.
      _neutralizeActiveTouchesForStylus();
      return;
    }
    if (_clusterEraserSession?.positions.containsKey(event.pointer) == true) {
      _continueClusterErase(event, localPosition);
      return;
    }
    // Eraser arbitration must run before a provisional selection pinch. A
    // clenched fist can initially arrive as three narrow contacts on existing
    // ink; two of them would otherwise be captured by selection scaling and
    // never reach the clustered-contact recognizer.
    if (event.kind == PointerDeviceKind.touch && role != PointerRole.erase) {
      final cluster = _clusteredTouchEraser.update(event, localPosition);
      if (cluster != null) {
        _promoteTouchClusterToEraser(cluster);
        return;
      }
    }
    if (_selectionPinchPointers.contains(event.pointer)) {
      _updateSelectionPinch();
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
            _selectionGestureRevision++;
            setState(() {});
          }
        } else {
          final gestureStart = preview.points.isEmpty
              ? world
              : preview.points.first;
          preview.points
            ..clear()
            ..addAll(<Offset>[gestureStart, world]);
          _selectionGestureRevision++;
          setState(() {});
        }
      case PointerRole.ignored || null:
        break;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _clusteredTouchEraser.remove(event.pointer);
    if (_clusterEraserSession?.positions.containsKey(event.pointer) == true) {
      _roles.remove(event.pointer);
      _pointerKinds.remove(event.pointer);
      _pointerLocalPositions.remove(event.pointer);
      _finishClusterErasePointer(event.pointer);
      return;
    }
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
    _stylusSuppressedTouchPointers.remove(event.pointer);
    _pointerIndicators.removePointer(event.pointer);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _clusteredTouchEraser.remove(event.pointer);
    if (_clusterEraserSession?.positions.containsKey(event.pointer) == true) {
      _roles.remove(event.pointer);
      _pointerKinds.remove(event.pointer);
      _pointerLocalPositions.remove(event.pointer);
      _finishClusterErasePointer(event.pointer);
      return;
    }
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
    _stylusSuppressedTouchPointers.remove(event.pointer);
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
    final zoomFactor = oldDistance > 4 && newDistance > 4
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
      screenRadius: geometry.screenRadius,
      lastTimeStamp: event.timeStamp,
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

    for (final pointer in pointers) {
      final previousRole = _roles[pointer];
      if (previousRole == PointerRole.ink) controller.cancelInk(pointer);
      _roles[pointer] = PointerRole.erase;
      _navigationPointers.remove(pointer);
      _selectionStarts.remove(pointer);
      _selectionMoveStarts.remove(pointer);
      _selectionGestures.remove(pointer);
      _pointerIndicators.removePointer(pointer);
    }

    // A large IR board often decomposes the heel of one fist into three or
    // more fingertip-shaped contacts. Treat their contact hull as one physical
    // eraser: one cursor, one swept circle and one Undo transaction.
    final center = _boundedLocalPosition(cluster.center);
    final radius = cluster.brushRadius.clamp(
      _confirmedFistMinimumScreenRadius,
      _confirmedFistMaximumScreenRadius,
    );
    final footprint = <EraserBrushStamp>[
      EraserBrushStamp(center: center, radius: radius),
    ];
    final worldFootprint = _screenFootprintToWorld(footprint);
    _clusterEraserSession = _ClusterEraserSession(
      positions: <int, Offset>{
        for (final entry in cluster.positions.entries)
          entry.key: _boundedLocalPosition(entry.value),
      },
      contactRadii: cluster.contactRadii,
      center: center,
      screenRadius: radius,
      lastTimeStamp: cluster.timeStamp,
    );
    _pointerIndicators.updatePointer(
      BoardPointerIndicator(
        pointer: _clusterPalmIndicatorPointer,
        position: center,
        kind: BoardPointerIndicatorKind.eraser,
        radius: radius,
      ),
    );
    _eraserPointers[_clusterPalmIndicatorPointer] = _EraserPointerState(
      stamps: worldFootprint,
      touchContact: true,
      screenRadius: radius,
      lastTimeStamp: cluster.timeStamp,
    );
    controller.eraseSweeps(_eraserSweepsForTransition(null, worldFootprint));
    if (mounted) setState(() {});
  }

  void _continueClusterErase(PointerMoveEvent event, Offset localPosition) {
    final session = _clusterEraserSession;
    if (session == null || !session.positions.containsKey(event.pointer)) {
      return;
    }
    session.positions[event.pointer] = localPosition;
    session.contactRadii[event.pointer] =
        EraserContactGeometry.reportedContactScreenRadius(event);
    final center = _centroidOfPositions(session.positions.values);
    var envelopeRadius = 0.0;
    for (final entry in session.positions.entries) {
      envelopeRadius = math.max(
        envelopeRadius,
        (entry.value - center).distance +
            (session.contactRadii[entry.key] ?? 10),
      );
    }
    final pressureRange = event.pressureMax - event.pressureMin;
    final normalizedPressure =
        pressureRange.isFinite && pressureRange > .05 && event.pressure.isFinite
        ? ((event.pressure - event.pressureMin) / pressureRange)
              .clamp(0.0, 1.0)
              .toDouble()
        : 0.0;
    final targetRadius = EraserContactGeometry.recognizedFistScreenRadius(
      measuredRadius: 0,
      normalizedSize: event.size,
      normalizedPressure: normalizedPressure,
      contactCount: session.positions.length,
      clusterEnvelopeRadius: envelopeRadius,
    );
    final elapsed = event.timeStamp > session.lastTimeStamp
        ? event.timeStamp - session.lastTimeStamp
        : const Duration(milliseconds: 16);
    final radius = EraserContactGeometry.smoothRecognizedScreenRadius(
      previousRadius: session.screenRadius,
      targetRadius: targetRadius,
      elapsed: elapsed,
    );
    final footprint = <EraserBrushStamp>[
      EraserBrushStamp(center: center, radius: radius),
    ];
    final current = _screenFootprintToWorld(footprint);
    final previous = _eraserPointers[_clusterPalmIndicatorPointer];
    _eraseStampTransition(previous?.stamps, current);
    _eraserPointers[_clusterPalmIndicatorPointer] = _EraserPointerState(
      stamps: current,
      touchContact: true,
      screenRadius: radius,
      lastTimeStamp: event.timeStamp,
    );
    session
      ..center = center
      ..screenRadius = radius
      ..lastTimeStamp = event.timeStamp;
    _pointerIndicators.updatePointer(
      BoardPointerIndicator(
        pointer: _clusterPalmIndicatorPointer,
        position: center,
        kind: BoardPointerIndicatorKind.eraser,
        radius: radius,
      ),
    );
  }

  void _finishClusterErasePointer(int pointer) {
    final session = _clusterEraserSession;
    if (session == null || !session.positions.containsKey(pointer)) return;
    session.positions.remove(pointer);
    session.contactRadii.remove(pointer);
    _pointerIndicators.removePointer(pointer);
    if (session.positions.isNotEmpty) return;
    _clusterEraserSession = null;
    _eraserPointers.remove(_clusterPalmIndicatorPointer);
    _pointerIndicators.removePointer(_clusterPalmIndicatorPointer);
    if (_eraserPointers.isEmpty) {
      _nativePalmCommitTimer?.cancel();
      _nativePalmCommitTimer = null;
      _pointerIndicators.removePointer(_nativePalmIndicatorPointer);
      controller.commitErase();
    }
    if (mounted) setState(() {});
  }

  static Offset _centroidOfPositions(Iterable<Offset> positions) {
    var total = Offset.zero;
    var count = 0;
    for (final position in positions) {
      total += position;
      count++;
    }
    return count == 0 ? Offset.zero : total / count.toDouble();
  }

  void _cancelSelectionTransientsForEraser(int eraserPointer) {
    var changed =
        _selectionTransformOwner != null ||
        _selectionPinchPointers.isNotEmpty ||
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
    _selectionPinchPointers.clear();
    _selectionPinchStartDistance = null;
    _selectionPinchAnchor = null;
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
      previousScreenRadius: previous.screenRadius,
      previousTimeStamp: previous.lastTimeStamp,
    );
    _updateEraserIndicator(
      pointer: event.pointer,
      position: effectiveLocal,
      radius: geometry.screenRadius,
    );
    _eraseStampTransition(previous.stamps, geometry.stamps);
    _eraserPointers[event.pointer] = _EraserPointerState(
      stamps: geometry.stamps,
      touchContact: previous.touchContact,
      screenRadius: geometry.screenRadius,
      lastTimeStamp: event.timeStamp,
    );
  }

  ({List<_WorldEraserStamp> stamps, double screenRadius}) _eraserGeometry(
    PointerEvent event, {
    required Offset localPosition,
    required Offset fallbackWorld,
    double? previousScreenRadius,
    Duration? previousTimeStamp,
  }) {
    if (event.kind != PointerDeviceKind.touch) {
      final targetScreenRadius =
          EraserContactGeometry.automaticToolScreenRadius(event);
      final elapsed =
          previousTimeStamp == null || event.timeStamp <= previousTimeStamp
          ? const Duration(milliseconds: 16)
          : event.timeStamp - previousTimeStamp;
      final screenRadius = previousScreenRadius == null
          ? targetScreenRadius
          : EraserContactGeometry.smoothAutomaticToolScreenRadius(
              previousRadius: previousScreenRadius,
              targetRadius: targetScreenRadius,
              elapsed: elapsed,
            );
      final safeScale = viewport.scale.isFinite && viewport.scale > 0
          ? viewport.scale
          : 1.0;
      return (
        stamps: <_WorldEraserStamp>[
          _WorldEraserStamp(
            center: fallbackWorld,
            radius: (screenRadius / safeScale).clamp(
              .25,
              EraserContactGeometry.maximumAutomaticToolScreenRadius /
                  BoardViewport.minScale,
            ),
          ),
        ],
        screenRadius: screenRadius,
      );
    }
    // Every touch reaching this method has already passed one of the secure
    // fist gates. Ordinary one-/two-finger input is routed to selection or
    // navigation and can never acquire this minimum destructive footprint.
    final measuredFootprint = controller.pointerPolicy.eraserFootprintFor(
      event,
      center: localPosition,
    );
    final geometry = _confirmedFistScreenGeometry(
      center: localPosition,
      measuredFootprint: measuredFootprint,
      fallbackRadius: controller.pointerPolicy.eraserRadiusFor(event),
      previousScreenRadius: previousScreenRadius,
      elapsed: previousTimeStamp == null || event.timeStamp <= previousTimeStamp
          ? const Duration(milliseconds: 16)
          : event.timeStamp - previousTimeStamp,
      dynamicRadiusHint: _confirmedFistDynamicScreenRadius(event),
    );
    return (
      stamps: _screenFootprintToWorld(geometry.footprint),
      screenRadius: geometry.screenRadius,
    );
  }

  /// Produces the single circular brush shown by the fist cursor.
  ///
  /// The measured ellipse still determines dynamic growth, but destructive
  /// geometry is deliberately converted to the exact same centred circle
  /// drawn by [BoardPointerIndicatorPainter]. Keeping one representation
  /// avoids a misleading enclosing circle whose corners do not actually
  /// erase. A short asymmetric filter grows quickly and shrinks calmly, so
  /// quantized hardware packets cannot make the brush pulse while a genuinely
  /// smaller resting area is still reflected during the same wipe.
  ({List<EraserBrushStamp> footprint, double screenRadius})
  _confirmedFistScreenGeometry({
    required Offset center,
    required List<EraserBrushStamp> measuredFootprint,
    required double fallbackRadius,
    double? previousScreenRadius,
    Duration elapsed = const Duration(milliseconds: 16),
    double dynamicRadiusHint = 0,
  }) {
    final measuredRadius = EraserContactGeometry.enclosingScreenRadius(
      center: center,
      footprint: measuredFootprint,
      fallback: fallbackRadius,
    );
    final targetRadius = math
        .max(
          _confirmedFistMinimumScreenRadius,
          math.max(
            measuredRadius,
            math.max(
              fallbackRadius.isFinite && fallbackRadius > 0
                  ? fallbackRadius
                  : 0,
              dynamicRadiusHint.isFinite && dynamicRadiusHint > 0
                  ? dynamicRadiusHint
                  : 0,
            ),
          ),
        )
        .clamp(
          _confirmedFistMinimumScreenRadius,
          _confirmedFistMaximumScreenRadius,
        )
        .toDouble();
    final radius =
        previousScreenRadius != null &&
            previousScreenRadius.isFinite &&
            previousScreenRadius > 0
        ? EraserContactGeometry.smoothRecognizedScreenRadius(
            previousRadius: previousScreenRadius,
            targetRadius: targetRadius,
            elapsed: elapsed,
          )
        : targetRadius;
    return (
      footprint: <EraserBrushStamp>[
        EraserBrushStamp(center: center, radius: radius),
      ],
      screenRadius: radius,
    );
  }

  /// Uses ambiguous normalized axes only after a physical/cluster/native gate
  /// has already established destructive fist intent.
  ///
  /// Several large boards quantize touchMajor/touchMinor while `size` or
  /// pressure still changes with the resting area. These ambiguous signals
  /// are fused only after the physical/native/cluster gate has already
  /// confirmed a fist. Pressure is ignored when the driver reports no useful
  /// range and can never classify an ordinary finger as destructive.
  double _confirmedFistDynamicScreenRadius(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) {
      return _confirmedFistMinimumScreenRadius;
    }
    final size = event.size.isFinite ? event.size.clamp(0.0, 1.0) : 0.0;
    final pressureRange = event.pressureMax - event.pressureMin;
    final normalizedPressure =
        pressureRange.isFinite && pressureRange > .05 && event.pressure.isFinite
        ? ((event.pressure - event.pressureMin) / pressureRange).clamp(0.0, 1.0)
        : 0.0;
    final measuredRadius = math.max(
      event.radiusMajor.isFinite && event.radiusMajor > 0
          ? event.radiusMajor
          : 0.0,
      event.radiusMinor.isFinite && event.radiusMinor > 0
          ? event.radiusMinor
          : 0.0,
    );
    return EraserContactGeometry.recognizedFistScreenRadius(
      // A number of Android firmwares pin SIZE to 1.0 for the complete
      // lifetime of every contact. Supplying the current physical axis here
      // keeps SIZE a bounded refinement instead of letting that pinned value
      // force every accepted fist to the maximum eraser size.
      measuredRadius: measuredRadius,
      normalizedSize: size,
      normalizedPressure: normalizedPressure,
    );
  }

  List<_WorldEraserStamp> _screenFootprintToWorld(
    List<EraserBrushStamp> footprint,
  ) {
    final safeScale = viewport.scale.isFinite && viewport.scale > 0
        ? viewport.scale
        : 1.0;
    final maximumWorldRadius =
        _confirmedFistMaximumScreenRadius / BoardViewport.minScale;
    return <_WorldEraserStamp>[
      for (final stamp in footprint)
        if (stamp.center.dx.isFinite &&
            stamp.center.dy.isFinite &&
            stamp.radius.isFinite &&
            stamp.radius > 0)
          _WorldEraserStamp(
            center: viewport.screenToWorld(stamp.center),
            // Preserve the on-screen circle exactly even at the 0.18x board
            // zoom. A fixed world-unit cap would make the real erased corridor
            // substantially smaller than its cursor at minimum zoom.
            radius: (stamp.radius / safeScale).clamp(.25, maximumWorldRadius),
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
        _appendVariableRadiusSweeps(sweeps, previous[index], current[index]);
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
    _appendVariableRadiusSweeps(sweeps, from, to);
    return sweeps;
  }

  /// Approximates a swept circle whose radius changes along the movement.
  ///
  /// A single capsule with `max(old, current)` kept erasing with the old broad
  /// fist radius all the way to a visibly smaller cursor. Short tapered
  /// segments preserve continuous coverage while making the destructive area
  /// converge to the exact current circle.
  void _appendVariableRadiusSweeps(
    List<InkEraserSweep> target,
    _WorldEraserStamp from,
    _WorldEraserStamp to,
  ) {
    final distance = (to.center - from.center).distance;
    final radiusDelta = (to.radius - from.radius).abs();
    final segmentCount = math
        .max((distance / 24).ceil(), (radiusDelta / 4).ceil())
        .clamp(1, 16)
        .toInt();
    for (var segment = 0; segment < segmentCount; segment++) {
      final startT = segment / segmentCount;
      final endT = (segment + 1) / segmentCount;
      final startCenter = Offset.lerp(from.center, to.center, startT)!;
      final endCenter = Offset.lerp(from.center, to.center, endT)!;
      final startRadius = from.radius + (to.radius - from.radius) * startT;
      final endRadius = from.radius + (to.radius - from.radius) * endT;
      target.add((
        start: startCenter,
        end: endCenter,
        radius: math.max(startRadius, endRadius),
      ));
    }
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

  void _hideNavigatorForContentInteraction() {
    _navigatorHideTimer?.cancel();
    _navigatorHideTimer = null;
    if (!_navigatorVisible) return;
    if (mounted) {
      setState(() => _navigatorVisible = false);
    } else {
      _navigatorVisible = false;
    }
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
    final selectionPoint = Vec2(world.dx, world.dy);
    final selectionTolerance = 12 / viewport.scale;
    if (!controller.selectionEngine.hasSelectableAt(
      controller.page,
      selectionPoint,
      tolerance: selectionTolerance,
      inkGroupCandidates: controller.groupingEngine.selectionCandidatesAt(
        controller.page,
        selectionPoint,
        tolerance: selectionTolerance,
      ),
    )) {
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
    required this.onClaimPointerDown,
    super.key,
  });
  final EditorController controller;
  final BoardViewport viewport;
  final bool inlineTextEditing;
  final VoidCallback onEditText;
  final bool Function(String owner) onClaimTransform;
  final void Function(String owner) onReleaseTransform;
  final ValueChanged<PointerDownEvent> onClaimPointerDown;

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
    // Four 44 px edge targets plus the 48 px corner controls can cover the
    // complete body of a small or very flat selection. In compact mode retain
    // uniform scaling and rotation outside the frame, leaving its entire body
    // available for the underlying move gesture.
    final compactControls = rect.width < 96 || rect.height < 96;
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: widget.onClaimPointerDown,
      child: Stack(
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
              left: compactControls ? rect.left - 56 : rect.left - 24,
              top: compactControls ? rect.bottom + 8 : rect.bottom - 24,
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
              left: compactControls ? rect.right + 8 : rect.right - 24,
              top: compactControls ? rect.bottom + 8 : rect.bottom - 24,
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
                                (details.delta.dx + details.delta.dy) /
                                    baseline)
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
          if (!widget.inlineTextEditing &&
              controller.selectedCover == null &&
              !compactControls)
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
      ),
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
                controller.isHandwritingConversionInProgress
                    ? Icons.hourglass_top_rounded
                    : Icons.text_fields_rounded,
                controller.isHandwritingConversionInProgress
                    ? 'Handschrift wird umgewandelt'
                    : 'Handschrift in Text umwandeln',
                controller.isHandwritingConversionInProgress
                    ? null
                    : () => unawaited(
                        controller.convertSelectedHandwritingToText(),
                      ),
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
    VoidCallback? action, {
    bool danger = false,
  }) {
    return Tooltip(
      message: label,
      child: IconButton(
        onPressed: action,
        icon: Icon(
          icon,
          color: action == null
              ? FlowboardColors.textSecondary
              : danger
              ? FlowboardColors.danger
              : FlowboardColors.textPrimary,
        ),
      ),
    );
  }
}

final class _EraserPointerState {
  const _EraserPointerState({
    required this.stamps,
    required this.touchContact,
    required this.screenRadius,
    required this.lastTimeStamp,
  });

  final List<_WorldEraserStamp> stamps;
  final bool touchContact;
  final double screenRadius;
  final Duration lastTimeStamp;
}

final class _ClusterEraserSession {
  _ClusterEraserSession({
    required Map<int, Offset> positions,
    required Map<int, double> contactRadii,
    required this.center,
    required this.screenRadius,
    required this.lastTimeStamp,
  }) : positions = Map<int, Offset>.of(positions),
       contactRadii = Map<int, double>.of(contactRadii);

  final Map<int, Offset> positions;
  final Map<int, double> contactRadii;
  Offset center;
  double screenRadius;
  Duration lastTimeStamp;
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
  int? _scheduledNotificationId;
  bool _disposed = false;

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
    if (_active.isEmpty) _notifyOnNextFrame();
  }

  void clearHover() {
    if (_hoverPosition == null) return;
    _hoverPosition = null;
    if (_active.isEmpty) _notifyOnNextFrame();
  }

  void updatePointer(BoardPointerIndicator indicator) {
    if (!indicator.position.dx.isFinite || !indicator.position.dy.isFinite) {
      return;
    }
    if (_active[indicator.pointer] == indicator) return;
    _active[indicator.pointer] = indicator;
    _notifyOnNextFrame();
  }

  void removePointer(int pointer) {
    if (_active.remove(pointer) == null) return;
    if (_active.isEmpty) _hoverPosition = null;
    _notifyOnNextFrame();
  }

  void clear({bool notify = true}) {
    if (_active.isEmpty && _hoverPosition == null) return;
    _active.clear();
    _hoverPosition = null;
    if (notify) _notifyOnNextFrame();
  }

  void _notifyOnNextFrame() {
    if (_disposed || _scheduledNotificationId != null) return;
    _scheduledNotificationId = SchedulerBinding.instance.scheduleFrameCallback((
      _,
    ) {
      _scheduledNotificationId = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final scheduled = _scheduledNotificationId;
    if (scheduled != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(scheduled);
      _scheduledNotificationId = null;
    }
    _active.clear();
    _hoverPosition = null;
    super.dispose();
  }
}

class _GestureOverlayPainter extends CustomPainter {
  const _GestureOverlayPainter({
    required this.gestures,
    required this.gestureRevision,
    required this.viewportScale,
    required this.viewportOffset,
  });

  final List<_GesturePreview> gestures;
  final int gestureRevision;
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
  bool shouldRepaint(covariant _GestureOverlayPainter oldDelegate) {
    if (oldDelegate.gestureRevision != gestureRevision ||
        oldDelegate.viewportScale != viewportScale ||
        oldDelegate.viewportOffset != viewportOffset ||
        oldDelegate.gestures.length != gestures.length) {
      return true;
    }
    for (var index = 0; index < gestures.length; index++) {
      if (!identical(oldDelegate.gestures[index], gestures[index])) return true;
    }
    return false;
  }
}
