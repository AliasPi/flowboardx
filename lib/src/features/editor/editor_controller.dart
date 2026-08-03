import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/autosave_controller.dart';
import '../../data/document_repository.dart';
import '../../domain/commands/command_history.dart';
import '../../domain/commands/document_command.dart';
import '../../domain/commands/document_commands.dart';
import '../../domain/commands/erase_stroke_segments_command.dart';
import '../../domain/grouping/ink_grouping_engine.dart';
import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/geometry.dart';
import '../../domain/model/ink.dart';
import '../../domain/model/scene_order.dart';
import '../assets/document_asset_store.dart';
import '../assets/imported_image_layout.dart';
import '../board/engine/board_viewport.dart';
import '../board/engine/ink_session_manager.dart';
import '../board/engine/ink_stroke_eraser.dart';
import '../board/engine/input_policy.dart';
import '../board/engine/spatial_index.dart';
import '../selection/selection_engine.dart';
import '../templates/template_factory.dart';
import '../templates/user_template.dart';
import '../templates/user_template_store.dart';
import '../handwriting/handwriting_recognition_service.dart';
import 'editor_commands.dart';
import 'inline_text_editing_engine.dart';
import 'text_object_layout.dart';

typedef InkEraserSweep = ({Offset start, Offset end, double radius});

enum LayerArrangement { oneForward, oneBackward, toFront, toBack }

class EditorController extends ChangeNotifier {
  static const String recentPenColorsMetadataKey = 'recentPenColors';
  static const int maximumRecentPenColors = 10;

  factory EditorController({
    required WhiteboardDocument document,
    required DocumentRepository repository,
    required Directory assetDirectory,
    Uuid? uuid,
    HandwritingRecognitionService? handwritingRecognition,
    @visibleForTesting VoidCallback? debugBeforeHandwritingSnapshotCapture,
  }) {
    final hydration = _upgradePersistedTextFrames(document);
    return EditorController._(
      initialDocument: hydration.document,
      repository: repository,
      assetDirectory: assetDirectory,
      uuid: uuid,
      handwritingRecognition: handwritingRecognition,
      debugBeforeHandwritingSnapshotCapture:
          debugBeforeHandwritingSnapshotCapture,
      ownsDocumentSession: true,
      followsDocumentNavigation: true,
      historyOwnerId: CommandHistory.defaultOwnerId,
      persistInitialDocument: hydration.changed,
    );
  }

  /// Creates an interaction view that shares document history and Auto-Save
  /// with [owner], while retaining its own page, camera, selection and active
  /// pointer sessions.
  ///
  /// This is the two-person workspace primitive: both users edit one durable
  /// document, but navigation gestures and page switches never leak into the
  /// other half.
  factory EditorController.participantView(
    EditorController owner, {
    String? participantId,
  }) => EditorController._(
    initialDocument: owner.document,
    repository: owner.repository,
    assetDirectory: owner.assetDirectory,
    uuid: const Uuid(),
    handwritingRecognition: owner.handwritingRecognition,
    debugBeforeHandwritingSnapshotCapture:
        owner._debugBeforeHandwritingSnapshotCapture,
    sharedHistory: owner.history,
    sharedAutosave: owner.autosave,
    sharedGroupingEngine: owner.groupingEngine,
    sharedSelectionEngine: owner.selectionEngine,
    ownsDocumentSession: false,
    followsDocumentNavigation: false,
    activePageId: owner.page.id,
    persistInitialDocument: false,
    historyOwnerId: participantId == null
        ? 'participant:${const Uuid().v4()}'
        : 'participant:${participantId.trim()}',
  );

  EditorController._({
    required WhiteboardDocument initialDocument,
    required this.repository,
    required this.assetDirectory,
    required bool ownsDocumentSession,
    required bool followsDocumentNavigation,
    required String historyOwnerId,
    Uuid? uuid,
    HandwritingRecognitionService? handwritingRecognition,
    VoidCallback? debugBeforeHandwritingSnapshotCapture,
    CommandHistory? sharedHistory,
    AutosaveController? sharedAutosave,
    InkGroupingEngine? sharedGroupingEngine,
    SelectionEngine? sharedSelectionEngine,
    String? activePageId,
    bool persistInitialDocument = false,
  }) : _uuid = uuid ?? const Uuid(),
       history = sharedHistory ?? CommandHistory(initialDocument),
       autosave =
           sharedAutosave ?? AutosaveController(repository, initialDocument.id),
       groupingEngine = sharedGroupingEngine ?? InkGroupingEngine(),
       selectionEngine = sharedSelectionEngine ?? SelectionEngine(),
       viewport = BoardViewport(
         scale: initialDocument.currentPage.viewport.zoom,
         offset: Offset(
           initialDocument.currentPage.viewport.offsetX,
           initialDocument.currentPage.viewport.offsetY,
         ),
       ),
       _selectedIds = initialDocument.currentPage.selection.selectedItemIds
           .toSet(),
       penStyle = ActivePenStyle(
         colorArgb: initialDocument.activePreset.colorArgb,
         width: initialDocument.activePreset.width,
         type: initialDocument.activePreset.type,
       ),
       _activePageId = activePageId ?? initialDocument.currentPage.id,
       _ownsDocumentSession = ownsDocumentSession,
       _followsDocumentNavigation = followsDocumentNavigation,
       _historyOwnerId = historyOwnerId,
       _debugBeforeHandwritingSnapshotCapture =
           debugBeforeHandwritingSnapshotCapture,
       handwritingRecognition =
           handwritingRecognition ??
           const PlatformHandwritingRecognitionService() {
    _historySubscription = history.changes.listen(_onDocumentChanged);
    if (_ownsDocumentSession) {
      _saveErrorSubscription = autosave.errors.listen((error) {
        lastError = 'Speichern fehlgeschlagen: $error';
        notifyListeners();
      });
      if (persistInitialDocument) autosave.schedule(initialDocument);
    }
  }

  final DocumentRepository repository;
  final Directory assetDirectory;
  final Uuid _uuid;
  FileBoardAssetResolver? _assetResolver;
  String? _resolvedAssetSignature;
  List<DocumentAsset>? _assetSignatureAssets;
  WhiteboardDocument? _resolvedPageDocument;
  String? _resolvedPageId;
  BoardPage? _resolvedPage;
  int _resolvedPageIndex = -1;
  int _debugPageResolutionCount = 0;
  final CommandHistory history;
  final AutosaveController autosave;
  final BoardViewport viewport;
  final InkSessionManager inkSessions = InkSessionManager();
  final PointerPolicy pointerPolicy = const PointerPolicy();
  final SelectionEngine selectionEngine;
  final InkGroupingEngine groupingEngine;
  final TemplateFactory templateFactory = TemplateFactory();
  final HandwritingRecognitionService handwritingRecognition;
  final VoidCallback? _debugBeforeHandwritingSnapshotCapture;

  late final StreamSubscription<WhiteboardDocument> _historySubscription;
  StreamSubscription<Object>? _saveErrorSubscription;
  final bool _ownsDocumentSession;
  final bool _followsDocumentNavigation;
  final String _historyOwnerId;
  String _activePageId;
  final Map<String, ViewportState> _localViewports = <String, ViewportState>{};
  final Map<int, _AnnotationTarget> _annotationTargets = {};
  final Set<int> _autosaveInkPointers = <int>{};
  final Map<String, double> _coverRevealPreviews = {};
  final Map<String, List<InkStroke>> _pendingEraseReplacements = {};
  final Set<String> _pendingFreeEraseSourceIds = <String>{};
  final Set<String> _pendingAnnotationEraseSourceIds = <String>{};
  final List<_PendingEraseSweep> _pendingEraseSweeps = [];
  String? _pendingErasePageId;
  int? _pendingEraseRevision;
  final SpatialIndex<InkStroke> _eraseIndex = SpatialIndex(cellSize: 160);
  final _AnnotationEraseIndex _annotationEraseIndex = _AnnotationEraseIndex();
  List<InkStroke>? _eraseIndexedStrokes;
  final Map<String, int> _eraseIndexedStrokePositions = <String, int>{};
  String? _eraseIndexedPageId;
  int _erasePreviewVersion = 0;
  int _cachedEraseStrokePreviewVersion = -1;
  List<InkStroke>? _cachedEraseStrokeSource;
  List<InkStroke>? _cachedEraseRenderStrokes;
  int _cachedEraseAnnotationPreviewVersion = -1;
  List<ObjectInkLayer>? _cachedEraseAnnotationSource;
  List<ObjectInkLayer>? _cachedEraseRenderAnnotationLayers;
  int _debugLastEraseStrokeCandidateCount = 0;
  int _debugLastEraseAnnotationCandidateCount = 0;
  int _debugEraseFullIndexBuildCount = 0;
  int _debugErasePreviewReplayCount = 0;
  Set<String> _selectedIds;
  BoardPage? _selectionMembersPage;
  Set<String>? _selectionMembersSource;
  _SelectionMembers _selectionMembersCache = _SelectionMembers.empty;
  int _debugSelectionMemberRefreshCount = 0;
  TransformDelta? _selectionTransformPreview;
  BoardPage? _cachedSelectionObjectPreviewPage;
  TransformDelta? _cachedSelectionObjectPreview;
  int _coverPreviewVersion = 0;
  int _cachedSelectionObjectCoverVersion = -1;
  List<BoardObject>? _cachedSelectionRenderObjects;
  BoardPage? _cachedSelectionStrokePreviewPage;
  TransformDelta? _cachedSelectionStrokePreview;
  int _cachedSelectionStrokeEraseVersion = -1;
  List<InkStroke>? _cachedSelectionRenderStrokes;
  BoardViewportHorizontalConstraint? _contentHorizontalConstraint;
  String? _selectionInteractionOwner;
  bool _handwritingConversionInProgress = false;
  bool _returnToInkWhenInsertedSelectionClears = false;
  _ClipboardPayload? _clipboard;
  Timer? _settingsPersistenceTimer;
  Offset? _pendingRadialPosition;
  bool _closed = false;
  bool _notifierDisposed = false;

  BoardTool tool = BoardTool.pen;
  ShapeKind activeShape = ShapeKind.rectangle;
  ActivePenStyle penStyle;
  String? lastError;
  bool saving = false;

  WhiteboardDocument get document => history.document;
  BoardPage get page {
    _resolveActivePage();
    return _resolvedPage!;
  }

  int get currentPageIndex {
    _resolveActivePage();
    return _resolvedPageIndex;
  }

  void _resolveActivePage() {
    final currentDocument = document;
    if (identical(_resolvedPageDocument, currentDocument) &&
        _resolvedPageId == _activePageId &&
        _resolvedPage != null) {
      return;
    }
    var index = _resolvedPageIndex;
    if (index < 0 ||
        index >= currentDocument.pages.length ||
        currentDocument.pages[index].id != _activePageId) {
      index = currentDocument.pageIndexById(_activePageId) ?? -1;
    }
    _resolvedPageDocument = currentDocument;
    _resolvedPageId = _activePageId;
    _resolvedPageIndex = index < 0 ? currentDocument.currentPageIndex : index;
    _resolvedPage = currentDocument.pages[_resolvedPageIndex];
    _debugPageResolutionCount++;
  }

  Set<String> get selectedIds =>
      _selectedIds.isEmpty ? const <String>{} : Set.unmodifiable(_selectedIds);
  Set<String> get selectedSceneItemIds =>
      _selectedIds.isEmpty ? const <String>{} : _expandedSelectionIds;
  bool get hasSelection => _selectedIds.isNotEmpty;
  bool get canUndo => history.canUndoFor(_historyOwnerId);
  bool get canRedo => history.canRedoFor(_historyOwnerId);
  bool get canPaste => _clipboard != null;
  BoardViewportHorizontalConstraint? get contentHorizontalConstraint =>
      _contentHorizontalConstraint;
  @visibleForTesting
  int get debugLastEraseStrokeCandidateCount =>
      _debugLastEraseStrokeCandidateCount;
  @visibleForTesting
  int get debugLastEraseAnnotationCandidateCount =>
      _debugLastEraseAnnotationCandidateCount;
  @visibleForTesting
  int get debugEraseFullIndexBuildCount => _debugEraseFullIndexBuildCount;
  @visibleForTesting
  int get debugErasePreviewReplayCount => _debugErasePreviewReplayCount;
  @visibleForTesting
  int get debugIndexedAnnotationStrokeCount => _annotationEraseIndex.length;
  @visibleForTesting
  int get debugSelectionMemberRefreshCount => _debugSelectionMemberRefreshCount;
  @visibleForTesting
  int get debugPageResolutionCount => _debugPageResolutionCount;
  List<int> get recentCustomPenColors {
    final encoded = document.metadata.custom[recentPenColorsMetadataKey];
    if (encoded == null || encoded.isEmpty) return const <int>[];
    final result = <int>[];
    final seen = <int>{};
    for (final token in encoded.split(',')) {
      final value = int.tryParse(token.trim(), radix: 16);
      if (value == null || value < 0 || value > 0xFFFFFFFF) continue;
      final normalized = value.toUnsigned(32);
      if (seen.add(normalized)) result.add(normalized);
      if (result.length == maximumRecentPenColors) break;
    }
    return List<int>.unmodifiable(result);
  }

  Offset? get radialMenuPositionNormalized {
    final x = double.tryParse(document.metadata.custom['radialMenuX'] ?? '');
    final y = double.tryParse(document.metadata.custom['radialMenuY'] ?? '');
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return Offset(x.clamp(0, 1), y.clamp(0, 1));
  }

  FileBoardAssetResolver get assetResolver {
    final currentDocument = document;
    if (!identical(_assetSignatureAssets, currentDocument.assets)) {
      _assetSignatureAssets = currentDocument.assets;
      final signature = currentDocument.assets
          .map((asset) => '${asset.id}:${asset.relativePath}:${asset.sha256}')
          .join('|');
      if (_assetResolver == null || _resolvedAssetSignature != signature) {
        _resolvedAssetSignature = signature;
        _assetResolver = FileBoardAssetResolver(
          directory: assetDirectory,
          document: currentDocument,
        );
      }
    }
    return _assetResolver!;
  }

  List<BoardObject> get renderObjects {
    final preview = _selectionTransformPreview;
    final currentPage = page;
    if (preview == null && _coverRevealPreviews.isEmpty) {
      return currentPage.objects;
    }
    if (identical(_cachedSelectionObjectPreviewPage, currentPage) &&
        identical(_cachedSelectionObjectPreview, preview) &&
        _cachedSelectionObjectCoverVersion == _coverPreviewVersion &&
        _cachedSelectionRenderObjects != null) {
      return _cachedSelectionRenderObjects!;
    }

    final replacements = <int, BoardObject>{};
    if (_coverRevealPreviews.isNotEmpty) {
      for (var index = 0; index < currentPage.objects.length; index++) {
        final object = currentPage.objects[index];
        final reveal = _coverRevealPreviews[object.id];
        if (object is CoverObject && reveal != null) {
          replacements[index] = object.copyWithReveal(reveal);
        }
      }
    }
    if (preview != null) {
      final members = _selectionMembers;
      for (
        var memberIndex = 0;
        memberIndex < members.objectIndices.length;
        memberIndex++
      ) {
        final sourceIndex = members.objectIndices[memberIndex];
        final source =
            replacements[sourceIndex] ?? members.objects[memberIndex];
        replacements[sourceIndex] = _previewTransformedObject(source, preview);
      }
    }
    final visible = replacements.isEmpty
        ? currentPage.objects
        : _SparseObjectPreviewList(currentPage.objects, replacements);
    _cachedSelectionObjectPreviewPage = currentPage;
    _cachedSelectionObjectPreview = preview;
    _cachedSelectionObjectCoverVersion = _coverPreviewVersion;
    _cachedSelectionRenderObjects = visible;
    return visible;
  }

