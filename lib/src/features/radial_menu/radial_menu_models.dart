import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The ten actions in the primary ring, ordered clockwise from twelve o'clock.
enum RadialMenuAction {
  pen,
  redo,
  selection,
  templates,
  nextPage,
  newPage,
  previousPage,
  insert,
  export,
  undo,
}

/// The single secondary branch which is currently visible.
enum RadialMenuBranch { pen, selection, templates, pages, insert, export }

enum RadialPenType { normal, marker, dashed, straight, eraser }

enum RadialSelectionTool { rectangle, lasso, selectAll }

enum RadialInsertCategory { geometry, image, table, pdf, cover }

enum RadialShapeKind { rectangle, circle, ellipse, triangle }

enum RadialImageSource { device, webSearch }

enum RadialPdfImportMode { singlePage, pageRange, allPages }

enum RadialCoverDirection { horizontal, vertical }

enum RadialExportAction { savePdf, shareLocal, quickShare }

@immutable
class RadialPenSettings {
  const RadialPenSettings({
    this.color = Colors.black,
    this.thickness = 8,
    this.type = RadialPenType.normal,
  });

  static const double minThickness = 1;
  static const double maxThickness = 32;

  /// Classroom-safe colour selected whenever the marker tool is activated.
  /// A later palette or free-colour choice deliberately remains possible.
  static const Color markerDefaultColor = Color(0xFFFFC107);

  final Color color;
  final double thickness;
  final RadialPenType type;

  RadialPenSettings copyWith({
    Color? color,
    double? thickness,
    RadialPenType? type,
  }) {
    return RadialPenSettings(
      color: color ?? this.color,
      thickness: (thickness ?? this.thickness).clamp(
        minThickness,
        maxThickness,
      ),
      type: type ?? this.type,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is RadialPenSettings &&
        other.color == color &&
        other.thickness == thickness &&
        other.type == type;
  }

  @override
  int get hashCode => Object.hash(color, thickness, type);
}

@immutable
class RadialPenPreset {
  const RadialPenPreset({required this.label, required this.settings});

  final String label;
  final RadialPenSettings settings;

  /// Optional application-specific presets. The built-in menu deliberately
  /// starts without presets: Normal, Marker, Gestrichelt and Gerade Linie are
  /// already first-class pen types, so a second Marker entry would be
  /// ambiguous.
  static const List<RadialPenPreset> defaults = <RadialPenPreset>[];
}

@immutable
class RadialPagePreview {
  const RadialPagePreview({
    required this.pageIndex,
    required this.pageNumber,
    this.pageId,
    this.thumbnail,
    this.backgroundColor = Colors.white,
    this.semanticLabel,
    this.isPlaceholder = false,
  });

  /// Stable zero-based page index passed back to [RadialMenuCallbacks.onPageSelected].
  final int pageIndex;
  final int pageNumber;

  /// Stable document identity used by destructive page actions. Older hosts
  /// may omit it and continue to use [pageIndex] for navigation only.
  final String? pageId;

  /// A rendered page thumbnail. Ownership and disposal stay with the caller.
  final ui.Image? thumbnail;
  final Color backgroundColor;
  final String? semanticLabel;
  final bool isPlaceholder;
}

enum RadialTemplateSource { builtIn, user }

/// A lightweight, model-independent template entry rendered directly in the
/// second radial ring. The editor keeps ownership of template persistence and
/// maps the stable [id] back to its domain model.
@immutable
class RadialTemplateEntry {
  const RadialTemplateEntry({
    required this.id,
    required this.label,
    required this.source,
    this.thumbnail,
    this.backgroundColor = Colors.white,
    this.semanticLabel,
    this.icon,
  }) : assert(id != ''),
       assert(label != '');

  final String id;
  final String label;
  final RadialTemplateSource source;

  /// Optional preview. Ownership and disposal remain with the editor.
  final ui.Image? thumbnail;
  final Color backgroundColor;
  final String? semanticLabel;
  final IconData? icon;
}

@immutable
class RadialTableSize {
  const RadialTableSize(this.rows, this.columns)
    : assert(rows > 0),
      assert(columns > 0);

  final int rows;
  final int columns;

  @override
  bool operator ==(Object other) {
    return other is RadialTableSize &&
        other.rows == rows &&
        other.columns == columns;
  }

  @override
  int get hashCode => Object.hash(rows, columns);
}

/// Typed, model-independent integration points for the whiteboard shell.
@immutable
class RadialMenuCallbacks {
  const RadialMenuCallbacks({
    this.onMenuOpenChanged,
    this.onFiveFingerPageGestureChanged,
    this.onPositionChanged,
    this.onPrimaryAction,
    this.onPenSettingsChanged,
    this.onCustomColorRequested,
    this.onSelectionToolChanged,
    this.onPageSelected,
    this.onPageDeleteRequested,
    this.onTemplateSelected,
    this.onShapeRequested,
    this.onImageRequested,
    this.onTableRequested,
    this.onPdfRequested,
    this.onCoverRequested,
    this.onExportRequested,
  });

