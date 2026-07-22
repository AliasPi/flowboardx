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

enum LayerArrangement { oneForward, oneBackward, toFront, toBack }

class EditorController extends ChangeNotifier {
  static const String recentPenColorsMetadataKey = 'recentPenColors';
  static const int maximumRecentPenColors = 10;

  EditorController({
    required WhiteboardDocument document,
    required this.repository,
    required this.assetDirectory,
    Uuid? uuid,
    HandwritingRecognitionService? handwritingRecognition,
  }) : _uuid = uuid ?? const Uuid(),
       history = CommandHistory(document),
       autosave = AutosaveController(repository, document.id),
       viewport = BoardViewport(
         scale: document.currentPage.viewport.zoom,
         offset: Offset(
           document.currentPage.viewport.offsetX,
           document.currentPage.viewport.offsetY,
         ),
       ),
       _selectedIds = document.currentPage.selection.selectedItemIds.toSet(),
       penStyle = ActivePenStyle(
         colorArgb: document.activePreset.colorArgb,
         width: document.activePreset.width,
         type: document.activePreset.type,
       ),
       handwritingRecognition =
           handwritingRecognition ??
           const PlatformHandwritingRecognitionService() {
    _historySubscription = history.changes.listen(_onDocumentChanged);
    _saveErrorSubscription = autosave.errors.listen((error) {
      lastError = 'Speichern fehlgeschlagen: $error';
      notifyListeners();
    });
  }