  BoardObject _previewTransformedObject(
    BoardObject object,
    TransformDelta delta,
  ) {
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

  List<InkStroke> get renderStrokes {
    final preview = _selectionTransformPreview;
    final currentPage = page;
    if (preview == null && _pendingFreeEraseSourceIds.isEmpty) {
      return currentPage.strokes;
    }
    if (preview == null) {
      if (_cachedEraseStrokePreviewVersion == _erasePreviewVersion &&
          identical(_cachedEraseStrokeSource, currentPage.strokes) &&
          _cachedEraseRenderStrokes != null) {
        return _cachedEraseRenderStrokes!;
      }
      _synchronizeEraseIndex(currentPage);
      final patches = <_StrokePreviewPatch>[];
      for (final sourceId in _pendingFreeEraseSourceIds) {
        final sourceIndex = _eraseIndexedStrokePositions[sourceId];
        final replacements = _pendingEraseReplacements[sourceId];
        if (sourceIndex == null || replacements == null) continue;
        patches.add(
          _StrokePreviewPatch(
            sourceIndex: sourceIndex,
            replacements: replacements,
          ),
        );
      }
      final visible = patches.isEmpty
          ? currentPage.strokes
          : _SparseStrokePreviewList(currentPage.strokes, patches);
      _cachedEraseStrokePreviewVersion = _erasePreviewVersion;
      _cachedEraseStrokeSource = currentPage.strokes;
      _cachedEraseRenderStrokes = visible;
      return visible;
    }
    if (identical(_cachedSelectionStrokePreviewPage, currentPage) &&
        identical(_cachedSelectionStrokePreview, preview) &&
        _cachedSelectionStrokeEraseVersion == _erasePreviewVersion &&
        _cachedSelectionRenderStrokes != null) {
      return _cachedSelectionRenderStrokes!;
    }

    final members = _selectionMembers;
    List<InkStroke> visible;
    if (_pendingFreeEraseSourceIds.isEmpty) {
      if (members.strokeIndices.isEmpty) {
        visible = currentPage.strokes;
      } else {
        visible = _SparseStrokeSelectionPreviewList(
          currentPage.strokes,
          <int, InkStroke>{
            for (var index = 0; index < members.strokeIndices.length; index++)
              members.strokeIndices[index]: members.strokes[index].transformed(
                preview,
              ),
          },
        );
      }
    } else {
      // Erasing cancels selection gestures in BoardSurface, so this is only a
      // defensive path for external/controller-level callers. Preserve exact
      // fragment semantics without complicating the common sparse overlay.
      final previewIds = _expandedSelectionIds;
      visible = <InkStroke>[
        for (final source in currentPage.strokes)
          for (final stroke
              in _pendingEraseReplacements[source.id] ?? <InkStroke>[source])
            if (previewIds.contains(source.id))
              stroke.transformed(preview)
            else
              stroke,
      ];
    }
    _cachedSelectionStrokePreviewPage = currentPage;
    _cachedSelectionStrokePreview = preview;
    _cachedSelectionStrokeEraseVersion = _erasePreviewVersion;
    _cachedSelectionRenderStrokes = visible;
    return visible;
  }

  /// Annotation strokes share the same live erase preview as free board ink.
  /// The immutable page remains untouched until [commitErase], keeping a whole
  /// fist gesture as one Undo/Auto-Save operation.
  List<ObjectInkLayer> get renderAnnotationLayers {
    final currentPage = page;
    if (_pendingAnnotationEraseSourceIds.isEmpty) {
      return currentPage.annotationLayers;
    }
    if (_cachedEraseAnnotationPreviewVersion == _erasePreviewVersion &&
        identical(_cachedEraseAnnotationSource, currentPage.annotationLayers) &&
        _cachedEraseRenderAnnotationLayers != null) {
      return _cachedEraseRenderAnnotationLayers!;
    }

    _annotationEraseIndex.synchronize(currentPage);
    final affectedLayers = <ObjectInkLayer>{};
    for (final sourceId in _pendingAnnotationEraseSourceIds) {
      affectedLayers.addAll(
        _annotationEraseIndex.layersContainingStroke(sourceId),
      );
    }
    final replacements = <int, ObjectInkLayer>{};
    for (final layer in affectedLayers) {
      final layerIndex = _annotationEraseIndex.indexOfLayer(layer);
      if (layerIndex == null) continue;
      replacements[layerIndex] = layer.copyWith(
        strokes: <InkStroke>[
          for (final source in layer.strokes)
            ...(_pendingEraseReplacements[source.id] ?? <InkStroke>[source]),
        ],
      );
    }
    final visible = replacements.isEmpty
        ? currentPage.annotationLayers
        : _SparseAnnotationLayerPreviewList(
            currentPage.annotationLayers,
            replacements,
          );
    _cachedEraseAnnotationPreviewVersion = _erasePreviewVersion;
    _cachedEraseAnnotationSource = currentPage.annotationLayers;
    _cachedEraseRenderAnnotationLayers = visible;
    return visible;
  }

  /// Sessions always sample in world units so their distance threshold and
  /// live preview behave identically on the board and over embedded objects.
  List<InkStroke> get renderInkPreviews => inkSessions.buildPreviewStrokes();

  CoverObject? get selectedCover {
    if (_selectedIds.length != 1) return null;
    final id = _selectedIds.single;
    for (final object in _selectionMembers.objects) {
      if (object is! CoverObject || object.id != id) continue;
      final reveal = _coverRevealPreviews[id];
      final withReveal = reveal == null
          ? object
          : object.copyWithReveal(reveal);
      final preview = _selectionTransformPreview;
      if (preview != null && _expandedSelectionIds.contains(id)) {
        return withReveal.copyWithTransform(
          withReveal.transform.apply(preview),
        );
      }
      return withReveal;
    }
    return null;
  }

  PdfObject? get selectedPdf {
    if (_selectedIds.length != 1) return null;
    final id = _selectedIds.single;
    for (final object in _selectionMembers.objects) {
      if (object is PdfObject && object.id == id) return object;
    }
    return null;
  }

  ContentGroup? get selectedContentGroup {
    if (_selectedIds.length != 1) return null;
    return _selectionMembers.selectedContentGroup;
  }

  TextObject? get selectedTextObject {
    if (_selectedIds.length != 1) return null;
    final id = _selectedIds.single;
    for (final object in _selectionMembers.objects) {
      if (object is TextObject && object.id == id) return object;
    }
    return null;
  }

  bool get canGroupSelection =>
      selectedContentGroup == null && _expandedSelectionIds.length >= 2;
  bool get canArrangeSelection {
    final members = _selectionMembers;
    return members.objects.isNotEmpty || members.strokes.isNotEmpty;
  }

  bool get hasSelectedHandwriting => _selectionMembers.strokes.isNotEmpty;
  bool get isHandwritingConversionInProgress =>
      _handwritingConversionInProgress;

  double coverRevealValue(String objectId, double persisted) =>
      _coverRevealPreviews[objectId] ?? persisted;

  Set<String> get _expandedSelectionIds => _selectionMembers.expandedIds;

  _SelectionMembers get _selectionMembers {
    if (_selectedIds.isEmpty) return _SelectionMembers.empty;
    final currentPage = page;
    if (identical(_selectionMembersPage, currentPage) &&
        identical(_selectionMembersSource, _selectedIds)) {
      return _selectionMembersCache;
    }
    final resolved = selectionEngine.resolveSelectionMembers(
      currentPage,
      _selectedIds,
    );

    _selectionMembersPage = currentPage;
    _selectionMembersSource = _selectedIds;
    _selectionMembersCache = _SelectionMembers(
      expandedIds: resolved.expandedIds,
      objectIndices: resolved.objectIndices,
      objects: resolved.objects,
      strokeIndices: resolved.strokeIndices,
      strokes: resolved.strokes,
      selectedGroupBounds: resolved.selectedGroupBounds,
      selectedContentGroup: resolved.selectedContentGroup,
      baseBounds: resolved.bounds,
    );
    _debugSelectionMemberRefreshCount++;
    return _selectionMembersCache;
  }

  void setTool(BoardTool value) {
    final keepCoverControls = selectedCover != null;
    tool = value;
    if (value == BoardTool.selectRectangle || value == BoardTool.selectLasso) {
      // An explicit selection-tool choice is persistent. Only the temporary
      // selection created directly after insertion returns to ink on an empty
      // canvas tap.
      _returnToInkWhenInsertedSelectionClears = false;
    }
    if (value == BoardTool.pen) {
      penStyle = penStyle.copyWith(type: InkToolType.normal);
    }
    if (value == BoardTool.marker) {
      penStyle = penStyle.copyWith(type: InkToolType.marker);
    }
    if (value == BoardTool.dashedPen) {
      penStyle = penStyle.copyWith(type: InkToolType.dashed);
    }
    if (value == BoardTool.straightLine) {
      penStyle = penStyle.copyWith(type: InkToolType.straightLine);
    }
    if (value == BoardTool.pen ||
        value == BoardTool.marker ||
        value == BoardTool.dashedPen ||
        value == BoardTool.straightLine ||
        value == BoardTool.eraser) {
      if (!keepCoverControls) {
        _selectedIds = <String>{};
        _selectionTransformPreview = null;
        _returnToInkWhenInsertedSelectionClears = false;
      }
      _scheduleSettingsPersistence();
    }
    notifyListeners();
  }

  void armShape(ShapeKind kind) {
    activeShape = kind;
    tool = BoardTool.shape;
    clearSelection();
    notifyListeners();
  }

  void updatePen({int? colorArgb, double? width, InkToolType? type}) {
    final keepCoverControls = selectedCover != null;
    penStyle = penStyle.copyWith(
      colorArgb: colorArgb,
      width: width,
      type: type,
    );
    tool = switch (penStyle.type) {
      InkToolType.normal => BoardTool.pen,
      InkToolType.marker => BoardTool.marker,
      InkToolType.dashed => BoardTool.dashedPen,
      InkToolType.straightLine => BoardTool.straightLine,
    };
    if (!keepCoverControls) {
      _selectedIds = <String>{};
      _selectionTransformPreview = null;
      _returnToInkWhenInsertedSelectionClears = false;
    }
    _scheduleSettingsPersistence();
    notifyListeners();
  }

  /// Remembers only colors explicitly accepted in the free color dialog.
  /// Standard palette taps deliberately do not enter this list.
  void rememberCustomPenColor(int colorArgb) {
    final normalized = colorArgb.toUnsigned(32);
    final colors = <int>[
      normalized,
      ...recentCustomPenColors.where((color) => color != normalized),
    ].take(maximumRecentPenColors).toList(growable: false);
    final encoded = colors
        .map((color) => color.toRadixString(16).padLeft(8, '0').toUpperCase())
        .join(',');
    if (document.metadata.custom[recentPenColorsMetadataKey] == encoded) return;
    final custom = Map<String, String>.from(document.metadata.custom)
      ..[recentPenColorsMetadataKey] = encoded;
    executeUntracked(
      ReplaceDocumentCommand(
        document.copyWith(metadata: document.metadata.copyWith(custom: custom)),
        'Letzte Stiftfarben speichern',
      ),
    );
  }

  void updateRadialMenuPosition(Offset normalizedPosition) {
    if (!normalizedPosition.dx.isFinite || !normalizedPosition.dy.isFinite) {
      return;
    }
    _pendingRadialPosition = Offset(
      normalizedPosition.dx.clamp(0, 1),
      normalizedPosition.dy.clamp(0, 1),
    );
    _scheduleSettingsPersistence();
  }

  bool beginInk(
    PointerDownEvent event,
    Offset worldPosition, {
    ActivePenStyle? style,
    String? authorId,
    Offset? samplingPosition,
  }) {
    if (_handwritingConversionInProgress) return false;
    // A transform preview is a single atomic document operation. Ink sessions
    // may run concurrently with each other, but must not invalidate another
    // participant's active move/resize/rotation preview.
    if (_selectionInteractionOwner != null) return false;
    if (_selectedIds.isNotEmpty || _selectionTransformPreview != null) {
      _selectedIds = <String>{};
      _selectionTransformPreview = null;
      _returnToInkWhenInsertedSelectionClears = false;
      notifyListeners();
    }
    final target = _annotationTargetAt(worldPosition);
    if (target == null && !viewport.worldBounds.contains(worldPosition)) {
      return false;
    }
    if (target != null) {
      _annotationTargets[event.pointer] = target;
    }
    final began = inkSessions.begin(
      event: event,
      worldPosition: worldPosition,
      style: style ?? penStyle,
      authorId: authorId ?? 'pointer-${event.device}',
      samplingPosition: samplingPosition,
    );
    if (!began) {
      _annotationTargets.remove(event.pointer);
    } else if (_autosaveInkPointers.add(event.pointer)) {
      // Copying/encoding the complete document during a pen gesture creates
      // page-count-dependent frame stalls on smartboards. Keep the newest
      // immutable snapshot pending, then persist after a short input-idle
      // window (or immediately on lifecycle flush).
      autosave.beginInteraction();
    }
    return began;
  }

  void updateInk(
    PointerMoveEvent event,
    Offset worldPosition, {
    Offset? samplingPosition,
  }) {
    final target = _annotationTargets[event.pointer];
    inkSessions.update(
      event,
      target == null ? _clampWorldOffset(worldPosition) : worldPosition,
      samplingPosition: samplingPosition,
    );
  }

  void endInk(
    PointerEvent event,
    Offset worldPosition, {
    Offset? samplingPosition,
  }) {
    final heldAutosave = _autosaveInkPointers.remove(event.pointer);
    try {
      final target = _annotationTargets.remove(event.pointer);
      final stroke = inkSessions.end(
        event,
        target == null ? _clampWorldOffset(worldPosition) : worldPosition,
        samplingPosition: samplingPosition,
      );
      if (stroke == null || stroke.points.isEmpty) return;
      final storedStroke = target?.toLocalStroke(stroke) ?? stroke;
      execute(
        AddStrokeAndRegroupCommand(
          pageId: page.id,
          stroke: storedStroke,
          objectId: target?.objectId,
          pdfPageIndex: target?.pdfPageIndex,
          grouping: groupingEngine,
        ),
      );
    } finally {
      if (heldAutosave) autosave.endInteraction();
    }
  }

  void cancelInk(int pointer) {
    _annotationTargets.remove(pointer);
    inkSessions.cancel(pointer);
    if (_autosaveInkPointers.remove(pointer)) autosave.endInteraction();
  }

  void eraseAt(Offset worldPosition, {double radius = 24}) =>
      eraseSweeps(<InkEraserSweep>[
        (start: worldPosition, end: worldPosition, radius: radius),
      ]);

  void eraseAlong(Offset start, Offset end, {double radius = 24}) =>
      eraseSweeps(<InkEraserSweep>[(start: start, end: end, radius: radius)]);

  /// Stages one input sample's complete eraser footprint and publishes its
  /// combined preview once.
  ///
  /// A calibrated palm can contain five circular stamps. Staging remains
  /// sequential for exact geometry, while listeners observe one atomic frame
  /// update instead of up to five complete board rebuilds.
  void eraseSweeps(Iterable<InkEraserSweep> values) {
    final currentPage = page;
    var changed = false;
    for (final value in values) {
      final start = value.start;
      final end = value.end;
      if (!start.dx.isFinite ||
          !start.dy.isFinite ||
          !end.dx.isFinite ||
          !end.dy.isFinite) {
        continue;
      }
      final radius = value.radius;
      final safeRadius = radius.isFinite && radius > 0
          ? radius.clamp(.25, 256.0)
          : 24.0;
      if (_pendingErasePageId != null &&
          _pendingErasePageId != currentPage.id) {
        _clearPendingErase();
      }
      _pendingErasePageId ??= currentPage.id;
      _pendingEraseRevision ??= document.revision;
      final horizontalConstraint = _contentHorizontalConstraint;
      final sweep = _PendingEraseSweep(
        start: start,
        end: end,
        radius: safeRadius,
        eraseMinimumX:
            horizontalConstraint?.side == BoardViewportPartitionSide.right
            ? horizontalConstraint!.worldBoundaryX
            : null,
        eraseMaximumX:
            horizontalConstraint?.side == BoardViewportPartitionSide.left
            ? horizontalConstraint!.worldBoundaryX
            : null,
      );
      _pendingEraseSweeps.add(sweep);
      changed = _stageEraseSweep(sweep, currentPage) || changed;
    }
    if (changed) {
      _invalidateErasePreviewCaches();
      notifyListeners();
    }
  }

  bool _stageEraseSweep(_PendingEraseSweep sweep, BoardPage currentPage) {
    final start = sweep.start;
    final end = sweep.end;
    final safeRadius = sweep.radius;
    final sourceIds = sweep.sourceIds;
    final capturedSourceIds = <String>{};

    _synchronizeEraseIndex(currentPage);
    _annotationEraseIndex.synchronize(currentPage);
    final query = Rect.fromLTRB(
      math.min(start.dx, end.dx) - safeRadius,
      math.min(start.dy, end.dy) - safeRadius,
      math.max(start.dx, end.dx) + safeRadius,
      math.max(start.dy, end.dy) + safeRadius,
    );
    var changed = false;
    final strokeCandidates = _eraseIndex.query(query);
    _debugLastEraseStrokeCandidateCount = strokeCandidates.length;
    for (final stroke in strokeCandidates) {
      if (_acceptsEraseSource(stroke.id, sourceIds) &&
          _strokeTouchesCapsule(stroke, start, end, safeRadius)) {
        final strokeRadius = stroke.width.isFinite
            ? math.max(0.0, stroke.width / 2)
            : 0.0;
        final strokeChanged = _stageStrokeErase(
          stroke,
          start,
          end,
          radius: safeRadius + strokeRadius,
          eraseMinimumX: sweep.eraseMinimumX,
          eraseMaximumX: sweep.eraseMaximumX,
        );
        if (strokeChanged && sweep.sourceIds == null) {
          capturedSourceIds.add(stroke.id);
        }
        changed = strokeChanged || changed;
      }
    }
    final annotationCandidates = _annotationEraseIndex.query(query);
    _debugLastEraseAnnotationCandidateCount = annotationCandidates.length;
    for (final entry in annotationCandidates) {
      final stroke = entry.stroke;
      if (!_acceptsEraseSource(stroke.id, sourceIds) ||
          !_annotationStrokeTouchesWorldCapsule(
            stroke,
            entry.target,
            start,
            end,
            safeRadius,
          )) {
        continue;
      }
      final localWidth = stroke.width.isFinite ? stroke.width : 0.0;
      final strokeRadius = math.max(
        0.0,
        localWidth * entry.target.minimumExtent / 2,
      );
      final strokeChanged = _stageStrokeErase(
        stroke,
        start,
        end,
        radius: safeRadius + strokeRadius,
        isAnnotation: true,
        eraseMinimumX: sweep.eraseMinimumX,
        eraseMaximumX: sweep.eraseMaximumX,
        project: (point) {
          final world = entry.target.pointToWorld(point);
          return Vec2(world.dx, world.dy);
        },
      );
      if (strokeChanged && sweep.sourceIds == null) {
        capturedSourceIds.add(stroke.id);
      }
      changed = strokeChanged || changed;
    }
    sweep.sourceIds ??= Set<String>.unmodifiable(capturedSourceIds);
    return changed;
  }

  void commitErase() {
    if (_pendingEraseSweeps.isEmpty) {
      _clearPendingErase();
      return;
    }
    // The preview is already the exact staged result in the common path.
    // Replay only when another participant changed the document mid-gesture.
    if (_pendingEraseRevision != document.revision) {
      _rebuildPendingErasePreview();
    }
    if (_pendingEraseReplacements.isEmpty) {
      _clearPendingErase();
      notifyListeners();
      return;
    }
    final replacements = <String, List<InkStroke>>{
      for (final entry in _pendingEraseReplacements.entries)
        entry.key: List<InkStroke>.of(entry.value),
    };
    final selectionBefore = Set<String>.of(_selectedIds);
    final selectedContentGroups = <String, List<String>>{
      for (final group in page.contentGroups)
        if (selectionBefore.contains(group.id)) group.id: group.memberIds,
    };
    _clearPendingErase();
    if (!execute(
      ReplaceErasedStrokeSegmentsCommand(
        pageId: page.id,
        replacements: replacements,
      ),
    )) {
      return;
    }
    _rebaseSelectionAfterErase(selectionBefore, selectedContentGroups);
    final validStrokeIds = page.strokes.map((stroke) => stroke.id).toSet();
    final nextSelection = <String>{..._selectedIds};
    var selectionChanged = false;
    for (final selectedId in selectionBefore) {
      final fragments = replacements[selectedId];
      if (fragments == null) continue;
      for (final fragment in fragments) {
        if (validStrokeIds.contains(fragment.id) &&
            nextSelection.add(fragment.id)) {
          selectionChanged = true;
        }
      }
    }
    if (selectionChanged) {
      _selectedIds = nextSelection;
      notifyListeners();
    }
  }

  void cancelErase() {
    if (_pendingEraseReplacements.isEmpty && _pendingEraseSweeps.isEmpty) {
      return;
    }
    _clearPendingErase();
    notifyListeners();
  }

  void _rebuildPendingErasePreview() {
    if (_pendingEraseSweeps.isEmpty) return;
    _debugErasePreviewReplayCount++;
    final currentPage = page;
    if (_pendingErasePageId != currentPage.id) {
      _clearPendingErase();
      return;
    }
    final sweeps = List<_PendingEraseSweep>.of(_pendingEraseSweeps);
    _pendingEraseReplacements.clear();
    _pendingFreeEraseSourceIds.clear();
    _pendingAnnotationEraseSourceIds.clear();
    _eraseIndexedStrokes = null;
    _eraseIndexedPageId = null;
    _eraseIndexedStrokePositions.clear();
    _eraseIndex.clear();
    for (final sweep in sweeps) {
      _stageEraseSweep(sweep, currentPage);
    }
    _invalidateErasePreviewCaches();
    _pendingEraseRevision = document.revision;
  }

  void _clearPendingErase() {
    final hadPreview =
        _pendingEraseReplacements.isNotEmpty ||
        _pendingFreeEraseSourceIds.isNotEmpty ||
        _pendingAnnotationEraseSourceIds.isNotEmpty;
    _pendingEraseReplacements.clear();
    _pendingFreeEraseSourceIds.clear();
    _pendingAnnotationEraseSourceIds.clear();
    _pendingEraseSweeps.clear();
    _pendingErasePageId = null;
    _pendingEraseRevision = null;
    if (hadPreview) _invalidateErasePreviewCaches();
  }

  bool _stageStrokeErase(
    InkStroke source,
    Offset start,
    Offset end, {
    required double radius,
    bool isAnnotation = false,
    InkPointProjection? project,
    double? eraseMinimumX,
    double? eraseMaximumX,
  }) {
    final current = _pendingEraseReplacements[source.id] ?? <InkStroke>[source];
    final next = <InkStroke>[];
    var changed = false;
    for (final fragment in current) {
      final result = InkStrokeEraser.eraseCapsule(
        stroke: fragment,
        eraserStart: Vec2(start.dx, start.dy),
        eraserEnd: Vec2(end.dx, end.dy),
        radius: radius,
        project: project,
        eraseMinimumX: eraseMinimumX,
        eraseMaximumX: eraseMaximumX,
        idFactory: (sourceId, fragmentIndex) => '$sourceId.erase.${_uuid.v4()}',
      );
      changed = changed || result.changed;
      next.addAll(result.fragments);
    }
    if (!changed) return false;
    _pendingEraseReplacements[source.id] = List<InkStroke>.unmodifiable(next);
    if (isAnnotation) {
      _pendingAnnotationEraseSourceIds.add(source.id);
    } else {
      _pendingFreeEraseSourceIds.add(source.id);
    }
    return true;
  }

  void _invalidateErasePreviewCaches() {
    _erasePreviewVersion++;
    _cachedEraseStrokePreviewVersion = -1;
    _cachedEraseStrokeSource = null;
    _cachedEraseRenderStrokes = null;
    _cachedEraseAnnotationPreviewVersion = -1;
    _cachedEraseAnnotationSource = null;
    _cachedEraseRenderAnnotationLayers = null;
  }

  static bool _acceptsEraseSource(String strokeId, Set<String>? sourceIds) {
    if (sourceIds == null || sourceIds.contains(strokeId)) return true;
    var ancestor = strokeId;
    while (true) {
      final separator = ancestor.lastIndexOf('.erase.');
      if (separator <= 0) return false;
      ancestor = ancestor.substring(0, separator);
      if (sourceIds.contains(ancestor)) return true;
    }
  }

  void selectAt(Offset worldPosition, {double? viewportScale}) {
    _selectionTransformPreview = null;
    final hitScale = viewportScale != null && viewportScale.isFinite
        ? viewportScale.clamp(BoardViewport.minScale, BoardViewport.maxScale)
        : viewport.scale;
    final selectionPoint = Vec2(worldPosition.dx, worldPosition.dy);
    final selectionTolerance = 14 / hitScale;
    final candidates = selectionEngine
        .candidatesAt(
          page,
          selectionPoint,
          tolerance: selectionTolerance,
          inkGroupCandidates: groupingEngine.selectionCandidatesAt(
            page,
            selectionPoint,
            tolerance: selectionTolerance,
          ),
        )
        .where((candidate) => _belongsToContentPartition(candidate.bounds))
        .toList(growable: false);
    if (candidates.isEmpty) {
      final resumeInk = _returnToInkWhenInsertedSelectionClears;
      _selectedIds = <String>{};
      _selectionTransformPreview = null;
      _returnToInkWhenInsertedSelectionClears = false;
      if (resumeInk) {
        _activateConfiguredInkTool(clearSelection: false);
      } else {
        notifyListeners();
      }
      return;
    }
    final currentIndex = candidates.indexWhere(
      (candidate) =>
          candidate.itemIds.toSet().containsAll(_selectedIds) &&
          _selectedIds.containsAll(candidate.itemIds),
    );
    final next = candidates[(currentIndex + 1) % candidates.length];
    if (!setEquals(_selectedIds, next.itemIds.toSet())) {
      _returnToInkWhenInsertedSelectionClears = false;
    }
    _selectedIds = next.itemIds.toSet();
    notifyListeners();
  }

  void selectRectangle(Rect worldRect) {
    _selectionTransformPreview = null;
    _returnToInkWhenInsertedSelectionClears = false;
    _selectedIds = _filterSelectionForContentPartition(
      selectionEngine.itemsInRectangle(
        page,
        Rect2(
          left: worldRect.left,
          top: worldRect.top,
          width: worldRect.width,
          height: worldRect.height,
        ),
      ),
    );
    notifyListeners();
  }

  void selectLasso(List<Offset> points) {
    _selectionTransformPreview = null;
    _returnToInkWhenInsertedSelectionClears = false;
    _selectedIds = _filterSelectionForContentPartition(
      selectionEngine.itemsInLasso(
        page,
        points.map((point) => Vec2(point.dx, point.dy)).toList(growable: false),
      ),
    );
    notifyListeners();
  }

  void selectAll() {
    _selectionTransformPreview = null;
    _returnToInkWhenInsertedSelectionClears = false;
    _selectedIds = _filterSelectionForContentPartition(
      selectionEngine.allItems(page),
    );
    notifyListeners();
  }

  /// Assigns this interaction controller to one immutable half of the board.
  ///
  /// Camera constraints alone are insufficient: a pointer may remain inside
  /// its screen half while a large selection crosses the world-space divider.
  /// Keeping the content partition in the controller makes every selection
  /// path use the same rule, independent of input device and UI surface.
  void setContentHorizontalConstraint(
    BoardViewportHorizontalConstraint? constraint,
  ) {
    final normalized = constraint != null && constraint.isValid
        ? constraint
        : null;
    final current = _contentHorizontalConstraint;
    if (current?.side == normalized?.side &&
        current?.worldBoundaryX == normalized?.worldBoundaryX) {
      return;
    }
    _contentHorizontalConstraint = normalized;
    _selectionTransformPreview = null;
    _returnToInkWhenInsertedSelectionClears = false;
    _selectedIds = _filterSelectionForContentPartition(_selectedIds);
    notifyListeners();
  }

  Set<String> _filterSelectionForContentPartition(Iterable<String> ids) {
    if (_contentHorizontalConstraint == null) return ids.toSet();
    return <String>{
      for (final id in ids)
        if (_selectionItemBounds(id) case final bounds?)
          if (_belongsToContentPartition(bounds)) id,
    };
  }

  Rect2? _selectionItemBounds(String id) {
    for (final group in page.contentGroups) {
      if (group.id == id) return group.bounds;
    }
    for (final group in page.groups) {
      if (group.id == id) return group.bounds;
    }
    final object = page.objectById(id);
    if (object != null) return object.transform.bounds;
    final stroke = page.strokeById(id);
    return stroke?.bounds;
  }

  bool _belongsToContentPartition(Rect2 bounds) {
    final constraint = _contentHorizontalConstraint;
    if (constraint == null) return true;
    final centerX = bounds.center.x;
    if (!centerX.isFinite) return false;
    return switch (constraint.side) {
      // Half-open ownership gives an item on the divider exactly one owner.
      BoardViewportPartitionSide.left => centerX < constraint.worldBoundaryX,
      BoardViewportPartitionSide.right => centerX >= constraint.worldBoundaryX,
    };
  }

  void clearSelection() {
    final hadTransientSelection = _returnToInkWhenInsertedSelectionClears;
    _returnToInkWhenInsertedSelectionClears = false;
    if (_selectedIds.isEmpty &&
        _selectionTransformPreview == null &&
        !hadTransientSelection) {
      return;
    }
    _selectedIds = {};
    _selectionTransformPreview = null;
    notifyListeners();
  }

  Rect2 get _baseSelectionBounds => _selectionMembers.baseBounds;

  Rect2 get selectionBounds {
    final bounds = _baseSelectionBounds;
    final preview = _selectionTransformPreview;
    if (preview == null) return bounds;
    // Transform each selected scene item before uniting its bounds. Rotating
    // the already axis-aligned aggregate would create an oversized frame when
    // an object has previously been rotated.
    return _transformedSelectionBounds(preview);
  }

  /// Serializes selection previews across both participant surfaces.
  /// Ordinary ink remains multi-pointer and does not use this lock.
  bool claimSelectionInteraction(String owner) {
    if (owner.isEmpty || _handwritingConversionInProgress) return false;
    final current = _selectionInteractionOwner;
    if (current != null && current != owner) return false;
    _selectionInteractionOwner = owner;
    return true;
  }

  void releaseSelectionInteraction(String owner) {
    if (_selectionInteractionOwner == owner) {
      _selectionInteractionOwner = null;
    }
  }

  bool selectionContains(Offset worldPosition, {double tolerance = 12}) {
    if (_selectedIds.isEmpty ||
        !worldPosition.dx.isFinite ||
        !worldPosition.dy.isFinite) {
      return false;
    }
    final point = Vec2(worldPosition.dx, worldPosition.dy);
    // The visible selection frame is an interaction surface, not only a
    // decoration. This is especially important for handwriting and multiple
    // disjoint items: requiring a hit on an individual stroke made moving an
    // already selected block unnecessarily precise. The same aggregate bounds
    // drive the painted frame, so every point visibly inside it can start a
    // move or a two-finger scale gesture.
    if (selectionBounds.inflate(tolerance).contains(point)) return true;

    // Retain the exact member checks as a defensive fallback for degenerate
    // zero-sized bounds and custom objects whose hit area may intentionally
    // extend beyond their aggregate axis-aligned frame.
    final members = _selectionMembers;
    for (final bounds in members.selectedGroupBounds) {
      if (bounds.inflate(tolerance).contains(point)) return true;
    }
    for (final object in members.objects) {
      if (object.transform.containsWorld(point, tolerance: tolerance)) {
        return true;
      }
    }
    for (final stroke in members.strokes) {
      if (selectionEngine.strokeContainsPoint(
        stroke,
        point,
        tolerance: tolerance,
      )) {
        return true;
      }
    }
    return false;
  }

  /// The persisted angle shown by the manual rotation control. A mixed
  /// selection has no single intrinsic angle, so it starts at zero while a
  /// single object reports its own angle.
  double get selectionRotationDegrees {
    final expanded = _expandedSelectionIds;
    if (expanded.length != 1) return 0;
    final objects = _selectionMembers.objects;
    if (objects.length != 1 || objects.single.id != expanded.single) return 0;
    final object = objects.single;
    return object.transform.rotationRadians * 180 / math.pi;
  }

  Rect2 get _selectionTransformRegion {
    final world = viewport.worldBounds;
    final constraint = _contentHorizontalConstraint;
    if (constraint == null || !constraint.isValid) {
      return Rect2(
        left: world.left,
        top: world.top,
        width: world.width,
        height: world.height,
      );
    }
    final boundary = constraint.worldBoundaryX.clamp(world.left, world.right);
    return switch (constraint.side) {
      BoardViewportPartitionSide.left => Rect2(
        left: world.left,
        top: world.top,
        width: boundary - world.left,
        height: world.height,
      ),
      BoardViewportPartitionSide.right => Rect2(
        left: boundary,
        top: world.top,
        width: world.right - boundary,
        height: world.height,
      ),
    };
  }

  Rect2 _transformedStrokeBounds(InkStroke stroke, TransformDelta delta) {
    final halfWidth = stroke.width / 2;
    final visible = stroke.bounds;
    final centerLineBounds = Rect2(
      left: visible.left + halfWidth,
      top: visible.top + halfWidth,
      width: math.max(0, visible.width - stroke.width),
      height: math.max(0, visible.height - stroke.width),
    ).transformed(delta);
    final nextWidth =
        stroke.width *
        math.sqrt(
          (delta.scaleX.abs() * delta.scaleY.abs()).clamp(
            0.0001,
            double.infinity,
          ),
        );
    return centerLineBounds.inflate(nextWidth / 2);
  }

  Rect2 _transformedSelectionBounds(TransformDelta delta) {
    final members = _selectionMembers;
    Rect2? result;
    for (final object in members.objects) {
      final bounds = object.transform.apply(delta).bounds;
      result = result == null ? bounds : result.union(bounds);
    }
    for (final stroke in members.strokes) {
      final bounds = _transformedStrokeBounds(stroke, delta);
      result = result == null ? bounds : result.union(bounds);
    }
    return result ?? const Rect2.zero();
  }

  TransformDelta? _constrainSelectionTransform(TransformDelta requested) {
    if (_selectedIds.isEmpty ||
        !requested.dx.isFinite ||
        !requested.dy.isFinite ||
        !requested.scaleX.isFinite ||
        !requested.scaleY.isFinite ||
        !requested.anchor.x.isFinite ||
        !requested.anchor.y.isFinite ||
        !requested.rotationRadians.isFinite ||
        !requested.scaleAxisRadians.isFinite) {
      return null;
    }
    final bounds = _transformedSelectionBounds(requested);
    final allowed = _selectionTransformRegion;
    if (bounds.isEmpty ||
        !bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite ||
        allowed.isEmpty ||
        bounds.width > allowed.width + .0001 ||
        bounds.height > allowed.height + .0001) {
      return null;
    }
    var correctionX = 0.0;
    var correctionY = 0.0;
    if (bounds.left < allowed.left) {
      correctionX = allowed.left - bounds.left;
    }
    if (bounds.right + correctionX > allowed.right) {
      correctionX = allowed.right - bounds.right;
    }
    if (bounds.top < allowed.top) {
      correctionY = allowed.top - bounds.top;
    }
    if (bounds.bottom + correctionY > allowed.bottom) {
      correctionY = allowed.bottom - bounds.bottom;
    }
    return TransformDelta(
      dx: requested.dx + correctionX,
      dy: requested.dy + correctionY,
      scaleX: requested.scaleX,
      scaleY: requested.scaleY,
      anchor: requested.anchor,
      rotationRadians: requested.rotationRadians,
      scaleAxisRadians: requested.scaleAxisRadians,
    );
  }

  void _previewSelectionTransform(TransformDelta requested) {
    // An identity preview deliberately replaces a previously valid preview
    // when a new sample is impossible. A malformed/oversized gesture can
    // therefore never commit the last valid frame accidentally.
    _selectionTransformPreview =
        _constrainSelectionTransform(requested) ?? const TransformDelta();
    notifyListeners();
  }

  void previewMoveSelection(Offset delta) {
    if (_selectedIds.isEmpty || !delta.dx.isFinite || !delta.dy.isFinite) {
      return;
    }
    _previewSelectionTransform(TransformDelta(dx: delta.dx, dy: delta.dy));
  }

  void previewScaleSelection(double scale, {required Offset anchor}) {
    if (_selectedIds.isEmpty || !scale.isFinite) return;
    final bounds = _baseSelectionBounds;
    final world = _selectionTransformRegion;
    final availableX = bounds.right > anchor.dx
        ? (world.right - anchor.dx) / (bounds.right - anchor.dx)
        : 20.0;
    final availableY = bounds.bottom > anchor.dy
        ? (world.bottom - anchor.dy) / (bounds.bottom - anchor.dy)
        : 20.0;
    final maximum = math.min(20.0, math.min(availableX, availableY));
    final safe = scale.clamp(.05, math.max(.05, maximum)).toDouble();
    _previewSelectionTransform(
      TransformDelta(
        scaleX: safe,
        scaleY: safe,
        anchor: Vec2(anchor.dx, anchor.dy),
      ),
    );
  }

  /// Previews an axis-aligned resize around a fixed opposite edge/corner.
  ///
  /// Keeping this separate from [previewScaleSelection] lets cover handles
  /// resize one side without changing the other dimension. Positive scales
  /// are clamped to the writable 3x3 world, so malformed pointer deltas can
  /// never create inverted or non-finite object geometry.
  void previewResizeSelection({
    required double scaleX,
    required double scaleY,
    required Offset anchor,
    double scaleAxisRadians = 0,
  }) {
    if (_selectedIds.isEmpty ||
        !scaleX.isFinite ||
        !scaleY.isFinite ||
        !scaleAxisRadians.isFinite ||
        !anchor.dx.isFinite ||
        !anchor.dy.isFinite) {
      return;
    }
    final bounds = _baseSelectionBounds;
    if (bounds.isEmpty) return;
    final world = _selectionTransformRegion;

    double maximumScaleX() {
      var maximum = 20.0;
      if (bounds.left < anchor.dx) {
        maximum = math.min(
          maximum,
          (anchor.dx - world.left) / (anchor.dx - bounds.left),
        );
      }
      if (bounds.right > anchor.dx) {
        maximum = math.min(
          maximum,
          (world.right - anchor.dx) / (bounds.right - anchor.dx),
        );
      }
      return maximum.isFinite ? math.max(.05, maximum) : 20.0;
    }

    double maximumScaleY() {
      var maximum = 20.0;
      if (bounds.top < anchor.dy) {
        maximum = math.min(
          maximum,
          (anchor.dy - world.top) / (anchor.dy - bounds.top),
        );
      }
      if (bounds.bottom > anchor.dy) {
        maximum = math.min(
          maximum,
          (world.bottom - anchor.dy) / (bounds.bottom - anchor.dy),
        );
      }
      return maximum.isFinite ? math.max(.05, maximum) : 20.0;
    }

    final safeX = scaleX.clamp(.05, maximumScaleX()).toDouble();
    final safeY = scaleY.clamp(.05, maximumScaleY()).toDouble();
    _previewSelectionTransform(
      TransformDelta(
        scaleX: safeX,
        scaleY: safeY,
        anchor: Vec2(anchor.dx, anchor.dy),
        scaleAxisRadians: scaleAxisRadians,
      ),
    );
  }

  /// Rotates the complete selection around [anchor] without changing its
  /// dimensions. Object-local annotation layers remain attached because the
  /// owning object's transform carries the angle.
  void previewRotateSelection(
    double rotationRadians, {
    required Offset anchor,
  }) {
    if (_selectedIds.isEmpty ||
        !rotationRadians.isFinite ||
        !anchor.dx.isFinite ||
        !anchor.dy.isFinite) {
      return;
    }
    final base = _baseSelectionBounds;
    if (base.isEmpty) return;
    var delta = TransformDelta(
      anchor: Vec2(anchor.dx, anchor.dy),
      rotationRadians: rotationRadians,
    );
    _previewSelectionTransform(delta);
  }

  void rotateSelectionBy(double rotationRadians) {
    if (_selectedIds.isEmpty || !rotationRadians.isFinite) return;
    final center = _baseSelectionBounds.center;
    previewRotateSelection(rotationRadians, anchor: Offset(center.x, center.y));
    commitSelectionTransform();
  }

  void setSelectionRotationDegrees(double degrees) {
    if (!degrees.isFinite || _selectedIds.isEmpty) return;
    final desired = degrees * math.pi / 180;
    final current = selectionRotationDegrees * math.pi / 180;
    rotateSelectionBy(desired - current);
  }

  void mirrorSelectionHorizontally() {
    if (_selectedIds.isEmpty) return;
    final center = _baseSelectionBounds.center;
    _selectionTransformPreview = _constrainSelectionTransform(
      TransformDelta(scaleX: -1, anchor: center),
    );
    commitSelectionTransform();
  }

  void commitSelectionTransform() {
    final requested = _selectionTransformPreview;
    if (requested == null) return;
    // Re-evaluate immediately before mutation. Both participant controllers
    // share a document history, so the other side may have committed between
    // this gesture's preview and pointer-up.
    final preview = _constrainSelectionTransform(requested);
    _selectionTransformPreview = null;
    if (preview == null) {
      notifyListeners();
      return;
    }
    final identity =
        preview.dx.abs() < .0001 &&
        preview.dy.abs() < .0001 &&
        (preview.scaleX - 1).abs() < .0001 &&
        (preview.scaleY - 1).abs() < .0001 &&
        preview.rotationRadians.abs() < .0001;
    if (identity || _selectedIds.isEmpty) {
      notifyListeners();
      return;
    }
    execute(TransformItemsCommand(page.id, _selectedIds, preview));
  }

  void cancelSelectionTransform() {
    if (_selectionTransformPreview == null) return;
    _selectionTransformPreview = null;
    notifyListeners();
  }

  void moveSelection(Offset delta) {
    previewMoveSelection(delta);
    commitSelectionTransform();
  }

  void scaleSelection(double scale, {required Offset anchor}) {
    previewScaleSelection(scale, anchor: anchor);
    commitSelectionTransform();
  }

  void copySelection() {
    if (_selectedIds.isEmpty) return;
    final expanded = _expandedSelectionIds;
    _clipboard = _ClipboardPayload(
      strokes: page.strokes
          .where((stroke) => expanded.contains(stroke.id))
          .toList(),
      objects: page.objects
          .where((object) => expanded.contains(object.id))
          .toList(),
      layers: page.annotationLayers
          .where((layer) => expanded.contains(layer.objectId))
          .toList(),
      groups: page.contentGroups
          .where((group) => _selectedIds.contains(group.id))
          .toList(),
    );
    notifyListeners();
  }

  void cutSelection() {
    copySelection();
    deleteSelection();
  }

  void duplicateSelection() {
    copySelection();
    paste(offset: const Offset(36, 36));
  }

  Offset? _constrainBoundsTranslation(Rect2 bounds, Offset requested) {
    if (bounds.isEmpty ||
        !requested.dx.isFinite ||
        !requested.dy.isFinite ||
        !bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite) {
      return null;
    }
    final allowed = _selectionTransformRegion;
    if (bounds.width > allowed.width + .0001 ||
        bounds.height > allowed.height + .0001) {
      return null;
    }
    var dx = requested.dx;
    var dy = requested.dy;
    if (bounds.left + dx < allowed.left) dx = allowed.left - bounds.left;
    if (bounds.right + dx > allowed.right) dx = allowed.right - bounds.right;
    if (bounds.top + dy < allowed.top) dy = allowed.top - bounds.top;
    if (bounds.bottom + dy > allowed.bottom) {
      dy = allowed.bottom - bounds.bottom;
    }
    return Offset(dx, dy);
  }

  void paste({Offset offset = const Offset(28, 28)}) {
    final payload = _clipboard;
    if (payload == null) return;
    Rect2? payloadBounds;
    for (final stroke in payload.strokes) {
      payloadBounds = payloadBounds == null
          ? stroke.bounds
          : payloadBounds.union(stroke.bounds);
    }
    for (final object in payload.objects) {
      payloadBounds = payloadBounds == null
          ? object.transform.bounds
          : payloadBounds.union(object.transform.bounds);
    }
    final safeOffset = payloadBounds == null
        ? null
        : _constrainBoundsTranslation(payloadBounds, offset);
    if (safeOffset == null) {
      lastError = 'Der Inhalt ist zu groß für den verfügbaren Dokumentbereich.';
      notifyListeners();
      return;
    }
    final idMap = <String, String>{};
    final delta = TransformDelta(dx: safeOffset.dx, dy: safeOffset.dy);
    var strokes = payload.strokes.map((stroke) {
      final id = _uuid.v4();
      idMap[stroke.id] = id;
      return stroke.transformed(delta).copyWith(id: id, clearPointerId: true);
    }).toList();
    var objects = payload.objects.map((object) {
      final id = _uuid.v4();
      idMap[object.id] = id;
      final transformed = object.copyWithTransform(
        object.transform.apply(delta),
      );
      return _cloneObjectWithId(transformed, id);
    }).toList();
    final copiedScene = orderedBoardSceneItems(
      objects: objects,
      strokes: strokes,
    );
    final firstZIndex = page.nextTopLevelSceneZIndex;
    final layeredScene = <BoardSceneItem>[
      for (var index = 0; index < copiedScene.length; index++)
        copiedScene[index].withZIndex(firstZIndex + index),
    ];
    strokes = layeredScene
        .where((item) => item.kind == BoardSceneItemKind.stroke)
        .map((item) => item.stroke!)
        .toList(growable: false);
    objects = layeredScene
        .where((item) => item.kind == BoardSceneItemKind.object)
        .map((item) => item.object!)
        .toList(growable: false);
    final layers = payload.layers
        .where((layer) => idMap.containsKey(layer.objectId))
        .map(
          (layer) => ObjectInkLayer(
            id: layer.pdfPageIndex == null
                ? '${idMap[layer.objectId]}.annotations'
                : '${idMap[layer.objectId]}.pdf.'
                      '${layer.pdfPageIndex}.annotations',
            objectId: idMap[layer.objectId]!,
            pdfPageIndex: layer.pdfPageIndex,
            strokes: layer.strokes.map(
              (stroke) => stroke.copyWith(id: _uuid.v4()),
            ),
            visible: layer.visible,
          ),
        )
        .toList();
    final groups = payload.groups
        .map(
          (group) => ContentGroup(
            id: _uuid.v4(),
            memberIds: group.memberIds
                .map((id) => idMap[id])
                .whereType<String>(),
            bounds: group.bounds.transformed(delta),
            locked: group.locked,
          ),
        )
        .where((group) => group.memberIds.length >= 2)
        .toList(growable: false);
    final nextPage = page.copyWith(
      strokes: [...page.strokes, ...strokes],
      objects: [...page.objects, ...objects],
      annotationLayers: [...page.annotationLayers, ...layers],
      contentGroups: [...page.contentGroups, ...groups],
    );
    execute(ReplacePageCommand(nextPage));
    final groupedMemberIds = groups.expand((group) => group.memberIds).toSet();
    _selectedIds = {
      ...groups.map((group) => group.id),
      ...strokes
          .where((stroke) => !groupedMemberIds.contains(stroke.id))
          .map((stroke) => stroke.id),
      ...objects
          .where((object) => !groupedMemberIds.contains(object.id))
          .map((object) => object.id),
    };
    notifyListeners();
  }

  void pasteAt(Offset worldPosition) {
    final payload = _clipboard;
    if (payload == null) return;
    Rect2? bounds;
    for (final stroke in payload.strokes) {
      bounds = bounds == null ? stroke.bounds : bounds.union(stroke.bounds);
    }
    for (final object in payload.objects) {
      bounds = bounds == null
          ? object.transform.bounds
          : bounds.union(object.transform.bounds);
    }
    final center = bounds?.center ?? Vec2.zero;
    paste(
      offset: Offset(worldPosition.dx - center.x, worldPosition.dy - center.y),
    );
  }

  void deleteSelection() {
    if (_selectedIds.isEmpty) return;
    execute(DeleteItemsCommand(page.id, _selectedIds));
    _selectedIds = {};
    _returnToInkWhenInsertedSelectionClears = false;
    notifyListeners();
  }

  void groupSelection() {
    if (!canGroupSelection) return;
    final groupId = _uuid.v4();
    execute(GroupItemsCommand(page.id, groupId, _selectedIds));
    if (page.contentGroups.any((group) => group.id == groupId)) {
      _selectedIds = {groupId};
      notifyListeners();
    }
  }

  void ungroupSelection() {
    final group = selectedContentGroup;
    if (group == null) return;
    execute(UngroupItemsCommand(page.id, group.id));
    _selectedIds = _filterSelectionForContentPartition(group.memberIds);
    notifyListeners();
  }

  void arrangeSelection(LayerArrangement arrangement) {
    if (!canArrangeSelection) return;
    final arranged = arrangeBoardSceneItems(
      objects: page.objects,
      strokes: page.strokes,
      selectedIds: _expandedSelectionIds,
      arrangement: switch (arrangement) {
        LayerArrangement.oneForward => SceneArrangement.oneForward,
        LayerArrangement.oneBackward => SceneArrangement.oneBackward,
        LayerArrangement.toFront => SceneArrangement.toFront,
        LayerArrangement.toBack => SceneArrangement.toBack,
      },
    );
    final objectsById = <String, BoardObject>{
      for (final object in page.objects) object.id: object,
    };
    final strokesById = <String, InkStroke>{
      for (final stroke in page.strokes) stroke.id: stroke,
    };
    final changed = arranged.any(
      (item) => switch (item.kind) {
        BoardSceneItemKind.object => !identical(
          item.object,
          objectsById[item.id],
        ),
        BoardSceneItemKind.stroke => !identical(
          item.stroke,
          strokesById[item.id],
        ),
      },
    );
    if (!changed) return;
    execute(
      ReplacePageCommand(
        page.copyWith(
          objects: arranged
              .where((item) => item.kind == BoardSceneItemKind.object)
              .map((item) => item.object!),
          strokes: arranged
              .where((item) => item.kind == BoardSceneItemKind.stroke)
              .map((item) => item.stroke!),
        ),
      ),
    );
  }

  Future<bool> convertSelectedHandwritingToText() async {
    if (_closed ||
        _handwritingConversionInProgress ||
        inkSessions.isWriting ||
        _selectionTransformPreview != null ||
        _selectionInteractionOwner != null) {
      return false;
    }
    var conversionStarted = false;
    try {
      final snapshot = _captureHandwritingConversionSnapshot();
      if (snapshot == null) return false;

      _handwritingConversionInProgress = true;
      conversionStarted = true;
      lastError = null;
      notifyListeners();
      if (!await handwritingRecognition.isAvailable()) {
        throw const HandwritingRecognitionUnavailable();
      }
      if (!_isCurrentHandwritingConversionSnapshot(snapshot)) return false;
      final result = await handwritingRecognition.recognize(
        HandwritingRecognitionRequest(strokes: snapshot.canonicalStrokes),
      );
      if (!result.isRecognized) {
        if (!_closed) {
          lastError =
              result.message ??
              'Die Handschrift wurde nicht sicher erkannt. Bitte markieren Sie ein vollständiges Wort oder eine Zeile.';
          notifyListeners();
        }
        return false;
      }
      if (!_isCurrentHandwritingConversionSnapshot(snapshot)) return false;

      Rect2? bounds;
      for (final stroke in snapshot.canonicalStrokes) {
        bounds = bounds == null ? stroke.bounds : bounds.union(stroke.bounds);
      }
      final textBounds = bounds ?? const Rect2.zero();
      var textObject = TextObject(
        id: _uuid.v4(),
        transform: ObjectTransform(
          x: textBounds.left,
          y: textBounds.top,
          width: TextObjectLayout.minimumWidth,
          height: TextObjectLayout.minimumHeight,
        ),
        text: result.text,
        fontSize: math.max(24, math.min(72, textBounds.height * .72)),
        colorArgb: snapshot.canonicalStrokes.first.colorArgb,
        sourceStrokeIds: snapshot.canonicalStrokes.map((stroke) => stroke.id),
        zIndex: page.nextTopLevelSceneZIndex,
      );
      textObject = textObject.copyWith(
        transform: TextObjectLayout.fit(
          value: textObject,
          maximumWidth: math.max(
            320,
            math.min(
              TextObjectLayout.defaultMaximumWidth,
              math.max(520, textBounds.width * 1.5),
            ),
          ),
        ),
      );
      final removed = snapshot.canonicalStrokes
          .map((stroke) => stroke.id)
          .toSet();
      final repairedContentGroups = page.contentGroups.map((group) {
        if (!group.memberIds.any(removed.contains)) return group;
        return group.copyWith(
          memberIds: <String>{
            ...group.memberIds.where((id) => !removed.contains(id)),
            textObject.id,
          },
        );
      });
      var nextPage = page
          .copyWith(
            strokes: page.strokes.where(
              (stroke) => !removed.contains(stroke.id),
            ),
            objects: [...page.objects, textObject],
            contentGroups: repairedContentGroups,
            selection: SelectionState(selectedItemIds: [textObject.id]),
          )
          .sanitized();
      final containingGroups = nextPage.contentGroups
          .where((group) => group.memberIds.contains(textObject.id))
          .map((group) => group.id)
          .toSet();
      final nextSelection = containingGroups.isEmpty
          ? <String>{textObject.id}
          : containingGroups;
      nextPage = nextPage.copyWith(
        selection: SelectionState(selectedItemIds: nextSelection),
      );
      if (!execute(ReplacePageCommand(nextPage))) return false;
      _selectedIds = nextSelection;
      notifyListeners();
      return true;
    } catch (error) {
      if (!_closed) {
        lastError = error.toString();
        notifyListeners();
      }
      return false;
    } finally {
      if (conversionStarted) {
        _handwritingConversionInProgress = false;
        if (!_closed) notifyListeners();
      }
    }
  }

  _HandwritingConversionSnapshot? _captureHandwritingConversionSnapshot() {
    _debugBeforeHandwritingSnapshotCapture?.call();
    final selectedIds = Set<String>.unmodifiable(_selectedIds);
    final expandedIds = Set<String>.unmodifiable(_expandedSelectionIds);
    if (selectedIds.isEmpty || expandedIds.isEmpty) return null;

    final canonicalStrokes = <InkStroke>[];
    final sourceStrokesById = <String, InkStroke>{};
    for (final source in page.strokes) {
      if (!expandedIds.contains(source.id)) continue;
      final canonical = _canonicalHandwritingStroke(source);
      if (canonical == null) continue;
      canonicalStrokes.add(canonical);
      sourceStrokesById[source.id] = source;
    }
    if (canonicalStrokes.isEmpty) return null;

    return _HandwritingConversionSnapshot(
      pageId: page.id,
      documentRevision: document.revision,
      selectedIds: selectedIds,
      expandedIds: expandedIds,
      sourceStrokesById: Map<String, InkStroke>.unmodifiable(sourceStrokesById),
      canonicalStrokes: List<InkStroke>.unmodifiable(canonicalStrokes),
    );
  }

  bool _isCurrentHandwritingConversionSnapshot(
    _HandwritingConversionSnapshot snapshot,
  ) {
    final currentPage = page;
    if (_closed ||
        currentPage.id != snapshot.pageId ||
        document.revision != snapshot.documentRevision ||
        inkSessions.isWriting ||
        _selectionTransformPreview != null ||
        _selectionInteractionOwner != null ||
        !setEquals(_selectedIds, snapshot.selectedIds) ||
        !setEquals(_expandedSelectionIds, snapshot.expandedIds)) {
      return false;
    }
    final currentSelectedStrokes = <String, InkStroke>{};
    for (final stroke in currentPage.strokes) {
      if (snapshot.sourceStrokesById.containsKey(stroke.id)) {
        currentSelectedStrokes[stroke.id] = stroke;
      }
    }
    for (final entry in snapshot.sourceStrokesById.entries) {
      if (!identical(currentSelectedStrokes[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  static InkStroke? _canonicalHandwritingStroke(InkStroke source) {
    const maximumCoordinate = 10000000.0;
    var hasUsablePoint = false;
    var needsPointRepair = false;
    for (final point in source.points) {
      if (!point.x.isFinite ||
          !point.y.isFinite ||
          point.x.abs() > maximumCoordinate ||
          point.y.abs() > maximumCoordinate) {
        needsPointRepair = true;
        continue;
      }
      hasUsablePoint = true;
      if (!point.pressure.isFinite ||
          point.pressure < 0 ||
          point.pressure > 1 ||
          !point.tiltX.isFinite ||
          point.tiltX < -1 ||
          point.tiltX > 1 ||
          !point.tiltY.isFinite ||
          point.tiltY < -1 ||
          point.tiltY > 1) {
        needsPointRepair = true;
      }
    }
    if (!hasUsablePoint) return null;
    final width = source.width.isFinite && source.width > 0
        ? source.width.clamp(.0001, 80.0).toDouble()
        : 4.0;
    if (!needsPointRepair) {
      return width == source.width ? source : source.copyWith(width: width);
    }
    return source.copyWith(
      points: _repairedHandwritingPoints(
        source.points,
        maximumCoordinate: maximumCoordinate,
      ),
      width: width,
    );
  }

  static Iterable<InkPoint> _repairedHandwritingPoints(
    Iterable<InkPoint> source, {
    required double maximumCoordinate,
  }) sync* {
    for (final point in source) {
      if (!point.x.isFinite ||
          !point.y.isFinite ||
          point.x.abs() > maximumCoordinate ||
          point.y.abs() > maximumCoordinate) {
        continue;
      }
      final pressure = point.pressure.isFinite
          ? point.pressure.clamp(0.0, 1.0).toDouble()
          : 1.0;
      final tiltX = point.tiltX.isFinite
          ? point.tiltX.clamp(-1.0, 1.0).toDouble()
          : 0.0;
      final tiltY = point.tiltY.isFinite
          ? point.tiltY.clamp(-1.0, 1.0).toDouble()
          : 0.0;
      if (pressure == point.pressure &&
          tiltX == point.tiltX &&
          tiltY == point.tiltY) {
        yield point;
      } else {
        yield InkPoint(
          x: point.x,
          y: point.y,
          pressure: pressure,
          timestampMicros: point.timestampMicros,
          tiltX: tiltX,
          tiltY: tiltY,
        );
      }
    }
  }

  /// Replaces a text object's content and typography as one undoable action.
  /// Its canvas bounds are remeasured, including wrapping and explicit lines.
  bool updateTextObject({
    required String objectId,
    required String text,
    double? fontSize,
    bool? bold,
    bool? italic,
    BoardTextAlign? alignment,
    double? maximumWidth,
    double? minimumWidth,
  }) {
    final index = page.objects.indexWhere((object) => object.id == objectId);
    if (index < 0 || page.objects[index] is! TextObject) return false;
    final current = page.objects[index] as TextObject;
    final normalizedSize = (fontSize ?? current.fontSize)
        .clamp(12.0, 160.0)
        .toDouble();
    var updated = current.copyWith(
      text: text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
      fontSize: normalizedSize,
      bold: bold,
      italic: italic,
      alignment: alignment,
    );
    updated = updated.copyWith(
      transform: TextObjectLayout.fit(
        value: updated,
        maximumWidth: maximumWidth ?? TextObjectLayout.defaultMaximumWidth,
        minimumObjectWidth: minimumWidth ?? TextObjectLayout.minimumWidth,
      ),
    );
    if (updated.text == current.text &&
        updated.fontSize == current.fontSize &&
        updated.bold == current.bold &&
        updated.italic == current.italic &&
        updated.alignment == current.alignment &&
        updated.transform == current.transform) {
      return false;
    }
    final objects = page.objects.toList(growable: false);
    objects[index] = updated;
    var nextPage = page.copyWith(objects: objects).sanitized();
    final containingGroups = nextPage.contentGroups
        .where((group) => group.memberIds.contains(updated.id))
        .map((group) => group.id)
        .toSet();
    final nextSelection = containingGroups.isEmpty
        ? <String>{updated.id}
        : containingGroups;
    nextPage = nextPage.copyWith(
      selection: SelectionState(selectedItemIds: nextSelection),
    );
    execute(ReplacePageCommand(nextPage));
    _selectedIds = nextSelection;
    notifyListeners();
    return true;
  }

  /// Applies the keyboard-free deletion gesture used by the inline text
  /// editor. [localPoints] are relative to the text object's top-left corner.
  bool applyInlineTextStrike({
    required String objectId,
    required List<Offset> localPoints,
  }) {
    final object = page.objectById(objectId);
    if (object is! TextObject ||
        !InlineTextEditingEngine.isStrikeThrough(object, localPoints)) {
      return false;
    }
    final updated = InlineTextEditingEngine.deleteAtStroke(object, localPoints);
    if (updated == object.text) return false;
    return updateTextObject(objectId: object.id, text: updated);
  }

  /// Recognizes pen strokes drawn directly over converted text and replaces
  /// the word under the ink, or inserts at the nearest caret. Recognition is
  /// local and the source object/page are revalidated after every await.
  Future<bool> applyInlineTextHandwriting({
    required String objectId,
    required List<List<Offset>> localStrokes,
  }) async {
    final sourcePageId = page.id;
    final source = page.objectById(objectId);
    if (source is! TextObject ||
        localStrokes.isEmpty ||
        localStrokes.every((stroke) => stroke.isEmpty)) {
      return false;
    }
    final createdAt = DateTime.now().toUtc();
    final timestamp = createdAt.microsecondsSinceEpoch;
    final recognitionStrokes = <InkStroke>[
      for (
        var strokeIndex = 0;
        strokeIndex < localStrokes.length;
        strokeIndex++
      )
        if (localStrokes[strokeIndex].isNotEmpty)
          InkStroke(
            id: 'inline-${_uuid.v4()}',
            createdAt: createdAt,
            colorArgb: source.colorArgb,
            width: math.max(1, penStyle.width),
            points: <InkPoint>[
              for (
                var pointIndex = 0;
                pointIndex < localStrokes[strokeIndex].length;
                pointIndex++
              )
                InkPoint(
                  x: localStrokes[strokeIndex][pointIndex].dx,
                  y: localStrokes[strokeIndex][pointIndex].dy,
                  timestampMicros:
                      timestamp + strokeIndex * 100000 + pointIndex * 1000,
                ),
            ],
          ),
    ];
    try {
      if (!await handwritingRecognition.isAvailable()) {
        throw const HandwritingRecognitionUnavailable();
      }
      final result = await handwritingRecognition.recognize(
        HandwritingRecognitionRequest(strokes: recognitionStrokes),
      );
      if (!result.isRecognized) {
        if (!_closed) {
          lastError =
              result.message ??
              'Die Korrektur wurde nicht sicher erkannt. Schreiben Sie das Wort bitte erneut.';
          notifyListeners();
        }
        return false;
      }
      if (_closed || page.id != sourcePageId) return false;
      final current = page.objectById(objectId);
      if (current is! TextObject || current.text != source.text) return false;
      final points = localStrokes
          .expand((stroke) => stroke)
          .toList(growable: false);
      final updated = InlineTextEditingEngine.replaceOrInsert(
        current,
        inkPoints: points,
        recognizedText: result.text,
      );
      if (updated == current.text) return false;
      lastError = null;
      final appending = InlineTextEditingEngine.isAppendAtEnd(current, points);
      double? maximumWidth;
      double? minimumWidth;
      if (appending) {
        final candidate = current.copyWith(text: updated);
        final insets = TextObjectLayout.contentInsetsFor(candidate);
        final inkRight = points.fold<double>(
          current.transform.width,
          (maximum, point) => math.max(maximum, point.dx),
        );
        final desired = math.max(
          inkRight + insets.right,
          TextObjectLayout.preferredWidth(candidate),
        );
        final available = math.max(
          TextObjectLayout.minimumWidth,
          viewport.worldBounds.right - current.transform.x,
        );
        maximumWidth = math.min(available, desired);
        minimumWidth = math.min(current.transform.width, maximumWidth);
      }
      return updateTextObject(
        objectId: current.id,
        text: updated,
        maximumWidth: maximumWidth,
        minimumWidth: minimumWidth,
      );
    } catch (error) {
      if (!_closed) {
        lastError = 'Textkorrektur fehlgeschlagen: $error';
        notifyListeners();
      }
      return false;
    }
  }

  void clearPage({required bool handwritingOnly}) {
    execute(
      ClearPageCommand(
        page.id,
        scope: handwritingOnly
            ? ClearPageScope.handwriting
            : ClearPageScope.all,
      ),
    );
    clearSelection();
  }

  void addPage() {
    if (!_allowNavigation()) return;
    if (document.pages.length >= WhiteboardDocument.maxPageCount) {
      lastError =
          'Maximal ${WhiteboardDocument.maxPageCount} Seiten sind möglich.';
      notifyListeners();
      return;
    }
    final newPage = BoardPage.empty(
      id: _uuid.v4(),
      name: 'Seite ${document.pages.length + 1}',
    );
    final added = execute(
      AddPageCommand(
        newPage,
        insertAt: _followsDocumentNavigation ? null : currentPageIndex + 1,
        selectNewPage: _followsDocumentNavigation,
      ),
    );
    if (!added) return;
    _activePageId = newPage.id;
    _afterPageChanged();
  }

  /// Deletes [pageId] through the shared command history.
  ///
  /// Participant views keep their own navigation state. When an independent
  /// participant deletes the page they are currently viewing, select the
  /// nearest surviving page *before* publishing the document mutation. This
  /// prevents the synchronous history notification from briefly falling back
  /// to the document owner's globally selected page.
  bool deletePage(String pageId) {
    if (!_allowNavigation()) return false;
    final pages = document.pages;
    if (pages.length <= 1) {
      lastError = 'Die letzte verbleibende Seite kann nicht gelöscht werden.';
      notifyListeners();
      return false;
    }
    final deleteIndex = document.pageIndexById(pageId);
    if (deleteIndex == null) {
      lastError = 'Die ausgewählte Seite existiert nicht mehr.';
      notifyListeners();
      return false;
    }

    final previousActivePageId = page.id;
    final deletesActivePage = previousActivePageId == pageId;
    if (deletesActivePage) {
      commitViewport();
      if (!_followsDocumentNavigation) {
        final replacementOldIndex = deleteIndex < pages.length - 1
            ? deleteIndex + 1
            : deleteIndex - 1;
        _activePageId = pages[replacementOldIndex].id;
      }
    }

    final deleted = execute(RemovePageCommand(pageId));
    if (!deleted) {
      _activePageId = previousActivePageId;
      return false;
    }
    if (deletesActivePage && !_followsDocumentNavigation) {
      _afterPageChanged();
    }
    return true;
  }

  void addTemplate(TemplateKind kind) {
    if (!_allowNavigation()) return;
    if (document.pages.length >= WhiteboardDocument.maxPageCount) return;
    final newPage = templateFactory.createPage(
      kind,
      pageNumber: document.pages.length + 1,
    );
    final added = execute(
      AddPageCommand(
        newPage,
        insertAt: _followsDocumentNavigation ? null : currentPageIndex + 1,
        selectNewPage: _followsDocumentNavigation,
      ),
    );
    if (!added) return;
    _activePageId = newPage.id;
    _afterPageChanged();
  }

  Future<void> addUserTemplate(
    UserTemplateStore store,
    UserTemplate template,
  ) async {
    if (!_allowNavigation()) {
      throw StateError(
        lastError ?? 'Die Vorlage kann gerade nicht eingefügt werden.',
      );
    }
    if (document.pages.length >= WhiteboardDocument.maxPageCount) {
      final message =
          'Maximal ${WhiteboardDocument.maxPageCount} Seiten sind möglich.';
      lastError = message;
      notifyListeners();
      throw StateError(message);
    }
    final targetPageId = _uuid.v4();
    final targetPageName =
        'Seite ${document.pages.length + 1} · ${template.name}';
    UserTemplateMaterialization? materialization;
    var committed = false;
    try {
      materialization = await store.materialize(
        templateId: template.id,
        targetAssetDirectory: assetDirectory,
        existingDocumentAssetIds: document.assets.map((asset) => asset.id),
        pageId: targetPageId,
        pageName: targetPageName,
      );
      if (_closed) {
        throw StateError('Der Editor wurde während des Einfügens geschlossen.');
      }
      if (document.pages.length >= WhiteboardDocument.maxPageCount) {
        throw StateError(
          'Maximal ${WhiteboardDocument.maxPageCount} Seiten sind möglich.',
        );
      }
      lastError = null;
      final hydratedPage = _upgradePersistedTextFramesInPage(
        materialization.page,
      ).page;
      history.execute(
        AddTemplatePageCommand(
          page: hydratedPage,
          assets: materialization.assets,
          insertAt: _followsDocumentNavigation ? null : currentPageIndex + 1,
          selectNewPage: _followsDocumentNavigation,
        ),
        ownerId: _historyOwnerId,
      );
      committed = true;
      _activePageId = hydratedPage.id;
      _afterPageChanged();
    } catch (error) {
      if (!committed) await materialization?.rollbackFiles();
      lastError = 'Nutzervorlage konnte nicht eingefügt werden: $error';
      notifyListeners();
      rethrow;
    }
  }

  void goToPage(int index) {
    if (index < 0 ||
        index >= document.pages.length ||
        index == currentPageIndex) {
      return;
    }
    if (!_allowNavigation()) return;
    commitViewport();
    final targetPageId = document.pages[index].id;
    if (_followsDocumentNavigation) {
      executeUntracked(SelectPageCommand(targetPageId));
    }
    _activePageId = targetPageId;
    _afterPageChanged();
  }

  /// Aligns an independent participant view with another view of the same
  /// durable document without changing the document's global page selection.
  ///
  /// Entering two-person mode uses this so both halves begin on the page and
  /// camera that were visible in solo mode. Subsequent navigation remains
  /// independent again.
  void synchronizeParticipantViewFrom(EditorController source) {
    if (identical(this, source)) return;
    if (!identical(history, source.history)) {
      throw ArgumentError(
        'Teilnehmeransichten müssen dieselbe Dokumenthistorie verwenden.',
      );
    }
    final target = document.pageById(source.page.id);
    if (target == null) {
      throw StateError('Die sichtbare Quellseite existiert nicht mehr.');
    }
    _activePageId = target.id;
    _localViewports[target.id] = ViewportState(
      offsetX: source.viewport.offset.dx,
      offsetY: source.viewport.offset.dy,
      zoom: source.viewport.scale,
    ).normalized();
    _afterPageChanged();
  }

  void nextPage() {
    final count = document.pages.length;
    if (count < 2) return;
    goToPage((currentPageIndex + 1) % count);
  }

  void previousPage() {
    final count = document.pages.length;
    if (count < 2) return;
    goToPage((currentPageIndex - 1) % count);
  }

  void commitViewport() {
    if (!_followsDocumentNavigation) {
      _localViewports[page.id] = ViewportState(
        offsetX: viewport.offset.dx,
        offsetY: viewport.offset.dy,
        zoom: viewport.scale,
      ).normalized();
      return;
    }
    final persisted = page.viewport;
    if ((persisted.offsetX - viewport.offset.dx).abs() < .01 &&
        (persisted.offsetY - viewport.offset.dy).abs() < .01 &&
        (persisted.zoom - viewport.scale).abs() < .0001) {
      return;
    }
    executeUntracked(
      UpdateViewportCommand(
        page.id,
        ViewportState(
          offsetX: viewport.offset.dx,
          offsetY: viewport.offset.dy,
          zoom: viewport.scale,
        ),
      ),
    );
  }

  /// Drops an in-progress pan/zoom preview without creating document history.
  /// This is used when a higher-priority global gesture claims the pointers
  /// after the board has already seen their first movement.
  void cancelViewportPreview() {
    final persisted = _followsDocumentNavigation
        ? page.viewport
        : _localViewports[page.id] ?? page.viewport;
    viewport.restore(
      scale: persisted.zoom,
      offset: Offset(persisted.offsetX, persisted.offsetY),
    );
  }

  void addShape(ShapeKind kind, Rect bounds) {
    final clipped = bounds.intersect(viewport.worldBounds);
    if (clipped.width < 2 || clipped.height < 2) return;
    final objectId = _uuid.v4();
    execute(
      AddObjectCommand(
        page.id,
        ShapeObject(
          id: objectId,
          transform: ObjectTransform(
            x: clipped.left,
            y: clipped.top,
            width: clipped.width,
            height: clipped.height,
          ),
          shape: kind,
          strokeArgb: 0xFF263238,
          strokeWidth: 4,
        ),
      ),
    );
    _selectInsertedObject(objectId);
  }

  void addTable({required int rows, required int columns, Offset? at}) {
    final origin = at ?? viewport.screenToWorld(const Offset(460, 260));
    final objectId = _uuid.v4();
    execute(
      AddObjectCommand(
        page.id,
        TableObject(
          id: objectId,
          transform: ObjectTransform(
            x: origin.dx,
            y: origin.dy,
            width: 640,
            height: 360,
          ),
          rows: rows.clamp(1, 24),
          columns: columns.clamp(1, 24),
          gridColorArgb: 0xFF607078,
        ),
      ),
    );
    _selectInsertedObject(objectId);
  }

  void addCover({
    Offset? at,
    RevealDirection direction = RevealDirection.leftToRight,
  }) {
    final origin = at ?? viewport.screenToWorld(const Offset(520, 300));
    final objectId = _uuid.v4();
    execute(
      AddObjectCommand(
        page.id,
        CoverObject(
          id: objectId,
          transform: ObjectTransform(
            x: origin.dx,
            y: origin.dy,
            width: 600,
            height: 360,
          ),
          direction: direction,
        ),
      ),
    );
    if (page.objectById(objectId) == null) return;

    _selectInsertedObject(objectId);
  }

  void previewCoverReveal(String objectId, double reveal) {
    if (!reveal.isFinite) return;
    final normalized = reveal.clamp(0.0, 1.0);
    if (_coverRevealPreviews[objectId] == normalized) return;
    _coverRevealPreviews[objectId] = normalized;
    _coverPreviewVersion++;
    notifyListeners();
  }

  void commitCoverReveal(String objectId, double reveal) {
    if (_coverRevealPreviews.remove(objectId) != null) {
      _coverPreviewVersion++;
    }
    final current = page.objectById(objectId);
    if (current is! CoverObject) {
      notifyListeners();
      return;
    }
    final normalized = reveal.clamp(0.0, 1.0);
    if ((current.reveal - normalized).abs() < .0001) {
      notifyListeners();
      return;
    }
    final objects = page.objects.map((object) {
      return object is CoverObject && object.id == objectId
          ? object.copyWithReveal(normalized)
          : object;
    }).toList();
    execute(ReplacePageCommand(page.copyWith(objects: objects)));
  }

  void cancelCoverReveal(String objectId) {
    if (_coverRevealPreviews.remove(objectId) != null) {
      _coverPreviewVersion++;
      notifyListeners();
    }
  }

  void setPdfActivePage(String objectId, int activePageIndex) {
    final current = page.objectById(objectId);
    if (current is! PdfObject) return;
    final nextPdf = current.copyWithActivePage(activePageIndex);
    if (nextPdf.activePageIndex == current.activePageIndex) return;
    final objects = page.objects
        .map((object) => object.id == objectId ? nextPdf : object)
        .toList(growable: false);
    execute(ReplacePageCommand(page.copyWith(objects: objects)));
  }

  Future<void> importImage(
    String sourcePath, {
    String mimeType = 'image/jpeg',
    Offset? at,
  }) async {
    final sourceDocumentId = document.id;
    final targetPageId = page.id;
    final origin = at ?? viewport.screenToWorld(const Offset(480, 240));
    final store = DocumentAssetStore(repository);
    // Validate before copying. Besides rejecting decompression bombs early,
    // this guarantees a failed probe cannot leave an orphaned asset behind.
    final intrinsicSize = await ImportedImageLayout.dimensionsFromFile(
      sourcePath,
    );
    final objectSize = ImportedImageLayout.boardSizeFor(intrinsicSize);
    final asset = await store.importFile(
      documentId: sourceDocumentId,
      sourcePath: sourcePath,
      type: DocumentAssetType.image,
      mimeType: mimeType,
    );
    if (!_canCommitImportedAsset(sourceDocumentId, targetPageId)) {
      await _rollbackImportedAsset(store, sourceDocumentId, asset);
      if (!_closed) {
        throw StateError('Die Zielseite des Bildimports existiert nicht mehr.');
      }
      return;
    }
    final objectId = _uuid.v4();
    final committed = execute(
      ImportObjectCommand(
        pageId: targetPageId,
        asset: asset,
        object: ImageObject(
          id: objectId,
          transform: ObjectTransform(
            x: origin.dx,
            y: origin.dy,
            width: objectSize.width,
            height: objectSize.height,
          ),
          assetId: asset.id,
          originalFileName: asset.originalFileName,
        ),
      ),
    );
    if (!committed) {
      await _rollbackImportedAsset(store, sourceDocumentId, asset);
      return;
    }
    if (page.id == targetPageId) _selectInsertedObject(objectId);
  }

  Future<void> importImageBytes(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
    Offset? at,
  }) async {
    final sourceDocumentId = document.id;
    final targetPageId = page.id;
    final origin = at ?? viewport.screenToWorld(const Offset(480, 240));
    final store = DocumentAssetStore(repository);
    // The header/descriptor probe must finish before materialising the asset;
    // otherwise a rejected decompression bomb would remain on disk.
    final intrinsicSize = await ImportedImageLayout.dimensionsFromBytes(bytes);
    final objectSize = ImportedImageLayout.boardSizeFor(intrinsicSize);
    final asset = await store.importBytes(
      documentId: sourceDocumentId,
      bytes: bytes,
      fileName: fileName,
      type: DocumentAssetType.image,
      mimeType: mimeType,
    );
    if (!_canCommitImportedAsset(sourceDocumentId, targetPageId)) {
      await _rollbackImportedAsset(store, sourceDocumentId, asset);
      if (!_closed) {
        throw StateError('Die Zielseite des Bildimports existiert nicht mehr.');
      }
      return;
    }
    final objectId = _uuid.v4();
    final committed = execute(
      ImportObjectCommand(
        pageId: targetPageId,
        asset: asset,
        object: ImageObject(
          id: objectId,
          transform: ObjectTransform(
            x: origin.dx,
            y: origin.dy,
            width: objectSize.width,
            height: objectSize.height,
          ),
          assetId: asset.id,
          originalFileName: asset.originalFileName,
        ),
      ),
    );
    if (!committed) {
      await _rollbackImportedAsset(store, sourceDocumentId, asset);
      return;
    }
    if (page.id == targetPageId) _selectInsertedObject(objectId);
  }

  Future<void> importPdf(
    String sourcePath, {
    PdfImportMode mode = PdfImportMode.wholeDocument,
    PdfPlacementMode placement = PdfPlacementMode.bundledObject,
    List<int> pageIndices = const [0],
    Offset? at,
  }) async {
    final selectedPages =
        pageIndices.where((index) => index >= 0).toSet().toList(growable: false)
          ..sort();
    if (selectedPages.isEmpty) {
      throw ArgumentError.value(
        pageIndices,
        'pageIndices',
        'Mindestens eine PDF-Seite muss ausgewählt sein.',
      );
    }
    final sourceDocumentId = document.id;
    final targetPageId = page.id;
    final origin = at ?? viewport.screenToWorld(const Offset(520, 180));
    final importWorldBounds = viewport.worldBounds;
    final pagesToCreate = placement == PdfPlacementMode.newWhiteboardPages
        ? selectedPages.length
        : 0;
    if (document.pages.length + pagesToCreate >
        WhiteboardDocument.maxPageCount) {
      throw StateError(
        'Der Import würde das Limit von '
        '${WhiteboardDocument.maxPageCount} Seiten überschreiten.',
      );
    }
    final store = DocumentAssetStore(repository);
    final asset = await store.importFile(
      documentId: sourceDocumentId,
      sourcePath: sourcePath,
      type: DocumentAssetType.pdf,
      mimeType: 'application/pdf',
    );
    final targetStillExists = _canCommitImportedAsset(
      sourceDocumentId,
      targetPageId,
    );
    final capacityStillAvailable =
        document.pages.length + pagesToCreate <=
        WhiteboardDocument.maxPageCount;
    if (!targetStillExists || !capacityStillAvailable) {
      await _rollbackImportedAsset(store, sourceDocumentId, asset);
      if (!_closed) {
        throw StateError(
          targetStillExists
              ? 'Während des Imports wurde das Seitenlimit erreicht.'
              : 'Die Zielseite des PDF-Imports existiert nicht mehr.',
        );
      }
      return;
    }
    final currentPageObjects = <PdfObject>[];
    final newPages = <BoardPage>[];
    switch (placement) {
      case PdfPlacementMode.bundledObject:
        currentPageObjects.add(
          _pdfObject(
            asset: asset,
            pageIndices: selectedPages,
            mode: mode,
            placement: placement,
            x: origin.dx,
            y: origin.dy,
          ),
        );
      case PdfPlacementMode.separateObjects:
        final layout = _layoutSeparatePdfObjects(
          count: selectedPages.length,
          preferredOrigin: origin,
          worldBounds: importWorldBounds,
        );
        for (var index = 0; index < selectedPages.length; index++) {
          currentPageObjects.add(
            _pdfObject(
              asset: asset,
              pageIndices: <int>[selectedPages[index]],
              mode: PdfImportMode.singlePage,
              placement: placement,
              x:
                  layout.start.dx +
                  (index % layout.columns) * (layout.width + layout.gap),
              y:
                  layout.start.dy +
                  (index ~/ layout.columns) * (layout.height + layout.gap),
              width: layout.width,
              height: layout.height,
            ),
          );
        }
      case PdfPlacementMode.newWhiteboardPages:
        for (final sourcePage in selectedPages) {
          final pageNumber = sourcePage + 1;
          newPages.add(
            BoardPage(
              id: _uuid.v4(),
              name: 'PDF-Seite $pageNumber',
              objects: <BoardObject>[
                _pdfObject(
                  asset: asset,
                  pageIndices: <int>[sourcePage],
                  mode: PdfImportMode.singlePage,
                  placement: placement,
                  x: 650,
                  y: 110,
                  width: 620,
                  height: 800,
                ),
              ],
            ),
          );
        }
    }
    final activateLastImportedPage =
        placement == PdfPlacementMode.newWhiteboardPages &&
        page.id == targetPageId &&
        !inkSessions.isWriting;
    final committed = execute(
      ImportPdfContentCommand(
        asset: asset,
        currentPageId: targetPageId,
        currentPageObjects: currentPageObjects,
        newPages: newPages,
        activateLastImportedPage: activateLastImportedPage,
      ),
    );
    if (!committed) {
      await _rollbackImportedAsset(store, sourceDocumentId, asset);
      throw StateError(
        lastError == null
            ? 'Der PDF-Inhalt konnte nicht in das Dokument eingefügt werden.'
            : 'Der PDF-Inhalt konnte nicht eingefügt werden: $lastError',
      );
    }
    final importedContentIsActive = switch (placement) {
      PdfPlacementMode.bundledObject ||
      PdfPlacementMode.separateObjects => page.id == targetPageId,
      PdfPlacementMode.newWhiteboardPages => activateLastImportedPage,
    };
    if (!importedContentIsActive) {
      // The import completed on its captured background page. Preserve the
      // user's current tool, selection, and any in-flight ink on the page
      // where they continued working.
      return;
    }
    tool = BoardTool.selectRectangle;
    _selectionTransformPreview = null;
    _selectedIds = switch (placement) {
      PdfPlacementMode.bundledObject || PdfPlacementMode.separateObjects =>
        currentPageObjects.map((object) => object.id).toSet(),
      PdfPlacementMode.newWhiteboardPages =>
        newPages.isEmpty
            ? <String>{}
            : newPages.last.objects.map((object) => object.id).toSet(),
    };
    _returnToInkWhenInsertedSelectionClears = _selectedIds.isNotEmpty;
    notifyListeners();
  }

  PdfObject _pdfObject({
    required DocumentAsset asset,
    required List<int> pageIndices,
    required PdfImportMode mode,
    required PdfPlacementMode placement,
    required double x,
    required double y,
    double width = 620,
    double height = 800,
  }) => PdfObject(
    id: _uuid.v4(),
    transform: ObjectTransform(x: x, y: y, width: width, height: height),
    assetId: asset.id,
    pageIndices: pageIndices,
    importMode: mode,
    placementMode: placement,
  );

  ({int columns, double width, double height, double gap, Offset start})
  _layoutSeparatePdfObjects({
    required int count,
    required Offset preferredOrigin,
    required Rect worldBounds,
  }) {
    final safeCount = math.max(1, count);
    const preferredWidth = 500.0;
    const preferredHeight = 650.0;
    const gap = 32.0;
    const margin = 64.0;
    final availableWidth = math.max(1.0, worldBounds.width - margin * 2);
    final availableHeight = math.max(1.0, worldBounds.height - margin * 2);
    var bestColumns = 1;
    var bestScale = 0.0;
    for (var columns = 1; columns <= safeCount; columns++) {
      final rows = (safeCount + columns - 1) ~/ columns;
      final cellWidth = (availableWidth - gap * (columns - 1)) / columns;
      final cellHeight = (availableHeight - gap * (rows - 1)) / rows;
      if (cellWidth <= 0 || cellHeight <= 0) continue;
      final scale = math.min(
        1.0,
        math.min(cellWidth / preferredWidth, cellHeight / preferredHeight),
      );
      if (scale > bestScale) {
        bestScale = scale;
        bestColumns = columns;
      }
    }
    final safeScale = bestScale.clamp(.05, 1.0);
    final width = preferredWidth * safeScale;
    final height = preferredHeight * safeScale;
    final rows = (safeCount + bestColumns - 1) ~/ bestColumns;
    final gridWidth = bestColumns * width + (bestColumns - 1) * gap;
    final gridHeight = rows * height + (rows - 1) * gap;
    final minimumX = worldBounds.left + margin;
    final minimumY = worldBounds.top + margin;
    final maximumX = math.max(minimumX, worldBounds.right - margin - gridWidth);
    final maximumY = math.max(
      minimumY,
      worldBounds.bottom - margin - gridHeight,
    );
    return (
      columns: bestColumns,
      width: width,
      height: height,
      gap: gap,
      start: Offset(
        preferredOrigin.dx.clamp(minimumX, maximumX),
        preferredOrigin.dy.clamp(minimumY, maximumY),
      ),
    );
  }

  void rename(String title) {
    final normalized = title.trim();
    if (normalized.isEmpty || normalized == document.title) return;
    execute(
      ReplaceDocumentCommand(
        document.copyWith(title: normalized),
        'Dokument umbenennen',
      ),
    );
  }

  void undo() {
    if (!_allowNavigation()) return;
    try {
      lastError = null;
      final previousPageId = page.id;
      history.undo(ownerId: _historyOwnerId);
      _repairTransientState(previousPageId);
    } catch (error) {
      lastError = 'Rückgängig fehlgeschlagen: $error';
      notifyListeners();
    }
  }

  void redo() {
    if (!_allowNavigation()) return;
    try {
      lastError = null;
      final previousPageId = page.id;
      history.redo(ownerId: _historyOwnerId);
      _repairTransientState(previousPageId);
    } catch (error) {
      lastError = 'Wiederholen fehlgeschlagen: $error';
      notifyListeners();
    }
  }

  bool execute(DocumentCommand command) {
    try {
      lastError = null;
      history.execute(command, ownerId: _historyOwnerId);
      return true;
    } catch (error) {
      lastError = error.toString();
      notifyListeners();
      return false;
    }
  }

  void executeUntracked(DocumentCommand command) {
    try {
      lastError = null;
      history.executeUntracked(command);
    } catch (error) {
      lastError = error.toString();
      notifyListeners();
    }
  }

  Future<void> flush() async {
    _persistSettings();
    if (document.metadata.recoveredFromCrash) {
      executeUntracked(
        ReplaceDocumentCommand(
          document.copyWith(
            metadata: document.metadata.copyWith(recoveredFromCrash: false),
          ),
          'Wiederherstellung bestätigen',
        ),
      );
    }
    saving = true;
    notifyListeners();
    try {
      await autosave.flush();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (var index = 0; index < _autosaveInkPointers.length; index++) {
      autosave.endInteraction();
    }
    _autosaveInkPointers.clear();
    _settingsPersistenceTimer?.cancel();
    if (_ownsDocumentSession) _persistSettings();
    await _historySubscription.cancel();
    await _saveErrorSubscription?.cancel();
    if (_ownsDocumentSession) {
      await autosave.dispose();
      await history.dispose();
      selectionEngine.clearCaches();
    }
  }

  @override
  void dispose() {
    _notifierDisposed = true;
    _settingsPersistenceTimer?.cancel();
    viewport.dispose();
    inkSessions.dispose();
    if (!_closed) {
      unawaited(
        close().catchError((Object error, StackTrace stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'Flowboard editor shutdown',
            ),
          );
        }),
      );
    }
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_notifierDisposed) super.notifyListeners();
  }

  void _onDocumentChanged(WhiteboardDocument value) {
    if (_ownsDocumentSession) autosave.schedule(value);
    final previousActivePageId = _activePageId;
    final previousPageIndex = _resolvedPageIndex;
    final activePageWasRemoved = value.pageById(previousActivePageId) == null;
    if (_followsDocumentNavigation) {
      _activePageId = value.currentPage.id;
    } else {
      final hint = previousPageIndex;
      final activePageStillPresent =
          hint >= 0 &&
          hint < value.pages.length &&
          value.pages[hint].id == _activePageId;
      if (!activePageStillPresent && activePageWasRemoved) {
        // Keep the participant at the same local slot where possible: after
        // deleting page N this shows the former page N+1, or the previous page
        // when the removed page was last. Falling back to currentPage would
        // leak the other participant's navigation into this half.
        final fallbackIndex = previousPageIndex < 0
            ? value.currentPageIndex
            : previousPageIndex.clamp(0, value.pages.length - 1);
        _activePageId = value.pages[fallbackIndex].id;
      }
    }
    if (_pendingEraseSweeps.isNotEmpty && _pendingErasePageId == page.id) {
      final currentPage = page;
      final freeInkChanged =
          _pendingFreeEraseSourceIds.isNotEmpty &&
          !_eraseSourcesAreUnchangedOrAppended(currentPage);
      final annotationInkChanged =
          _pendingAnnotationEraseSourceIds.isNotEmpty &&
          !_annotationEraseIndex.referencesSameSources(currentPage);
      if (freeInkChanged || annotationInkChanged) {
        // A concurrent partial erase/replacement must be reflected immediately
        // so both participants see the same gaps. This replay is intentionally
        // limited to destructive source changes: replaying every accumulated
        // sweep for ordinary appended ink made long concurrent gestures grow
        // quadratically.
        _rebuildPendingErasePreview();
      } else {
        // Appended ink did not exist when an earlier sweep passed and therefore
        // must not be erased retroactively. Extending the spatial index here
        // still makes it available to the participant's next sweep.
        if (_pendingFreeEraseSourceIds.isNotEmpty) {
          _synchronizeEraseIndex(currentPage);
        }
        _pendingEraseRevision = value.revision;
      }
    }
    _removeInvalidSelectionIds();
    if (activePageWasRemoved) {
      _afterPageChanged();
      return;
    }
    notifyListeners();
  }

  bool _eraseSourcesAreUnchangedOrAppended(BoardPage currentPage) {
    if (_eraseIndexedPageId != currentPage.id) return false;
    final previous = _eraseIndexedStrokes;
    final next = currentPage.strokes;
    if (identical(previous, next)) return true;
    final appendList = next is SingleAppendSceneList<InkStroke>
        ? next as SingleAppendSceneList<InkStroke>
        : null;
    return previous != null &&
        appendList != null &&
        appendList.isSingleAppendOf(previous);
  }

  void _afterPageChanged({bool restoreViewport = true}) {
    if (_coverRevealPreviews.isNotEmpty) {
      _coverRevealPreviews.clear();
      _coverPreviewVersion++;
    }
    _clearPendingErase();
    _selectionTransformPreview = null;
    _selectionInteractionOwner = null;
    _eraseIndexedStrokes = null;
    _eraseIndexedPageId = null;
    _eraseIndexedStrokePositions.clear();
    _eraseIndex.clear();
    _annotationEraseIndex.clear();
    _debugLastEraseStrokeCandidateCount = 0;
    _debugLastEraseAnnotationCandidateCount = 0;
    _selectedIds = _filterSelectionForContentPartition(
      page.selection.selectedItemIds,
    );
    _returnToInkWhenInsertedSelectionClears = false;
    if (restoreViewport) {
      final persisted = _followsDocumentNavigation
          ? page.viewport
          : _localViewports[page.id] ?? page.viewport;
      viewport.restore(
        scale: persisted.zoom,
        offset: Offset(persisted.offsetX, persisted.offsetY),
      );
    }
    notifyListeners();
  }

  void _repairTransientState(String previousPageId) {
    _removeInvalidSelectionIds();
    // Content-only Undo/Redo must never move a participant's independent
    // camera. Restoring the stale pre-split viewport here exposed the other
    // half for one frame until BoardSurface's post-frame clamp ran.
    _afterPageChanged(restoreViewport: page.id != previousPageId);
  }

  void _removeInvalidSelectionIds() {
    if (_selectedIds.isEmpty) return;
    final retained = selectionEngine.retainExistingIds(page, _selectedIds);
    if (retained.length != _selectedIds.length) _selectedIds = retained;
  }

  void _rebaseSelectionAfterErase(
    Set<String> selectionBefore,
    Map<String, List<String>> selectedContentGroups,
  ) {
    final sceneItemIds = <String>{
      ...page.strokes.map((stroke) => stroke.id),
      ...page.objects.map((object) => object.id),
    };
    final validSelectionIds = <String>{
      ...sceneItemIds,
      ...page.groups.map((group) => group.id),
      ...page.contentGroups.map((group) => group.id),
    };
    final rebased = <String>{};
    for (final selectedId in selectionBefore) {
      if (validSelectionIds.contains(selectedId)) {
        rebased.add(selectedId);
        continue;
      }
      // A persistent group with fewer than two surviving members is dissolved
      // by DeleteItemsCommand. Keep its remaining content selected rather than
      // retaining a dead group id or unexpectedly dropping the selection.
      final formerMembers = selectedContentGroups[selectedId];
      if (formerMembers != null) {
        rebased.addAll(formerMembers.where(sceneItemIds.contains));
      }
    }
    final partitioned = _filterSelectionForContentPartition(rebased);
    if (setEquals(_selectedIds, partitioned)) return;
    _selectedIds = partitioned;
    _selectionTransformPreview = null;
    if (_selectedIds.isEmpty) _returnToInkWhenInsertedSelectionClears = false;
    notifyListeners();
  }

  bool _allowNavigation() {
    if (!inkSessions.isWriting) return true;
    lastError =
        'Seitenwechsel und Undo sind erst nach dem aktuellen Stiftzug möglich.';
    notifyListeners();
    return false;
  }

  void _scheduleSettingsPersistence() {
    _settingsPersistenceTimer?.cancel();
    _settingsPersistenceTimer = Timer(
      const Duration(milliseconds: 450),
      _persistSettings,
    );
  }

  void _activateConfiguredInkTool({
    required bool clearSelection,
    bool notify = true,
  }) {
    tool = switch (penStyle.type) {
      InkToolType.normal => BoardTool.pen,
      InkToolType.marker => BoardTool.marker,
      InkToolType.dashed => BoardTool.dashedPen,
      InkToolType.straightLine => BoardTool.straightLine,
    };
    if (clearSelection) {
      _selectedIds = <String>{};
      _selectionTransformPreview = null;
      _returnToInkWhenInsertedSelectionClears = false;
    }
    _scheduleSettingsPersistence();
    if (notify) notifyListeners();
  }

  /// Leaves a transient insert mode without changing the configured pen
  /// preset. Dialog cancellation must never leave the rectangle tool armed.
  void resumeConfiguredInkTool({bool clearSelection = true}) =>
      _activateConfiguredInkTool(clearSelection: clearSelection);

  void _selectInsertedObject(String objectId) {
    if (page.objectById(objectId) == null) return;
    tool = BoardTool.selectRectangle;
    _selectedIds = <String>{objectId};
    _selectionTransformPreview = null;
    _returnToInkWhenInsertedSelectionClears = true;
    notifyListeners();
  }

  bool _canCommitImportedAsset(String documentId, String targetPageId) =>
      !_closed &&
      document.id == documentId &&
      document.pageById(targetPageId) != null;

  Future<void> _rollbackImportedAsset(
    DocumentAssetStore store,
    String documentId,
    DocumentAsset asset,
  ) async {
    try {
      await store.discardImportedAsset(documentId: documentId, asset: asset);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Flowboard asset import rollback',
          context: ErrorDescription(
            'while deleting an uncommitted ${asset.type.name} asset',
          ),
        ),
      );
    }
  }

  void _persistSettings() {
    _settingsPersistenceTimer?.cancel();
    _settingsPersistenceTimer = null;
    final current = document;
    final presets = current.presets
        .map((preset) {
          if (preset.id != current.activePresetId) return preset;
          return PenPreset(
            id: preset.id,
            name: preset.name,
            colorArgb: penStyle.colorArgb,
            width: penStyle.width,
            type: penStyle.type,
          );
        })
        .toList(growable: false);
    final custom = Map<String, String>.from(current.metadata.custom);
    final radial = _pendingRadialPosition;
    if (radial != null) {
      custom['radialMenuX'] = radial.dx.toStringAsFixed(5);
      custom['radialMenuY'] = radial.dy.toStringAsFixed(5);
      _pendingRadialPosition = null;
    }
    final active = current.activePreset;
    final presetChanged =
        active.colorArgb != penStyle.colorArgb ||
        active.width != penStyle.width ||
        active.type != penStyle.type;
    final metadataChanged =
        custom.length != current.metadata.custom.length ||
        custom.entries.any(
          (entry) => current.metadata.custom[entry.key] != entry.value,
        );
    if (!presetChanged && !metadataChanged) return;
    executeUntracked(
      ReplaceDocumentCommand(
        current.copyWith(
          presets: presets,
          metadata: current.metadata.copyWith(custom: custom),
        ),
        'Werkzeugeinstellungen speichern',
      ),
    );
  }

  _AnnotationTarget? _annotationTargetAt(Offset point) {
    final position = Vec2(point.dx, point.dy);
    BoardObject? target;
    for (final object in page.objects) {
      if (object is! ImageObject &&
          object is! PdfObject &&
          object is! TableObject) {
        continue;
      }
      if (!object.transform.containsWorld(position)) continue;
      // Equal legacy z-indices preserve object-list order. Replacing on >=
      // therefore matches the former reverse walk over the fully sorted scene.
      if (target == null || object.zIndex >= target.zIndex) target = object;
    }
    if (target == null) return null;
    return _AnnotationTarget(
      target.id,
      target.transform,
      pdfPageIndex: target is PdfObject ? target.activeSourcePageIndex : null,
    );
  }

  Offset _clampWorldOffset(Offset point) {
    final bounds = viewport.worldBounds;
    return Offset(
      point.dx.clamp(bounds.left, bounds.right),
      point.dy.clamp(bounds.top, bounds.bottom),
    );
  }

  void _synchronizeEraseIndex(BoardPage currentPage) {
    if (_eraseIndexedPageId == currentPage.id &&
        identical(_eraseIndexedStrokes, currentPage.strokes)) {
      return;
    }
    final previous = _eraseIndexedStrokes;
    final next = currentPage.strokes;
    final appendList = next is SingleAppendSceneList<InkStroke>
        ? next as SingleAppendSceneList<InkStroke>
        : null;
    if (_eraseIndexedPageId == currentPage.id &&
        previous != null &&
        appendList != null &&
        appendList.isSingleAppendOf(previous)) {
      final index = next.length - 1;
      final stroke = next[index];
      _eraseIndexedStrokePositions[stroke.id] = index;
      _insertStrokeIntoEraseIndex(stroke);
      _eraseIndexedStrokes = next;
      return;
    }
    _eraseIndex.clear();
    _eraseIndexedStrokePositions.clear();
    for (var index = 0; index < currentPage.strokes.length; index++) {
      final stroke = currentPage.strokes[index];
      _eraseIndexedStrokePositions[stroke.id] = index;
      _insertStrokeIntoEraseIndex(stroke);
    }
    _eraseIndexedPageId = currentPage.id;
    _eraseIndexedStrokes = currentPage.strokes;
    _debugEraseFullIndexBuildCount++;
  }

  void _insertStrokeIntoEraseIndex(InkStroke stroke) =>
      _eraseIndex.insertMappedPolyline<InkPoint>(
        stroke,
        stroke.points,
        xOf: _inkPointX,
        yOf: _inkPointY,
        inflate: math.max(0, stroke.width / 2),
      );

  static bool _strokeTouchesCircle(
    InkStroke stroke,
    Offset center,
    double radius,
  ) {
    if (stroke.points.isEmpty) return false;
    final threshold = radius + stroke.width / 2;
    if (stroke.points.length == 1) {
      final point = stroke.points.first;
      return (Offset(point.x, point.y) - center).distance <= threshold;
    }
    final thresholdSquared = threshold * threshold;
    for (var index = 1; index < stroke.points.length; index++) {
      final first = stroke.points[index - 1];
      final second = stroke.points[index];
      final ax = first.x;
      final ay = first.y;
      final dx = second.x - ax;
      final dy = second.y - ay;
      final lengthSquared = dx * dx + dy * dy;
      final projection = lengthSquared <= 0
          ? 0.0
          : (((center.dx - ax) * dx + (center.dy - ay) * dy) / lengthSquared)
                .clamp(0.0, 1.0);
      final nearestX = ax + projection * dx;
      final nearestY = ay + projection * dy;
      final distanceX = center.dx - nearestX;
      final distanceY = center.dy - nearestY;
      if (distanceX * distanceX + distanceY * distanceY <= thresholdSquared) {
        return true;
      }
    }
    return false;
  }

  static bool _strokeTouchesCapsule(
    InkStroke stroke,
    Offset start,
    Offset end,
    double radius,
  ) {
    if (stroke.points.isEmpty) return false;
    if ((end - start).distanceSquared <= .000001) {
      return _strokeTouchesCircle(stroke, start, radius);
    }
    final strokeRadius = stroke.width.isFinite
        ? math.max(0.0, stroke.width / 2)
        : 0.0;
    final threshold = radius + strokeRadius;
    final thresholdSquared = threshold * threshold;
    if (stroke.points.length == 1) {
      final point = stroke.points.first;
      return _pointToSegmentDistanceSquared(
            Offset(point.x, point.y),
            start,
            end,
          ) <=
          thresholdSquared;
    }
    for (var index = 1; index < stroke.points.length; index++) {
      final first = stroke.points[index - 1];
      final second = stroke.points[index];
      if (_segmentDistanceSquared(
            Offset(first.x, first.y),
            Offset(second.x, second.y),
            start,
            end,
          ) <=
          thresholdSquared) {
        return true;
      }
    }
    return false;
  }

  static bool _annotationStrokeTouchesWorldCapsule(
    InkStroke stroke,
    _AnnotationTarget target,
    Offset start,
    Offset end,
    double radius,
  ) {
    if (stroke.points.isEmpty) return false;
    final localWidth = stroke.width.isFinite ? stroke.width : 0.0;
    final strokeRadius = math.max(0.0, localWidth * target.minimumExtent / 2);
    final threshold = radius + strokeRadius;
    final thresholdSquared = threshold * threshold;
    if (stroke.points.length == 1) {
      return _pointToSegmentDistanceSquared(
            target.pointToWorld(stroke.points.first),
            start,
            end,
          ) <=
          thresholdSquared;
    }
    var previous = target.pointToWorld(stroke.points.first);
    for (var index = 1; index < stroke.points.length; index++) {
      final current = target.pointToWorld(stroke.points[index]);
      if (_segmentDistanceSquared(previous, current, start, end) <=
          thresholdSquared) {
        return true;
      }
      previous = current;
    }
    return false;
  }

  static double _segmentDistanceSquared(
    Offset firstStart,
    Offset firstEnd,
    Offset secondStart,
    Offset secondEnd,
  ) {
    if (_segmentsIntersect(firstStart, firstEnd, secondStart, secondEnd)) {
      return 0;
    }
    return math.min(
      math.min(
        _pointToSegmentDistanceSquared(firstStart, secondStart, secondEnd),
        _pointToSegmentDistanceSquared(firstEnd, secondStart, secondEnd),
      ),
      math.min(
        _pointToSegmentDistanceSquared(secondStart, firstStart, firstEnd),
        _pointToSegmentDistanceSquared(secondEnd, firstStart, firstEnd),
      ),
    );
  }

  static double _pointToSegmentDistanceSquared(
    Offset point,
    Offset start,
    Offset end,
  ) {
    final delta = end - start;
    final lengthSquared = delta.distanceSquared;
    if (lengthSquared <= .000001) return (point - start).distanceSquared;
    final projection =
        ((point - start).dx * delta.dx + (point - start).dy * delta.dy) /
        lengthSquared;
    final nearest = start + delta * projection.clamp(0.0, 1.0);
    return (point - nearest).distanceSquared;
  }

  static bool _segmentsIntersect(
    Offset firstStart,
    Offset firstEnd,
    Offset secondStart,
    Offset secondEnd,
  ) {
    final firstA = _cross(firstStart, firstEnd, secondStart);
    final firstB = _cross(firstStart, firstEnd, secondEnd);
    final secondA = _cross(secondStart, secondEnd, firstStart);
    final secondB = _cross(secondStart, secondEnd, firstEnd);
    const epsilon = .0000001;
    if (((firstA > epsilon && firstB < -epsilon) ||
            (firstA < -epsilon && firstB > epsilon)) &&
        ((secondA > epsilon && secondB < -epsilon) ||
            (secondA < -epsilon && secondB > epsilon))) {
      return true;
    }
    return (firstA.abs() <= epsilon &&
            _withinSegment(secondStart, firstStart, firstEnd)) ||
        (firstB.abs() <= epsilon &&
            _withinSegment(secondEnd, firstStart, firstEnd)) ||
        (secondA.abs() <= epsilon &&
            _withinSegment(firstStart, secondStart, secondEnd)) ||
        (secondB.abs() <= epsilon &&
            _withinSegment(firstEnd, secondStart, secondEnd));
  }

  static double _cross(Offset start, Offset end, Offset point) =>
      (end.dx - start.dx) * (point.dy - start.dy) -
      (end.dy - start.dy) * (point.dx - start.dx);

  static bool _withinSegment(Offset point, Offset start, Offset end) {
    const epsilon = .0000001;
    return point.dx >= math.min(start.dx, end.dx) - epsilon &&
        point.dx <= math.max(start.dx, end.dx) + epsilon &&
        point.dy >= math.min(start.dy, end.dy) - epsilon &&
        point.dy <= math.max(start.dy, end.dy) + epsilon;
  }

  BoardObject _cloneObjectWithId(BoardObject object, String id) =>
      switch (object) {
        final ShapeObject value => ShapeObject(
          id: id,
          transform: value.transform,
          shape: value.shape,
          fillArgb: value.fillArgb,
          strokeArgb: value.strokeArgb,
          strokeWidth: value.strokeWidth,
          zIndex: value.zIndex,
          opacity: value.opacity,
          locked: value.locked,
        ),
        final ImageObject value => ImageObject(
          id: id,
          transform: value.transform,
          assetId: value.assetId,
          originalFileName: value.originalFileName,
          fit: value.fit,
          altText: value.altText,
          zIndex: value.zIndex,
          opacity: value.opacity,
          locked: value.locked,
        ),
        final PdfObject value => PdfObject(
          id: id,
          transform: value.transform,
          assetId: value.assetId,
          pageIndices: value.pageIndices,
          importMode: value.importMode,
          placementMode: value.placementMode,
          activePageIndex: value.activePageIndex,
          zIndex: value.zIndex,
          opacity: value.opacity,
          locked: value.locked,
        ),
        final TableObject value => TableObject(
          id: id,
          transform: value.transform,
          rows: value.rows,
          columns: value.columns,
          cells: value.cells,
          gridColorArgb: value.gridColorArgb,
          gridWidth: value.gridWidth,
          zIndex: value.zIndex,
          opacity: value.opacity,
          locked: value.locked,
        ),
        final CoverObject value => CoverObject(
          id: id,
          transform: value.transform,
          direction: value.direction,
          reveal: value.reveal,
          colorArgb: value.colorArgb,
          zIndex: value.zIndex,
          opacity: value.opacity,
          locked: value.locked,
        ),
        final TextObject value => TextObject(
          id: id,
          transform: value.transform,
          text: value.text,
          fontSize: value.fontSize,
          colorArgb: value.colorArgb,
          bold: value.bold,
          italic: value.italic,
          alignment: value.alignment,
          textLayoutVersion: value.textLayoutVersion,
          sourceStrokeIds: value.sourceStrokeIds,
          zIndex: value.zIndex,
          opacity: value.opacity,
          locked: value.locked,
        ),
      };
}

final class _HandwritingConversionSnapshot {
  const _HandwritingConversionSnapshot({
    required this.pageId,
    required this.documentRevision,
    required this.selectedIds,
    required this.expandedIds,
    required this.sourceStrokesById,
    required this.canonicalStrokes,
  });