  final ValueChanged<bool>? onMenuOpenChanged;

  /// Signals the complete lifetime of a five-touch page rotation. The board
  /// can cancel transient ink/selection/navigation state at `true` and keep
  /// processing suspended until all participating fingers are released.
  final ValueChanged<bool>? onFiveFingerPageGestureChanged;
  final ValueChanged<Offset>? onPositionChanged;
  final ValueChanged<RadialMenuAction>? onPrimaryAction;
  final ValueChanged<RadialPenSettings>? onPenSettingsChanged;

  /// Return `null` when the platform color picker was cancelled.
  final Future<Color?> Function(Color currentColor)? onCustomColorRequested;
  final ValueChanged<RadialSelectionTool>? onSelectionToolChanged;
  final ValueChanged<int>? onPageSelected;

  /// Invoked by a long press on a page in the click wheel. The host owns the
  /// confirmation UI and must revalidate [RadialPagePreview.pageId] before
  /// deleting because the shared document may have changed meanwhile.
  final ValueChanged<RadialPagePreview>? onPageDeleteRequested;
  final ValueChanged<RadialTemplateEntry>? onTemplateSelected;
  final ValueChanged<RadialShapeKind>? onShapeRequested;
  final ValueChanged<RadialImageSource>? onImageRequested;
  final ValueChanged<RadialTableSize>? onTableRequested;
  final ValueChanged<RadialPdfImportMode>? onPdfRequested;
  final ValueChanged<RadialCoverDirection>? onCoverRequested;
  final ValueChanged<RadialExportAction>? onExportRequested;
}

@immutable
class RadialMenuLabels {
  const RadialMenuLabels({
    required this.menu,
    required this.openMenu,
    required this.closeMenu,
    required this.primary,
    required this.customColor,
    required this.penTypes,
    required this.selectionTools,
    required this.insertCategories,
    required this.shapes,
    required this.imageSources,
    required this.pdfModes,
    required this.coverDirections,
    required this.exportActions,
    required this.thickness,
    required this.previousPages,
    required this.nextPages,
    required this.rows,
    required this.columns,
    required this.insertTable,
  });

  factory RadialMenuLabels.german() => const RadialMenuLabels(
    menu: 'Flowboard-Menü',
    openMenu: 'Menü öffnen',
    closeMenu: 'Menü schließen',
    primary: <RadialMenuAction, String>{
      RadialMenuAction.pen: 'Stift',
      RadialMenuAction.redo: 'Wiederholen',
      RadialMenuAction.selection: 'Auswahl',
      RadialMenuAction.templates: 'Vorlagen',
      RadialMenuAction.nextPage: 'Nächste Seite',
      RadialMenuAction.newPage: 'Neue Seite',
      RadialMenuAction.previousPage: 'Vorherige Seite',
      RadialMenuAction.insert: 'Einfügen',
      RadialMenuAction.export: 'Export',
      RadialMenuAction.undo: 'Rückgängig',
    },
    customColor: 'Freie Farbe',
    penTypes: <RadialPenType, String>{
      RadialPenType.normal: 'Normal',
      RadialPenType.marker: 'Marker',
      RadialPenType.dashed: 'Gestrichelt',
      RadialPenType.straight: 'Gerade Linie',
      RadialPenType.eraser: 'Radiergummi',
    },
    selectionTools: <RadialSelectionTool, String>{
      RadialSelectionTool.rectangle: 'Auswahlrechteck',
      RadialSelectionTool.lasso: 'Auswahllasso',
      RadialSelectionTool.selectAll: 'Alles auswählen',
    },
    insertCategories: <RadialInsertCategory, String>{
      RadialInsertCategory.geometry: 'Geometrie',
      RadialInsertCategory.image: 'Bilder',
      RadialInsertCategory.table: 'Tabelle',
      RadialInsertCategory.pdf: 'PDF',
      RadialInsertCategory.cover: 'Abdeckung',
    },
    shapes: <RadialShapeKind, String>{
      RadialShapeKind.rectangle: 'Rechteck',
      RadialShapeKind.circle: 'Kreis',
      RadialShapeKind.ellipse: 'Ellipse',
      RadialShapeKind.triangle: 'Dreieck',
    },
    imageSources: <RadialImageSource, String>{
      RadialImageSource.device: 'Vom Gerät',
      RadialImageSource.webSearch: 'Bildersuche',
    },
    pdfModes: <RadialPdfImportMode, String>{
      RadialPdfImportMode.singlePage: 'Eine Seite',
      RadialPdfImportMode.pageRange: 'Mehrere Seiten',
      RadialPdfImportMode.allPages: 'Ganze PDF',
    },
    coverDirections: <RadialCoverDirection, String>{
      RadialCoverDirection.horizontal: 'Horizontal',
      RadialCoverDirection.vertical: 'Vertikal',
    },
    exportActions: <RadialExportAction, String>{
      RadialExportAction.savePdf: 'Als PDF speichern',
      RadialExportAction.shareLocal: 'Per WLAN / QR teilen',
      RadialExportAction.quickShare: 'Quick Share',
    },
    thickness: 'Stiftdicke',
    previousPages: 'Vorherige Seiten',
    nextPages: 'Weitere Seiten',
    rows: 'Zeilen',
    columns: 'Spalten',
    insertTable: 'Tabelle einfügen',
  );

