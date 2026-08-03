import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/document_repository.dart';
import '../../diagnostics/diagnostics.dart';
import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/ink.dart';
import '../assets/google_image_browser_dialog.dart';
import '../assets/web_image_search_service.dart';
import '../board/engine/board_viewport.dart';
import '../board/engine/input_policy.dart';
import '../board/presentation/board_surface.dart';
import '../export_share/export_share.dart';
import '../library/document_preview.dart';
import '../pages/editor_page_controls.dart';
import '../pages/page_thumbnail_invalidation_index.dart';
import '../pages/page_thumbnail_renderer.dart';
import '../radial_menu/radial_menu.dart';
import '../templates/templates.dart';
import '../timer/countdown_timer.dart';
import '../../app/app_theme.dart';
import '../../app/brand_mark.dart';
import '../../platform/android_pdf_file_saver.dart';
import '../../platform/android_pdf_quick_share.dart';
import 'board_export_factory.dart';
import 'board_participant_controller.dart';
import 'editor_controller.dart';
import 'editor_help_dialog.dart';
import 'editor_pen_quick_controls.dart';
import 'participant_mode_toggle.dart';
import 'pdf_import_dialog.dart';
import 'pdf_import_coordinator.dart';
import 'pen_color_picker_dialog.dart';
import 'table_insert_dialog.dart';

final class _OpenedPdfPreview {
  const _OpenedPdfPreview({required this.path, required this.document});

  final String path;
  final PdfDocument document;
}

/// Values consumed by the editor chrome outside [BoardSurface].
///
/// The board already listens to its controller directly. Comparing this small
/// snapshot prevents high-frequency eraser and transform previews from
/// rebuilding the top bar, both radial menus, timers and the other participant
/// surface.
final class _EditorShellSnapshot {
  const _EditorShellSnapshot({
    required this.documentTitle,
    required this.pageCount,
    required this.currentPageIndex,
    required this.pageId,
    required this.tool,
    required this.shape,
    required this.penColor,
    required this.penWidth,
    required this.penType,
    required this.saving,
    required this.lastError,
    required this.canUndo,
    required this.canRedo,
    required this.canPaste,
  });

  factory _EditorShellSnapshot.from(EditorController controller) {
    final pen = controller.penStyle;
    return _EditorShellSnapshot(
      documentTitle: controller.document.title,
      pageCount: controller.document.pages.length,
      currentPageIndex: controller.currentPageIndex,
      pageId: controller.page.id,
      tool: controller.tool,
      shape: controller.activeShape,
      penColor: pen.colorArgb,
      penWidth: pen.width,
      penType: pen.type,
      saving: controller.saving,
      lastError: controller.lastError,
      canUndo: controller.canUndo,
      canRedo: controller.canRedo,
      canPaste: controller.canPaste,
    );
  }

  final String documentTitle;
  final int pageCount;
  final int currentPageIndex;
  final String pageId;
  final BoardTool tool;
  final ShapeKind shape;
  final int penColor;
  final double penWidth;
  final InkToolType penType;
  final bool saving;
  final String? lastError;
  final bool canUndo;
  final bool canRedo;
  final bool canPaste;

  @override
  bool operator ==(Object other) =>
      other is _EditorShellSnapshot &&
      other.documentTitle == documentTitle &&
      other.pageCount == pageCount &&
      other.currentPageIndex == currentPageIndex &&
      other.pageId == pageId &&
      other.tool == tool &&
      other.shape == shape &&
      other.penColor == penColor &&
      other.penWidth == penWidth &&
      other.penType == penType &&
      other.saving == saving &&
      other.lastError == lastError &&
      other.canUndo == canUndo &&
      other.canRedo == canRedo &&
      other.canPaste == canPaste;

  @override
  int get hashCode => Object.hash(
    documentTitle,
    pageCount,
    currentPageIndex,
    pageId,
    tool,
    shape,
    penColor,
    penWidth,
    penType,
    saving,
    lastError,
    canUndo,
    canRedo,
    canPaste,
  );
}

final class _WorkspaceRegionClipper extends CustomClipper<Rect> {
  const _WorkspaceRegionClipper(this.region);

  final Rect region;

  @override
  Rect getClip(Size size) => region.intersect(Offset.zero & size);