  final String pageId;
  final int documentRevision;
  final Set<String> selectedIds;
  final Set<String> expandedIds;
  final Map<String, InkStroke> sourceStrokesById;
  final List<InkStroke> canonicalStrokes;
}

({WhiteboardDocument document, bool changed}) _upgradePersistedTextFrames(
  WhiteboardDocument document,
) {
  var changed = false;
  final pages = document.pages
      .map((page) {
        final hydration = _upgradePersistedTextFramesInPage(page);
        if (hydration.changed) changed = true;
        return hydration.page;
      })
      .toList(growable: false);
  if (!changed) return (document: document, changed: false);
  return (document: document.copyWith(pages: pages), changed: true);
}

({BoardPage page, bool changed}) _upgradePersistedTextFramesInPage(
  BoardPage page,
) {
  var changed = false;
  final objects = page.objects
      .map((object) {
        if (object is! TextObject) return object;
        final upgraded = TextObjectLayout.upgradeLegacyFrame(object);
        if (!identical(upgraded, object)) changed = true;
        return upgraded;
      })
      .toList(growable: false);
  return (
    page: changed ? page.copyWith(objects: objects).sanitized() : page,
    changed: changed,
  );
}

final class _SelectionMembers {
  _SelectionMembers({
    required Iterable<String> expandedIds,
    required Iterable<int> objectIndices,
    required Iterable<BoardObject> objects,
    required Iterable<int> strokeIndices,
    required Iterable<InkStroke> strokes,
    required Iterable<Rect2> selectedGroupBounds,
    required this.selectedContentGroup,
    required this.baseBounds,
  }) : expandedIds = Set<String>.unmodifiable(expandedIds),
       objectIndices = List<int>.unmodifiable(objectIndices),
       objects = List<BoardObject>.unmodifiable(objects),
       strokeIndices = List<int>.unmodifiable(strokeIndices),
       strokes = List<InkStroke>.unmodifiable(strokes),
       selectedGroupBounds = List<Rect2>.unmodifiable(selectedGroupBounds);