  final DocumentRepository repository;
  final Directory assetDirectory;
  final Uuid _uuid;
  FileBoardAssetResolver? _assetResolver;
  String? _resolvedAssetSignature;
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
  late final StreamSubscription<Object> _saveErrorSubscription;
  final Map<int, _AnnotationTarget> _annotationTargets = {};
  final Map<String, double> _coverRevealPreviews = {};
  final Set<String> _pendingEraseIds = {};
  final SpatialIndex<InkStroke> _eraseIndex = SpatialIndex(cellSize: 160);
  List<InkStroke>? _eraseIndexedStrokes;
  String? _eraseIndexedPageId;
  Set<String> _selectedIds;
  TransformDelta? _selectionTransformPreview;
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
  BoardPage get page => document.currentPage;
  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);
  Set<String> get selectedSceneItemIds =>
      Set.unmodifiable(_expandedSelectionIds);
  bool get hasSelection => _selectedIds.isNotEmpty;
  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;
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
    final signature = document.assets
        .map((asset) => '${asset.id}:${asset.relativePath}:${asset.sha256}')
        .join('|');
    if (_assetResolver == null || _resolvedAssetSignature != signature) {
      _resolvedAssetSignature = signature;
      _assetResolver = FileBoardAssetResolver(
        directory: assetDirectory,
        document: document,
      );
    }
    return _assetResolver!;
  }

  List<BoardObject> get renderObjects {
    final preview = _selectionTransformPreview;
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
    if (preview == null) return page.strokes;
    final previewIds = _expandedSelectionIds;
    return page.strokes
        .map(
          (stroke) => previewIds.contains(stroke.id)
              ? stroke.transformed(preview)
              : stroke,
        )
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
    final result = <String>{};
    for (final id in _selectedIds) {
      final contentGroup = page.contentGroups
          .where((group) => group.id == id)
          .firstOrNull;
      if (contentGroup != null) {
        result.addAll(contentGroup.memberIds);
        continue;
      }
      final inkGroup = page.groups.where((group) => group.id == id).firstOrNull;
      result.addAll(inkGroup?.strokeIds ?? [id]);
    }
    return result;
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
        value == BoardTool.straightLine) {
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

  bool beginInk(PointerDownEvent event, Offset worldPosition) {
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
      style: penStyle,
      authorId: 'pointer-${event.device}',
    );
    if (!began) _annotationTargets.remove(event.pointer);
    return began;
  }

  void updateInk(PointerMoveEvent event, Offset worldPosition) {
    final target = _annotationTargets[event.pointer];
    inkSessions.update(
      event,
      target == null ? _clampWorldOffset(worldPosition) : worldPosition,
    );
  }

  void endInk(PointerEvent event, Offset worldPosition) {
    final target = _annotationTargets.remove(event.pointer);
    final stroke = inkSessions.end(
      event,
      target == null ? _clampWorldOffset(worldPosition) : worldPosition,
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

  void eraseAt(Offset worldPosition, {double radius = 24}) {
    _synchronizeEraseIndex();
    final query = Rect.fromCircle(center: worldPosition, radius: radius);
    for (final stroke in _eraseIndex.query(query)) {
      if (_strokeTouchesCircle(stroke, worldPosition, radius)) {
        _pendingEraseIds.add(stroke.id);
      }
    }
    for (final object in page.objects) {
      final pdfPageIndex = object is PdfObject
          ? object.activeSourcePageIndex
          : null;
      final layer = page.annotationFor(object.id, pdfPageIndex: pdfPageIndex);
      if (layer == null ||
          !object.transform.bounds
              .inflate(radius)
              .contains(Vec2(worldPosition.dx, worldPosition.dy))) {
        continue;
      }
      final target = _AnnotationTarget(
        object.id,
        object.transform,
        pdfPageIndex: pdfPageIndex,
      );
      final local = target.toLocal(worldPosition);
      final localRadius = radius / target.minimumExtent;
      final localArea = Rect2(
        left: local.dx - localRadius,
        top: local.dy - localRadius,
        width: localRadius * 2,
        height: localRadius * 2,
      );
      for (final stroke in layer.strokes) {
        if (stroke.bounds.intersects(localArea) &&
            _strokeTouchesCircle(stroke, local, localRadius)) {
          _pendingEraseIds.add(stroke.id);
        }
      }
    }
  }

  void commitErase() {
    if (_pendingEraseIds.isEmpty) return;
    execute(DeleteItemsCommand(page.id, _pendingEraseIds));
    _pendingEraseIds.clear();
  }

  void cancelErase() => _pendingEraseIds.clear();

  void selectAt(Offset worldPosition) {
    _selectionTransformPreview = null;
    final candidates = selectionEngine.candidatesAt(
      page,
      Vec2(worldPosition.dx, worldPosition.dy),
      tolerance: 14 / viewport.scale,
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
    return preview == null ? bounds : bounds.transformed(preview);
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
  }) {
    if (_selectedIds.isEmpty ||
        !scaleX.isFinite ||
        !scaleY.isFinite ||
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
    );
    notifyListeners();
  }

  void commitSelectionTransform() {
    final preview = _selectionTransformPreview;
    if (preview == null) return;
    _selectionTransformPreview = null;
    final identity =
        preview.dx.abs() < .0001 &&
        preview.dy.abs() < .0001 &&
        (preview.scaleX - 1).abs() < .0001 &&
        (preview.scaleY - 1).abs() < .0001;
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
      if (appending) {
        final inkRight = points.fold<double>(
          current.transform.width,
          (maximum, point) => math.max(maximum, point.dx),
        );
        final addedCharacters = math.max(
          1,
          updated.length - current.text.length,
        );
        final estimatedTextRight =
            current.transform.width +
            addedCharacters * current.fontSize * .68 +
            current.fontSize;
        final desired = math.max(
          inkRight + current.fontSize,
          estimatedTextRight,
        );
        final available = math.max(
          TextObjectLayout.minimumWidth,
          viewport.worldBounds.right - current.transform.x,
        );
        maximumWidth = math.min(
          available,
          math.max(TextObjectLayout.defaultMaximumWidth, desired),
        );
      }
      return updateTextObject(
        objectId: current.id,
        text: updated,
        maximumWidth: maximumWidth,
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
    execute(
      AddPageCommand(
        BoardPage.empty(
          id: _uuid.v4(),
          name: 'Seite ${document.pages.length + 1}',
        ),
      ),
    );
    _afterPageChanged();
  }

  void addTemplate(TemplateKind kind) {
    if (!_allowNavigation()) return;
    if (document.pages.length >= WhiteboardDocument.maxPageCount) return;
    execute(
      AddPageCommand(
        templateFactory.createPage(kind, pageNumber: document.pages.length + 1),
      ),
    );
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
      history.execute(
        AddTemplatePageCommand(
          page: materialization.page,
          assets: materialization.assets,
        ),
      );
      committed = true;
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
        index == document.currentPageIndex) {
      return;
    }
    if (!_allowNavigation()) return;
    executeUntracked(SelectPageCommand(document.pages[index].id));
    _afterPageChanged();
  }

  void nextPage() {
    final count = document.pages.length;
    if (count < 2) return;
    goToPage((document.currentPageIndex + 1) % count);
  }

  void previousPage() {
    final count = document.pages.length;
    if (count < 2) return;
    goToPage((document.currentPageIndex - 1) % count);
  }

  void commitViewport() {
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
  }) async {
    final sourceDocumentId = document.id;
    final targetPageId = page.id;
    final origin = viewport.screenToWorld(const Offset(480, 240));
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
  }) async {
    final sourceDocumentId = document.id;
    final targetPageId = page.id;
    final origin = viewport.screenToWorld(const Offset(480, 240));
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
    final origin = viewport.screenToWorld(const Offset(520, 180));
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
    history.undo();
    _repairTransientState();
  }

  void redo() {
    if (!_allowNavigation()) return;
    history.redo();
    _repairTransientState();
  }

  bool execute(DocumentCommand command) {
    try {
      lastError = null;
      history.execute(command);
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
    _persistSettings();
    await _historySubscription.cancel();
    await _saveErrorSubscription.cancel();
    await autosave.dispose();
    await history.dispose();
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
    autosave.schedule(value);
    notifyListeners();
  }

  void _afterPageChanged() {
    _coverRevealPreviews.clear();
    _selectionTransformPreview = null;
    _eraseIndexedStrokes = null;
    _eraseIndexedPageId = null;
    _eraseIndex.clear();
    _selectedIds = page.selection.selectedItemIds.toSet();
    _returnToInkWhenInsertedSelectionClears = false;
    viewport.restore(
      scale: page.viewport.zoom,
      offset: Offset(page.viewport.offsetX, page.viewport.offsetY),
    );
    groupingEngine.invalidatePage(page.id);
    notifyListeners();
  }

  void _repairTransientState() {
    final valid = {
      ...page.strokes.map((stroke) => stroke.id),
      ...page.objects.map((object) => object.id),
      ...page.groups.map((group) => group.id),
      ...page.contentGroups.map((group) => group.id),
    };
    _selectedIds.removeWhere((id) => !valid.contains(id));
    _afterPageChanged();
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
    final scene = orderedBoardSceneItems(
      objects: page.objects,
      strokes: page.strokes,
    );
    for (final item in scene.reversed) {
      final object = item.object;
      if (object == null) continue;
      if ((object is ImageObject ||
              object is PdfObject ||
              object is TableObject) &&
          object.transform.bounds.contains(position)) {
        return _AnnotationTarget(
          object.id,
          object.transform,
          pdfPageIndex: object is PdfObject
              ? object.activeSourcePageIndex
              : null,
        );
      }
    }
    return null;
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
      if (math.pow(distanceX, 2) + math.pow(distanceY, 2) <= thresholdSquared) {
        return true;
      }
    }
    return false;
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
          sourceStrokeIds: value.sourceStrokeIds,
          zIndex: value.zIndex,
          opacity: value.opacity,
          locked: value.locked,
        ),
      };
}

class _AnnotationTarget {
  const _AnnotationTarget(this.objectId, this.transform, {this.pdfPageIndex});
  final String objectId;
  final ObjectTransform transform;
  final int? pdfPageIndex;

  double get minimumExtent =>
      (transform.width < transform.height ? transform.width : transform.height)
          .clamp(1, double.infinity);

  Offset toLocal(Offset world) => Offset(
    (world.dx - transform.x) / transform.width,
    (world.dy - transform.y) / transform.height,
  );

  InkStroke toLocalStroke(InkStroke stroke) => stroke.copyWith(
    points: stroke.points.map(
      (point) => InkPoint(
        x: (point.x - transform.x) / transform.width,
        y: (point.y - transform.y) / transform.height,
        pressure: point.pressure,
        timestampMicros: point.timestampMicros,
        tiltX: point.tiltX,
        tiltY: point.tiltY,
      ),
    ),
    width: stroke.width / minimumExtent,
  );
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