  @override
  bool shouldReclip(covariant _WorkspaceRegionClipper oldClipper) =>
      oldClipper.region != region;
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    required this.document,
    required this.repository,
    required this.assetDirectory,
    super.key,
  });

  final WhiteboardDocument document;
  final DocumentRepository repository;
  final Directory assetDirectory;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with WidgetsBindingObserver {
  late final EditorController _editor;
  late final EditorController _secondaryEditor;
  late final RadialMenuController _radial;
  late final RadialMenuController _secondaryRadial;
  late final BoardParticipantController _primaryParticipant;
  late final BoardParticipantController _secondaryParticipant;
  EditorParticipantMode _participantMode = EditorParticipantMode.onePerson;
  bool _secondaryParticipantInitialized = false;
  final PdfShareController _shareController = PdfShareController();
  final PageThumbnailRenderer _thumbnailRenderer = PageThumbnailRenderer();
  final PageThumbnailInvalidationIndex _thumbnailInvalidation =
      PageThumbnailInvalidationIndex();
  final Map<String, ui.Image> _thumbnails = {};
  final Map<String, int> _thumbnailIdentity = {};
  int _thumbnailGeneration = 0;
  int _thumbnailImageRevision = 0;
  WhiteboardDocument? _thumbnailObservedDocument;
  List<BoardPage>? _radialPreviewPageSource;
  int _radialPreviewThumbnailRevision = -1;
  List<RadialPagePreview> _cachedRadialPagePreviews =
      const <RadialPagePreview>[];
  _EditorShellSnapshot? _primaryShellSnapshot;
  _EditorShellSnapshot? _secondaryShellSnapshot;
  Timer? _thumbnailDebounce;
  bool _thumbnailRefreshRunning = false;
  bool _thumbnailRefreshQueued = false;
  bool _pageSheetOpen = false;
  bool _pageDeleteDialogOpen = false;
  bool _exporting = false;
  double? _exportProgress;
  bool _leaving = false;
  bool _topBarCollapsed = false;
  bool _fingerDrawingEnabled = false;
  late final CountdownTimerController _countdownTimer;
  final CountdownTimerOverlayPresenter _largeTimerPresenter =
      CountdownTimerOverlayPresenter();
  Size _layoutSize = Size.zero;
  int _radialPositionResetToken = 0;
  int _secondaryRadialPositionResetToken = 0;
  Future<UserTemplateStore>? _userTemplateStore;
  Future<List<UserTemplate>>? _userTemplateLoad;
  List<UserTemplate> _userTemplates = const <UserTemplate>[];
  bool _templateMutationRunning = false;
  bool _insertConfigurationOpen = false;
  final PdfImportCoordinator _pdfImportCoordinator = PdfImportCoordinator();
  final ValueNotifier<bool> _radialPageGestureActive = ValueNotifier(false);
  final ValueNotifier<bool> _secondaryRadialPageGestureActive = ValueNotifier(
    false,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _editor = EditorController(
      document: widget.document,
      repository: widget.repository,
      assetDirectory: widget.assetDirectory,
    );
    _countdownTimer = CountdownTimerController(
      onAlarm: playSystemCountdownAlarm,
    );
    _secondaryEditor = EditorController.participantView(
      _editor,
      participantId: 'right',
    );
    _primaryParticipant = BoardParticipantController(
      id: 'left',
      tool: _editor.tool,
      activeShape: _editor.activeShape,
      penStyle: _editor.penStyle,
    );
    _secondaryParticipant = BoardParticipantController(
      id: 'right',
      tool: _editor.tool,
      activeShape: _editor.activeShape,
      penStyle: _editor.penStyle,
    );
    _radial = RadialMenuController(
      isOpen: false,
      activeBranch: null,
      penSettings: RadialPenSettings(
        color: Color(_editor.penStyle.colorArgb),
        thickness: _editor.penStyle.width.clamp(1, 32),
        type: _radialType(_editor.penStyle.type),
      ),
    );
    _secondaryRadial = RadialMenuController(
      isOpen: false,
      activeBranch: null,
      penSettings: RadialPenSettings(
        color: Color(_secondaryParticipant.penStyle.colorArgb),
        thickness: _secondaryParticipant.penStyle.width.clamp(1, 32),
        type: _radialType(_secondaryParticipant.penStyle.type),
      ),
    );
    _editor.addListener(_onEditorChanged);
    _secondaryEditor.addListener(_onSecondaryEditorChanged);
    _onEditorChanged();
    unawaited(_reloadUserTemplates());
    if (widget.document.metadata.recoveredFromCrash) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Die letzte konsistente Version wurde nach einem unerwarteten Abbruch wiederhergestellt.',
            ),
            backgroundColor: FlowboardColors.warning,
          ),
        );
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _countdownTimer.refresh();
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_editor.flush().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editor.removeListener(_onEditorChanged);
    _secondaryEditor.removeListener(_onSecondaryEditorChanged);
    _radial.dispose();
    _secondaryRadial.dispose();
    _primaryParticipant.dispose();
    _secondaryParticipant.dispose();
    _largeTimerPresenter.dispose();
    _countdownTimer.dispose();
    _radialPageGestureActive.dispose();
    _secondaryRadialPageGestureActive.dispose();
    _secondaryEditor.dispose();
    _editor.dispose();
    _shareController.dispose();
    _thumbnailRenderer.dispose();
    _thumbnailDebounce?.cancel();
    for (final image in _thumbnails.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            _layoutSize = constraints.biggest;
            // Every visible editor layer is positioned. The timer milestone
            // listener intentionally renders as SizedBox.shrink; without an
            // expanding fit that zero-sized non-positioned child collapses
            // the entire Stack on real Navigator routes.
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: _buildBoardWorkspace(constraints.biggest),
                ),
                Positioned(
                  left: 16,
                  top: 12,
                  child: _EditorTopBar(
                    width: _topBarCollapsed
                        ? math.min(152, math.max(0, constraints.maxWidth - 32))
                        : math.max(0, constraints.maxWidth - 32),
                    collapsed: _topBarCollapsed,
                    controller: _editor,
                    secondaryController: _secondaryEditor,
                    onBack: _leave,
                    onRename: _rename,
                    onPages: _showPagesSheet,
                    onSaveCurrentPageAsTemplate: () =>
                        unawaited(_saveCurrentPageAsTemplate()),
                    onResetMenuPosition: _resetRadialMenuPosition,
                    onHelp: () => FlowboardHelpDialog.show(
                      context,
                      onExportDiagnostics: _shareDiagnosticLog,
                    ),
                    participantMode: _participantMode,
                    onParticipantModeChanged: _setParticipantMode,
                    fingerDrawingEnabled: _fingerDrawingEnabled,
                    onFingerDrawingChanged: (enabled) =>
                        setState(() => _fingerDrawingEnabled = enabled),
                    countdownTimer: _countdownTimer,
                    onShowLargeTimer: _showLargeTimer,
                    onPenColorChanged: (editor, color) =>
                        _applyQuickPen(editor, color: color),
                    onCustomPenColorRequested: (editor) =>
                        unawaited(_chooseQuickPenColor(editor)),
                    onPenTypeChanged: _applyQuickPenType,
                    onAddPage: (editor) => _addPageAndShowWheel(
                      editor: editor,
                      source: identical(editor, _secondaryEditor)
                          ? _secondaryRadial
                          : _radial,
                    ),
                    onDeletePage: (editor, pageId) =>
                        _confirmAndDeletePage(editor, pageId),
                    onToggleCollapsed: () =>
                        setState(() => _topBarCollapsed = !_topBarCollapsed),
                  ),
                ),
                CountdownTimerAutoPresentation(
                  controller: _countdownTimer,
                  onShowLarge: _showLargeTimer,
                ),
                ..._buildRadialMenus(constraints.biggest),
                if ((_editor.lastError ?? _secondaryEditor.lastError)
                    case final message?)
                  Positioned(
                    left: constraints.maxWidth / 2 - 250,
                    top: 82,
                    width: 500,
                    child: _ErrorBanner(message: message),
                  ),
                if (_exporting)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: Card(
                          child: SizedBox(
                            width: 360,
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(
                                    value: _exportProgress,
                                  ),
                                  const SizedBox(height: 20),
                                  Text(
                                    'PDF wird erstellt',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  if (_exportProgress != null) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      '${(_exportProgress! * 100).round()} %',
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBoardWorkspace(Size size) {
    if (_participantMode == EditorParticipantMode.onePerson) {
      return BoardSurface(
        key: const ValueKey('solo-board-surface'),
        controller: _editor,
        participant: _primaryParticipant,
        participantId: _primaryParticipant.id,
        onEmptyLongPress: (screen, world) => _showEmptyMenu(
          screen,
          world,
          editor: _editor,
          participant: _primaryParticipant,
        ),
        inputSuppression: _radialPageGestureActive,
        fingerDrawingEnabled: _fingerDrawingEnabled,
      );
    }
    const dividerWidth = 3.0;
    final halfWidth = math.max(0.0, (size.width - dividerWidth) / 2);
    final leftRegion = Rect.fromLTWH(0, 0, halfWidth, size.height);
    final rightRegion = Rect.fromLTWH(
      halfWidth + dividerWidth,
      0,
      halfWidth,
      size.height,
    );
    // The logical 3x3 board is split through the centre of its middle page.
    // Keeping this divider in world coordinates makes the partition stable
    // while both participants retain independent cameras and active pages.
    final splitWorldBoundary = _editor.viewport.worldBounds.center.dx;
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRect(
            clipper: _WorkspaceRegionClipper(leftRegion),
            child: BoardSurface(
              key: const ValueKey('left-board-surface'),
              controller: _editor,
              participant: _primaryParticipant,
              participantId: _primaryParticipant.id,
              onEmptyLongPress: (screen, world) => _showEmptyMenu(
                screen,
                world,
                editor: _editor,
                participant: _primaryParticipant,
              ),
              inputSuppression: _radialPageGestureActive,
              confineInputToBounds: true,
              inputBounds: leftRegion,
              horizontalViewportConstraint: BoardViewportHorizontalConstraint(
                side: BoardViewportPartitionSide.left,
                worldBoundaryX: splitWorldBoundary,
              ),
              fingerDrawingEnabled: _fingerDrawingEnabled,
            ),
          ),
        ),
        Positioned.fill(
          child: ClipRect(
            clipper: _WorkspaceRegionClipper(rightRegion),
            child: BoardSurface(
              key: const ValueKey('right-board-surface'),
              controller: _secondaryEditor,
              participant: _secondaryParticipant,
              participantId: _secondaryParticipant.id,
              onEmptyLongPress: (screen, world) => _showEmptyMenu(
                screen,
                world,
                editor: _secondaryEditor,
                participant: _secondaryParticipant,
              ),
              inputSuppression: _secondaryRadialPageGestureActive,
              confineInputToBounds: true,
              inputBounds: rightRegion,
              horizontalViewportConstraint: BoardViewportHorizontalConstraint(
                side: BoardViewportPartitionSide.right,
                worldBoundaryX: splitWorldBoundary,
              ),
              fingerDrawingEnabled: _fingerDrawingEnabled,
            ),
          ),
        ),
        Center(
          child: IgnorePointer(
            child: Container(
              key: const ValueKey('two-person-divider'),
              width: dividerWidth,
              color: FlowboardColors.mint.withValues(alpha: .72),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRadialMenus(Size size) {
    if (_participantMode == EditorParticipantMode.onePerson) {
      return <Widget>[
        Positioned.fill(
          child: _buildRadialMenu(
            key: const ValueKey('solo-radial-menu'),
            regionSize: size,
            radial: _radial,
            participant: _primaryParticipant,
            participantEditor: _editor,
            suppression: _radialPageGestureActive,
            resetToken: _radialPositionResetToken,
            persistPosition: true,
          ),
        ),
      ];
    }
    const dividerWidth = 3.0;
    final halfWidth = math.max(0.0, (size.width - dividerWidth) / 2);
    final regionSize = Size(halfWidth, size.height);
    return <Widget>[
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: halfWidth,
        child: ClipRect(
          child: _buildRadialMenu(
            key: const ValueKey('left-radial-menu'),
            regionSize: regionSize,
            radial: _radial,
            participant: _primaryParticipant,
            participantEditor: _editor,
            suppression: _radialPageGestureActive,
            resetToken: _radialPositionResetToken,
            confineToBounds: true,
          ),
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: halfWidth,
        child: ClipRect(
          child: _buildRadialMenu(
            key: const ValueKey('right-radial-menu'),
            regionSize: regionSize,
            radial: _secondaryRadial,
            participant: _secondaryParticipant,
            participantEditor: _secondaryEditor,
            suppression: _secondaryRadialPageGestureActive,
            resetToken: _secondaryRadialPositionResetToken,
            confineToBounds: true,
          ),
        ),
      ),
    ];
  }

  Widget _buildRadialMenu({
    required Key key,
    required Size regionSize,
    required RadialMenuController radial,
    required BoardParticipantController participant,
    required EditorController participantEditor,
    required ValueNotifier<bool> suppression,
    required int resetToken,
    bool confineToBounds = false,
    bool persistPosition = false,
  }) {
    final split = _participantMode == EditorParticipantMode.twoPeople;
    final initialPosition = split
        ? Offset(regionSize.width / 2, regionSize.height * .62)
        : _initialRadialPosition(regionSize);
    final maximum = math.min(
      610.0,
      math.min(regionSize.width - 16, regionSize.height * .92),
    );
    return RadialMenu(
      key: key,
      controller: radial,
      initialPosition: initialPosition,
      maxDiameter: math.max(360, maximum),
      centerLogo: const FlowboardMark(size: 62),
      positionResetToken: resetToken,
      currentPageIndex: participantEditor.currentPageIndex,
      templateEntries: _radialTemplateEntries,
      pagePreviews: _radialPagePreviews,
      callbacks: _radialCallbacks(
        radial: radial,
        participant: participant,
        participantEditor: participantEditor,
        suppression: suppression,
        persistPosition: persistPosition,
      ),
      confineToBounds: confineToBounds,
      canUndo: participantEditor.canUndo,
      canRedo: participantEditor.canRedo,
    );
  }

  List<RadialPagePreview> get _radialPagePreviews {
    final pages = _editor.document.pages;
    if (identical(_radialPreviewPageSource, pages) &&
        _radialPreviewThumbnailRevision == _thumbnailImageRevision) {
      return _cachedRadialPagePreviews;
    }
    _radialPreviewPageSource = pages;
    _radialPreviewThumbnailRevision = _thumbnailImageRevision;
    _cachedRadialPagePreviews =
        List<RadialPagePreview>.unmodifiable(<RadialPagePreview>[
          for (var index = 0; index < pages.length; index++)
            RadialPagePreview(
              pageIndex: index,
              pageNumber: index + 1,
              pageId: pages[index].id,
              thumbnail: _thumbnails[pages[index].id],
              semanticLabel: pages[index].name,
            ),
        ]);
    return _cachedRadialPagePreviews;
  }

  RadialMenuCallbacks _radialCallbacks({
    required RadialMenuController radial,
    required BoardParticipantController participant,
    required EditorController participantEditor,
    required ValueNotifier<bool> suppression,
    required bool persistPosition,
  }) => RadialMenuCallbacks(
    onFiveFingerPageGestureChanged: (active) {
      if (suppression.value != active) suppression.value = active;
    },
    onPositionChanged: persistPosition
        ? (position) {
            if (_layoutSize.isEmpty) return;
            _editor.updateRadialMenuPosition(
              Offset(
                position.dx / _layoutSize.width,
                position.dy / _layoutSize.height,
              ),
            );
          }
        : null,
    onPrimaryAction: (action) {
      switch (action) {
        case RadialMenuAction.pen:
          if (radial.activeBranch == RadialMenuBranch.pen) {
            _setParticipantTool(participant, BoardTool.pen);
          }
        case RadialMenuAction.redo:
          participantEditor.redo();
        case RadialMenuAction.selection:
          if (radial.activeBranch == RadialMenuBranch.selection) {
            _setParticipantTool(participant, BoardTool.selectRectangle);
          }
        case RadialMenuAction.templates:
          _resumeParticipantAfterShape(participant);
          unawaited(_reloadUserTemplates(reportErrors: true));
        case RadialMenuAction.nextPage:
          _resumeParticipantAfterShape(participant);
          participantEditor.nextPage();
        case RadialMenuAction.newPage:
          _resumeParticipantAfterShape(participant);
          _addPageAndShowWheel(source: radial, editor: participantEditor);
        case RadialMenuAction.previousPage:
          _resumeParticipantAfterShape(participant);
          participantEditor.previousPage();
        case RadialMenuAction.insert:
          break;
        case RadialMenuAction.export:
          _resumeParticipantAfterShape(participant);
        case RadialMenuAction.undo:
          participantEditor.undo();
      }
    },
    onPenSettingsChanged: (settings) =>
        _updateParticipantDrawingSettings(participant, settings),
    onCustomColorRequested: _chooseCustomPenColor,
    onSelectionToolChanged: (tool) {
      switch (tool) {
        case RadialSelectionTool.rectangle:
          _setParticipantTool(participant, BoardTool.selectRectangle);
        case RadialSelectionTool.lasso:
          _setParticipantTool(participant, BoardTool.selectLasso);
        case RadialSelectionTool.selectAll:
          _setParticipantTool(participant, BoardTool.selectRectangle);
          participantEditor.selectAll();
      }
    },
    onPageSelected: participantEditor.goToPage,
    onPageDeleteRequested: (preview) {
      final stableId = preview.pageId;
      final fallbackIndex = preview.pageIndex;
      final pageId =
          stableId ??
          (fallbackIndex >= 0 &&
                  fallbackIndex < participantEditor.document.pages.length
              ? participantEditor.document.pages[fallbackIndex].id
              : null);
      if (pageId != null) {
        unawaited(_confirmAndDeletePage(participantEditor, pageId));
      }
    },
    onTemplateSelected: (entry) =>
        _useRadialTemplate(entry, editor: participantEditor),
    onShapeRequested: (shape) =>
        _armParticipantShape(participant, _shapeKind(shape)),
    onImageRequested: (source) => unawaited(
      source == RadialImageSource.device
          ? _pickImage(participant: participant)
          : _searchImage(participant: participant),
    ),
    onTableRequested: (size) => unawaited(
      _configureAndInsertTable(
        size,
        at: _participantInsertOrigin(participant),
        participant: participant,
        editor: participantEditor,
        radial: radial,
      ),
    ),
    onPdfRequested: (_) => unawaited(
      _pickPdf(participant: participant, editor: participantEditor),
    ),
    onCoverRequested: (direction) {
      participantEditor.addCover(
        at: _participantInsertOrigin(participant),
        direction: direction == RadialCoverDirection.horizontal
            ? RevealDirection.leftToRight
            : RevealDirection.topToBottom,
      );
      participant.setTool(BoardTool.selectRectangle);
    },
    onExportRequested: (action) => unawaited(switch (action) {
      RadialExportAction.savePdf => _savePdf(),
      RadialExportAction.shareLocal => _sharePdf(),
      RadialExportAction.quickShare => _quickSharePdf(),
    }),
  );

  Future<Color?> _chooseCustomPenColor(Color current) async {
    final selected = await showDialog<Color>(
      context: context,
      builder: (_) => PenColorPickerDialog(
        initialColor: current,
        recentColors: _editor.recentCustomPenColors
            .map(Color.new)
            .toList(growable: false),
      ),
    );
    if (selected != null && mounted) {
      _editor.rememberCustomPenColor(selected.toARGB32());
    }
    return selected;
  }

  void _applyQuickPen(
    EditorController editor, {
    Color? color,
    InkToolType? type,
  }) {
    final secondary = identical(editor, _secondaryEditor);
    final participant = secondary ? _secondaryParticipant : _primaryParticipant;
    final radial = secondary ? _secondaryRadial : _radial;
    final current = participant.penStyle;
    final nextColor = color ?? Color(current.colorArgb);
    final nextType = type ?? current.type;
    _updateParticipantPen(
      participant,
      colorArgb: nextColor.toARGB32(),
      width: current.width,
      type: nextType,
    );
    radial.setPenSettings(
      RadialPenSettings(
        color: nextColor,
        thickness: current.width.clamp(1, 32),
        type: _radialType(nextType),
      ),
    );
  }

  void _applyQuickPenType(EditorController editor, RadialPenType type) {
    final inkType = _inkType(type);
    if (inkType != null) {
      _applyQuickPen(
        editor,
        color: type == RadialPenType.marker
            ? RadialPenSettings.markerDefaultColor
            : null,
        type: inkType,
      );
      return;
    }

    final secondary = identical(editor, _secondaryEditor);
    final participant = secondary ? _secondaryParticipant : _primaryParticipant;
    final radial = secondary ? _secondaryRadial : _radial;
    _setParticipantTool(participant, BoardTool.eraser);
    radial.setPenSettings(radial.penSettings.copyWith(type: type));
  }

  Future<void> _chooseQuickPenColor(EditorController editor) async {
    final participant = identical(editor, _secondaryEditor)
        ? _secondaryParticipant
        : _primaryParticipant;
    final selected = await _chooseCustomPenColor(
      Color(participant.penStyle.colorArgb),
    );
    if (selected != null && mounted) {
      _applyQuickPen(editor, color: selected);
    }
  }

  bool _isPrimaryParticipant(BoardParticipantController participant) =>
      identical(participant, _primaryParticipant);

  EditorController _editorFor(BoardParticipantController participant) =>
      _isPrimaryParticipant(participant) ? _editor : _secondaryEditor;

  void _setParticipantTool(
    BoardParticipantController participant,
    BoardTool tool,
  ) {
    _editorFor(participant).setTool(tool);
    participant.setTool(tool);
  }

  void _updateParticipantPen(
    BoardParticipantController participant, {
    required int colorArgb,
    required double width,
    required InkToolType type,
  }) {
    _editorFor(
      participant,
    ).updatePen(colorArgb: colorArgb, width: width, type: type);
    participant.updatePen(colorArgb: colorArgb, width: width, type: type);
  }

  void _updateParticipantDrawingSettings(
    BoardParticipantController participant,
    RadialPenSettings settings,
  ) {
    final inkType = _inkType(settings.type);
    if (inkType == null) {
      // The eraser has no manually configured width. Preserve the participant's
      // ink width and let BoardSurface derive one screen-space footprint from
      // every physical eraser/palm contact.
      _editorFor(participant).setTool(BoardTool.eraser);
      participant.selectEraser();
      return;
    }
    _updateParticipantPen(
      participant,
      colorArgb: settings.color.toARGB32(),
      width: settings.thickness,
      type: inkType,
    );
  }

  void _armParticipantShape(
    BoardParticipantController participant,
    ShapeKind shape,
  ) {
    _editorFor(participant).armShape(shape);
    participant.armShape(shape);
  }

  void _resumeParticipantAfterShape(BoardParticipantController participant) {
    if (participant.tool != BoardTool.shape) return;
    _editorFor(participant).resumeConfiguredInkTool();
    final style = participant.penStyle;
    participant.updatePen(
      colorArgb: style.colorArgb,
      width: style.width,
      type: style.type,
    );
  }

  Offset _participantInsertOrigin(BoardParticipantController participant) {
    final isSplit = _participantMode == EditorParticipantMode.twoPeople;
    final regionWidth = isSplit
        ? math.max(1.0, (_layoutSize.width - 3) / 2)
        : math.max(1.0, _layoutSize.width);
    final regionHeight = math.max(1.0, _layoutSize.height);
    final regionCenterX = isSplit && !_isPrimaryParticipant(participant)
        ? regionWidth * 1.5 + 3
        : regionWidth / 2;
    return _editorFor(
      participant,
    ).viewport.screenToWorld(Offset(regionCenterX, regionHeight / 2));
  }

  void _setParticipantMode(EditorParticipantMode mode) {
    if (_participantMode == mode) return;
    DiagnosticLogService.instance.info(
      'editor.participant_mode_changed',
      fields: {'mode': mode.name},
    );
    _radial
      ..setBranch(null)
      ..setOpen(false);
    _secondaryRadial
      ..setBranch(null)
      ..setOpen(false);
    _radialPageGestureActive.value = false;
    _secondaryRadialPageGestureActive.value = false;

    if (mode == EditorParticipantMode.twoPeople) {
      _secondaryEditor.synchronizeParticipantViewFrom(_editor);
      _primaryParticipant.synchronize(
        tool: _editor.tool,
        activeShape: _editor.activeShape,
        penStyle: _editor.penStyle,
      );
      if (!_secondaryParticipantInitialized) {
        _secondaryParticipant.synchronize(
          tool: _primaryParticipant.tool,
          activeShape: _primaryParticipant.activeShape,
          penStyle: _primaryParticipant.penStyle,
        );
        _secondaryEditor.updatePen(
          colorArgb: _primaryParticipant.penStyle.colorArgb,
          width: _primaryParticipant.penStyle.width,
          type: _primaryParticipant.penStyle.type,
        );
        if (_primaryParticipant.tool == BoardTool.shape) {
          _secondaryEditor.armShape(_primaryParticipant.activeShape);
        } else {
          _secondaryEditor.setTool(_primaryParticipant.tool);
        }
        _secondaryRadial.setPenSettings(
          RadialPenSettings(
            color: Color(_secondaryParticipant.penStyle.colorArgb),
            thickness: _secondaryParticipant.penStyle.width,
            type: _secondaryParticipant.tool == BoardTool.eraser
                ? RadialPenType.eraser
                : _radialType(_secondaryParticipant.penStyle.type),
          ),
        );
        _secondaryParticipantInitialized = true;
      }
    } else {
      // Right-side insertions legitimately update the shared controller's
      // transient tool so their new object can be resized. When the split is
      // removed, restore the left/primary participant's tool before the solo
      // surface starts listening again; otherwise the first pen-down can
      // clear a selection and immediately synchronize back to the stale
      // right-side tool.
      if (_primaryParticipant.tool == BoardTool.shape) {
        _editor.armShape(_primaryParticipant.activeShape);
      } else {
        _editor.setTool(_primaryParticipant.tool);
      }
    }

    final splitWorldBoundary = _editor.viewport.worldBounds.center.dx;
    if (mode == EditorParticipantMode.twoPeople) {
      _editor.setContentHorizontalConstraint(
        BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.left,
          worldBoundaryX: splitWorldBoundary,
        ),
      );
      _secondaryEditor.setContentHorizontalConstraint(
        BoardViewportHorizontalConstraint(
          side: BoardViewportPartitionSide.right,
          worldBoundaryX: splitWorldBoundary,
        ),
      );
    } else {
      _editor.setContentHorizontalConstraint(null);
      _secondaryEditor.setContentHorizontalConstraint(null);
    }

    setState(() {
      _participantMode = mode;
      _radialPositionResetToken++;
      _secondaryRadialPositionResetToken++;
    });
    if (mode == EditorParticipantMode.twoPeople) {
      _alignParticipantViewportsToDivider();
    }
  }

  void _alignParticipantViewportsToDivider() {
    final size = _layoutSize;
    if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) return;

    const dividerWidth = 3.0;
    final halfWidth = math.max(0.0, (size.width - dividerWidth) / 2);
    final leftRegion = Rect.fromLTWH(0, 0, halfWidth, size.height);
    final rightRegion = Rect.fromLTWH(
      halfWidth + dividerWidth,
      0,
      halfWidth,
      size.height,
    );
    final splitWorldBoundary = _editor.viewport.worldBounds.center.dx;
    _editor.viewport.alignToHorizontalPartition(
      viewportSize: size,
      visibleScreenBounds: leftRegion,
      horizontalConstraint: BoardViewportHorizontalConstraint(
        side: BoardViewportPartitionSide.left,
        worldBoundaryX: splitWorldBoundary,
      ),
    );
    _secondaryEditor.viewport.alignToHorizontalPartition(
      viewportSize: size,
      visibleScreenBounds: rightRegion,
      horizontalConstraint: BoardViewportHorizontalConstraint(
        side: BoardViewportPartitionSide.right,
        worldBoundaryX: splitWorldBoundary,
      ),
    );
  }

  void _showLargeTimer() {
    if (!mounted) return;
    if (!_largeTimerPresenter.show(context, controller: _countdownTimer)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showLargeTimer();
      });
    }
  }

  void _onEditorChanged() {
    if (!mounted) return;
    if (_participantMode == EditorParticipantMode.onePerson) {
      _primaryParticipant.synchronize(
        tool: _editor.tool,
        activeShape: _editor.activeShape,
        penStyle: _editor.penStyle,
      );
    }
    final currentDocument = _editor.document;
    if (!identical(_thumbnailObservedDocument, currentDocument)) {
      _thumbnailObservedDocument = currentDocument;
      final invalidation = _thumbnailInvalidation.synchronize(currentDocument);
      if (!invalidation.isEmpty) {
        _thumbnailGeneration++;
        for (final pageId in invalidation.removedPageIds) {
          final oldImage = _thumbnails.remove(pageId);
          if (oldImage != null) _disposeThumbnailAfterFrame(oldImage);
          _thumbnailIdentity.remove(pageId);
          _thumbnailImageRevision++;
        }
      }
      if (invalidation.dirtyPageIds.isNotEmpty) {
        _scheduleThumbnailRefresh();
      }
    }
    final nextSnapshot = _EditorShellSnapshot.from(_editor);
    if (nextSnapshot == _primaryShellSnapshot) return;
    _primaryShellSnapshot = nextSnapshot;
    setState(() {});
  }

  void _onSecondaryEditorChanged() {
    if (!mounted) return;
    final nextSnapshot = _EditorShellSnapshot.from(_secondaryEditor);
    if (nextSnapshot == _secondaryShellSnapshot) return;
    _secondaryShellSnapshot = nextSnapshot;
    setState(() {});
  }

  Offset _initialRadialPosition(Size size) {
    final saved = _editor.radialMenuPositionNormalized;
    if (saved != null) {
      return Offset(saved.dx * size.width, saved.dy * size.height);
    }
    return Offset(
      size.width - math.min(330, size.width * .28),
      size.height - math.min(320, size.height * .34),
    );
  }

  void _resetRadialMenuPosition() {
    setState(() {
      _radialPositionResetToken++;
      if (_participantMode == EditorParticipantMode.twoPeople) {
        _secondaryRadialPositionResetToken++;
      }
    });
  }

  void _scheduleThumbnailRefresh() {
    _thumbnailDebounce?.cancel();
    _thumbnailDebounce = Timer(const Duration(milliseconds: 850), () {
      _startThumbnailRefresh();
    });
  }

  void _startThumbnailRefresh() {
    if (_inkInputIsLatencySensitive) {
      _scheduleThumbnailRefresh();
      return;
    }
    unawaited(
      _drainThumbnailRefresh().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Flowboard page thumbnails',
            context: ErrorDescription('while refreshing page thumbnails'),
          ),
        );
      }),
    );
  }

  Future<void> _drainThumbnailRefresh() async {
    if (_thumbnailRefreshRunning) {
      _thumbnailRefreshQueued = true;
      return;
    }
    _thumbnailRefreshRunning = true;
    try {
      do {
        _thumbnailRefreshQueued = false;
        if (_pageSheetOpen) {
          _thumbnailRefreshQueued = true;
          break;
        }
        await _refreshThumbnails();
      } while (mounted && !_pageSheetOpen && _thumbnailRefreshQueued);
    } finally {
      _thumbnailRefreshRunning = false;
    }
  }

  Future<void> _refreshThumbnails() async {
    final generation = _thumbnailGeneration;
    final document = _editor.document;
    final pending = <({String pageId, int identity, ui.Image image})>[];

    void discardPending() {
      for (final entry in pending) {
        entry.image.dispose();
      }
      pending.clear();
    }

    Future<void> publishPending() async {
      if (pending.isEmpty) return;
      if (!mounted ||
          generation != _thumbnailGeneration ||
          _pageSheetOpen ||
          _inkInputIsLatencySensitive) {
        discardPending();
        return;
      }
      final staleImages = <ui.Image>[];
      var changed = false;
      for (final entry in pending) {
        if (_thumbnailInvalidation.revisionFor(entry.pageId) !=
            entry.identity) {
          entry.image.dispose();
          continue;
        }
        final oldImage = _thumbnails[entry.pageId];
        _thumbnails[entry.pageId] = entry.image;
        _thumbnailIdentity[entry.pageId] = entry.identity;
        _thumbnailImageRevision++;
        changed = true;
        if (oldImage != null && !identical(oldImage, entry.image)) {
          staleImages.add(oldImage);
        }
      }
      pending.clear();
      if (!changed || !mounted) {
        for (final image in staleImages) {
          image.dispose();
        }
        return;
      }
      // Publishing several previews in one frame avoids rebuilding both board
      // surfaces and radial menus once per page during a 100-page recovery.
      setState(() {});
      await SchedulerBinding.instance.endOfFrame;
      for (final image in staleImages) {
        image.dispose();
      }
    }

    final pageCount = document.pages.length;
    final currentIndex = document.currentPageIndex;
    for (var order = 0; order < pageCount; order++) {
      final pageIndex = order == 0
          ? currentIndex
          : order <= currentIndex
          ? order - 1
          : order;
      final page = document.pages[pageIndex];
      if (_inkInputIsLatencySensitive) {
        discardPending();
        _scheduleThumbnailRefresh();
        return;
      }
      if (_pageSheetOpen) {
        discardPending();
        _thumbnailRefreshQueued = true;
        return;
      }
      final identity = _thumbnailInvalidation.revisionFor(page.id);
      if (identity == null) continue;
      if (_thumbnailIdentity[page.id] == identity) continue;
      ui.Image image;
      try {
        image = await _thumbnailRenderer.render(
          page,
          _editor.assetResolver,
          shouldCancel: () =>
              !mounted ||
              generation != _thumbnailGeneration ||
              _pageSheetOpen ||
              _inkInputIsLatencySensitive,
        );
      } on PageThumbnailRenderCancelled {
        discardPending();
        if (!mounted) return;
        if (_pageSheetOpen) {
          _thumbnailRefreshQueued = true;
        } else if (_inkInputIsLatencySensitive) {
          _scheduleThumbnailRefresh();
        }
        return;
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Flowboard page thumbnails',
            context: ErrorDescription(
              'while rendering thumbnail for page ${page.id}',
            ),
          ),
        );
        continue;
      }
      if (!mounted ||
          generation != _thumbnailGeneration ||
          _pageSheetOpen ||
          _inkInputIsLatencySensitive ||
          _thumbnailInvalidation.revisionFor(page.id) != identity) {
        image.dispose();
        discardPending();
        if (_pageSheetOpen) {
          _thumbnailRefreshQueued = true;
        } else if (_inkInputIsLatencySensitive) {
          _scheduleThumbnailRefresh();
        }
        return;
      }
      pending.add((pageId: page.id, identity: identity, image: image));
      if (order == 0 || pending.length >= 8) {
        await publishPending();
      }
    }
    await publishPending();
  }

  static const Duration _thumbnailInkQuietPeriod = Duration(milliseconds: 2200);

  bool get _inkInputIsLatencySensitive =>
      _editor.inkSessions.isWriting ||
      _editor.inkSessions.wasActiveWithin(_thumbnailInkQuietPeriod) ||
      (_participantMode == EditorParticipantMode.twoPeople &&
          (_secondaryEditor.inkSessions.isWriting ||
              _secondaryEditor.inkSessions.wasActiveWithin(
                _thumbnailInkQuietPeriod,
              )));

  void _disposeThumbnailAfterFrame(ui.Image image) {
    SchedulerBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  Future<void> _leave() async {
    if (_countdownTimer.isAlarmActive) {
      // Back navigation must not silently dispose the controller and thereby
      // stop an unacknowledged alarm. Bring its explicit confirmation back to
      // the foreground instead.
      _showLargeTimer();
      return;
    }
    if (_leaving) return;
    _leaving = true;
    try {
      await _editor.flush();
      if (!mounted) return;
      if (_countdownTimer.isAlarmActive) {
        // The timer may have expired while the asynchronous flush was in
        // progress. Never dispose its repeating alarm without the explicit
        // acknowledgement in the large panel.
        _showLargeTimer();
        return;
      }
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        _showError(
          'Das Whiteboard konnte noch nicht sicher gespeichert werden: $error',
        );
      }
    } finally {
      _leaving = false;
    }
  }

  Future<void> _rename() async {
    var draftTitle = _editor.document.title;
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Whiteboard umbenennen'),
        content: TextFormField(
          initialValue: draftTitle,
          autofocus: true,
          maxLength: 80,
          onChanged: (value) => draftTitle = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draftTitle),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (title != null && mounted) _editor.rename(title);
  }

  Future<UserTemplateStore> _templateStore() {
    return _userTemplateStore ??= getApplicationSupportDirectory().then(
      (support) => UserTemplateStore(
        directory: Directory(p.join(support.path, 'FlowboardX')),
      ),
    );
  }

  List<RadialTemplateEntry> get _radialTemplateEntries => <RadialTemplateEntry>[
    for (final definition in TemplateFactory.definitions)
      RadialTemplateEntry(
        id: 'builtIn:${definition.kind.name}',
        label: definition.title,
        source: RadialTemplateSource.builtIn,
        semanticLabel: '${definition.title}: ${definition.description}',
        icon: switch (definition.kind) {
          TemplateKind.overlappingCircles => Icons.join_inner_rounded,
          TemplateKind.mindMap => Icons.hub_outlined,
          TemplateKind.primarySchoolLines => Icons.view_stream_outlined,
          TemplateKind.vennDiagram => Icons.bubble_chart_outlined,
        },
      ),
    RadialTemplateEntry(
      id: 'user-library',
      label: 'Eigene Vorlagen',
      source: RadialTemplateSource.user,
      semanticLabel: _userTemplates.isEmpty
          ? 'Eigene Vorlagen öffnen, noch keine Vorlage gespeichert'
          : 'Eigene Vorlagen öffnen, ${_userTemplates.length} gespeichert',
      icon: Icons.collections_bookmark_outlined,
    ),
  ];

  Future<void> _reloadUserTemplates({bool reportErrors = false}) async {
    final load = _templateStore().then((store) => store.load());
    _userTemplateLoad = load;
    try {
      final templates = await load;
      if (!mounted || !identical(_userTemplateLoad, load)) return;
      setState(() => _userTemplates = templates);
    } catch (error) {
      if (mounted && identical(_userTemplateLoad, load) && reportErrors) {
        _showError('Nutzervorlagen konnten nicht geladen werden: $error');
      }
    }
  }

  void _useRadialTemplate(
    RadialTemplateEntry entry, {
    EditorController? editor,
  }) {
    final targetEditor = editor ?? _editor;
    if (entry.source == RadialTemplateSource.builtIn) {
      TemplateKind? selected;
      for (final kind in TemplateKind.values) {
        if (entry.id == 'builtIn:${kind.name}') {
          selected = kind;
          break;
        }
      }
      if (selected == null) {
        _showError('Die gewählte Vorlage ist nicht mehr verfügbar.');
        return;
      }
      targetEditor.addTemplate(selected);
      return;
    }

    if (entry.id == 'user-library') {
      unawaited(_showUserTemplateLibrary(editor: targetEditor));
      return;
    }

    final templateId = entry.id.startsWith('user:')
        ? entry.id.substring('user:'.length)
        : entry.id;
    UserTemplate? selected;
    for (final template in _userTemplates) {
      if (template.id == templateId) {
        selected = template;
        break;
      }
    }
    if (selected == null) {
      _showError('Die Nutzervorlage ist nicht mehr verfügbar.');
      unawaited(_reloadUserTemplates());
      return;
    }
    unawaited(_insertUserTemplate(selected, editor: targetEditor));
  }

  Future<void> _showUserTemplateLibrary({EditorController? editor}) async {
    await _reloadUserTemplates(reportErrors: true);
    if (!mounted) return;
    final selected = await UserTemplateLibraryDialog.show(
      context,
      userTemplates: _userTemplates,
      onDelete: _deleteUserTemplate,
    );
    if (selected == null || !mounted) return;
    await _insertUserTemplate(selected, editor: editor);
  }

  Future<bool> _deleteUserTemplate(UserTemplate template) async {
    if (_templateMutationRunning) {
      if (mounted) _showError('Eine Vorlage wird bereits verarbeitet.');
      return false;
    }
    _templateMutationRunning = true;
    Object? failure;
    var deleted = false;
    try {
      deleted = await (await _templateStore()).delete(template.id);
      await _reloadUserTemplates();
    } catch (error) {
      failure = error;
    } finally {
      _templateMutationRunning = false;
    }
    if (!mounted) return deleted && failure == null;
    if (failure != null) {
      _showError('Vorlage konnte nicht gelöscht werden: $failure');
      return false;
    }
    if (deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vorlage „${template.name}“ wurde gelöscht.')),
      );
    }
    return deleted;
  }

  Future<void> _insertUserTemplate(
    UserTemplate template, {
    EditorController? editor,
  }) async {
    if (!mounted) return;
    if (_templateMutationRunning) {
      _showError('Eine Vorlage wird bereits verarbeitet.');
      return;
    }
    _templateMutationRunning = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Vorlage „${template.name}“ wird eingefügt …'),
        duration: const Duration(minutes: 5),
      ),
    );
    Object? failure;
    try {
      final store = await _templateStore();
      await (editor ?? _editor).addUserTemplate(store, template);
    } catch (error) {
      failure = error;
    }
    _templateMutationRunning = false;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    if (failure == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Vorlage „${template.name}“ wurde eingefügt.')),
      );
    } else {
      _showError('Vorlage konnte nicht eingefügt werden: $failure');
    }
  }

  Future<void> _saveCurrentPageAsTemplate() async {
    if (_templateMutationRunning) {
      _showError('Eine Vorlage wird bereits verarbeitet.');
      return;
    }
    var draftName = _editor.page.name;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Seite als Vorlage speichern'),
        content: TextFormField(
          initialValue: draftName,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Vorlagenname'),
          onChanged: (value) => draftName = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draftName),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    _templateMutationRunning = true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Vorlage und Medien werden sicher gespeichert …'),
        duration: Duration(minutes: 5),
      ),
    );
    Object? failure;
    try {
      await (await _templateStore()).save(
        name: name,
        page: _editor.page,
        sourceAssets: _editor.document.assets,
        sourceAssetDirectory: _editor.assetDirectory,
      );
      await _reloadUserTemplates();
    } catch (error) {
      failure = error;
    }
    _templateMutationRunning = false;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    if (failure == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Vorlage „${name.trim()}“ wurde gespeichert.')),
      );
    } else {
      _showError('Vorlage konnte nicht gespeichert werden: $failure');
    }
  }

  void _addPageAndShowWheel({
    RadialMenuController? source,
    EditorController? editor,
  }) {
    final targetEditor = editor ?? _editor;
    final previousCount = targetEditor.document.pages.length;
    targetEditor.addPage();
    if (targetEditor.document.pages.length == previousCount) return;
    final radial = source ?? _radial;
    radial.setOpen(true);
    radial.setBranch(RadialMenuBranch.pages);
  }

  Future<void> _confirmAndDeletePage(
    EditorController targetEditor,
    String pageId,
  ) async {
    if (_pageDeleteDialogOpen || !mounted) return;
    var pageIndex = targetEditor.document.pageIndexById(pageId);
    if (pageIndex == null) return;
    if (targetEditor.document.pages.length <= 1) {
      _showError('Die letzte verbleibende Seite kann nicht gelöscht werden.');
      return;
    }
    final pageNumber = pageIndex + 1;
    _pageDeleteDialogOpen = true;
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Seite $pageNumber löschen?'),
          content: const Text(
            'Die Seite und ihr gesamter Inhalt werden entfernt. '
            'Die Aktion kann anschließend rückgängig gemacht werden.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Seite löschen'),
            ),
          ],
        ),
      );
    } finally {
      _pageDeleteDialogOpen = false;
    }
    if (confirmed != true || !mounted) return;

    // A second participant may have added, removed or reordered pages while
    // the confirmation was visible. Revalidate the stable id and the final
    // page invariant immediately before executing the command.
    pageIndex = targetEditor.document.pageIndexById(pageId);
    if (pageIndex == null) return;
    if (targetEditor.document.pages.length <= 1) {
      _showError('Die letzte verbleibende Seite kann nicht gelöscht werden.');
      return;
    }
    targetEditor.deletePage(pageId);
  }

  Future<void> _showPagesSheet() async {
    final screen = MediaQuery.sizeOf(context);
    final itemExtent = math.min(290.0, math.max(230.0, screen.width * .24));
    _pageSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: math.min(1400, screen.width * .94),
        ),
        builder: (sheetContext) => _PagePickerSheet(
          height: (screen.height * .38).clamp(280, 390),
          itemExtent: itemExtent,
          viewportWidth: screen.width,
          pages: List<BoardPage>.of(_editor.document.pages),
          currentPageIndex: _editor.document.currentPageIndex,
          thumbnails: Map<String, ui.Image>.of(_thumbnails),
          onAddPage: () {
            Navigator.pop(sheetContext);
            _addPageAndShowWheel();
          },
          onPageSelected: (index) {
            Navigator.pop(sheetContext);
            _editor.goToPage(index);
          },
        ),
      );
    } finally {
      _pageSheetOpen = false;
      if (mounted && _thumbnailRefreshQueued) _startThumbnailRefresh();
    }
  }

  void _showEmptyMenu(
    Offset screen,
    Offset world, {
    EditorController? editor,
    BoardParticipantController? participant,
  }) {
    final targetEditor = editor ?? _editor;
    final targetParticipant = participant ?? _primaryParticipant;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        screen.dx,
        screen.dy,
        screen.dx,
        screen.dy,
      ),
      items: [
        if (targetEditor.canPaste)
          const PopupMenuItem(
            value: 'paste',
            child: ListTile(
              leading: Icon(Icons.content_paste_rounded),
              title: Text('Einfügen aus Zwischenablage'),
            ),
          ),
        const PopupMenuItem(
          value: 'clearAll',
          child: ListTile(
            leading: Icon(Icons.delete_sweep_outlined),
            title: Text('Alles leeren'),
          ),
        ),
        PopupMenuItem(
          value: 'clearInk',
          child: ListTile(
            leading: Icon(Icons.gesture_rounded),
            title: Text('Handschriftliches leeren'),
          ),
        ),
        PopupMenuItem(
          value: 'insert',
          child: ListTile(
            leading: Icon(Icons.add_box_outlined),
            title: Text('Einfügen'),
          ),
        ),
      ],
    ).then((value) {
      if (!mounted) return;
      if (value == 'clearAll') {
        _confirmClear(handwritingOnly: false, editor: targetEditor);
      }
      if (value == 'clearInk') {
        _confirmClear(handwritingOnly: true, editor: targetEditor);
      }
      if (value == 'insert') {
        _showQuickInsert(
          world,
          editor: targetEditor,
          participant: targetParticipant,
        );
      }
      if (value == 'paste') targetEditor.pasteAt(world);
    });
  }

  Future<void> _confirmClear({
    required bool handwritingOnly,
    EditorController? editor,
  }) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              handwritingOnly
                  ? 'Handschrift löschen?'
                  : 'Seite vollständig leeren?',
            ),
            content: const Text(
              'Die Aktion kann anschließend mit Undo rückgängig gemacht werden.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Leeren'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed && mounted) {
      (editor ?? _editor).clearPage(handwritingOnly: handwritingOnly);
    }
  }

  Future<void> _showQuickInsert(
    Offset world, {
    EditorController? editor,
    BoardParticipantController? participant,
  }) async {
    final targetEditor = editor ?? _editor;
    final targetParticipant = participant ?? _primaryParticipant;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            for (final item in const [
              ('shape', Icons.category_outlined, 'Rechteck'),
              ('image', Icons.image_outlined, 'Bild'),
              ('table', Icons.table_chart_outlined, 'Tabelle'),
              ('pdf', Icons.picture_as_pdf_outlined, 'PDF'),
              ('cover', Icons.visibility_off_outlined, 'Abdeckung'),
            ])
              ListTile(
                leading: Icon(item.$2),
                title: Text(item.$3),
                onTap: () => Navigator.pop(context, item.$1),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'shape':
        targetEditor.addShape(
          ShapeKind.rectangle,
          Rect.fromLTWH(world.dx, world.dy, 420, 260),
        );
        targetParticipant.setTool(BoardTool.selectRectangle);
      case 'image':
        await _pickImage(participant: targetParticipant);
      case 'table':
        await _configureAndInsertTable(
          const RadialTableSize(3, 4),
          at: world,
          participant: targetParticipant,
          editor: targetEditor,
        );
      case 'pdf':
        await _pickPdf(participant: targetParticipant, editor: targetEditor);
      case 'cover':
        targetEditor.addCover(at: world);
        targetParticipant.setTool(BoardTool.selectRectangle);
      case null:
        break;
    }
  }

  Future<void> _pickImage({BoardParticipantController? participant}) async {
    final targetParticipant = participant ?? _primaryParticipant;
    final targetEditor = _editorFor(targetParticipant);
    final insertionOrigin = _participantInsertOrigin(targetParticipant);
    try {
      _resumeParticipantAfterShape(targetParticipant);
      final picked = await FilePicker.pickFiles(
        dialogTitle: 'Bild einfügen',
        type: FileType.custom,
        allowedExtensions: const [
          'jpg',
          'jpeg',
          'png',
          'webp',
          'gif',
          'bmp',
          'heic',
        ],
        allowMultiple: false,
      );
      if (!mounted || picked == null || picked.files.isEmpty) return;
      final file = picked.files.single;
      final path = file.path;
      if (path == null) return;
      final extension = p.extension(path).toLowerCase();
      final mime = switch (extension) {
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.bmp' => 'image/bmp',
        '.heic' => 'image/heic',
        _ => 'image/jpeg',
      };
      await targetEditor.importImage(path, mimeType: mime, at: insertionOrigin);
      targetParticipant.setTool(BoardTool.selectRectangle);
    } catch (error) {
      if (mounted) _showError('Bild konnte nicht eingefügt werden: $error');
    }
  }

  Future<void> _searchImage({BoardParticipantController? participant}) async {
    final targetParticipant = participant ?? _primaryParticipant;
    final targetEditor = _editorFor(targetParticipant);
    final insertionOrigin = _participantInsertOrigin(targetParticipant);
    final service = WebImageSearchService();
    try {
      _resumeParticipantAfterShape(targetParticipant);
      final result = await showDialog<ImageSearchResult>(
        context: context,
        builder: (context) => GoogleImageBrowserDialog(service: service),
      );
      if (!mounted || result == null) return;
      final bytes = await service.download(result);
      if (!mounted) return;
      final mimeType =
          WebImageSearchService.detectImageMimeType(bytes) ??
          result.mimeType ??
          'image/jpeg';
      final extension = switch (mimeType) {
        'image/png' => '.png',
        'image/gif' => '.gif',
        'image/webp' => '.webp',
        'image/bmp' => '.bmp',
        _ => '.jpg',
      };
      await targetEditor.importImageBytes(
        bytes,
        fileName: 'google-image$extension',
        mimeType: mimeType,
        at: insertionOrigin,
      );
      targetParticipant.setTool(BoardTool.selectRectangle);
    } catch (error) {
      if (mounted) _showError('Web-Bild konnte nicht eingefügt werden: $error');
    } finally {
      service.dispose();
    }
  }

  Future<void> _configureAndInsertTable(
    RadialTableSize initialSize, {
    Offset? at,
    BoardParticipantController? participant,
    EditorController? editor,
    RadialMenuController? radial,
  }) async {
    final targetParticipant = participant ?? _primaryParticipant;
    final targetEditor = editor ?? _editorFor(targetParticipant);
    if (_insertConfigurationOpen) return;
    _insertConfigurationOpen = true;
    try {
      // Opening Insert arms the rectangle preview by default. A category
      // switch must disarm it immediately, including when this is cancelled.
      _resumeParticipantAfterShape(targetParticipant);
      final selected = await TableInsertDialog.show(
        context,
        initialSize: initialSize,
      );
      if (!mounted || selected == null) return;
      (radial ?? _radial).setTableSize(selected);
      targetEditor.addTable(
        rows: selected.rows,
        columns: selected.columns,
        at: at,
      );
      targetParticipant.setTool(BoardTool.selectRectangle);
    } finally {
      _insertConfigurationOpen = false;
    }
  }

  Future<void> _pickPdf({
    BoardParticipantController? participant,
    EditorController? editor,
  }) async {
    final targetParticipant = participant ?? _primaryParticipant;
    final targetEditor = editor ?? _editorFor(targetParticipant);
    final insertionOrigin = _participantInsertOrigin(targetParticipant);
    if (_pdfImportCoordinator.isRunning) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Die PDF-Auswahl ist bereits geöffnet.'),
          ),
        );
      }
      return;
    }
    try {
      _resumeParticipantAfterShape(targetParticipant);
      await _pdfImportCoordinator.run<
        _OpenedPdfPreview,
        PdfImportSelection,
        void
      >(
        openPreview: () async {
          final picked = await FilePicker.pickFiles(
            dialogTitle: 'PDF einfügen',
            type: FileType.custom,
            allowedExtensions: const ['pdf'],
          );
          if (!mounted || picked == null || picked.files.isEmpty) return null;
          final path = picked.files.first.path;
          if (path == null || path.trim().isEmpty) {
            throw const FormatException(
              'Die ausgewählte PDF besitzt keinen lesbaren Dateipfad.',
            );
          }
          await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);
          final document = await PdfDocument.openFile(path);
          if (!mounted) {
            await document.dispose();
            return null;
          }
          if (document.pages.isEmpty) {
            await document.dispose();
            throw const FormatException(
              'Die ausgewählte PDF enthält keine darstellbaren Seiten.',
            );
          }
          return _OpenedPdfPreview(path: path, document: document);
        },
        selectPages: (preview) => PdfImportDialog.show(
          context,
          document: preview.document,
          fileName: p.basename(preview.path),
        ),
        disposePreview: (preview) => preview.document.dispose(),
        importSelection: (preview, selection) async {
          if (!mounted) return;
          final mode = switch (selection.mode) {
            RadialPdfImportMode.singlePage => PdfImportMode.singlePage,
            RadialPdfImportMode.pageRange => PdfImportMode.pageRange,
            RadialPdfImportMode.allPages => PdfImportMode.wholeDocument,
          };
          // The coordinator has disposed the preview before this copy starts.
          // That avoids intermittent source-file locking on Windows.
          await targetEditor.importPdf(
            preview.path,
            mode: mode,
            placement: selection.placement,
            pageIndices: selection.pageIndices,
            at: insertionOrigin,
          );
          targetParticipant.setTool(BoardTool.selectRectangle);
        },
      );
    } catch (error) {
      if (mounted) _showError('PDF konnte nicht eingefügt werden: $error');
    }
  }

  Future<void> _savePdf() async {
    if (_exporting) return;
    final fileName = '${_safeFileName(_editor.document.title)}.pdf';
    final useAndroidSaf = AndroidPdfFileSaver.instance.isSupported;
    PreparedBoardExport? prepared;
    File? destination;
    String? output;
    setState(() {
      _exporting = true;
      _exportProgress = 0;
    });
    try {
      if (!useAndroidSaf) {
        if (Platform.isIOS) {
          final directory = await getApplicationDocumentsDirectory();
          if (!mounted) return;
          output = p.join(directory.path, 'Exports', fileName);
        } else {
          output = await FilePicker.saveFile(
            dialogTitle: 'Whiteboard als PDF speichern',
            fileName: fileName,
            type: FileType.custom,
            allowedExtensions: const ['pdf'],
          );
          if (!mounted) return;
        }
        if (output == null) return;
        if (!output.toLowerCase().endsWith('.pdf')) output = '$output.pdf';
      } else {
        final directory = await getTemporaryDirectory();
        if (!mounted) return;
        output = p.join(
          directory.path,
          'flowboard-export-${DateTime.now().microsecondsSinceEpoch}.pdf',
        );
      }
      destination = File(output);
      prepared = await const BoardExportFactory().prepare(
        _editor.document,
        _editor.assetResolver,
      );
      if (!mounted) return;
      await const PdfExporter().exportToFile(
        prepared.snapshot,
        destination,
        overwrite: true,
        onProgress: (progress) {
          if (mounted) setState(() => _exportProgress = progress.fraction);
        },
      );
      if (!mounted) return;
      Uri? savedUri;
      if (useAndroidSaf) {
        savedUri = await AndroidPdfFileSaver.instance.save(
          destination,
          suggestedName: fileName,
        );
        if (savedUri == null) return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              useAndroidSaf
                  ? 'PDF wurde am gewählten Speicherort gespeichert.'
                  : 'PDF gespeichert: $output',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) _showError('PDF-Export fehlgeschlagen: $error');
    } finally {
      prepared?.dispose();
      if (useAndroidSaf && destination != null) {
        try {
          if (await destination.exists()) await destination.delete();
        } on Object {
          // Temporary export cleanup is best-effort.
        }
      }
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _sharePdf() async {
    if (_exporting) return;
    PreparedBoardExport? prepared;
    File? file;
    var retry = false;
    setState(() {
      _exporting = true;
      _exportProgress = null;
    });
    try {
      prepared = await const BoardExportFactory().prepare(
        _editor.document,
        _editor.assetResolver,
      );
      if (!mounted) return;
      final directory = await getTemporaryDirectory();
      file = File(
        p.join(
          directory.path,
          '${_safeFileName(_editor.document.title)}-share-'
          '${DateTime.now().microsecondsSinceEpoch}.pdf',
        ),
      );
      if (!mounted) return;
      setState(() => _exporting = false);
      final dialogFuture = showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => Dialog(
          child: QrSharePanel(
            controller: _shareController,
            onClose: () => Navigator.pop(dialogContext, false),
            onRetry: () => Navigator.pop(dialogContext, true),
          ),
        ),
      );
      final exportFuture = _shareController.exportAndShare(
        prepared.snapshot,
        file,
      );
      retry = await dialogFuture ?? false;
      // Closing the panel also cancels an export that is still running. This
      // prevents an invisible server from retaining the temporary file.
      await _shareController.stop();
      await exportFuture;
    } catch (error) {
      if (mounted) _showError('Lokale Freigabe fehlgeschlagen: $error');
    } finally {
      await _shareController.stop();
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } on Object {
          // Temporary share cleanup is best-effort.
        }
      }
      prepared?.dispose();
      if (mounted) setState(() => _exporting = false);
    }
    if (retry && mounted) {
      await _sharePdf();
    }
  }

  Future<void> _quickSharePdf() async {
    if (_exporting) return;
    if (!AndroidPdfQuickShare.instance.isSupported) {
      _showError('Quick Share ist auf diesem Gerät nicht verfügbar.');
      return;
    }
    PreparedBoardExport? prepared;
    File? file;
    setState(() {
      _exporting = true;
      _exportProgress = 0;
    });
    try {
      prepared = await const BoardExportFactory().prepare(
        _editor.document,
        _editor.assetResolver,
      );
      if (!mounted) return;
      final directory = await getTemporaryDirectory();
      if (!mounted) return;
      file = File(
        p.join(
          directory.path,
          'flowboard-quick-share-${DateTime.now().microsecondsSinceEpoch}.pdf',
        ),
      );
      await const PdfExporter().exportToFile(
        prepared.snapshot,
        file,
        overwrite: false,
        onProgress: (progress) {
          if (mounted) setState(() => _exportProgress = progress.fraction);
        },
      );
      if (!mounted) return;
      await AndroidPdfQuickShare.instance.share(
        file,
        suggestedName: '${_safeFileName(_editor.document.title)}.pdf',
        chooserTitle: 'PDF per Quick Share teilen',
      );
    } catch (error) {
      if (mounted) _showError('Quick Share fehlgeschlagen: $error');
    } finally {
      prepared?.dispose();
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } on Object {
          // Temporary share cleanup is best-effort.
        }
      }
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _shareDiagnosticLog() async {
    try {
      final directory = await getTemporaryDirectory();
      final file = await DiagnosticLogService.instance.createExportCopy(
        directory,
      );
      if (!mounted) return;
      if (file == null) {
        _showError('Es ist noch kein Diagnoseprotokoll verfügbar.');
        return;
      }
      DiagnosticLogService.instance.info('diagnostics.export_requested');
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: 'application/x-ndjson')],
          title: 'Flowboard-X-Diagnoseprotokoll',
          subject: 'Flowboard-X-Diagnoseprotokoll',
          sharePositionOrigin: _shareOrigin(),
        ),
      );
    } catch (error, stack) {
      DiagnosticLogService.instance.recordException(
        event: 'diagnostics.export_failed',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        _showError('Das Diagnoseprotokoll konnte nicht geteilt werden.');
      }
    }
  }

  Rect? _shareOrigin() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: FlowboardColors.danger),
    );
  }

  static String _safeFileName(String input) {
    final safe = input.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    return safe.isEmpty ? 'Flowboard' : safe;
  }

  static RadialPenType _radialType(InkToolType type) => switch (type) {
    InkToolType.normal => RadialPenType.normal,
    InkToolType.marker => RadialPenType.marker,
    InkToolType.dashed => RadialPenType.dashed,
    InkToolType.straightLine => RadialPenType.straight,
  };

  static InkToolType? _inkType(RadialPenType type) => switch (type) {
    RadialPenType.normal => InkToolType.normal,
    RadialPenType.marker => InkToolType.marker,
    RadialPenType.dashed => InkToolType.dashed,
    RadialPenType.straight => InkToolType.straightLine,
    RadialPenType.eraser => null,
  };

  static ShapeKind _shapeKind(RadialShapeKind kind) => switch (kind) {
    RadialShapeKind.rectangle => ShapeKind.rectangle,
    RadialShapeKind.circle => ShapeKind.circle,
    RadialShapeKind.ellipse => ShapeKind.ellipse,
    RadialShapeKind.triangle => ShapeKind.triangle,
  };
}