  const _SelectionMembers._empty()
    : expandedIds = const <String>{},
      objectIndices = const <int>[],
      objects = const <BoardObject>[],
      strokeIndices = const <int>[],
      strokes = const <InkStroke>[],
      selectedGroupBounds = const <Rect2>[],
      selectedContentGroup = null,
      baseBounds = const Rect2.zero();

  static const _SelectionMembers empty = _SelectionMembers._empty();

  final Set<String> expandedIds;
  final List<int> objectIndices;
  final List<BoardObject> objects;
  final List<int> strokeIndices;
  final List<InkStroke> strokes;
  final List<Rect2> selectedGroupBounds;
  final ContentGroup? selectedContentGroup;
  final Rect2 baseBounds;
}

/// Fixed-length immutable overlay for the few objects changed by a live cover
/// or selection transform. Constructing it is proportional to changed items,
/// while ordinary indexed iteration still follows the page's scene order.
final class _SparseObjectPreviewList extends ListBase<BoardObject>
    implements FixedSceneListOverlay<BoardObject> {
  _SparseObjectPreviewList(this._source, Map<int, BoardObject> replacements)
    : _replacements = Map<int, BoardObject>.unmodifiable(replacements);

  final List<BoardObject> _source;
  final Map<int, BoardObject> _replacements;

  @override
  List<BoardObject> get sceneSource => _source;

  @override
  Map<int, BoardObject> get sceneReplacements => _replacements;

  @override
  int get length => _source.length;

  @override
  set length(int value) =>
      throw UnsupportedError('Object preview lists are immutable.');

  @override
  BoardObject operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _replacements[index] ?? _source[index];
  }

