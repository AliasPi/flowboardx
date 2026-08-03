import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'radial_eraser_glyph.dart';
import 'radial_menu_geometry.dart';
import 'radial_menu_models.dart';

const List<IconData> _primaryIcons = <IconData>[
  Icons.brush_rounded,
  Icons.redo_rounded,
  Icons.select_all_rounded,
  Icons.layers_rounded,
  Icons.arrow_forward_rounded,
  Icons.note_add_outlined,
  Icons.arrow_back_rounded,
  Icons.add_box_outlined,
  Icons.ios_share_rounded,
  Icons.undo_rounded,
];

const List<IconData> _selectionIcons = <IconData>[
  Icons.crop_square_rounded,
  Icons.gesture_rounded,
  Icons.select_all_rounded,
];

const List<IconData> _insertIcons = <IconData>[
  Icons.category_outlined,
  Icons.image_outlined,
  Icons.table_chart_outlined,
  Icons.picture_as_pdf_outlined,
  Icons.vertical_align_top_rounded,
];

const List<IconData> _shapeIcons = <IconData>[
  Icons.crop_square_rounded,
  Icons.circle_outlined,
  Icons.panorama_fish_eye_rounded,
  Icons.change_history_rounded,
];

const List<IconData> _penTypeIcons = <IconData>[
  Icons.draw_rounded,
  Icons.highlight_rounded,
  Icons.more_horiz_rounded,
  Icons.horizontal_rule_rounded,
  Icons.backspace_outlined,
];

/// Paints the complete radial surface in a single retained repaint boundary.
/// The immutable constructor makes repaint decisions explicit and predictable.
class RadialMenuPainter extends CustomPainter {
  RadialMenuPainter({
    required this.isOpen,
    required this.branch,
    required this.expandedPrimary,
    required this.selectedPrimary,
    required this.penSettings,
    required this.selectionTool,
    required this.insertCategory,
    required this.shapeKind,
    required this.tableSize,
    required this.palette,
    required this.presets,
    required this.pagePreviews,
    required this.currentPageIndex,
    required this.templateEntries,
    required this.surfaceSize,
    required this.openProgress,
    required this.submenuProgress,
    required this.tailRotation,
    required this.hovered,
    required this.pressed,
    required this.theme,
    required this.labels,
    required this.logoIcon,
    required this.onSemanticActivate,
    required this.onSemanticThicknessChanged,
    required this.textDirection,
    required this.canUndo,
    required this.canRedo,
  });

  final bool isOpen;
  final RadialMenuBranch? branch;
  final RadialMenuAction? expandedPrimary;
  final RadialMenuAction selectedPrimary;
  final RadialPenSettings penSettings;
  final RadialSelectionTool selectionTool;
  final RadialInsertCategory insertCategory;
  final RadialShapeKind shapeKind;
  final RadialTableSize tableSize;
  final List<Color> palette;
  final List<RadialPenPreset> presets;
  final List<RadialPagePreview> pagePreviews;
  final int currentPageIndex;
  final List<RadialTemplateEntry> templateEntries;
  final Size surfaceSize;
  final double openProgress;
  final double submenuProgress;
  final double tailRotation;
  final RadialHitTarget hovered;
  final RadialHitTarget pressed;
  final RadialMenuThemeData theme;
  final RadialMenuLabels labels;
  final IconData? logoIcon;
  final ValueChanged<RadialHitTarget> onSemanticActivate;
  final ValueChanged<double> onSemanticThicknessChanged;
  final TextDirection textDirection;
  final bool canUndo;
  final bool canRedo;

  /// The tapered gauge is a literal preview: its stroke grows from the
  /// minimum to the maximum selectable logical pen width, scaled exactly like
  /// the rest of the menu. Kept public for deterministic geometry tests.
  static double thicknessGaugeStrokeWidth(
    RadialMenuGeometry geometry,
    double fraction,
  ) {
    final normalized = fraction.clamp(0.0, 1.0);
    return (RadialPenSettings.minThickness +
            (RadialPenSettings.maxThickness - RadialPenSettings.minThickness) *
                normalized) *
        geometry.scale;
  }

  int get secondaryCount => switch (branch) {
    // Colors are one visual control. Individual swatches remain independent
    // hit and semantics targets inside that continuous panel.
    RadialMenuBranch.pen => 1,
    RadialMenuBranch.selection => RadialSelectionTool.values.length,
    RadialMenuBranch.templates => templateEntries.length,
    RadialMenuBranch.pages => pagePreviews.length,
    RadialMenuBranch.insert => RadialInsertCategory.values.length,
    RadialMenuBranch.export => RadialExportAction.values.length,
    null => 0,
  };

  int get tertiaryCount {
    // Pen types are one visual control. Its four internal choices are mapped
    // in [hitTargetAt] and exposed separately to accessibility services.
    if (branch == RadialMenuBranch.pen) return 1;
    if (branch != RadialMenuBranch.insert) return 0;
    return switch (insertCategory) {
      RadialInsertCategory.geometry => RadialShapeKind.values.length,
      RadialInsertCategory.image => RadialImageSource.values.length,
      // These categories continue in a dedicated dialog/direct insertion.
      // Keeping them out of Ring 3 avoids presenting configuration choices
      // before their real content (especially PDF pages) is available.
      RadialInsertCategory.table ||
      RadialInsertCategory.pdf ||
      RadialInsertCategory.cover => 0,
    };
  }

  /// The thickness control belongs to drawing ink, not to erasing.
  ///
  /// Eraser size is derived from the live contact footprint. Keeping the
  /// slider visible while the eraser was selected suggested that a SMART-style
  /// palm/fist eraser had to be configured manually and also made the stylus
  /// eraser depend on the last pen width.
  bool get hasThicknessSlider =>
      branch == RadialMenuBranch.pen &&
      penSettings.type != RadialPenType.eraser;

  int? get _parentIndex => switch (branch) {
    RadialMenuBranch.pen => RadialMenuAction.pen.index,
    RadialMenuBranch.selection => RadialMenuAction.selection.index,
    RadialMenuBranch.templates => RadialMenuAction.templates.index,
    RadialMenuBranch.pages =>
      (expandedPrimary ?? RadialMenuAction.nextPage).index,
    RadialMenuBranch.insert => RadialMenuAction.insert.index,
    RadialMenuBranch.export => RadialMenuAction.export.index,
    null => null,
  };

  double _submenuStartAngle(RadialMenuGeometry geometry) =>
      branch == RadialMenuBranch.pages
      ? -math.pi / math.max(1, secondaryCount)
      : geometry.compactSubmenuStartAngle(_parentIndex ?? 0);