class _ParticipantPenQuickControls extends StatelessWidget {
  const _ParticipantPenQuickControls({
    required this.controlId,
    required this.participantLabel,
    required this.controller,
    required this.onColorChanged,
    required this.onCustomColorRequested,
    required this.onTypeChanged,
  });

  final String controlId;
  final String? participantLabel;
  final EditorController controller;
  final void Function(EditorController editor, Color color) onColorChanged;
  final ValueChanged<EditorController> onCustomColorRequested;
  final void Function(EditorController editor, RadialPenType type)
  onTypeChanged;

  @override
  Widget build(BuildContext context) {
    final label = participantLabel;
    return Semantics(
      key: ValueKey('editor-pen-quick-controls-$controlId'),
      container: true,
      label: label == null ? 'Stifteinstellungen' : 'Stifteinstellungen $label',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(left: 5, right: 1),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: FlowboardColors.mint,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          EditorPenColorQuickButton(
            controlId: controlId,
            color: Color(controller.penStyle.colorArgb),
            onColorSelected: (color) => onColorChanged(controller, color),
            onCustomColorRequested: () => onCustomColorRequested(controller),
          ),
          EditorPenTypeQuickButton(
            controlId: controlId,
            type: controller.tool == BoardTool.eraser
                ? RadialPenType.eraser
                : switch (controller.penStyle.type) {
                    InkToolType.normal => RadialPenType.normal,
                    InkToolType.marker => RadialPenType.marker,
                    InkToolType.dashed => RadialPenType.dashed,
                    InkToolType.straightLine => RadialPenType.straight,
                  },
            onTypeSelected: (type) => onTypeChanged(controller, type),
          ),
        ],
      ),
    );
  }
}