  @override
  void operator []=(int index, BoardObject value) =>
      throw UnsupportedError('Object preview lists are immutable.');

  @override
  Iterator<BoardObject> get iterator => _values().iterator;

  Iterable<BoardObject> _values() sync* {
    for (var index = 0; index < _source.length; index++) {
      yield _replacements[index] ?? _source[index];
    }
  }
}

/// Fixed-length immutable overlay for selected strokes. Unlike the eraser
/// preview it never changes list length, so every replacement keeps its source
/// index and unrelated stroke identities remain available to renderer caches.
final class _SparseStrokeSelectionPreviewList extends ListBase<InkStroke>
    implements FixedSceneListOverlay<InkStroke> {
  _SparseStrokeSelectionPreviewList(
    this._source,
    Map<int, InkStroke> replacements,
  ) : _replacements = Map<int, InkStroke>.unmodifiable(replacements);

  final List<InkStroke> _source;
  final Map<int, InkStroke> _replacements;

  @override
  List<InkStroke> get sceneSource => _source;

  @override
  Map<int, InkStroke> get sceneReplacements => _replacements;

  @override
  int get length => _source.length;

  @override
  set length(int value) =>
      throw UnsupportedError('Selection preview lists are immutable.');

  @override
  InkStroke operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _replacements[index] ?? _source[index];
  }

  @override
  void operator []=(int index, InkStroke value) =>
      throw UnsupportedError('Selection preview lists are immutable.');

  @override
  Iterator<InkStroke> get iterator => _values().iterator;

  Iterable<InkStroke> _values() sync* {
    for (var index = 0; index < _source.length; index++) {
      yield _replacements[index] ?? _source[index];
    }
  }
}