  double _secondarySpan(RadialMenuGeometry geometry) =>
      branch == RadialMenuBranch.pages
      ? math.pi * 2
      : geometry.compactSubmenuSpan;

  double _thicknessSpan(RadialMenuGeometry geometry) =>
      hasThicknessSlider ? geometry.thicknessSpan : 0;

  double _tertiaryStartAngle(RadialMenuGeometry geometry) =>
      _submenuStartAngle(geometry) + _thicknessSpan(geometry);

  double _tertiarySpan(RadialMenuGeometry geometry) =>
      geometry.compactSubmenuSpan - _thicknessSpan(geometry);

  RadialHitTarget hitTargetAt(Offset position, Size size) {
    final interactiveOpen = isOpen;
    final interactiveSubmenu = branch != null;
    final easedOpen = Curves.easeOutCubic.transform(openProgress.clamp(0, 1));
    final easedSubmenu = Curves.easeOutCubic.transform(
      (openProgress * submenuProgress).clamp(0, 1),
    );
    final geometry = RadialMenuGeometry(size);
    final target = geometry.hitTest(
      position,
      isOpen: interactiveOpen,
      secondaryCount: interactiveSubmenu ? secondaryCount : 0,
      tertiaryCount: interactiveSubmenu ? tertiaryCount : 0,
      hasThicknessSlider: interactiveSubmenu && hasThicknessSlider,
      secondaryStartAngle: interactiveSubmenu
          ? _submenuStartAngle(geometry)
          : null,
      secondarySpan: _secondarySpan(geometry),
      tertiaryStartAngle: _tertiaryStartAngle(geometry),
      tertiarySpan: _tertiarySpan(geometry),
      thicknessStartAngle: _submenuStartAngle(geometry),
      thicknessSpan: _thicknessSpan(geometry),
      openProgress: easedOpen,
      submenuProgress: easedSubmenu,
    );
    if (target.layer == RadialMenuLayer.primary &&
        target.index >= 0 &&
        target.index < RadialMenuAction.values.length &&
        !_primaryActionEnabled(RadialMenuAction.values[target.index])) {
      return RadialHitTarget.none;
    }
    if (branch != RadialMenuBranch.pen) return target;

    if (target.layer == RadialMenuLayer.secondary) {
      return RadialHitTarget(
        RadialMenuLayer.secondary,
        _optionIndexAt(
          geometry,
          position,
          count: _penColorOptionCount,
          startAngle: _submenuStartAngle(geometry),
          span: _secondarySpan(geometry),
        ),
      );
    }
    if (target.layer == RadialMenuLayer.tertiary) {
      return RadialHitTarget(
        RadialMenuLayer.tertiary,
        _optionIndexAt(
          geometry,
          position,
          count: RadialPenType.values.length,
          startAngle: _tertiaryStartAngle(geometry),
          span: _tertiarySpan(geometry),
        ),
      );
    }
    return target;
  }

  bool _primaryActionEnabled(RadialMenuAction action) => switch (action) {
    RadialMenuAction.undo => canUndo,
    RadialMenuAction.redo => canRedo,
    _ => true,
  };

  int get _penColorOptionCount => palette.length + 1 + presets.length;

  int _optionIndexAt(
    RadialMenuGeometry geometry,
    Offset position, {
    required int count,
    required double startAngle,
    required double span,
  }) {
    if (count <= 1) return 0;
    final fraction = geometry.arcFractionFor(
      position,
      startAngle: startAngle,
      span: span,
    );
    return math.min(count - 1, (fraction * count).floor());
  }

  @override
  bool? hitTest(Offset position) {
    return hitTargetAt(position, surfaceSize).isInteractive;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = RadialMenuGeometry(size);
    _paintCenterShadow(canvas, geometry);
    final easedOpen = Curves.easeOutCubic.transform(openProgress.clamp(0, 1));
    if (easedOpen > .001) {
      _paintPrimaryRing(canvas, geometry, easedOpen);
    }

    final easedSubmenu = Curves.easeOutCubic.transform(
      (openProgress * submenuProgress).clamp(0, 1),
    );
    if (branch != null && easedSubmenu > .001) {
      _paintSecondaryRing(canvas, geometry, easedSubmenu);
      if (tertiaryCount > 0 || hasThicknessSlider) {
        _paintTertiaryRing(canvas, geometry, easedSubmenu);
      }
    }

    _paintCenter(canvas, geometry);
    // The animated tails sit directly on the mint center outline. Painting
    // them last keeps the fine strokes visible without moving them away from
    // the draggable disc.
    _paintTailRing(canvas, geometry);
  }

  void _paintCenterShadow(Canvas canvas, RadialMenuGeometry geometry) {
    canvas.drawCircle(
      geometry.center.translate(0, 4 * geometry.scale),
      geometry.centerRadius + 7 * geometry.scale,
      Paint()
        ..color = const Color(0x99000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 11 * geometry.scale),
    );
  }