class _EditorTopBar extends StatelessWidget {
  const _EditorTopBar({
    required this.width,
    required this.collapsed,
    required this.controller,
    required this.secondaryController,
    required this.onBack,
    required this.onRename,
    required this.onPages,
    required this.onSaveCurrentPageAsTemplate,
    required this.onResetMenuPosition,
    required this.onHelp,
    required this.participantMode,
    required this.onParticipantModeChanged,
    required this.fingerDrawingEnabled,
    required this.onFingerDrawingChanged,
    required this.countdownTimer,
    required this.onShowLargeTimer,
    required this.onPenColorChanged,
    required this.onCustomPenColorRequested,
    required this.onPenTypeChanged,
    required this.onAddPage,
    required this.onDeletePage,
    required this.onToggleCollapsed,
  });

  final double width;
  final bool collapsed;
  final EditorController controller;
  final EditorController secondaryController;
  final Future<void> Function() onBack;
  final VoidCallback onRename;
  final VoidCallback? onPages;
  final VoidCallback onSaveCurrentPageAsTemplate;
  final VoidCallback onResetMenuPosition;
  final VoidCallback onHelp;
  final EditorParticipantMode participantMode;
  final ValueChanged<EditorParticipantMode> onParticipantModeChanged;
  final bool fingerDrawingEnabled;
  final ValueChanged<bool> onFingerDrawingChanged;
  final CountdownTimerController countdownTimer;
  final VoidCallback onShowLargeTimer;
  final void Function(EditorController editor, Color color) onPenColorChanged;
  final ValueChanged<EditorController> onCustomPenColorRequested;
  final void Function(EditorController editor, RadialPenType type)
  onPenTypeChanged;
  final ValueChanged<EditorController> onAddPage;
  final Future<void> Function(EditorController, String) onDeletePage;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final compactSystemText = textScaler.scale(14) <= 18;
    final split = participantMode == EditorParticipantMode.twoPeople;
    final showPageControls = compactSystemText && width >= (split ? 1040 : 820);
    final showResetLabel = width >= 1800 && compactSystemText;
    final showAuxiliaryActions =
        width >= (split && showPageControls ? 2200 : 1180);
    final showTitle = width >= (split ? 1500 : 900);
    final showInteractionControls = width >= 620;
    final showPenQuickActions = width >= (split ? 1280 : 720);
    final showHistoryActions =
        width >= (split && showPageControls ? 2200 : 1050);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
      width: width,
      height: 64,
      child: Material(
        color: FlowboardColors.panel.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: collapsed
            ? Row(
                children: [
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Übersicht',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const FlowboardMark(size: 36),
                  IconButton(
                    tooltip: 'Leiste ausklappen',
                    onPressed: onToggleCollapsed,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              )
            : Row(
                children: [
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Übersicht',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const FlowboardMark(size: 36),
                  if (showTitle) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: onRename,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Text(
                            controller.document.title,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ] else
                    const SizedBox(width: 8),
                  if (showPenQuickActions) ...[
                    _ParticipantPenQuickControls(
                      controlId: 'primary',
                      participantLabel: split ? 'Links' : null,
                      controller: controller,
                      onColorChanged: onPenColorChanged,
                      onCustomColorRequested: onCustomPenColorRequested,
                      onTypeChanged: onPenTypeChanged,
                    ),
                    if (split) ...[
                      const SizedBox(width: 4),
                      _ParticipantPenQuickControls(
                        controlId: 'secondary',
                        participantLabel: 'Rechts',
                        controller: secondaryController,
                        onColorChanged: onPenColorChanged,
                        onCustomColorRequested: onCustomPenColorRequested,
                        onTypeChanged: onPenTypeChanged,
                      ),
                    ],
                    const SizedBox(width: 2),
                  ],
                  if (showInteractionControls) ...[
                    ParticipantModeToggle(
                      mode: participantMode,
                      onChanged: onParticipantModeChanged,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      key: const ValueKey('finger-drawing-toggle'),
                      tooltip: fingerDrawingEnabled
                          ? 'Schreiben mit Finger ausschalten'
                          : 'Schreiben mit Finger einschalten',
                      onPressed: () =>
                          onFingerDrawingChanged(!fingerDrawingEnabled),
                      isSelected: fingerDrawingEnabled,
                      selectedIcon: const Icon(
                        Icons.fingerprint_rounded,
                        color: FlowboardColors.mint,
                      ),
                      icon: const Icon(Icons.fingerprint_rounded),
                    ),
                    CountdownTimerToolbarButton(
                      controller: countdownTimer,
                      onShowLarge: onShowLargeTimer,
                      showLabel: showResetLabel,
                    ),
                  ],
                  if (showAuxiliaryActions && onPages != null)
                    IconButton(
                      tooltip: 'Seiten',
                      onPressed: onPages,
                      icon: const Icon(Icons.view_carousel_outlined),
                    ),
                  if (showAuxiliaryActions) ...[
                    IconButton(
                      tooltip: 'Aktuelle Seite als Vorlage speichern',
                      onPressed: onSaveCurrentPageAsTemplate,
                      icon: const Icon(Icons.bookmark_add_outlined),
                    ),
                    if (showResetLabel)
                      TextButton.icon(
                        onPressed: onResetMenuPosition,
                        icon: const Icon(Icons.center_focus_strong_rounded),
                        label: const Text('Menüposition zurücksetzen'),
                      )
                    else
                      IconButton(
                        tooltip: 'Menüposition zurücksetzen',
                        onPressed: onResetMenuPosition,
                        icon: const Icon(Icons.center_focus_strong_rounded),
                      ),
                    IconButton(
                      tooltip: 'Bedienhilfe',
                      onPressed: onHelp,
                      icon: const Icon(Icons.help_outline_rounded),
                    ),
                  ] else
                    PopupMenuButton<_EditorTopBarAction>(
                      tooltip: 'Weitere Aktionen',
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (action) {
                        switch (action) {
                          case _EditorTopBarAction.pages:
                            onPages?.call();
                          case _EditorTopBarAction.saveTemplate:
                            onSaveCurrentPageAsTemplate();
                          case _EditorTopBarAction.resetMenu:
                            onResetMenuPosition();
                          case _EditorTopBarAction.help:
                            onHelp();
                          case _EditorTopBarAction.undo:
                            controller.undo();
                          case _EditorTopBarAction.redo:
                            controller.redo();
                          case _EditorTopBarAction.toggleParticipantMode:
                            onParticipantModeChanged(
                              participantMode == EditorParticipantMode.onePerson
                                  ? EditorParticipantMode.twoPeople
                                  : EditorParticipantMode.onePerson,
                            );
                          case _EditorTopBarAction.toggleFingerDrawing:
                            onFingerDrawingChanged(!fingerDrawingEnabled);
                          case _EditorTopBarAction.timer:
                            if (countdownTimer.isAlarmActive) {
                              onShowLargeTimer();
                            } else {
                              showCountdownTimerSetup(
                                context,
                                controller: countdownTimer,
                                onShowLarge: onShowLargeTimer,
                              );
                            }
                          case _EditorTopBarAction.penColor:
                            onCustomPenColorRequested(controller);
                          case _EditorTopBarAction.penNormal:
                            onPenTypeChanged(controller, RadialPenType.normal);
                          case _EditorTopBarAction.penMarker:
                            onPenTypeChanged(controller, RadialPenType.marker);
                          case _EditorTopBarAction.penDashed:
                            onPenTypeChanged(controller, RadialPenType.dashed);
                          case _EditorTopBarAction.penStraight:
                            onPenTypeChanged(
                              controller,
                              RadialPenType.straight,
                            );
                          case _EditorTopBarAction.penEraser:
                            onPenTypeChanged(controller, RadialPenType.eraser);
                          case _EditorTopBarAction.secondaryPenColor:
                            onCustomPenColorRequested(secondaryController);
                          case _EditorTopBarAction.secondaryPenNormal:
                            onPenTypeChanged(
                              secondaryController,
                              RadialPenType.normal,
                            );
                          case _EditorTopBarAction.secondaryPenMarker:
                            onPenTypeChanged(
                              secondaryController,
                              RadialPenType.marker,
                            );
                          case _EditorTopBarAction.secondaryPenDashed:
                            onPenTypeChanged(
                              secondaryController,
                              RadialPenType.dashed,
                            );
                          case _EditorTopBarAction.secondaryPenStraight:
                            onPenTypeChanged(
                              secondaryController,
                              RadialPenType.straight,
                            );
                          case _EditorTopBarAction.secondaryPenEraser:
                            onPenTypeChanged(
                              secondaryController,
                              RadialPenType.eraser,
                            );
                          case _EditorTopBarAction.previousPrimaryPage:
                            controller.previousPage();
                          case _EditorTopBarAction.nextPrimaryPage:
                            controller.nextPage();
                          case _EditorTopBarAction.addPrimaryPage:
                            onAddPage(controller);
                          case _EditorTopBarAction.deletePrimaryPage:
                            unawaited(
                              onDeletePage(controller, controller.page.id),
                            );
                          case _EditorTopBarAction.previousSecondaryPage:
                            secondaryController.previousPage();
                          case _EditorTopBarAction.nextSecondaryPage:
                            secondaryController.nextPage();
                          case _EditorTopBarAction.addSecondaryPage:
                            onAddPage(secondaryController);
                          case _EditorTopBarAction.deleteSecondaryPage:
                            unawaited(
                              onDeletePage(
                                secondaryController,
                                secondaryController.page.id,
                              ),
                            );
                        }
                      },
                      itemBuilder: (_) => <PopupMenuEntry<_EditorTopBarAction>>[
                        if (!showPenQuickActions) ...[
                          if (split)
                            const PopupMenuItem(
                              enabled: false,
                              child: Text('Stift links'),
                            ),
                          const PopupMenuItem(
                            value: _EditorTopBarAction.penColor,
                            child: ListTile(
                              leading: Icon(Icons.palette_outlined),
                              title: Text('Stiftfarbe'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: _EditorTopBarAction.penNormal,
                            child: ListTile(
                              leading: Icon(Icons.edit_rounded),
                              title: Text('Stift: Normal'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: _EditorTopBarAction.penMarker,
                            child: ListTile(
                              leading: Icon(Icons.border_color_rounded),
                              title: Text('Stift: Marker'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: _EditorTopBarAction.penDashed,
                            child: ListTile(
                              leading: Icon(Icons.more_horiz_rounded),
                              title: Text('Stift: Gestrichelt'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: _EditorTopBarAction.penStraight,
                            child: ListTile(
                              leading: Icon(Icons.show_chart_rounded),
                              title: Text('Stift: Gerade Linie'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: _EditorTopBarAction.penEraser,
                            child: ListTile(
                              leading: Icon(Icons.cleaning_services_rounded),
                              title: Text('Stift: Radiergummi'),
                            ),
                          ),
                          if (split) ...[
                            const PopupMenuDivider(),
                            const PopupMenuItem(
                              enabled: false,
                              child: Text('Stift rechts'),
                            ),
                            const PopupMenuItem(
                              value: _EditorTopBarAction.secondaryPenColor,
                              child: ListTile(
                                leading: Icon(Icons.palette_outlined),
                                title: Text('Stiftfarbe'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: _EditorTopBarAction.secondaryPenNormal,
                              child: ListTile(
                                leading: Icon(Icons.edit_rounded),
                                title: Text('Stift: Normal'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: _EditorTopBarAction.secondaryPenMarker,
                              child: ListTile(
                                leading: Icon(Icons.border_color_rounded),
                                title: Text('Stift: Marker'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: _EditorTopBarAction.secondaryPenDashed,
                              child: ListTile(
                                leading: Icon(Icons.more_horiz_rounded),
                                title: Text('Stift: Gestrichelt'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: _EditorTopBarAction.secondaryPenStraight,
                              child: ListTile(
                                leading: Icon(Icons.show_chart_rounded),
                                title: Text('Stift: Gerade Linie'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: _EditorTopBarAction.secondaryPenEraser,
                              child: ListTile(
                                leading: Icon(Icons.cleaning_services_rounded),
                                title: Text('Stift: Radiergummi'),
                              ),
                            ),
                          ],
                          const PopupMenuDivider(),
                        ],
                        if (!showInteractionControls) ...[
                          PopupMenuItem(
                            value: _EditorTopBarAction.toggleParticipantMode,
                            child: ListTile(
                              leading: Icon(
                                participantMode ==
                                        EditorParticipantMode.onePerson
                                    ? Icons.people_alt_rounded
                                    : Icons.person_rounded,
                              ),
                              title: Text(
                                participantMode ==
                                        EditorParticipantMode.onePerson
                                    ? 'Zwei-Personen-Modus'
                                    : 'Ein-Personen-Modus',
                              ),
                            ),
                          ),
                          PopupMenuItem(
                            value: _EditorTopBarAction.toggleFingerDrawing,
                            child: ListTile(
                              leading: Icon(
                                Icons.fingerprint_rounded,
                                color: fingerDrawingEnabled
                                    ? FlowboardColors.mint
                                    : null,
                              ),
                              title: Text(
                                fingerDrawingEnabled
                                    ? 'Finger-Schreiben ausschalten'
                                    : 'Finger-Schreiben einschalten',
                              ),
                            ),
                          ),
                          PopupMenuItem(
                            value: _EditorTopBarAction.timer,
                            child: ListTile(
                              leading: Icon(
                                countdownTimer.isAlarmActive
                                    ? Icons.notifications_active_rounded
                                    : countdownTimer.isRunning
                                    ? Icons.timer_rounded
                                    : Icons.timer_outlined,
                                color: countdownTimer.isAlarmActive
                                    ? FlowboardColors.warning
                                    : null,
                              ),
                              title: Text(
                                countdownTimer.isAlarmActive
                                    ? 'Alarm bestätigen'
                                    : 'Timer',
                              ),
                              subtitle: countdownTimer.isAlarmActive
                                  ? const Text('Im großen Timerfenster')
                                  : countdownTimer.status ==
                                        CountdownTimerStatus.idle
                                  ? const Text('Zeit einstellen')
                                  : Text(
                                      formatCountdown(countdownTimer.remaining),
                                    ),
                            ),
                          ),
                        ],
                        if (onPages != null)
                          const PopupMenuItem(
                            value: _EditorTopBarAction.pages,
                            child: ListTile(
                              leading: Icon(Icons.view_carousel_outlined),
                              title: Text('Seiten'),
                            ),
                          ),
                        const PopupMenuItem(
                          value: _EditorTopBarAction.saveTemplate,
                          child: ListTile(
                            leading: Icon(Icons.bookmark_add_outlined),
                            title: Text('Seite als Vorlage speichern'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _EditorTopBarAction.resetMenu,
                          child: ListTile(
                            leading: Icon(Icons.center_focus_strong_rounded),
                            title: Text('Menüposition zurücksetzen'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _EditorTopBarAction.help,
                          child: ListTile(
                            leading: Icon(Icons.help_outline_rounded),
                            title: Text('Bedienhilfe'),
                          ),
                        ),
                        if (!showHistoryActions) ...[
                          PopupMenuItem(
                            value: _EditorTopBarAction.undo,
                            enabled: controller.canUndo,
                            child: const ListTile(
                              leading: Icon(Icons.undo_rounded),
                              title: Text('Rückgängig'),
                            ),
                          ),
                          PopupMenuItem(
                            value: _EditorTopBarAction.redo,
                            enabled: controller.canRedo,
                            child: const ListTile(
                              leading: Icon(Icons.redo_rounded),
                              title: Text('Wiederholen'),
                            ),
                          ),
                        ],
                        if (!showPageControls) ...[
                          if (split)
                            const PopupMenuItem(
                              enabled: false,
                              child: Text('Seitennavigation links'),
                            ),
                          PopupMenuItem(
                            value: _EditorTopBarAction.previousPrimaryPage,
                            enabled: controller.document.pages.length > 1,
                            child: const ListTile(
                              leading: Icon(Icons.chevron_left_rounded),
                              title: Text('Vorherige Seite'),
                            ),
                          ),
                          PopupMenuItem(
                            value: _EditorTopBarAction.nextPrimaryPage,
                            enabled: controller.document.pages.length > 1,
                            child: const ListTile(
                              leading: Icon(Icons.chevron_right_rounded),
                              title: Text('Nächste Seite'),
                            ),
                          ),
                          PopupMenuItem(
                            value: _EditorTopBarAction.addPrimaryPage,
                            enabled:
                                controller.document.pages.length <
                                WhiteboardDocument.maxPageCount,
                            child: const ListTile(
                              leading: Icon(Icons.note_add_outlined),
                              title: Text('Neue Seite'),
                            ),
                          ),
                          PopupMenuItem(
                            value: _EditorTopBarAction.deletePrimaryPage,
                            enabled: controller.document.pages.length > 1,
                            child: const ListTile(
                              leading: Icon(Icons.delete_outline_rounded),
                              title: Text('Aktuelle Seite löschen'),
                            ),
                          ),
                          if (split) ...[
                            const PopupMenuItem(
                              enabled: false,
                              child: Text('Seitennavigation rechts'),
                            ),
                            PopupMenuItem(
                              value: _EditorTopBarAction.previousSecondaryPage,
                              enabled:
                                  secondaryController.document.pages.length > 1,
                              child: const ListTile(
                                leading: Icon(Icons.chevron_left_rounded),
                                title: Text('Vorherige Seite'),
                              ),
                            ),
                            PopupMenuItem(
                              value: _EditorTopBarAction.nextSecondaryPage,
                              enabled:
                                  secondaryController.document.pages.length > 1,
                              child: const ListTile(
                                leading: Icon(Icons.chevron_right_rounded),
                                title: Text('Nächste Seite'),
                              ),
                            ),
                            PopupMenuItem(
                              value: _EditorTopBarAction.addSecondaryPage,
                              enabled:
                                  secondaryController.document.pages.length <
                                  WhiteboardDocument.maxPageCount,
                              child: const ListTile(
                                leading: Icon(Icons.note_add_outlined),
                                title: Text('Neue Seite'),
                              ),
                            ),
                            PopupMenuItem(
                              value: _EditorTopBarAction.deleteSecondaryPage,
                              enabled:
                                  secondaryController.document.pages.length > 1,
                              child: const ListTile(
                                leading: Icon(Icons.delete_outline_rounded),
                                title: Text('Aktuelle Seite löschen'),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  if (showPageControls) ...[
                    const SizedBox(width: 6),
                    EditorPageControls(
                      controlId: 'primary',
                      participantLabel: split ? 'Links' : null,
                      currentPageIndex: controller.currentPageIndex,
                      pageCount: controller.document.pages.length,
                      canAdd:
                          controller.document.pages.length <
                          WhiteboardDocument.maxPageCount,
                      onPrevious: controller.previousPage,
                      onNext: controller.nextPage,
                      onAdd: () => onAddPage(controller),
                      onDelete: () => unawaited(
                        onDeletePage(controller, controller.page.id),
                      ),
                    ),
                    if (split) ...[
                      const SizedBox(width: 6),
                      EditorPageControls(
                        controlId: 'secondary',
                        participantLabel: 'Rechts',
                        currentPageIndex: secondaryController.currentPageIndex,
                        pageCount: secondaryController.document.pages.length,
                        canAdd:
                            secondaryController.document.pages.length <
                            WhiteboardDocument.maxPageCount,
                        onPrevious: secondaryController.previousPage,
                        onNext: secondaryController.nextPage,
                        onAdd: () => onAddPage(secondaryController),
                        onDelete: () => unawaited(
                          onDeletePage(
                            secondaryController,
                            secondaryController.page.id,
                          ),
                        ),
                      ),
                    ],
                  ],
                  if (showHistoryActions) ...[
                    IconButton(
                      tooltip: 'Undo',
                      onPressed: controller.canUndo ? controller.undo : null,
                      icon: const Icon(Icons.undo_rounded),
                    ),
                    IconButton(
                      tooltip: 'Redo',
                      onPressed: controller.canRedo ? controller.redo : null,
                      icon: const Icon(Icons.redo_rounded),
                    ),
                  ],
                  IconButton(
                    tooltip: 'Leiste einklappen',
                    onPressed: onToggleCollapsed,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
      ),
    );
  }
}

enum _EditorTopBarAction {
  penColor,
  penNormal,
  penMarker,
  penDashed,
  penStraight,
  penEraser,
  secondaryPenColor,
  secondaryPenNormal,
  secondaryPenMarker,
  secondaryPenDashed,
  secondaryPenStraight,
  secondaryPenEraser,
  pages,
  saveTemplate,
  resetMenu,
  help,
  undo,
  redo,
  toggleParticipantMode,
  toggleFingerDrawing,
  timer,
  previousPrimaryPage,
  nextPrimaryPage,
  addPrimaryPage,
  deletePrimaryPage,
  previousSecondaryPage,
  nextSecondaryPage,
  addSecondaryPage,
  deleteSecondaryPage,
}

/// Owns the page tray's scroll controller for the complete route lifetime.
/// A modal route's result completes before its exit animation has finished;
/// disposing a controller in the caller at that point can leave the departing
/// widgets listening to an already disposed notifier.
class _PagePickerSheet extends StatefulWidget {
  const _PagePickerSheet({
    required this.height,
    required this.itemExtent,
    required this.viewportWidth,
    required this.pages,
    required this.currentPageIndex,
    required this.thumbnails,
    required this.onAddPage,
    required this.onPageSelected,
  });

  final double height;
  final double itemExtent;
  final double viewportWidth;
  final List<BoardPage> pages;
  final int currentPageIndex;
  final Map<String, ui.Image> thumbnails;
  final VoidCallback onAddPage;
  final ValueChanged<int> onPageSelected;

  @override
  State<_PagePickerSheet> createState() => _PagePickerSheetState();
}

class _PagePickerSheetState extends State<_PagePickerSheet> {
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: math.max(
      0,
      widget.currentPageIndex * (widget.itemExtent + 14) -
          widget.viewportWidth * .24,
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      width: double.infinity,
      height: widget.height,
      child: HorizontalPageTray(
        controller: _controller,
        itemCount: widget.pages.length + 1,
        itemBuilder: (context, index) {
          if (index == widget.pages.length) {
            return SizedBox(
              width: math.max(190, widget.itemExtent * .72),
              child: FilledButton.tonalIcon(
                onPressed: widget.onAddPage,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Neue Seite'),
              ),
            );
          }
          final page = widget.pages[index];
          return _PageCard(
            width: widget.itemExtent,
            pageNumber: index + 1,
            selected: index == widget.currentPageIndex,
            thumbnail: widget.thumbnails[page.id],
            onTap: () => widget.onPageSelected(index),
          );
        },
      ),
    ),
  );
}

/// Horizontal card tray used by the page picker.
///
/// Desktop Flutter intentionally excludes mouse drags from its default scroll
/// behavior. A smartboard, however, can report the same physical swipe as
/// touch, stylus, inverted stylus, or mouse input depending on its driver. The
/// local behavior below accepts all of those sources without changing scrolling
/// elsewhere in the application.
class HorizontalPageTray extends StatelessWidget {
  const HorizontalPageTray({
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.fromLTRB(24, 16, 24, 28),
    this.separatorWidth = 14,
    super.key,
  });

  final ScrollController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final double separatorWidth;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const _PageTrayScrollBehavior(),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        child: _PageTrayPointerDragRegion(
          controller: controller,
          child: ListView.separated(
            controller: controller,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: padding,
            scrollDirection: Axis.horizontal,
            itemCount: itemCount,
            separatorBuilder: (_, _) => SizedBox(width: separatorWidth),
            itemBuilder: itemBuilder,
          ),
        ),
      ),
    );
  }
}

class _PageTrayScrollBehavior extends MaterialScrollBehavior {
  const _PageTrayScrollBehavior();

  // Physical pointer drags are handled by _PageTrayPointerDragRegion so the
  // result does not depend on platform/driver-specific desktop behavior.
  // Trackpad pan/zoom remains native; mouse-wheel pointer signals are not
  // governed by dragDevices and therefore keep working as before.
  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.trackpad,
  };

  // The tray owns one permanently visible scrollbar. Suppress the automatic
  // desktop scrollbar that MaterialScrollBehavior would otherwise add.
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class _PageTrayPointerDragRegion extends StatefulWidget {
  const _PageTrayPointerDragRegion({
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  State<_PageTrayPointerDragRegion> createState() =>
      _PageTrayPointerDragRegionState();
}

class _PageTrayPointerDragRegionState
    extends State<_PageTrayPointerDragRegion> {
  static const _supportedKinds = <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
  };
  static const _scrollbarExclusionHeight = 24.0;

  int? _pointer;
  Offset _pointerStart = Offset.zero;
  double _scrollStart = 0;
  bool _dragging = false;
  VelocityTracker? _velocityTracker;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.child,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null ||
        !_supportedKinds.contains(event.kind) ||
        !widget.controller.hasClients ||
        (event.kind == PointerDeviceKind.mouse &&
            event.buttons & kPrimaryButton == 0)) {
      return;
    }
    final height = context.size?.height ?? 0;
    if (height > 0 &&
        event.localPosition.dy >= height - _scrollbarExclusionHeight) {
      return;
    }
    _pointer = event.pointer;
    _pointerStart = event.localPosition;
    _scrollStart = widget.controller.offset;
    _dragging = false;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final delta = event.localPosition - _pointerStart;
    if (!_dragging) {
      if (delta.distance < kTouchSlop) return;
      if (delta.dy.abs() >= delta.dx.abs()) {
        _resetDrag();
        return;
      }
      _dragging = true;
    }
    if (!widget.controller.hasClients) {
      _resetDrag();
      return;
    }
    final target = (_scrollStart - delta.dx).clamp(
      0.0,
      widget.controller.position.maxScrollExtent,
    );
    widget.controller.jumpTo(target);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    if (_dragging && widget.controller.hasClients) {
      final velocity =
          _velocityTracker?.getVelocity().pixelsPerSecond.dx ?? 0.0;
      _startBallisticScroll(velocity);
    }
    _resetDrag();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _resetDrag();
  }

  void _startBallisticScroll(double pointerVelocity) {
    if (pointerVelocity.abs() < 80) return;
    final current = widget.controller.offset;
    final projectedDistance = (-pointerVelocity * .16).clamp(-1200.0, 1200.0);
    final target = (current + projectedDistance).clamp(
      0.0,
      widget.controller.position.maxScrollExtent,
    );
    final distance = (target - current).abs();
    if (distance < 1) return;
    final duration = Duration(
      milliseconds: (140 + distance * .22).clamp(140, 420).round(),
    );
    unawaited(
      widget.controller
          .animateTo(target, duration: duration, curve: Curves.decelerate)
          .catchError((Object _) {}),
    );
  }

  void _resetDrag() {
    _pointer = null;
    _dragging = false;
    _velocityTracker = null;
  }
}

class _PageCard extends StatelessWidget {
  const _PageCard({
    required this.width,
    required this.pageNumber,
    required this.selected,
    required this.thumbnail,
    required this.onTap,
  });

  final double width;
  final int pageNumber;
  final bool selected;
  final ui.Image? thumbnail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Seite $pageNumber',
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: width,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? FlowboardColors.mint : FlowboardColors.divider,
              width: selected ? 3 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: ColoredBox(
                    color: Colors.white,
                    child: thumbnail == null
                        ? const Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : RawImage(image: thumbnail, fit: BoxFit.cover),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$pageNumber',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef DeleteUserTemplate = Future<bool> Function(UserTemplate template);

/// Pen-friendly, asset-independent browser for templates created on this
/// device. It intentionally owns a local list so successful deletions are
/// reflected immediately while the dialog route remains open.
class UserTemplateLibraryDialog extends StatefulWidget {
  const UserTemplateLibraryDialog({
    required this.userTemplates,
    required this.onDelete,
    super.key,
  });

  final List<UserTemplate> userTemplates;
  final DeleteUserTemplate onDelete;

  static Future<UserTemplate?> show(
    BuildContext context, {
    required List<UserTemplate> userTemplates,
    required DeleteUserTemplate onDelete,
  }) => showDialog<UserTemplate>(
    context: context,
    builder: (_) => UserTemplateLibraryDialog(
      userTemplates: userTemplates,
      onDelete: onDelete,
    ),
  );

  @override
  State<UserTemplateLibraryDialog> createState() =>
      _UserTemplateLibraryDialogState();
}

class _UserTemplateLibraryDialogState extends State<UserTemplateLibraryDialog> {
  late final List<UserTemplate> _templates = List<UserTemplate>.of(
    widget.userTemplates,
  );
  final Set<String> _deleting = <String>{};

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: FlowboardColors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: math.min(1040, math.max(340, viewport.width - 32)),
        height: math.min(720, math.max(430, viewport.height - 48)),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.collections_bookmark_outlined,
                    color: FlowboardColors.mint,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Eigene Vorlagen',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Schließen',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 18),
                child: Text(
                  'Eine Vorschau antippen, um daraus eine neue Seite zu '
                  'erstellen. Gespeichert wird über das Vorlagensymbol in der '
                  'Kopfleiste.',
                  style: TextStyle(color: FlowboardColors.textSecondary),
                ),
              ),
              Expanded(
                child: _templates.isEmpty
                    ? const _EmptyUserTemplateDialogState()
                    : GridView.builder(
                        key: const ValueKey('user-template-library-grid'),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 310,
                              childAspectRatio: 1.22,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 14,
                            ),
                        itemCount: _templates.length,
                        itemBuilder: (context, index) {
                          final template = _templates[index];
                          return _UserTemplatePreviewCard(
                            template: template,
                            deleting: _deleting.contains(template.id),
                            onTap: () => Navigator.pop(context, template),
                            onDelete: () => _confirmDelete(template),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(UserTemplate template) async {
    if (_deleting.contains(template.id)) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Eigene Vorlage löschen?'),
            content: Text(
              '„${template.name}“ wird dauerhaft aus der Vorlagenbibliothek '
              'entfernt. Bereits daraus erstellte Seiten bleiben erhalten.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: FlowboardColors.danger,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Löschen'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _deleting.add(template.id));
    final deleted = await widget.onDelete(template);
    if (!mounted) return;
    setState(() {
      _deleting.remove(template.id);
      if (deleted) {
        _templates.removeWhere((item) => item.id == template.id);
      }
    });
  }
}

class _UserTemplatePreviewCard extends StatelessWidget {
  const _UserTemplatePreviewCard({
    required this.template,
    required this.deleting,
    required this.onTap,
    required this.onDelete,
  });

  final UserTemplate template;
  final bool deleting;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final created = template.createdAt.toLocal();
    final date =
        '${created.day.toString().padLeft(2, '0')}.'
        '${created.month.toString().padLeft(2, '0')}.${created.year}';
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: deleting ? null : onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DocumentPagePreview(page: template.page),
                  if (deleting)
                    const ColoredBox(
                      color: Colors.black54,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          template.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          date,
                          style: const TextStyle(
                            color: FlowboardColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Vorlage löschen',
                    onPressed: deleting ? null : onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyUserTemplateDialogState extends StatelessWidget {
  const _EmptyUserTemplateDialogState();

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bookmarks_outlined,
            size: 58,
            color: FlowboardColors.textSecondary,
          ),
          SizedBox(height: 14),
          Text(
            'Noch keine eigenen Vorlagen',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text(
            'Speichere die aktuelle Seite über das Vorlagensymbol oben in '
            'der Kopfleiste.',
            textAlign: TextAlign.center,
            style: TextStyle(color: FlowboardColors.textSecondary),
          ),
        ],
      ),
    ),
  );
}

/// Responsive template browser shared by the editor modal and layout tests.
/// Its sliver tiles grow with the effective system text scale instead of
/// relying on a device-specific fixed height.
class TemplateLibrarySheet extends StatelessWidget {
  const TemplateLibrarySheet({
    required this.userTemplates,
    required this.onSaveCurrentPage,
    required this.onBuiltInTemplateSelected,
    required this.onUserTemplateSelected,
    required this.onUserTemplateDeleted,
    super.key,
  });

  final List<UserTemplate> userTemplates;
  final VoidCallback onSaveCurrentPage;
  final ValueChanged<TemplateKind> onBuiltInTemplateSelected;
  final ValueChanged<UserTemplate> onUserTemplateSelected;
  final ValueChanged<UserTemplate> onUserTemplateDeleted;

  @override
  Widget build(BuildContext context) {
    final scaledBodySize = MediaQuery.textScalerOf(context).scale(16);
    final textScale = scaledBodySize.isFinite
        ? math.max(1.0, scaledBodySize / 16)
        : 1.0;
    // Includes card margin, padding, icon and two scaled lines for both title
    // and description, with enough headroom for platform font metrics.
    final tileExtent = 190.0 + (textScale - 1) * 96;

    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: .82,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 14),
              sliver: SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final saveButton = FilledButton.tonalIcon(
                      onPressed: onSaveCurrentPage,
                      icon: const Icon(Icons.bookmark_add_outlined),
                      label: const Text('Aktuelle Seite speichern'),
                    );
                    final title = Text(
                      'Neue Seite aus Vorlage',
                      style: Theme.of(context).textTheme.headlineSmall,
                    );
                    if (constraints.maxWidth < 640 * textScale) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          const SizedBox(height: 12),
                          saveButton,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: title),
                        const SizedBox(width: 16),
                        saveButton,
                      ],
                    );
                  },
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'Flowboard-Vorlagen',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 340,
                  mainAxisExtent: tileExtent,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final definition = TemplateFactory.definitions[index];
                  return _TemplateTile(
                    definition: definition,
                    onTap: () => onBuiltInTemplateSelected(definition.kind),
                  );
                }, childCount: TemplateFactory.definitions.length),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 10),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'Vorlagen von Nutzern',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            if (userTemplates.isEmpty)
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 28),
                sliver: SliverToBoxAdapter(child: _EmptyUserTemplates()),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 340,
                    mainAxisExtent: tileExtent,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final template = userTemplates[index];
                    return _UserTemplateTile(
                      template: template,
                      onTap: () => onUserTemplateSelected(template),
                      onDelete: () => onUserTemplateDeleted(template),
                    );
                  }, childCount: userTemplates.length),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.definition, required this.onTap});
  final TemplateDefinition definition;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (definition.kind) {
      TemplateKind.overlappingCircles => Icons.join_inner_rounded,
      TemplateKind.mindMap => Icons.hub_outlined,
      TemplateKind.primarySchoolLines => Icons.format_align_justify_rounded,
      TemplateKind.vennDiagram => Icons.bubble_chart_outlined,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 36, color: FlowboardColors.mint),
              const Spacer(),
              Text(
                definition.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                definition.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyUserTemplates extends StatelessWidget {
  const _EmptyUserTemplates();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: FlowboardColors.panel.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: FlowboardColors.divider),
      ),
      child: const Padding(
        padding: EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              Icons.bookmarks_outlined,
              color: FlowboardColors.textSecondary,
            ),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                'Noch keine eigenen Vorlagen. Speichere oben die aktuelle Seite.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserTemplateTile extends StatelessWidget {
  const _UserTemplateTile({
    required this.template,
    required this.onTap,
    required this.onDelete,
  });

  final UserTemplate template;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final created = template.createdAt.toLocal();
    final date =
        '${created.day.toString().padLeft(2, '0')}.'
        '${created.month.toString().padLeft(2, '0')}.${created.year}';
    final contentCount =
        template.page.strokes.length + template.page.objects.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.bookmark_rounded,
                    size: 32,
                    color: FlowboardColors.mint,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Vorlage löschen',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  template.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$date · $contentCount Elemente',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: FlowboardColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Material(
    color: FlowboardColors.danger,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    ),
  );
}

class _WebImageDialog extends StatefulWidget {
  const _WebImageDialog({required this.service});
  final WebImageSearchService service;

  @override
  State<_WebImageDialog> createState() => _WebImageDialogState();
}

class _WebImageDialogState extends State<_WebImageDialog> {
  final _query = TextEditingController();
  List<ImageSearchResult> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return Dialog(
      child: SizedBox(
        width: math.min(900, math.max(320, viewport.width - 32)),
        height: math.min(650, math.max(420, viewport.height - 48)),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Google Bilder',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 14),
                child: Text(
                  'Google Bilder · ohne API-Schlüssel · SafeSearch aktiv. '
                  'Nutzungsrechte auf der Quellseite prüfen.',
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Suchbegriff',
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _loading ? null : _search,
                    child: const Text('Suchen'),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: FlowboardColors.danger),
                  ),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 210,
                              childAspectRatio: 1.15,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                            ),
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final result = _results[index];
                          final attribution =
                              <String?>[
                                    result.creator?.trim(),
                                    result.license?.trim(),
                                  ]
                                  .whereType<String>()
                                  .where((value) => value.isNotEmpty)
                                  .join(' · ');
                          return InkWell(
                            onTap: () => Navigator.pop(context, result),
                            borderRadius: BorderRadius.circular(12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ColoredBox(
                                    color: FlowboardColors.panelElevated,
                                    child: Image.network(
                                      result.thumbnailUrl.toString(),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.broken_image_outlined,
                                      ),
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: ColoredBox(
                                      color: Colors.black.withValues(
                                        alpha: .72,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(7),
                                        child: SizedBox(
                                          width: double.infinity,
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                result.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                attribution.isEmpty
                                                    ? 'Lizenz prüfen'
                                                    : attribution,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: Colors.white70,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.service.search(_query.text);
      if (mounted) setState(() => _results = results);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