class _AnnotationTarget {
  factory _AnnotationTarget(
    String objectId,
    ObjectTransform transform, {
    int? pdfPageIndex,
  }) {
    final cosine = math.cos(transform.rotationRadians);
    final sine = math.sin(transform.rotationRadians);
    final centerX = transform.x + transform.width / 2;
    final centerY = transform.y + transform.height / 2;
    final baseX = transform.x + (transform.flipX ? transform.width : 0);
    final baseY = transform.y + (transform.flipY ? transform.height : 0);
    final scaleX = transform.flipX ? -transform.width : transform.width;
    final scaleY = transform.flipY ? -transform.height : transform.height;
    return _AnnotationTarget._(
      objectId,
      transform,
      pdfPageIndex,
      cosine,
      sine,
      centerX + (baseX - centerX) * cosine - (baseY - centerY) * sine,
      scaleX * cosine,
      -scaleY * sine,
      centerY + (baseX - centerX) * sine + (baseY - centerY) * cosine,
      scaleX * sine,
      scaleY * cosine,
    );
  }

  const _AnnotationTarget._(
    this.objectId,
    this.transform,
    this.pdfPageIndex,
    this._cosine,
    this._sine,
    this._worldXBase,
    this._worldXX,
    this._worldXY,
    this._worldYBase,
    this._worldYX,
    this._worldYY,
  );