  final String menu;
  final String openMenu;
  final String closeMenu;
  final Map<RadialMenuAction, String> primary;
  final String customColor;
  final Map<RadialPenType, String> penTypes;
  final Map<RadialSelectionTool, String> selectionTools;
  final Map<RadialInsertCategory, String> insertCategories;
  final Map<RadialShapeKind, String> shapes;
  final Map<RadialImageSource, String> imageSources;
  final Map<RadialPdfImportMode, String> pdfModes;
  final Map<RadialCoverDirection, String> coverDirections;
  final Map<RadialExportAction, String> exportActions;
  final String thickness;
  final String previousPages;
  final String nextPages;
  final String rows;
  final String columns;
  final String insertTable;
}

@immutable
class RadialMenuThemeData {
  const RadialMenuThemeData({
    this.segmentColor = const Color(0xFF343639),
    this.segmentRaisedColor = const Color(0xFF414448),
    this.segmentPressedColor = const Color(0xFF1C6B5A),
    this.activeColor = const Color(0xFF39D69F),
    this.activeMutedColor = const Color(0xFF174F43),
    this.outlineColor = const Color(0xFF62666B),
    this.textColor = const Color(0xFFF4F6F7),
    this.mutedTextColor = const Color(0xFFB7BCC1),
    this.centerColor = const Color(0xFF202326),
    this.scrimColor = const Color(0xAA111315),
  });

  final Color segmentColor;
  final Color segmentRaisedColor;
  final Color segmentPressedColor;
  final Color activeColor;
  final Color activeMutedColor;
  final Color outlineColor;
  final Color textColor;
  final Color mutedTextColor;
  final Color centerColor;
  final Color scrimColor;
}

/// Owns durable menu choices. Animations, hover and drag gestures remain in the
/// widget so this controller is safe to retain with a document workspace.
class RadialMenuController extends ChangeNotifier {
  RadialMenuController({
    bool isOpen = false,
    RadialMenuBranch? activeBranch,
    RadialMenuAction selectedPrimary = RadialMenuAction.pen,
    RadialPenSettings penSettings = const RadialPenSettings(),
    RadialSelectionTool selectionTool = RadialSelectionTool.rectangle,
    RadialInsertCategory insertCategory = RadialInsertCategory.geometry,
    RadialShapeKind shapeKind = RadialShapeKind.rectangle,
    RadialTableSize tableSize = const RadialTableSize(3, 3),
  }) : _isOpen = isOpen,
       _activeBranch = activeBranch,
       _selectedPrimary = selectedPrimary,
       _penSettings = penSettings.copyWith(),
       _selectionTool = selectionTool,
       _insertCategory = insertCategory,
       _shapeKind = shapeKind,
       _expandedPrimary = switch (activeBranch) {
         RadialMenuBranch.pen => RadialMenuAction.pen,
         RadialMenuBranch.selection => RadialMenuAction.selection,
         RadialMenuBranch.templates => RadialMenuAction.templates,
         RadialMenuBranch.pages => RadialMenuAction.nextPage,
         RadialMenuBranch.insert => RadialMenuAction.insert,
         RadialMenuBranch.export => RadialMenuAction.export,
         null => null,
       },
       _tableSize = RadialTableSize(
         tableSize.rows.clamp(1, 24),
         tableSize.columns.clamp(1, 24),
       );

  bool _isOpen;
  RadialMenuBranch? _activeBranch;
  RadialMenuAction _selectedPrimary;
  RadialPenSettings _penSettings;
  RadialSelectionTool _selectionTool;
  RadialInsertCategory _insertCategory;
  RadialShapeKind _shapeKind;
  RadialTableSize _tableSize;
  RadialMenuAction? _expandedPrimary;

