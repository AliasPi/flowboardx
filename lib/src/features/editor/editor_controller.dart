import 'dart:async';
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
  }) {
    final hydration = _upgradePersistedTextFrames(document);
    return EditorController._(
      initialDocument: hydration.document,
      repository: repository,
      assetDirectory: assetDirectory,
      uuid: uuid,
      handwritingRecognition: handwritingRecognition,
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
    sharedHistory: owner.history,
    sharedAutosave: owner.autosave,
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
    CommandHistory? sharedHistory,
    AutosaveController? sharedAutosave,
    String? activePageId,
    bool persistInitialDocument = false,
  }) : _uuid = uuid ?? const Uuid(),
       history = sharedHistory ?? CommandHistory(initialDocument),
       autosave =
           sharedAutosave ?? AutosaveController(repository, initialDocument.id),
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
  WhiteboardDocument? _assetSignatureDocument;
  final CommandHistory history;
  final AutosaveController autosave;
  final BoardViewport viewport;
  final InkSessionManager inkSessions = InkSessionManager();
  final PointerPolicy pointerPolicy = const PointerPolicy();
  final SelectionEngine selectionEngine = const SelectionEngine();
  final InkGroupingEngine groupingEngine = InkGroupingEngine();
  final TemplateFactory templateFactory = TemplateFactory();
  final HandwritingRecognitionService handwritingRecognition;

  late final StreamSubscription<WhiteboardDocument> _historySubscription;
  StreamSubscription<Object>? _saveErrorSubscription;
  final bool _ownsDocumentSession;
  final bool _followsDocumentNavigation;
  final String _historyOwnerId;
  String _activePageId;
  final Map<String, ViewportState> _localViewports = <String, ViewportState>{};
  final Map<int, _AnnotationTarget> _annotationTargets = {};
  final Map<String, double> _coverRevealPreviews = {};
  final Map<String, List<InkStroke>> _pendingEraseReplacements = {};
  final List<_PendingEraseSweep> _pendingEraseSweeps = [];
  String? _pendingErasePageId;
  int? _pendingEraseRevision;
  final SpatialIndex<InkStroke> _eraseIndex = SpatialIndex(cellSize: 160);
  List<InkStroke>? _eraseIndexedStrokes;
  String? _eraseIndexedPageId;
  Set<String> _selectedIds;
  BoardPage? _expandedSelectionPage;
  Set<String> _expandedSelectionSource = const <String>{};
  Set<String> _expandedSelectionCache = const <String>{};
  TransformDelta? _selectionTransformPreview;
  String? _selectionInteractionOwner;
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
  BoardPage get page =>
      document.pageById(_activePageId) ?? document.currentPage;
  int get currentPageIndex {
    final index = document.pages.indexWhere((page) => page.id == this.page.id);
    return index < 0 ? document.currentPageIndex : index;
  }

  Set<String> get selectedIds =>
      _selectedIds.isEmpty ? const <String>{} : Set.unmodifiable(_selectedIds);
  Set<String> get selectedSceneItemIds =>
      _selectedIds.isEmpty ? const <String>{} : _expandedSelectionIds;
  bool get hasSelection => _selectedIds.isNotEmpty;
  bool get canUndo => history.canUndoFor(_historyOwnerId);
  bool get canRedo => history.canRedoFor(_historyOwnerId);
  bool get canPaste => _clipboard != null;
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
    if (!identical(_assetSignatureDocument, currentDocument)) {
      _assetSignatureDocument = currentDocument;
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
    if (preview == null && _coverRevealPreviews.isEmpty) {
      return page.objects;
    }
    final previewIds = preview == null
        ? const <String>{}
        : _expandedSelectionIds;
    return page.objects
        .map((object) {
          final revealPreview = _coverRevealPreviews[object.id];
          final withReveal = object is CoverObject && revealPreview != null
              ? object.copyWithReveal(revealPreview)
              : object;
          if (_selectionTransformPreview == null ||
              !previewIds.contains(object.id)) {
            return withReveal;
          }
          return _previewTransformedObject(
            withReveal,
            _selectionTransformPreview!,
          );
        })
        .toList(growable: false);
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
    if (preview == null && _pendingEraseReplacements.isEmpty) {
      return page.strokes;
    }
    final previewIds = _expandedSelectionIds;
    return <InkStroke>[
      for (final source in page.strokes)
        for (final stroke
            in _pendingEraseReplacements[source.id] ?? <InkStroke>[source])
          if (preview != null && previewIds.contains(source.id))
            stroke.transformed(preview)
          else
            stroke,
    ];
  }

  /// Annotation strokes share the same live erase preview as free board ink.
  /// The immutable page remains untouched until [commitErase], keeping a whole
  /// fist gesture as one Undo/Auto-Save operation.
  List<ObjectInkLayer> get renderAnnotationLayers {
    if (_pendingEraseReplacements.isEmpty) return page.annotationLayers;
    return page.annotationLayers
        .map((layer) {
          if (!layer.strokes.any(
            (stroke) => _pendingEraseReplacements.containsKey(stroke.id),
          )) {
            return layer;
          }
          final visible = <InkStroke>[
            for (final source in layer.strokes)
              ...(_pendingEraseReplacements[source.id] ?? <InkStroke>[source]),
          ];
          return layer.copyWith(strokes: visible);
        })
        .toList(growable: false);
  }

  /// Sessions always sample in world units so their distance threshold and
  /// live preview behave identically on the board and over embedded objects.
  List<InkStroke> get renderInkPreviews => inkSessions.buildPreviewStrokes();

  CoverObject? get selectedCover {
    if (_selectedIds.length != 1) return null;
    final id = _selectedIds.single;
    for (final object in page.objects) {
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
    for (final object in page.objects) {
      if (object is PdfObject && object.id == id) return object;
    }
    return null;
  }

  ContentGroup? get selectedContentGroup {
    if (_selectedIds.length != 1) return null;
    final id = _selectedIds.single;
    for (final group in page.contentGroups) {
      if (group.id == id) return group;
    }
    return null;
  }

  TextObject? get selectedTextObject {
    if (_selectedIds.length != 1) return null;
    final selected = page.objectById(_selectedIds.single);
    return selected is TextObject ? selected : null;
  }

  bool get canGroupSelection =>
      selectedContentGroup == null && _expandedSelectionIds.length >= 2;
  bool get canArrangeSelection {
    final expanded = _expandedSelectionIds;
    return page.objects.any((object) => expanded.contains(object.id)) ||
        page.strokes.any((stroke) => expanded.contains(stroke.id));
  }

  bool get hasSelectedHandwriting =>
      page.strokes.any((stroke) => _expandedSelectionIds.contains(stroke.id));

  double coverRevealValue(String objectId, double persisted) =>
      _coverRevealPreviews[objectId] ?? persisted;

  Set<String> get _expandedSelectionIds {
    if (_selectedIds.isEmpty) return const <String>{};
    final currentPage = page;
    if (identical(_expandedSelectionPage, currentPage) &&
        setEquals(_expandedSelectionSource, _selectedIds)) {
      return _expandedSelectionCache;
    }
    final result = <String>{};
    for (final id in _selectedIds) {
      final contentGroup = currentPage.contentGroups
          .where((group) => group.id == id)
          .firstOrNull;
      if (contentGroup != null) {
        result.addAll(contentGroup.memberIds);
        continue;
      }
      final inkGroup = currentPage.groups
          .where((group) => group.id == id)
          .firstOrNull;
      result.addAll(inkGroup?.strokeIds ?? [id]);
    }
    _expandedSelectionPage = currentPage;
    _expandedSelectionSource = Set<String>.unmodifiable(_selectedIds);
    _expandedSelectionCache = Set<String>.unmodifiable(result);
    return _expandedSelectionCache;
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
    if (!began) _annotationTargets.remove(event.pointer);
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
  }

  void cancelInk(int pointer) {
    _annotationTargets.remove(pointer);
    inkSessions.cancel(pointer);
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
      if (_pendingErasePageId != null && _pendingErasePageId != page.id) {
        _clearPendingErase();
      }
      _pendingErasePageId ??= page.id;
      _pendingEraseRevision ??= document.revision;
      final sweep = _PendingEraseSweep(
        start: start,
        end: end,
        radius: safeRadius,
      );
      _pendingEraseSweeps.add(sweep);
      changed = _stageEraseSweep(sweep) || changed;
    }
    if (changed) notifyListeners();
  }

  bool _stageEraseSweep(_PendingEraseSweep sweep) {
    final start = sweep.start;
    final end = sweep.end;
    final safeRadius = sweep.radius;
    final capturedSourceIds = <String>{};
    bool accepts(InkStroke stroke) {
      final sourceIds = sweep.sourceIds;
      return sourceIds == null ||
          sourceIds.any(
            (sourceId) =>
                stroke.id == sourceId ||
                stroke.id.startsWith('$sourceId.erase.'),
          );
    }

    _synchronizeEraseIndex();
    final query = Rect.fromLTRB(
      math.min(start.dx, end.dx) - safeRadius,
      math.min(start.dy, end.dy) - safeRadius,
      math.max(start.dx, end.dx) + safeRadius,
      math.max(start.dy, end.dy) + safeRadius,
    );
    var changed = false;
    for (final stroke in _eraseIndex.query(query)) {
      if (accepts(stroke) &&
          _strokeTouchesCapsule(stroke, start, end, safeRadius)) {
        final strokeRadius = stroke.width.isFinite
            ? math.max(0.0, stroke.width / 2)
            : 0.0;
        final strokeChanged = _stageStrokeErase(
          stroke,
          start,
          end,
          radius: safeRadius + strokeRadius,
        );
        if (strokeChanged && sweep.sourceIds == null) {
          capturedSourceIds.add(stroke.id);
        }
        changed = strokeChanged || changed;
      }
    }
    for (final object in page.objects) {
      final pdfPageIndex = object is PdfObject
          ? object.activeSourcePageIndex
          : null;
      final layer = activeObjectInkLayer(object, page.annotationLayers);
      if (layer == null ||
          !object.transform.bounds
              .inflate(safeRadius)
              .intersects(
                Rect2(
                  left: query.left,
                  top: query.top,
                  width: query.width,
                  height: query.height,
                ),
              )) {
        continue;
      }
      final target = _AnnotationTarget(
        object.id,
        object.transform,
        pdfPageIndex: pdfPageIndex,
      );
      for (final stroke in layer.strokes) {
        if (accepts(stroke) &&
            _annotationStrokeTouchesWorldCapsule(
              stroke,
              target,
              start,
              end,
              safeRadius,
            )) {
          final localWidth = stroke.width.isFinite ? stroke.width : 0.0;
          final strokeRadius = math.max(
            0.0,
            localWidth * target.minimumExtent / 2,
          );
          final strokeChanged = _stageStrokeErase(
            stroke,
            start,
            end,
            radius: safeRadius + strokeRadius,
            project: (point) {
              final world = target.pointToWorld(point);
              return Vec2(world.dx, world.dy);
            },
          );
          if (strokeChanged && sweep.sourceIds == null) {
            capturedSourceIds.add(stroke.id);
          }
          changed = strokeChanged || changed;
        }
      }
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
    var selectionChanged = false;
    for (final selectedId in selectionBefore) {
      final fragments = replacements[selectedId];
      if (fragments == null) continue;
      for (final fragment in fragments) {
        if (validStrokeIds.contains(fragment.id) &&
            _selectedIds.add(fragment.id)) {
          selectionChanged = true;
        }
      }
    }
    if (selectionChanged) notifyListeners();
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
    if (_pendingErasePageId != page.id) {
      _clearPendingErase();
      return;
    }
    final sweeps = List<_PendingEraseSweep>.of(_pendingEraseSweeps);
    _pendingEraseReplacements.clear();
    _eraseIndexedStrokes = null;
    _eraseIndexedPageId = null;
    _eraseIndex.clear();
    for (final sweep in sweeps) {
      _stageEraseSweep(sweep);
    }
    _pendingEraseRevision = document.revision;
  }

  void _clearPendingErase() {
    _pendingEraseReplacements.clear();
    _pendingEraseSweeps.clear();
    _pendingErasePageId = null;
    _pendingEraseRevision = null;
  }

  bool _stageStrokeErase(
    InkStroke source,
    Offset start,
    Offset end, {
    required double radius,
    InkPointProjection? project,
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
        idFactory: (sourceId, fragmentIndex) => '$sourceId.erase.${_uuid.v4()}',
      );
      changed = changed || result.changed;
      next.addAll(result.fragments);
    }
    if (!changed) return false;
    _pendingEraseReplacements[source.id] = List<InkStroke>.unmodifiable(next);
    return true;
  }

  void selectAt(Offset worldPosition, {double? viewportScale}) {
    _selectionTransformPreview = null;
    final hitScale = viewportScale != null && viewportScale.isFinite
        ? viewportScale.clamp(BoardViewport.minScale, BoardViewport.maxScale)
        : viewport.scale;
    final candidates = selectionEngine.candidatesAt(
      page,
      Vec2(worldPosition.dx, worldPosition.dy),
      tolerance: 14 / hitScale,
    );
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
    _selectedIds = selectionEngine.itemsInRectangle(
      page,
      Rect2(
        left: worldRect.left,
        top: worldRect.top,
        width: worldRect.width,
        height: worldRect.height,
      ),
    );
    notifyListeners();
  }

  void selectLasso(List<Offset> points) {
    _selectionTransformPreview = null;
    _returnToInkWhenInsertedSelectionClears = false;
    _selectedIds = selectionEngine.itemsInLasso(
      page,
      points.map((point) => Vec2(point.dx, point.dy)).toList(growable: false),
    );
    notifyListeners();
  }

  void selectAll() {
    _selectionTransformPreview = null;
    _returnToInkWhenInsertedSelectionClears = false;
    _selectedIds = selectionEngine.allItems(page);
    notifyListeners();
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

  Rect2 get _baseSelectionBounds =>
      selectionEngine.boundsOf(page, _selectedIds);

  Rect2 get selectionBounds {
    final bounds = _baseSelectionBounds;
    final preview = _selectionTransformPreview;
    if (preview == null) return bounds;
    // Transform each selected scene item before uniting its bounds. Rotating
    // the already axis-aligned aggregate would create an oversized frame when
    // an object has previously been rotated.
    return selectionEngine.boundsOf(
      page.copyWith(objects: renderObjects, strokes: renderStrokes),
      _selectedIds,
    );
  }

  /// Serializes selection previews across both participant surfaces.
  /// Ordinary ink remains multi-pointer and does not use this lock.
  bool claimSelectionInteraction(String owner) {
    if (owner.isEmpty) return false;
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
    final expanded = _expandedSelectionIds;
    final point = Vec2(worldPosition.dx, worldPosition.dy);
    for (final object in page.objects) {
      if (expanded.contains(object.id) &&
          object.transform.containsWorld(point, tolerance: tolerance)) {
        return true;
      }
    }
    final candidates = selectionEngine.candidatesAt(
      page,
      point,
      tolerance: tolerance,
    );
    return candidates.any(
      (candidate) =>
          _selectedIds.contains(candidate.id) ||
          candidate.itemIds.any(expanded.contains),
    );
  }

  /// The persisted angle shown by the manual rotation control. A mixed
  /// selection has no single intrinsic angle, so it starts at zero while a
  /// single object reports its own angle.
  double get selectionRotationDegrees {
    final expanded = _expandedSelectionIds;
    if (expanded.length != 1) return 0;
    final object = page.objectById(expanded.single);
    if (object == null) return 0;
    return object.transform.rotationRadians * 180 / math.pi;
  }

  void previewMoveSelection(Offset delta) {
    if (_selectedIds.isEmpty || !delta.dx.isFinite || !delta.dy.isFinite) {
      return;
    }
    final bounds = _baseSelectionBounds;
    final world = viewport.worldBounds;
    var dx = delta.dx;
    var dy = delta.dy;
    if (bounds.left + dx < world.left) dx = world.left - bounds.left;
    if (bounds.right + dx > world.right) dx = world.right - bounds.right;
    if (bounds.top + dy < world.top) dy = world.top - bounds.top;
    if (bounds.bottom + dy > world.bottom) dy = world.bottom - bounds.bottom;
    _selectionTransformPreview = TransformDelta(dx: dx, dy: dy);
    notifyListeners();
  }

  void previewScaleSelection(double scale, {required Offset anchor}) {
    if (_selectedIds.isEmpty || !scale.isFinite) return;
    final bounds = _baseSelectionBounds;
    final world = viewport.worldBounds;
    final availableX = bounds.right > anchor.dx
        ? (world.right - anchor.dx) / (bounds.right - anchor.dx)
        : 20.0;
    final availableY = bounds.bottom > anchor.dy
        ? (world.bottom - anchor.dy) / (bounds.bottom - anchor.dy)
        : 20.0;
    final maximum = math.min(20.0, math.min(availableX, availableY));
    final safe = scale.clamp(.05, math.max(.05, maximum)).toDouble();
    _selectionTransformPreview = TransformDelta(
      scaleX: safe,
      scaleY: safe,
      anchor: Vec2(anchor.dx, anchor.dy),
    );
    notifyListeners();
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
    final world = viewport.worldBounds;

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
    _selectionTransformPreview = TransformDelta(
      scaleX: safeX,
      scaleY: safeY,
      anchor: Vec2(anchor.dx, anchor.dy),
      scaleAxisRadians: scaleAxisRadians,
    );
    notifyListeners();
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
    final rotatedBounds = base.transformed(delta);
    final world = viewport.worldBounds;
    var dx = 0.0;
    var dy = 0.0;
    if (rotatedBounds.width <= world.width) {
      if (rotatedBounds.left < world.left) dx = world.left - rotatedBounds.left;
      if (rotatedBounds.right + dx > world.right) {
        dx = world.right - rotatedBounds.right;
      }
    }
    if (rotatedBounds.height <= world.height) {
      if (rotatedBounds.top < world.top) dy = world.top - rotatedBounds.top;
      if (rotatedBounds.bottom + dy > world.bottom) {
        dy = world.bottom - rotatedBounds.bottom;
      }
    }
    delta = TransformDelta(
      dx: dx,
      dy: dy,
      anchor: Vec2(anchor.dx, anchor.dy),
      rotationRadians: rotationRadians,
    );
    _selectionTransformPreview = delta;
    notifyListeners();
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
    _selectionTransformPreview = TransformDelta(scaleX: -1, anchor: center);
    commitSelectionTransform();
  }

  void commitSelectionTransform() {
    final preview = _selectionTransformPreview;
    if (preview == null) return;
    _selectionTransformPreview = null;
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

  void paste({Offset offset = const Offset(28, 28)}) {
    final payload = _clipboard;
    if (payload == null) return;
    final idMap = <String, String>{};
    final delta = TransformDelta(dx: offset.dx, dy: offset.dy);
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
    final firstZIndex = nextBoardSceneZIndex(
      objects: page.objects,
      strokes: page.strokes,
    );
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
    _selectedIds = group.memberIds.toSet();
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
    final sourcePageId = page.id;
    final expanded = _expandedSelectionIds;
    final strokes = page.strokes
        .where((stroke) => expanded.contains(stroke.id))
        .toList(growable: false);
    if (strokes.isEmpty) return false;
    try {
      if (!await handwritingRecognition.isAvailable()) {
        throw const HandwritingRecognitionUnavailable();
      }
      final result = await handwritingRecognition.recognize(
        HandwritingRecognitionRequest(strokes: strokes),
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
      if (_closed ||
          page.id != sourcePageId ||
          strokes.any((stroke) => page.strokeById(stroke.id) == null)) {
        return false;
      }
      Rect2? bounds;
      for (final stroke in strokes) {
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
        colorArgb: strokes.first.colorArgb,
        sourceStrokeIds: strokes.map((stroke) => stroke.id),
        zIndex: nextBoardSceneZIndex(
          objects: page.objects,
          strokes: page.strokes,
        ),
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
      final removed = strokes.map((stroke) => stroke.id).toSet();
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
      execute(ReplacePageCommand(nextPage));
      _selectedIds = nextSelection;
      notifyListeners();
      return true;
    } catch (error) {
      lastError = error.toString();
      notifyListeners();
      return false;
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
    _coverRevealPreviews[objectId] = reveal.clamp(0, 1);
    notifyListeners();
  }

  void commitCoverReveal(String objectId, double reveal) {
    _coverRevealPreviews.remove(objectId);
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
    if (_coverRevealPreviews.remove(objectId) != null) notifyListeners();
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
      history.undo(ownerId: _historyOwnerId);
      _repairTransientState();
    } catch (error) {
      lastError = 'Rückgängig fehlgeschlagen: $error';
      notifyListeners();
    }
  }

  void redo() {
    if (!_allowNavigation()) return;
    try {
      lastError = null;
      history.redo(ownerId: _historyOwnerId);
      _repairTransientState();
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
    _settingsPersistenceTimer?.cancel();
    if (_ownsDocumentSession) _persistSettings();
    await _historySubscription.cancel();
    await _saveErrorSubscription?.cancel();
    if (_ownsDocumentSession) {
      await autosave.dispose();
      await history.dispose();
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
    final requestedPage = value.pageById(_activePageId);
    if (_followsDocumentNavigation) {
      _activePageId = value.currentPage.id;
    } else if (requestedPage == null) {
      _activePageId = value.currentPage.id;
    }
    if (_pendingEraseSweeps.isNotEmpty) _rebuildPendingErasePreview();
    _removeInvalidSelectionIds();
    notifyListeners();
  }

  void _afterPageChanged() {
    _coverRevealPreviews.clear();
    _clearPendingErase();
    _selectionTransformPreview = null;
    _selectionInteractionOwner = null;
    _eraseIndexedStrokes = null;
    _eraseIndexedPageId = null;
    _eraseIndex.clear();
    _selectedIds = page.selection.selectedItemIds.toSet();
    _returnToInkWhenInsertedSelectionClears = false;
    final persisted = _followsDocumentNavigation
        ? page.viewport
        : _localViewports[page.id] ?? page.viewport;
    viewport.restore(
      scale: persisted.zoom,
      offset: Offset(persisted.offsetX, persisted.offsetY),
    );
    groupingEngine.invalidatePage(page.id);
    notifyListeners();
  }

  void _repairTransientState() {
    _removeInvalidSelectionIds();
    _afterPageChanged();
  }

  void _removeInvalidSelectionIds() {
    if (_selectedIds.isEmpty) return;
    final valid = <String>{
      ...page.strokes.map((stroke) => stroke.id),
      ...page.objects.map((object) => object.id),
      ...page.groups.map((group) => group.id),
      ...page.contentGroups.map((group) => group.id),
    };
    _selectedIds.removeWhere((id) => !valid.contains(id));
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
    if (setEquals(_selectedIds, rebased)) return;
    _selectedIds = rebased;
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

  void _synchronizeEraseIndex() {
    if (_eraseIndexedPageId == page.id &&
        identical(_eraseIndexedStrokes, page.strokes)) {
      return;
    }
    _eraseIndex.clear();
    for (final stroke in page.strokes) {
      final bounds = stroke.bounds;
      _eraseIndex.insert(
        stroke,
        Rect.fromLTWH(bounds.left, bounds.top, bounds.width, bounds.height),
      );
    }
    _eraseIndexedPageId = page.id;
    _eraseIndexedStrokes = page.strokes;
  }

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

class _AnnotationTarget {
  const _AnnotationTarget(this.objectId, this.transform, {this.pdfPageIndex});
  final String objectId;
  final ObjectTransform transform;
  final int? pdfPageIndex;

  double get minimumExtent =>
      (transform.width < transform.height ? transform.width : transform.height)
          .clamp(1, double.infinity);

  Offset toLocal(Offset world) {
    final local = transform.worldToLocal(Vec2(world.dx, world.dy));
    return Offset(local.x / transform.width, local.y / transform.height);
  }

  Offset pointToWorld(InkPoint point) {
    final world = transform.localToWorld(
      Vec2(point.x * transform.width, point.y * transform.height),
    );
    return Offset(world.x, world.y);
  }

  InkStroke toLocalStroke(InkStroke stroke) => stroke.copyWith(
    points: stroke.points.map((point) {
      final local = transform.worldToLocal(point.position);
      return InkPoint(
        x: local.x / transform.width,
        y: local.y / transform.height,
        pressure: point.pressure,
        timestampMicros: point.timestampMicros,
        tiltX: point.tiltX,
        tiltY: point.tiltY,
      );
    }),
    width: stroke.width / minimumExtent,
  );
}

final class _PendingEraseSweep {
  _PendingEraseSweep({
    required this.start,
    required this.end,
    required this.radius,
  });

  final Offset start;
  final Offset end;
  final double radius;
  Set<String>? sourceIds;
}

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