  final String objectId;
  final ObjectTransform transform;
  final int? pdfPageIndex;
  final double _cosine;
  final double _sine;
  final double _worldXBase;
  final double _worldXX;
  final double _worldXY;
  final double _worldYBase;
  final double _worldYX;
  final double _worldYY;

  double get minimumExtent =>
      (transform.width < transform.height ? transform.width : transform.height)
          .clamp(1, double.infinity);

  Offset toLocal(Offset world) {
    final normalized = _worldToNormalized(world.dx, world.dy);
    return Offset(normalized.$1, normalized.$2);
  }

  Offset pointToWorld(InkPoint point) => Offset(
    _worldXBase + _worldXX * point.x + _worldXY * point.y,
    _worldYBase + _worldYX * point.x + _worldYY * point.y,
  );

  double pointWorldX(InkPoint point) =>
      _worldXBase + _worldXX * point.x + _worldXY * point.y;

  double pointWorldY(InkPoint point) =>
      _worldYBase + _worldYX * point.x + _worldYY * point.y;

  InkStroke toLocalStroke(InkStroke stroke) => stroke.copyWith(
    points: stroke.points.map((point) {
      final local = _worldToNormalized(point.x, point.y);
      return InkPoint(
        x: local.$1,
        y: local.$2,
        pressure: point.pressure,
        timestampMicros: point.timestampMicros,
        tiltX: point.tiltX,
        tiltY: point.tiltY,
      );
    }),
    width: stroke.width / minimumExtent,
  );