  bool get isOpen => _isOpen;
  RadialMenuBranch? get activeBranch => _activeBranch;
  RadialMenuAction get selectedPrimary => _selectedPrimary;
  RadialPenSettings get penSettings => _penSettings;
  RadialSelectionTool get selectionTool => _selectionTool;
  RadialInsertCategory get insertCategory => _insertCategory;
  RadialShapeKind get shapeKind => _shapeKind;
  RadialTableSize get tableSize => _tableSize;
  RadialMenuAction? get expandedPrimary => _expandedPrimary;

  void setOpen(bool value) {
    if (_isOpen == value) return;
    _isOpen = value;
    notifyListeners();
  }

  void toggleOpen() => setOpen(!_isOpen);

  void setBranch(RadialMenuBranch? value) {
    final expanded = switch (value) {
      RadialMenuBranch.pen => RadialMenuAction.pen,
      RadialMenuBranch.selection => RadialMenuAction.selection,
      RadialMenuBranch.templates => RadialMenuAction.templates,
      RadialMenuBranch.pages => RadialMenuAction.nextPage,
      RadialMenuBranch.insert => RadialMenuAction.insert,
      RadialMenuBranch.export => RadialMenuAction.export,
      null => null,
    };
    if (_activeBranch == value && _expandedPrimary == expanded) return;
    _activeBranch = value;
    _expandedPrimary = expanded;
    notifyListeners();
  }

  void activatePrimary(RadialMenuAction action) {
    final branch = switch (action) {
      RadialMenuAction.pen => RadialMenuBranch.pen,
      RadialMenuAction.selection => RadialMenuBranch.selection,
      RadialMenuAction.templates => RadialMenuBranch.templates,
      RadialMenuAction.nextPage ||
      RadialMenuAction.newPage ||
      RadialMenuAction.previousPage => RadialMenuBranch.pages,
      RadialMenuAction.insert => RadialMenuBranch.insert,
      RadialMenuAction.export => RadialMenuBranch.export,
      _ => null,
    };

    var changed = false;
    final collapsesCurrent =
        branch != null &&
        branch != RadialMenuBranch.pages &&
        _activeBranch == branch &&
        _expandedPrimary == action;

    // Opening a mode starts from a predictable classroom-safe default. A
    // second tap only collapses the fan and therefore keeps the adjustments
    // the user made while it was open.
    if (!collapsesCurrent && action == RadialMenuAction.pen) {
      const defaults = RadialPenSettings();
      if (_penSettings != defaults) {
        _penSettings = defaults;
        changed = true;
      }
    } else if (!collapsesCurrent && action == RadialMenuAction.selection) {
      if (_selectionTool != RadialSelectionTool.rectangle) {
        _selectionTool = RadialSelectionTool.rectangle;
        changed = true;
      }
    } else if (!collapsesCurrent && action == RadialMenuAction.insert) {
      if (_insertCategory != RadialInsertCategory.geometry) {
        _insertCategory = RadialInsertCategory.geometry;
        changed = true;
      }
      if (_shapeKind != RadialShapeKind.rectangle) {
        _shapeKind = RadialShapeKind.rectangle;
        changed = true;
      }
    }

    final isMode =
        action == RadialMenuAction.pen || action == RadialMenuAction.selection;
    if (isMode && _selectedPrimary != action) {
      _selectedPrimary = action;
      changed = true;
    }
    final nextBranch = collapsesCurrent ? null : branch;
    if (_activeBranch != nextBranch) {
      _activeBranch = nextBranch;
      changed = true;
    }
    final nextExpanded = nextBranch == null ? null : action;
    if (_expandedPrimary != nextExpanded) {
      _expandedPrimary = nextExpanded;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void setPenSettings(RadialPenSettings value) {
    final normalized = value.copyWith();
    if (_penSettings == normalized) return;
    _penSettings = normalized;
    _selectedPrimary = RadialMenuAction.pen;
    notifyListeners();
  }

  void setSelectionTool(RadialSelectionTool value) {
    if (_selectionTool == value &&
        _selectedPrimary == RadialMenuAction.selection) {
      return;
    }
    _selectionTool = value;
    _selectedPrimary = RadialMenuAction.selection;
    notifyListeners();
  }

  void setInsertCategory(RadialInsertCategory value) {
    if (_insertCategory == value) return;
    _insertCategory = value;
    notifyListeners();
  }

  void setShapeKind(RadialShapeKind value) {
    if (_shapeKind == value) return;
    _shapeKind = value;
    notifyListeners();
  }

  void setTableSize(RadialTableSize value) {
    final normalized = RadialTableSize(
      value.rows.clamp(1, 24),
      value.columns.clamp(1, 24),
    );
    if (_tableSize == normalized) return;
    _tableSize = normalized;
    notifyListeners();
  }
}