  void _paintTailRing(Canvas canvas, RadialMenuGeometry geometry) {
    final radius = (geometry.tailInnerRadius + geometry.tailOuterRadius) / 2;
    final rect = Rect.fromCircle(center: geometry.center, radius: radius);
    final rotation = tailRotation * math.pi * 2;
    final scale = geometry.scale;
    const sweep = .78;
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 7 * scale
      ..color = theme.activeColor.withValues(alpha: .16)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 * scale);
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2, 3.2 * scale)
      ..shader = SweepGradient(
        colors: <Color>[
          theme.activeColor.withValues(alpha: .08),
          theme.activeColor.withValues(alpha: .55),
          theme.textColor.withValues(alpha: .96),
        ],
      ).createShader(rect);

    for (final base in <double>[.14, math.pi + .14]) {
      final start = base + rotation - math.pi / 2;
      canvas.drawArc(rect, start, sweep, false, glowPaint);
      canvas.drawArc(rect, start, sweep, false, arcPaint);
      final tip = geometry.polarPoint(radius, base + rotation + sweep);
      canvas.drawCircle(
        tip,
        5.5 * scale,
        Paint()
          ..color = theme.activeColor.withValues(alpha: .18)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * scale),
      );
      canvas.drawCircle(
        tip,
        3.1 * scale,
        Paint()..color = theme.textColor.withValues(alpha: .96),
      );
      canvas.drawCircle(
        tip,
        1.45 * scale,
        Paint()..color = theme.activeMutedColor,
      );
    }
  }

  void _paintCenter(Canvas canvas, RadialMenuGeometry geometry) {
    final rect = Rect.fromCircle(
      center: geometry.center,
      radius: geometry.centerRadius,
    );
    canvas.drawCircle(
      geometry.center,
      geometry.centerRadius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.25, -.3),
          radius: .95,
          colors: <Color>[
            theme.centerColor.withValues(red: .19, green: .21, blue: .22),
            theme.centerColor,
          ],
        ).createShader(rect),
    );
    canvas.drawCircle(
      geometry.center,
      geometry.centerRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * geometry.scale
        ..color = theme.outlineColor.withValues(alpha: .75),
    );
    canvas.drawCircle(
      geometry.center,
      geometry.centerRadius - 5 * geometry.scale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 * geometry.scale
        ..color = theme.activeColor.withValues(alpha: isOpen ? .7 : .28),
    );

    final centerHit = pressed == RadialHitTarget.center
        ? theme.activeColor.withValues(alpha: .12)
        : hovered == RadialHitTarget.center
        ? Colors.white.withValues(alpha: .06)
        : Colors.transparent;
    canvas.drawCircle(
      geometry.center,
      geometry.centerRadius - 2 * geometry.scale,
      Paint()..color = centerHit,
    );
    if (logoIcon != null) {
      _drawIcon(
        canvas,
        logoIcon!,
        geometry.center,
        35 * geometry.scale,
        theme.textColor,
      );
    }
  }

  void _paintPrimaryRing(
    Canvas canvas,
    RadialMenuGeometry geometry,
    double progress,
  ) {
    final collapsedRadius = geometry.tailOuterRadius + 4 * geometry.scale;
    final inner = _lerp(collapsedRadius, geometry.primaryInnerRadius, progress);
    final outer = _lerp(
      collapsedRadius + 1,
      geometry.primaryOuterRadius,
      progress,
    );
    if (outer - inner < 1) return;

    for (var index = 0; index < RadialMenuAction.values.length; index++) {
      final action = RadialMenuAction.values[index];
      final target = RadialHitTarget(RadialMenuLayer.primary, index);
      final enabled = _primaryActionEnabled(action);
      final active =
          enabled &&
          (branch == null
              ? selectedPrimary == action
              : expandedPrimary == action);
      final path = geometry.ringSegmentPath(
        index: index,
        count: RadialMenuAction.values.length,
        innerRadius: inner,
        outerRadius: outer,
        startAngle: -math.pi / RadialMenuAction.values.length,
        cornerRadius: 9 * geometry.scale,
      );
      _drawSegment(
        canvas,
        path,
        target: target,
        active: active,
        opacity: progress,
        enabled: enabled,
      );

      final position = geometry.pointForSegment(
        index: index,
        count: RadialMenuAction.values.length,
        radius: (inner + outer) / 2,
        startAngle: -math.pi / RadialMenuAction.values.length,
      );
      canvas.save();
      canvas.clipPath(path);
      _drawIconAndLabel(
        canvas,
        icon: _primaryIcons[index],
        label: _compactPrimaryLabel(action),
        center: position,
        iconSize: 24 * geometry.scale,
        fontSize: 8.8 * geometry.scale,
        maxWidth: _segmentLabelWidth(
          radius: (inner + outer) / 2,
          sweep: math.pi * 2 / RadialMenuAction.values.length,
          scale: geometry.scale,
          preferred: 65 * geometry.scale,
        ),
        opacity: progress * (enabled ? 1 : .32),
      );
      canvas.restore();
    }
  }

  void _paintSecondaryRing(
    Canvas canvas,
    RadialMenuGeometry geometry,
    double progress,
  ) {
    if (secondaryCount == 0) return;
    final collapsedRadius = geometry.primaryOuterRadius + 4 * geometry.scale;
    final inner = _lerp(
      collapsedRadius,
      geometry.secondaryInnerRadius,
      progress,
    );
    final outer = _lerp(
      collapsedRadius + 1,
      geometry.secondaryOuterRadius,
      progress,
    );

    final startAngle = _submenuStartAngle(geometry);
    final span = _secondarySpan(geometry);
    if (branch == RadialMenuBranch.pen) {
      _paintPenColorPanel(
        canvas,
        geometry,
        inner: inner,
        outer: outer,
        startAngle: startAngle,
        span: span,
        progress: progress,
      );
      return;
    }
    for (var index = 0; index < secondaryCount; index++) {
      final target = RadialHitTarget(RadialMenuLayer.secondary, index);
      final path = geometry.ringSegmentPath(
        index: index,
        count: secondaryCount,
        innerRadius: inner,
        outerRadius: outer,
        startAngle: startAngle,
        span: span,
        cornerRadius: 9 * geometry.scale,
      );
      _drawSegment(
        canvas,
        path,
        target: target,
        active: _secondaryIsActive(index),
        opacity: progress,
      );
      final position = geometry.pointForSegment(
        index: index,
        count: secondaryCount,
        radius: (inner + outer) / 2,
        startAngle: startAngle,
        span: span,
      );
      canvas.save();
      canvas.clipPath(path);
      _paintSecondaryContent(canvas, geometry, index, position, progress);
      canvas.restore();
    }
  }

  void _paintTertiaryRing(
    Canvas canvas,
    RadialMenuGeometry geometry,
    double progress,
  ) {
    final collapsedRadius = geometry.secondaryOuterRadius + 4 * geometry.scale;
    final inner = _lerp(
      collapsedRadius,
      geometry.tertiaryInnerRadius,
      progress,
    );
    final outer = _lerp(
      collapsedRadius + 1,
      geometry.tertiaryOuterRadius,
      progress,
    );

    final startAngle = _tertiaryStartAngle(geometry);
    final span = _tertiarySpan(geometry);
    if (hasThicknessSlider) {
      _paintThicknessSlider(canvas, geometry, inner, outer, progress);
    }
    if (tertiaryCount == 0) return;
    if (branch == RadialMenuBranch.pen) {
      _paintPenTypePanel(
        canvas,
        geometry,
        inner: inner,
        outer: outer,
        startAngle: startAngle,
        span: span,
        progress: progress,
      );
      return;
    }
    for (var index = 0; index < tertiaryCount; index++) {
      final target = RadialHitTarget(RadialMenuLayer.tertiary, index);
      final path = geometry.ringSegmentPath(
        index: index,
        count: tertiaryCount,
        innerRadius: inner,
        outerRadius: outer,
        startAngle: startAngle,
        span: span,
        cornerRadius: 9 * geometry.scale,
      );
      _drawSegment(
        canvas,
        path,
        target: target,
        active: _tertiaryIsActive(index),
        opacity: progress,
      );
      final position = geometry.pointForSegment(
        index: index,
        count: tertiaryCount,
        radius: (inner + outer) / 2,
        startAngle: startAngle,
        span: span,
      );
      final content = _tertiaryContent(index);
      canvas.save();
      canvas.clipPath(path);
      _drawIconAndLabel(
        canvas,
        icon: content.$1,
        label: content.$2,
        center: position,
        iconSize: 23 * geometry.scale,
        fontSize: 9 * geometry.scale,
        maxWidth: _segmentLabelWidth(
          radius: (inner + outer) / 2,
          sweep: span / tertiaryCount,
          scale: geometry.scale,
          preferred: 70 * geometry.scale,
        ),
        opacity: progress,
      );
      canvas.restore();
    }
  }

  void _paintPenColorPanel(
    Canvas canvas,
    RadialMenuGeometry geometry, {
    required double inner,
    required double outer,
    required double startAngle,
    required double span,
    required double progress,
  }) {
    const gap = .035;
    final path = geometry.roundedArcSegmentPath(
      startAngle: startAngle + gap / 2,
      sweepAngle: math.max(0, span - gap),
      innerRadius: inner,
      outerRadius: outer,
      cornerRadius: 9 * geometry.scale,
    );
    _drawSegment(
      canvas,
      path,
      target: _panelInteractionTarget(RadialMenuLayer.secondary),
      active: false,
      opacity: progress,
    );

    for (var index = 0; index < _penColorOptionCount; index++) {
      final position = geometry.pointForSegment(
        index: index,
        count: _penColorOptionCount,
        radius: (inner + outer) / 2,
        startAngle: startAngle,
        span: span,
      );
      _paintSecondaryContent(canvas, geometry, index, position, progress);
    }
  }

  void _paintPenTypePanel(
    Canvas canvas,
    RadialMenuGeometry geometry, {
    required double inner,
    required double outer,
    required double startAngle,
    required double span,
    required double progress,
  }) {
    const gap = .035;
    final path = geometry.roundedArcSegmentPath(
      startAngle: startAngle + gap / 2,
      sweepAngle: math.max(0, span - gap),
      innerRadius: inner,
      outerRadius: outer,
      cornerRadius: 9 * geometry.scale,
    );
    _drawSegment(
      canvas,
      path,
      target: _panelInteractionTarget(RadialMenuLayer.tertiary),
      active: false,
      opacity: progress,
    );

    for (var index = 0; index < RadialPenType.values.length; index++) {
      final position = geometry.pointForSegment(
        index: index,
        count: RadialPenType.values.length,
        radius: inner + (outer - inner) * .55,
        startAngle: startAngle,
        span: span,
      );
      final selected = RadialPenType.values[index] == penSettings.type;
      _drawPenTypeGlyph(
        canvas,
        type: RadialPenType.values[index],
        center: position,
        size: (selected ? 27 : 23) * geometry.scale,
        color: (selected ? theme.activeColor : theme.textColor).withValues(
          alpha: progress,
        ),
      );
    }
  }

  RadialHitTarget _panelInteractionTarget(RadialMenuLayer layer) {
    if (pressed.layer == layer) return pressed;
    if (hovered.layer == layer) return hovered;
    return RadialHitTarget(layer);
  }

  void _paintThicknessSlider(
    Canvas canvas,
    RadialMenuGeometry geometry,
    double inner,
    double outer,
    double progress,
  ) {
    const gap = .035;
    final startAngle = _submenuStartAngle(geometry);
    final span = _thicknessSpan(geometry);
    final path = geometry.roundedArcSegmentPath(
      startAngle: startAngle + gap / 2,
      sweepAngle: math.max(0, span - gap),
      innerRadius: inner,
      outerRadius: outer,
      cornerRadius: 9 * geometry.scale,
    );
    _drawSegment(
      canvas,
      path,
      target: RadialHitTarget.thickness,
      active: false,
      opacity: progress,
    );

    final fraction =
        (penSettings.thickness - RadialPenSettings.minThickness) /
        (RadialPenSettings.maxThickness - RadialPenSettings.minThickness);
    final gaugeRadius = inner + (outer - inner) * .67;
    final gaugeRect = Rect.fromCircle(
      center: geometry.center,
      radius: gaugeRadius,
    );
    final visualInset = math.min(.06, span * .14);
    final startCanvas = startAngle - math.pi / 2 + visualInset;
    final sweep = math.max(0.0, span - visualInset * 2);
    const samples = 24;
    for (var index = 0; index < samples; index++) {
      final from = index / samples;
      final to = (index + 1) / samples;
      final active = to <= fraction + .0001;
      canvas.drawArc(
        gaugeRect,
        startCanvas + sweep * from,
        sweep / samples + .002,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = thicknessGaugeStrokeWidth(geometry, to)
          ..strokeCap = StrokeCap.butt
          ..color = (active ? theme.activeColor : theme.outlineColor)
              .withValues(alpha: (active ? 1 : .7) * progress),
      );
    }
    final knob = geometry.polarPoint(
      gaugeRadius,
      startAngle + visualInset + sweep * fraction,
    );
    canvas.drawCircle(
      knob,
      (4.5 + 4.5 * fraction) * geometry.scale,
      Paint()..color = theme.textColor.withValues(alpha: progress),
    );
    canvas.drawCircle(
      knob,
      4 * geometry.scale,
      Paint()..color = theme.activeMutedColor.withValues(alpha: progress),
    );

    final labelPosition = geometry.polarPoint(
      inner + (outer - inner) * .25,
      startAngle + span / 2,
    );
    _drawText(
      canvas,
      'Dicke\n${penSettings.thickness.toStringAsFixed(0)} px',
      labelPosition,
      10 * geometry.scale,
      68 * geometry.scale,
      theme.textColor.withValues(alpha: progress),
      maxLines: 2,
    );
  }

  void _paintSecondaryContent(
    Canvas canvas,
    RadialMenuGeometry geometry,
    int index,
    Offset position,
    double opacity,
  ) {
    switch (branch) {
      case RadialMenuBranch.pen:
        if (index < palette.length) {
          _drawColorSwatch(
            canvas,
            position,
            palette[index],
            geometry.scale,
            opacity,
            selected: penSettings.color == palette[index],
          );
          return;
        }
        if (index == palette.length) {
          _drawCustomColorSwatch(
            canvas,
            position,
            geometry.scale,
            opacity,
            selected: !palette.contains(penSettings.color),
          );
          return;
        }
        final preset = presets[index - palette.length - 1];
        _drawPreset(canvas, position, preset, geometry.scale, opacity);
        return;
      case RadialMenuBranch.selection:
        final tool = RadialSelectionTool.values[index];
        final selectionLabel = labels.selectionTools[tool] ?? tool.name;
        _drawIconAndLabel(
          canvas,
          icon: _selectionIcons[index],
          label: _compactSecondaryLabel(selectionLabel),
          center: position,
          iconSize: 24 * geometry.scale,
          fontSize: 9 * geometry.scale,
          maxWidth: 88 * geometry.scale,
          opacity: opacity,
        );
        return;
      case RadialMenuBranch.templates:
        final template = templateEntries[index];
        if (template.thumbnail case final thumbnail?) {
          _drawThumbnail(
            canvas,
            center: position.translate(0, -5 * geometry.scale),
            thumbnail: thumbnail,
            background: template.backgroundColor,
            scale: geometry.scale,
            opacity: opacity,
            width: 42,
            height: 29,
          );
          _drawText(
            canvas,
            _compactSecondaryLabel(template.label),
            position.translate(0, 18 * geometry.scale),
            8.2 * geometry.scale,
            70 * geometry.scale,
            theme.mutedTextColor.withValues(alpha: opacity),
            maxLines: 1,
          );
        } else {
          _drawIconAndLabel(
            canvas,
            icon:
                template.icon ??
                (template.source == RadialTemplateSource.user
                    ? Icons.person_outline_rounded
                    : Icons.dashboard_customize_outlined),
            label: _compactSecondaryLabel(template.label),
            center: position,
            iconSize: 22 * geometry.scale,
            fontSize: 8.5 * geometry.scale,
            maxWidth: 76 * geometry.scale,
            opacity: opacity,
          );
        }
        return;
      case RadialMenuBranch.pages:
        final page = pagePreviews[index];
        if (page.thumbnail case final thumbnail?) {
          _drawThumbnail(
            canvas,
            center: position.translate(0, -5 * geometry.scale),
            thumbnail: thumbnail,
            background: page.backgroundColor,
            scale: geometry.scale,
            opacity: opacity,
            width: 46,
            height: 31,
          );
        } else {
          final placeholder = RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: position.translate(0, -5 * geometry.scale),
              width: 46 * geometry.scale,
              height: 31 * geometry.scale,
            ),
            Radius.circular(3 * geometry.scale),
          );
          canvas.drawRRect(
            placeholder,
            Paint()..color = page.backgroundColor.withValues(alpha: opacity),
          );
          canvas.drawRRect(
            placeholder,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = geometry.scale
              ..color = theme.outlineColor.withValues(alpha: opacity),
          );
        }
        _drawText(
          canvas,
          '${page.pageNumber}',
          position.translate(0, 19 * geometry.scale),
          9 * geometry.scale,
          40 * geometry.scale,
          theme.textColor.withValues(alpha: opacity),
          maxLines: 1,
        );
        return;
      case RadialMenuBranch.insert:
        final category = RadialInsertCategory.values[index];
        final insertLabel = labels.insertCategories[category] ?? category.name;
        _drawIconAndLabel(
          canvas,
          icon: _insertIcons[index],
          label: _compactSecondaryLabel(insertLabel),
          center: position,
          iconSize: 23 * geometry.scale,
          fontSize: 9 * geometry.scale,
          maxWidth: 78 * geometry.scale,
          opacity: opacity,
        );
        return;
      case RadialMenuBranch.export:
        final action = RadialExportAction.values[index];
        final exportLabel = labels.exportActions[action] ?? action.name;
        _drawIconAndLabel(
          canvas,
          icon: switch (action) {
            RadialExportAction.savePdf => Icons.picture_as_pdf_rounded,
            RadialExportAction.shareLocal => Icons.qr_code_2,
            RadialExportAction.quickShare => Icons.near_me_rounded,
          },
          label: _compactSecondaryLabel(exportLabel),
          center: position,
          iconSize: 25 * geometry.scale,
          fontSize: 9 * geometry.scale,
          maxWidth: 92 * geometry.scale,
          opacity: opacity,
        );
        return;
      case null:
        return;
    }
  }

  void _drawSegment(
    Canvas canvas,
    Path path, {
    required RadialHitTarget target,
    required bool active,
    required double opacity,
    bool enabled = true,
  }) {
    if (opacity > .65) {
      canvas.drawShadow(path, Colors.black.withValues(alpha: .7), 3, false);
    }
    final isPressed = enabled && pressed == target;
    final isHovered = enabled && hovered == target;
    final base = !enabled
        ? Color.lerp(theme.segmentColor, Colors.black, .2)!
        : isPressed
        ? theme.segmentPressedColor
        : isHovered
        ? theme.segmentRaisedColor
        : active
        ? Color.lerp(theme.segmentColor, theme.activeMutedColor, .55)!
        : theme.segmentColor;
    final bounds = path.getBounds();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color.lerp(
              base,
              Colors.white,
              isHovered ? .1 : .045,
            )!.withValues(alpha: opacity),
            Color.lerp(base, Colors.black, .12)!.withValues(alpha: opacity),
          ],
        ).createShader(bounds),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 1.6 : .8
        ..color = (active ? theme.activeColor : theme.outlineColor).withValues(
          alpha: (enabled ? (active ? .72 : .46) : .2) * opacity,
        ),
    );
  }

  void _drawIconAndLabel(
    Canvas canvas, {
    required IconData icon,
    required String label,
    required Offset center,
    required double iconSize,
    required double fontSize,
    required double maxWidth,
    required double opacity,
  }) {
    _drawIcon(
      canvas,
      icon,
      center.translate(0, -iconSize * .34),
      iconSize,
      theme.textColor.withValues(alpha: opacity),
    );
    _drawText(
      canvas,
      label,
      center.translate(0, iconSize * .57),
      fontSize,
      maxWidth,
      theme.mutedTextColor.withValues(alpha: opacity),
    );
  }

  /// Draws purpose-built tool glyphs where Material's generic symbols are
  /// visually ambiguous at radial-menu sizes. In particular, the marker has
  /// a broad chisel nib and translucent swatch, while the line tool is a
  /// perfectly straight segment with explicit endpoints.
  void _drawPenTypeGlyph(
    Canvas canvas, {
    required RadialPenType type,
    required Offset center,
    required double size,
    required Color color,
  }) {
    if (type == RadialPenType.eraser) {
      RadialEraserGlyph.paint(canvas, center: center, size: size, color: color);
      return;
    }
    if (type != RadialPenType.marker && type != RadialPenType.straight) {
      _drawIcon(canvas, _penTypeIcons[type.index], center, size, color);
      return;
    }

    final unit = size / 28;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2.15 * unit;

    if (type == RadialPenType.straight) {
      final from = center.translate(-10.5 * unit, 7 * unit);
      final to = center.translate(10.5 * unit, -7 * unit);
      canvas.drawLine(from, to, stroke..strokeWidth = 2.35 * unit);
      final endpoint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(from, 2.35 * unit, endpoint);
      canvas.drawCircle(to, 2.35 * unit, endpoint);
      return;
    }

    // Highlighter body, cap seam and wide chisel nib. The low-alpha swatch is
    // part of the glyph itself, so it remains recognisable in every theme.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-math.pi / 4);
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(-1.5 * unit, -1.5 * unit),
        width: 9 * unit,
        height: 20 * unit,
      ),
      Radius.circular(2.2 * unit),
    );
    canvas.drawRRect(body, stroke);
    canvas.drawLine(
      Offset(-5.8 * unit, 3.8 * unit),
      Offset(2.8 * unit, 3.8 * unit),
      stroke..strokeWidth = 1.35 * unit,
    );
    final nib = Path()
      ..moveTo(-5.8 * unit, 8.5 * unit)
      ..lineTo(2.8 * unit, 8.5 * unit)
      ..lineTo(5.2 * unit, 12 * unit)
      ..lineTo(-3.4 * unit, 12 * unit)
      ..close();
    canvas.drawPath(nib, Paint()..color = color);
    canvas.restore();
    canvas.drawLine(
      center.translate(-10 * unit, 10 * unit),
      center.translate(10 * unit, 10 * unit),
      Paint()
        ..color = color.withValues(alpha: color.a * .32)
        ..strokeCap = StrokeCap.square
        ..strokeWidth = 4.5 * unit,
    );
  }

  String _compactPrimaryLabel(RadialMenuAction action) => switch (action) {
    RadialMenuAction.previousPage => 'Vorherige\nSeite',
    RadialMenuAction.nextPage => 'Nächste\nSeite',
    RadialMenuAction.newPage => 'Neue\nSeite',
    _ => labels.primary[action] ?? action.name,
  };

  String _compactSecondaryLabel(String label) => switch (label) {
    'Auswahlrechteck' => 'Rechteck',
    'Auswahllasso' => 'Lasso',
    'Alles auswählen' => 'Alles',
    'Als PDF speichern' => 'PDF speichern',
    'Per WLAN / QR teilen' => 'WLAN / QR',
    'Grundschullinien' => 'Linienblatt',
    'Eigene Vorlagen' => 'Eigene\nVorlagen',
    _ => label,
  };

  double _segmentLabelWidth({
    required double radius,
    required double sweep,
    required double scale,
    required double preferred,
  }) {
    final chord = 2 * radius * math.sin(math.min(math.pi, sweep.abs()) / 2);
    return math.max(28 * scale, math.min(preferred, chord - 14 * scale));
  }

  void _drawIcon(
    Canvas canvas,
    IconData icon,
    Offset center,
    double size,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          inherit: false,
          color: color,
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
        ),
      ),
      textDirection: textDirection,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset center,
    double fontSize,
    double maxWidth,
    Color color, {
    int maxLines = 2,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          inherit: false,
          color: color,
          fontSize: math.max(5.5, fontSize),
          fontWeight: FontWeight.w500,
          height: 1.05,
          letterSpacing: .1,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: textDirection,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  void _drawColorSwatch(
    Canvas canvas,
    Offset center,
    Color color,
    double scale,
    double opacity, {
    required bool selected,
  }) {
    final radius = (selected ? 13 : 11) * scale;
    if (selected) {
      canvas.drawCircle(
        center,
        radius + 4 * scale,
        Paint()..color = theme.activeColor.withValues(alpha: opacity),
      );
    }
    canvas.drawCircle(
      center,
      radius + 1.5 * scale,
      Paint()..color = theme.textColor.withValues(alpha: .9 * opacity),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color.withValues(alpha: opacity),
    );
  }

  void _drawThumbnail(
    Canvas canvas, {
    required Offset center,
    required ui.Image thumbnail,
    required Color background,
    required double scale,
    required double opacity,
    required double width,
    required double height,
  }) {
    final destination = Rect.fromCenter(
      center: center,
      width: width * scale,
      height: height * scale,
    );
    final clip = RRect.fromRectAndRadius(
      destination,
      Radius.circular(3.5 * scale),
    );
    canvas.save();
    canvas.clipRRect(clip);
    canvas.drawRect(
      destination,
      Paint()..color = background.withValues(alpha: opacity),
    );
    final source = Rect.fromLTWH(
      0,
      0,
      thumbnail.width.toDouble(),
      thumbnail.height.toDouble(),
    );
    canvas.drawImageRect(
      thumbnail,
      source,
      destination,
      Paint()
        ..filterQuality = FilterQuality.low
        ..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.restore();
    canvas.drawRRect(
      clip,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(.8, scale)
        ..color = theme.textColor.withValues(alpha: .72 * opacity),
    );
  }

  void _drawCustomColorSwatch(
    Canvas canvas,
    Offset center,
    double scale,
    double opacity, {
    required bool selected,
  }) {
    final rect = Rect.fromCircle(center: center, radius: 13 * scale);
    if (selected) {
      canvas.drawCircle(
        center,
        18 * scale,
        Paint()..color = theme.activeColor.withValues(alpha: opacity),
      );
    }
    canvas.drawCircle(
      center,
      14.5 * scale,
      Paint()..color = theme.textColor.withValues(alpha: opacity),
    );
    canvas.drawCircle(
      center,
      12 * scale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5 * scale
        ..shader = SweepGradient(
          colors: <Color>[
            Colors.red,
            Colors.yellow,
            Colors.green,
            Colors.cyan,
            Colors.blue,
            Colors.purple,
            Colors.red,
          ].map((color) => color.withValues(alpha: opacity)).toList(),
        ).createShader(rect),
    );
  }

  void _drawPreset(
    Canvas canvas,
    Offset center,
    RadialPenPreset preset,
    double scale,
    double opacity,
  ) {
    canvas.drawLine(
      center.translate(-13 * scale, -5 * scale),
      center.translate(13 * scale, -5 * scale),
      Paint()
        ..strokeWidth = math.max(1, preset.settings.thickness * scale * .42)
        ..strokeCap = StrokeCap.round
        ..color = preset.settings.color.withValues(alpha: opacity),
    );
    _drawText(
      canvas,
      preset.label,
      center.translate(0, 10 * scale),
      8.5 * scale,
      53 * scale,
      theme.textColor.withValues(alpha: opacity),
      maxLines: 1,
    );
  }

  bool _secondaryIsActive(int index) {
    return switch (branch) {
      RadialMenuBranch.pen =>
        (index < palette.length && palette[index] == penSettings.color) ||
            (index == palette.length && !palette.contains(penSettings.color)),
      RadialMenuBranch.selection =>
        RadialSelectionTool.values[index] == selectionTool,
      RadialMenuBranch.pages =>
        pagePreviews[index].pageIndex == currentPageIndex,
      RadialMenuBranch.insert =>
        RadialInsertCategory.values[index] == insertCategory,
      _ => false,
    };
  }

  bool _tertiaryIsActive(int index) {
    if (branch == RadialMenuBranch.pen) {
      return RadialPenType.values[index] == penSettings.type;
    }
    if (branch == RadialMenuBranch.insert &&
        insertCategory == RadialInsertCategory.geometry) {
      return RadialShapeKind.values[index] == shapeKind;
    }
    return false;
  }

  (IconData, String) _tertiaryContent(int index) {
    if (branch == RadialMenuBranch.pen) {
      final type = RadialPenType.values[index];
      return (_penTypeIcons[index], labels.penTypes[type] ?? type.name);
    }
    return switch (insertCategory) {
      RadialInsertCategory.geometry => (
        _shapeIcons[index],
        labels.shapes[RadialShapeKind.values[index]] ??
            RadialShapeKind.values[index].name,
      ),
      RadialInsertCategory.image => (
        index == 0 ? Icons.photo_library_outlined : Icons.travel_explore,
        labels.imageSources[RadialImageSource.values[index]] ??
            RadialImageSource.values[index].name,
      ),
      RadialInsertCategory.table => switch (index) {
        0 => (
          Icons.remove_rounded,
          '${labels.rows} verringern, aktuell ${tableSize.rows}',
        ),
        1 => (
          Icons.add_rounded,
          '${labels.rows} erhöhen, aktuell ${tableSize.rows}',
        ),
        2 => (
          Icons.remove_rounded,
          '${labels.columns} verringern, aktuell ${tableSize.columns}',
        ),
        3 => (
          Icons.add_rounded,
          '${labels.columns} erhöhen, aktuell ${tableSize.columns}',
        ),
        _ => (Icons.table_chart_rounded, labels.insertTable),
      },
      RadialInsertCategory.pdf => (
        <IconData>[
          Icons.looks_one_outlined,
          Icons.filter_none_rounded,
          Icons.library_books_outlined,
        ][index],
        labels.pdfModes[RadialPdfImportMode.values[index]] ??
            RadialPdfImportMode.values[index].name,
      ),
      RadialInsertCategory.cover => (
        index == 0 ? Icons.swap_horiz_rounded : Icons.swap_vert_rounded,
        labels.coverDirections[RadialCoverDirection.values[index]] ??
            RadialCoverDirection.values[index].name,
      ),
    };
  }

  String _secondarySemanticLabel(int index) {
    return switch (branch) {
      RadialMenuBranch.pen =>
        index < palette.length
            ? _colorLabel(palette[index])
            : index == palette.length
            ? labels.customColor
            : 'Preset ${presets[index - palette.length - 1].label}',
      RadialMenuBranch.selection =>
        labels.selectionTools[RadialSelectionTool.values[index]] ??
            RadialSelectionTool.values[index].name,
      RadialMenuBranch.templates =>
        templateEntries[index].semanticLabel ?? templateEntries[index].label,
      RadialMenuBranch.pages =>
        pagePreviews[index].semanticLabel ??
            'Seite ${pagePreviews[index].pageNumber}',
      RadialMenuBranch.insert =>
        labels.insertCategories[RadialInsertCategory.values[index]] ??
            RadialInsertCategory.values[index].name,
      RadialMenuBranch.export =>
        labels.exportActions[RadialExportAction.values[index]] ??
            RadialExportAction.values[index].name,
      null => '',
    };
  }

  String _tertiarySemanticLabel(int index) {
    if (branch == RadialMenuBranch.pen &&
        index >= 0 &&
        index < RadialPenType.values.length &&
        RadialPenType.values[index] == RadialPenType.eraser) {
      return '${_tertiaryContent(index).$2}, automatische Größe';
    }
    return _tertiaryContent(index).$2;
  }

  String _colorLabel(Color color) {
    const known = <int, String>{
      0xFF000000: 'Schwarz',
      0xFFFFFFFF: 'Weiß',
      0xFFF44336: 'Rot',
      0xFF2196F3: 'Blau',
      0xFF4CAF50: 'Grün',
      0xFFFFC107: 'Gelb',
      0xFF00BCD4: 'Cyan',
      0xFF9C27B0: 'Violett',
    };
    return known[color.toARGB32()] ?? 'Farbe';
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (Size size) {
    final geometry = RadialMenuGeometry(size);
    final semantics = <CustomPainterSemantics>[
      CustomPainterSemantics(
        rect: Rect.fromCircle(
          center: geometry.center,
          radius: geometry.centerRadius,
        ),
        properties: SemanticsProperties(
          label: labels.menu,
          hint: isOpen ? labels.closeMenu : labels.openMenu,
          button: true,
          toggled: isOpen,
          onTap: () => onSemanticActivate(RadialHitTarget.center),
          textDirection: textDirection,
        ),
      ),
    ];
    if (!isOpen || openProgress < .72) return semantics;

    for (var index = 0; index < RadialMenuAction.values.length; index++) {
      final action = RadialMenuAction.values[index];
      final enabled = _primaryActionEnabled(action);
      semantics.add(
        _semanticsForSegment(
          geometry: geometry,
          radius:
              (geometry.primaryInnerRadius + geometry.primaryOuterRadius) / 2,
          index: index,
          count: RadialMenuAction.values.length,
          startAngle: -math.pi / RadialMenuAction.values.length,
          label: labels.primary[action] ?? action.name,
          target: RadialHitTarget(RadialMenuLayer.primary, index),
          selected: branch == null
              ? selectedPrimary == action
              : expandedPrimary == action,
          enabled: enabled,
        ),
      );
    }
    if (branch == null || submenuProgress < .55) return semantics;

    final submenuStart = _submenuStartAngle(geometry);
    final submenuSpan = _secondarySpan(geometry);
    final semanticSecondaryCount = branch == RadialMenuBranch.pen
        ? _penColorOptionCount
        : secondaryCount;
    for (var index = 0; index < semanticSecondaryCount; index++) {
      semantics.add(
        _semanticsForSegment(
          geometry: geometry,
          radius:
              (geometry.secondaryInnerRadius + geometry.secondaryOuterRadius) /
              2,
          index: index,
          count: semanticSecondaryCount,
          startAngle: submenuStart,
          span: submenuSpan,
          label: _secondarySemanticLabel(index),
          target: RadialHitTarget(RadialMenuLayer.secondary, index),
          selected: _secondaryIsActive(index),
        ),
      );
    }

    if (hasThicknessSlider) {
      final sliderCenter = geometry.polarPoint(
        (geometry.tertiaryInnerRadius + geometry.tertiaryOuterRadius) / 2,
        submenuStart + _thicknessSpan(geometry) / 2,
      );
      final step = 1.0;
      semantics.add(
        CustomPainterSemantics(
          rect: Rect.fromCircle(
            center: sliderCenter,
            radius: 34 * geometry.scale,
          ),
          properties: SemanticsProperties(
            label: labels.thickness,
            value: penSettings.thickness.toStringAsFixed(0),
            increasedValue: math
                .min(
                  RadialPenSettings.maxThickness,
                  penSettings.thickness + step,
                )
                .toStringAsFixed(0),
            decreasedValue: math
                .max(
                  RadialPenSettings.minThickness,
                  penSettings.thickness - step,
                )
                .toStringAsFixed(0),
            slider: true,
            onIncrease: () => onSemanticThicknessChanged(
              math.min(
                RadialPenSettings.maxThickness,
                penSettings.thickness + step,
              ),
            ),
            onDecrease: () => onSemanticThicknessChanged(
              math.max(
                RadialPenSettings.minThickness,
                penSettings.thickness - step,
              ),
            ),
            textDirection: textDirection,
          ),
        ),
      );
    }
    final tertiaryStart = _tertiaryStartAngle(geometry);
    final tertiarySpan = _tertiarySpan(geometry);
    final semanticTertiaryCount = branch == RadialMenuBranch.pen
        ? RadialPenType.values.length
        : tertiaryCount;
    for (var index = 0; index < semanticTertiaryCount; index++) {
      semantics.add(
        _semanticsForSegment(
          geometry: geometry,
          radius:
              (geometry.tertiaryInnerRadius + geometry.tertiaryOuterRadius) / 2,
          index: index,
          count: semanticTertiaryCount,
          startAngle: tertiaryStart,
          span: tertiarySpan,
          label: _tertiarySemanticLabel(index),
          target: RadialHitTarget(RadialMenuLayer.tertiary, index),
          selected: _tertiaryIsActive(index),
        ),
      );
    }
    return semantics;
  };

  CustomPainterSemantics _semanticsForSegment({
    required RadialMenuGeometry geometry,
    required double radius,
    required int index,
    required int count,
    required String label,
    required RadialHitTarget target,
    required bool selected,
    bool enabled = true,
    double startAngle = 0,
    double span = math.pi * 2,
  }) {
    final center = geometry.pointForSegment(
      index: index,
      count: count,
      radius: radius,
      startAngle: startAngle,
      span: span,
    );
    return _semanticsAtPosition(
      center: center,
      radius: 27 * geometry.scale,
      label: label,
      target: target,
      selected: selected,
      enabled: enabled,
    );
  }

  CustomPainterSemantics _semanticsAtPosition({
    required Offset center,
    required double radius,
    required String label,
    required RadialHitTarget target,
    required bool selected,
    bool enabled = true,
  }) {
    return CustomPainterSemantics(
      rect: Rect.fromCircle(center: center, radius: radius),
      properties: SemanticsProperties(
        label: label,
        button: true,
        selected: selected,
        enabled: enabled,
        onTap: enabled ? () => onSemanticActivate(target) : null,
        textDirection: textDirection,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant RadialMenuPainter oldDelegate) {
    return isOpen != oldDelegate.isOpen ||
        branch != oldDelegate.branch ||
        expandedPrimary != oldDelegate.expandedPrimary ||
        selectedPrimary != oldDelegate.selectedPrimary ||
        penSettings != oldDelegate.penSettings ||
        selectionTool != oldDelegate.selectionTool ||
        insertCategory != oldDelegate.insertCategory ||
        shapeKind != oldDelegate.shapeKind ||
        tableSize != oldDelegate.tableSize ||
        !listEquals(palette, oldDelegate.palette) ||
        !listEquals(presets, oldDelegate.presets) ||
        !listEquals(pagePreviews, oldDelegate.pagePreviews) ||
        currentPageIndex != oldDelegate.currentPageIndex ||
        !listEquals(templateEntries, oldDelegate.templateEntries) ||
        surfaceSize != oldDelegate.surfaceSize ||
        openProgress != oldDelegate.openProgress ||
        submenuProgress != oldDelegate.submenuProgress ||
        tailRotation != oldDelegate.tailRotation ||
        hovered != oldDelegate.hovered ||
        pressed != oldDelegate.pressed ||
        canUndo != oldDelegate.canUndo ||
        canRedo != oldDelegate.canRedo ||
        theme != oldDelegate.theme ||
        labels != oldDelegate.labels ||
        logoIcon != oldDelegate.logoIcon ||
        textDirection != oldDelegate.textDirection;
  }

  @override
  bool shouldRebuildSemantics(covariant RadialMenuPainter oldDelegate) {
    return isOpen != oldDelegate.isOpen ||
        branch != oldDelegate.branch ||
        expandedPrimary != oldDelegate.expandedPrimary ||
        selectedPrimary != oldDelegate.selectedPrimary ||
        penSettings != oldDelegate.penSettings ||
        selectionTool != oldDelegate.selectionTool ||
        insertCategory != oldDelegate.insertCategory ||
        shapeKind != oldDelegate.shapeKind ||
        tableSize != oldDelegate.tableSize ||
        !listEquals(pagePreviews, oldDelegate.pagePreviews) ||
        currentPageIndex != oldDelegate.currentPageIndex ||
        !listEquals(templateEntries, oldDelegate.templateEntries) ||
        surfaceSize != oldDelegate.surfaceSize ||
        _primarySemanticsVisible != oldDelegate._primarySemanticsVisible ||
        _submenuSemanticsVisible != oldDelegate._submenuSemanticsVisible ||
        canUndo != oldDelegate.canUndo ||
        canRedo != oldDelegate.canRedo ||
        labels != oldDelegate.labels ||
        textDirection != oldDelegate.textDirection;
  }

  bool get _primarySemanticsVisible => isOpen && openProgress >= .72;

  bool get _submenuSemanticsVisible =>
      _primarySemanticsVisible && branch != null && submenuProgress >= .55;

  double _lerp(double a, double b, double t) => a + (b - a) * t;
}