  (double, double) _worldToNormalized(double worldX, double worldY) {
    final centerX = transform.x + transform.width / 2;
    final centerY = transform.y + transform.height / 2;
    final deltaX = worldX - centerX;
    final deltaY = worldY - centerY;
    final unrotatedX = centerX + deltaX * _cosine + deltaY * _sine;
    final unrotatedY = centerY - deltaX * _sine + deltaY * _cosine;
    final localX = unrotatedX - transform.x;
    final localY = unrotatedY - transform.y;
    return (
      (transform.flipX ? transform.width - localX : localX) / transform.width,
      (transform.flipY ? transform.height - localY : localY) / transform.height,
    );
  }
}

/// Spatially indexes only the annotation strokes that are currently rendered.
///
/// Rebuilding is O(objects + layers + annotation points), but only happens
/// when either immutable source list changes. Pointer moves then query nearby
/// strokes directly instead of performing an O(objects * layers) lookup and
/// scanning every stroke of each intersecting object.
final class _AnnotationEraseIndex {
  final SpatialIndex<_IndexedAnnotationStroke> _spatial =
      SpatialIndex<_IndexedAnnotationStroke>(cellSize: 160);
  final Map<String, ObjectInkLayer> _legacyLayerByObject =
      <String, ObjectInkLayer>{};
  final Map<String, Map<int, ObjectInkLayer>> _pageLayersByObject =
      <String, Map<int, ObjectInkLayer>>{};
  final Map<String, Set<ObjectInkLayer>> _layersByStrokeId =
      <String, Set<ObjectInkLayer>>{};
  final Map<ObjectInkLayer, int> _layerPositions = <ObjectInkLayer, int>{};

  String? _pageId;
  List<BoardObject>? _objects;
  List<ObjectInkLayer>? _layers;

  int get length => _spatial.length;

  bool referencesSameSources(BoardPage page) =>
      _pageId == page.id &&
      identical(_objects, page.objects) &&
      identical(_layers, page.annotationLayers);

  void synchronize(BoardPage page) {
    if (referencesSameSources(page)) {
      return;
    }
    clear();
    _pageId = page.id;
    _objects = page.objects;
    _layers = page.annotationLayers;

    for (var index = 0; index < page.annotationLayers.length; index++) {
      final layer = page.annotationLayers[index];
      _layerPositions[layer] = index;
      for (final stroke in layer.strokes) {
        (_layersByStrokeId[stroke.id] ??= <ObjectInkLayer>{}).add(layer);
      }
      if (!layer.visible) continue;
      final pdfPageIndex = layer.pdfPageIndex;
      if (pdfPageIndex == null) {
        _legacyLayerByObject.putIfAbsent(layer.objectId, () => layer);
      } else {
        (_pageLayersByObject[layer.objectId] ??= <int, ObjectInkLayer>{})
            .putIfAbsent(pdfPageIndex, () => layer);
      }
    }

    for (final object in page.objects) {
      final layer = _visibleLayerFor(object);
      if (layer == null || layer.strokes.isEmpty) continue;
      final target = _AnnotationTarget(
        object.id,
        object.transform,
        pdfPageIndex: object is PdfObject ? object.activeSourcePageIndex : null,
      );
      for (final stroke in layer.strokes) {
        final entry = _IndexedAnnotationStroke(stroke: stroke, target: target);
        final localWidth = stroke.width.isFinite ? stroke.width : 0.0;
        _spatial.insertMappedPolyline<InkPoint>(
          entry,
          stroke.points,
          xOf: target.pointWorldX,
          yOf: target.pointWorldY,
          inflate: math.max(0.0, localWidth * target.minimumExtent / 2),
        );
      }
    }
  }

  Set<_IndexedAnnotationStroke> query(Rect area) => _spatial.query(area);

  Iterable<ObjectInkLayer> layersContainingStroke(String strokeId) =>
      _layersByStrokeId[strokeId] ?? const <ObjectInkLayer>{};

  int? indexOfLayer(ObjectInkLayer layer) => _layerPositions[layer];

  void clear() {
    _spatial.clear();
    _legacyLayerByObject.clear();
    _pageLayersByObject.clear();
    _layersByStrokeId.clear();
    _layerPositions.clear();
    _pageId = null;
    _objects = null;
    _layers = null;
  }

  ObjectInkLayer? _visibleLayerFor(BoardObject object) {
    if (object is PdfObject) {
      final exact =
          _pageLayersByObject[object.id]?[object.activeSourcePageIndex];
      if (exact != null) return exact;
    }
    return _legacyLayerByObject[object.id];
  }
}

final class _IndexedAnnotationStroke {
  const _IndexedAnnotationStroke({required this.stroke, required this.target});

  final InkStroke stroke;
  final _AnnotationTarget target;
}

final class _StrokePreviewPatch {
  const _StrokePreviewPatch({
    required this.sourceIndex,
    required this.replacements,
  });

  final int sourceIndex;
  final List<InkStroke> replacements;
}

final class _ResolvedStrokePreviewPatch {
  const _ResolvedStrokePreviewPatch({
    required this.sourceIndex,
    required this.previewStart,
    required this.deltaAfter,
    required this.replacements,
  });

  final int sourceIndex;
  final int previewStart;
  final int deltaAfter;
  final List<InkStroke> replacements;

  int get previewEnd => previewStart + replacements.length;
}

/// Immutable sparse overlay over the page's stroke list.
///
/// Creating an erase preview is O(changed strokes log changed strokes), not
/// O(all page strokes). Consumers still see a normal [List] in original scene
/// order; full traversal only occurs when a renderer actually consumes it.
final class _SparseStrokePreviewList extends ListBase<InkStroke> {
  factory _SparseStrokePreviewList(
    List<InkStroke> source,
    List<_StrokePreviewPatch> patches,
  ) {
    final sorted = List<_StrokePreviewPatch>.of(
      patches,
    )..sort((first, second) => first.sourceIndex.compareTo(second.sourceIndex));
    final resolved = <_ResolvedStrokePreviewPatch>[];
    var delta = 0;
    for (final patch in sorted) {
      final previewStart = patch.sourceIndex + delta;
      delta += patch.replacements.length - 1;
      resolved.add(
        _ResolvedStrokePreviewPatch(
          sourceIndex: patch.sourceIndex,
          previewStart: previewStart,
          deltaAfter: delta,
          replacements: patch.replacements,
        ),
      );
    }
    return _SparseStrokePreviewList._(
      source,
      List<_ResolvedStrokePreviewPatch>.unmodifiable(resolved),
      source.length + delta,
    );
  }

  const _SparseStrokePreviewList._(this._source, this._patches, this._length);

  final List<InkStroke> _source;
  final List<_ResolvedStrokePreviewPatch> _patches;
  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) =>
      throw UnsupportedError('Erase preview lists are immutable.');

  @override
  InkStroke operator [](int index) {
    RangeError.checkValidIndex(index, this);
    var low = 0;
    var high = _patches.length - 1;
    var candidateIndex = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_patches[middle].previewStart <= index) {
        candidateIndex = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    if (candidateIndex < 0) return _source[index];
    final patch = _patches[candidateIndex];
    if (index < patch.previewEnd) {
      return patch.replacements[index - patch.previewStart];
    }
    return _source[index - patch.deltaAfter];
  }

  @override
  void operator []=(int index, InkStroke value) =>
      throw UnsupportedError('Erase preview lists are immutable.');

  @override
  Iterator<InkStroke> get iterator => _values().iterator;

  Iterable<InkStroke> _values() sync* {
    var patchIndex = 0;
    for (var sourceIndex = 0; sourceIndex < _source.length; sourceIndex++) {
      if (patchIndex < _patches.length &&
          _patches[patchIndex].sourceIndex == sourceIndex) {
        yield* _patches[patchIndex].replacements;
        patchIndex++;
      } else {
        yield _source[sourceIndex];
      }
    }
  }
}

/// Fixed-length sparse overlay for the few annotation layers changed by one
/// eraser gesture. It avoids copying every unrelated layer on every MOVE.
final class _SparseAnnotationLayerPreviewList extends ListBase<ObjectInkLayer> {
  _SparseAnnotationLayerPreviewList(
    this._source,
    Map<int, ObjectInkLayer> replacements,
  ) : _replacements = Map<int, ObjectInkLayer>.unmodifiable(replacements);

  final List<ObjectInkLayer> _source;
  final Map<int, ObjectInkLayer> _replacements;

  @override
  int get length => _source.length;

  @override
  set length(int value) =>
      throw UnsupportedError('Erase preview lists are immutable.');

  @override
  ObjectInkLayer operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _replacements[index] ?? _source[index];
  }

  @override
  void operator []=(int index, ObjectInkLayer value) =>
      throw UnsupportedError('Erase preview lists are immutable.');

  @override
  Iterator<ObjectInkLayer> get iterator => _values().iterator;

  Iterable<ObjectInkLayer> _values() sync* {
    for (var index = 0; index < _source.length; index++) {
      yield _replacements[index] ?? _source[index];
    }
  }
}

final class _PendingEraseSweep {
  _PendingEraseSweep({
    required this.start,
    required this.end,
    required this.radius,
    this.eraseMinimumX,
    this.eraseMaximumX,
  });

  final Offset start;
  final Offset end;
  final double radius;
  final double? eraseMinimumX;
  final double? eraseMaximumX;
  Set<String>? sourceIds;
}

double _inkPointX(InkPoint point) => point.x;
double _inkPointY(InkPoint point) => point.y;

class _ClipboardPayload {
  const _ClipboardPayload({
    required this.strokes,
    required this.objects,
    required this.layers,
    required this.groups,
  });
  final List<InkStroke> strokes;
  final List<BoardObject> objects;
  final List<ObjectInkLayer> layers;
  final List<ContentGroup> groups;
}
