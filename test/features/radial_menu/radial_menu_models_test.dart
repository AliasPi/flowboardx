import 'package:flowboard_x/src/features/radial_menu/radial_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RadialMenuController', () {
    test('uses black as the stable default pen color', () {
      final controller = RadialMenuController();

      expect(controller.penSettings.color, Colors.black);
      expect(controller.penSettings.thickness, 8);
      expect(controller.penSettings.type, RadialPenType.normal);
      expect(controller.selectedPrimary, RadialMenuAction.pen);
    });

    test('keeps exactly one submenu branch active', () {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);

      controller.activatePrimary(RadialMenuAction.pen);
      expect(controller.activeBranch, RadialMenuBranch.pen);

      controller.activatePrimary(RadialMenuAction.insert);
      expect(controller.activeBranch, RadialMenuBranch.insert);

      controller.activatePrimary(RadialMenuAction.undo);
      expect(controller.activeBranch, isNull);
    });

    test('normalizes unsafe thickness and table dimensions', () {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);

      controller.setPenSettings(
        const RadialPenSettings(thickness: 900, color: Colors.red),
      );
      controller.setTableSize(const RadialTableSize(100, 99));

      expect(controller.penSettings.thickness, RadialPenSettings.maxThickness);
      expect(controller.tableSize, const RadialTableSize(24, 24));
    });

    test(
      'same primary collapses its outer rings without changing the mode',
      () {
        final controller = RadialMenuController(isOpen: true);
        addTearDown(controller.dispose);

        controller.activatePrimary(RadialMenuAction.pen);
        expect(controller.activeBranch, RadialMenuBranch.pen);
        controller.activatePrimary(RadialMenuAction.pen);

        expect(controller.activeBranch, isNull);
        expect(controller.selectedPrimary, RadialMenuAction.pen);
      },
    );

    test('page actions keep the cyclic page wheel open', () {
      final controller = RadialMenuController(isOpen: true);
      addTearDown(controller.dispose);

      controller.activatePrimary(RadialMenuAction.nextPage);
      expect(controller.activeBranch, RadialMenuBranch.pages);
      expect(controller.expandedPrimary, RadialMenuAction.nextPage);
      controller.activatePrimary(RadialMenuAction.previousPage);
      expect(controller.activeBranch, RadialMenuBranch.pages);
      expect(controller.expandedPrimary, RadialMenuAction.previousPage);
      controller.activatePrimary(RadialMenuAction.newPage);
      expect(controller.activeBranch, RadialMenuBranch.pages);
      expect(controller.expandedPrimary, RadialMenuAction.newPage);
    });

    test('templates open and collapse their own second ring', () {
      final controller = RadialMenuController(isOpen: true);
      addTearDown(controller.dispose);

      controller.activatePrimary(RadialMenuAction.templates);
      expect(controller.activeBranch, RadialMenuBranch.templates);
      expect(controller.expandedPrimary, RadialMenuAction.templates);
      controller.activatePrimary(RadialMenuAction.templates);
      expect(controller.activeBranch, isNull);
    });

    test('opening modes applies their explicit defaults', () {
      final controller = RadialMenuController(
        isOpen: true,
        selectedPrimary: RadialMenuAction.selection,
        penSettings: const RadialPenSettings(
          color: Colors.red,
          thickness: 20,
          type: RadialPenType.marker,
        ),
        selectionTool: RadialSelectionTool.lasso,
        insertCategory: RadialInsertCategory.pdf,
        shapeKind: RadialShapeKind.triangle,
      );
      addTearDown(controller.dispose);

      controller.activatePrimary(RadialMenuAction.pen);
      expect(controller.penSettings, const RadialPenSettings());

      controller.activatePrimary(RadialMenuAction.selection);
      expect(controller.selectionTool, RadialSelectionTool.rectangle);

      controller.activatePrimary(RadialMenuAction.insert);
      expect(controller.insertCategory, RadialInsertCategory.geometry);
      expect(controller.shapeKind, RadialShapeKind.rectangle);
    });

    test('collapsing an active pen fan preserves adjusted settings', () {
      final controller = RadialMenuController(isOpen: true);
      addTearDown(controller.dispose);

      controller.activatePrimary(RadialMenuAction.pen);
      controller.setPenSettings(
        const RadialPenSettings(
          color: Colors.blue,
          thickness: 12,
          type: RadialPenType.dashed,
        ),
      );
      controller.activatePrimary(RadialMenuAction.pen);

      expect(controller.activeBranch, isNull);
      expect(
        controller.penSettings,
        const RadialPenSettings(
          color: Colors.blue,
          thickness: 12,
          type: RadialPenType.dashed,
        ),
      );
    });
  });

  test('built-in pen menu contains no duplicate presets', () {
    expect(RadialPenPreset.defaults, isEmpty);
  });

  test('export menu exposes creating a whiteboard from selected pages', () {
    final labels = RadialMenuLabels.german();

    expect(
      RadialExportAction.values,
      contains(RadialExportAction.newWhiteboardFromPages),
    );
    expect(
      labels.exportActions[RadialExportAction.newWhiteboardFromPages],
      'Seiten in neues Whiteboard',
    );
  });

  test('primary action enum is the required clockwise order', () {
    expect(RadialMenuAction.values, <RadialMenuAction>[
      RadialMenuAction.pen,
      RadialMenuAction.redo,
      RadialMenuAction.selection,
      RadialMenuAction.templates,
      RadialMenuAction.nextPage,
      RadialMenuAction.newPage,
      RadialMenuAction.previousPage,
      RadialMenuAction.insert,
      RadialMenuAction.export,
      RadialMenuAction.undo,
    ]);
  });

  group('RadialMenuGeometry', () {
    const size = Size.square(RadialMenuGeometry.designDiameter);
    const geometry = RadialMenuGeometry(size);

    test('places Stift at twelve o clock and follows clockwise order', () {
      for (var index = 0; index < RadialMenuAction.values.length; index++) {
        final point = geometry.pointForSegment(
          index: index,
          count: RadialMenuAction.values.length,
          radius:
              (geometry.primaryInnerRadius + geometry.primaryOuterRadius) / 2,
          startAngle: -3.141592653589793 / RadialMenuAction.values.length,
        );
        final hit = geometry.hitTest(
          point,
          isOpen: true,
          secondaryCount: 0,
          tertiaryCount: 0,
          hasThicknessSlider: false,
        );

        expect(hit, RadialHitTarget(RadialMenuLayer.primary, index));
      }

      final penCenter = geometry.pointForSegment(
        index: 0,
        count: 10,
        radius: 125,
        startAngle: -3.141592653589793 / 10,
      );
      expect(penCenter.dx, closeTo(geometry.center.dx, .001));
      expect(penCenter.dy, lessThan(geometry.center.dy));
    });

    test('closed menu accepts only its center', () {
      expect(
        geometry
            .hitTest(
              geometry.center,
              isOpen: false,
              secondaryCount: 0,
              tertiaryCount: 0,
              hasThicknessSlider: false,
            )
            .layer,
        RadialMenuLayer.center,
      );
      expect(
        geometry.hitTest(
          geometry.center.translate(120, 0),
          isOpen: false,
          secondaryCount: 0,
          tertiaryCount: 0,
          hasThicknessSlider: false,
        ),
        RadialHitTarget.none,
      );
    });

    test('keeps secondary and tertiary entries inside a three-slot fan', () {
      final start = geometry.compactSubmenuStartAngle(
        RadialMenuAction.selection.index,
      );
      final span = geometry.compactSubmenuSpan;
      for (var index = 0; index < 3; index++) {
        final point = geometry.pointForSegment(
          index: index,
          count: 3,
          radius:
              (geometry.secondaryInnerRadius + geometry.secondaryOuterRadius) /
              2,
          startAngle: start,
          span: span,
        );
        expect(
          geometry.hitTest(
            point,
            isOpen: true,
            secondaryCount: 3,
            tertiaryCount: 0,
            hasThicknessSlider: false,
            secondaryStartAngle: start,
            secondarySpan: span,
          ),
          RadialHitTarget(RadialMenuLayer.secondary, index),
        );
      }

      final opposite = geometry.polarPoint(
        (geometry.secondaryInnerRadius + geometry.secondaryOuterRadius) / 2,
        geometry.primaryCenterAngle(RadialMenuAction.selection.index) +
            3.141592653589793,
      );
      expect(
        geometry.hitTest(
          opposite,
          isOpen: true,
          secondaryCount: 3,
          tertiaryCount: 0,
          hasThicknessSlider: false,
          secondaryStartAngle: start,
          secondarySpan: span,
        ),
        RadialHitTarget.none,
      );
    });

    test('separates compact thickness slider from pen type segments', () {
      expect(
        geometry.thicknessSpan,
        greaterThan(geometry.compactSubmenuSpan / 2),
      );
      final sliderPoint = geometry.polarPoint(
        (geometry.tertiaryInnerRadius + geometry.tertiaryOuterRadius) / 2,
        geometry.thicknessStartAngle + geometry.thicknessSpan / 2,
      );
      final typePoint = geometry.pointForSegment(
        index: 2,
        count: 4,
        radius:
            (geometry.tertiaryInnerRadius + geometry.tertiaryOuterRadius) / 2,
        startAngle: geometry.penTypesStartAngle,
        span: geometry.penTypesSpan,
      );

      expect(
        geometry.hitTest(
          sliderPoint,
          isOpen: true,
          secondaryCount: 12,
          tertiaryCount: 4,
          hasThicknessSlider: true,
          secondaryStartAngle: geometry.compactSubmenuStartAngle(0),
          secondarySpan: geometry.compactSubmenuSpan,
          tertiaryStartAngle: geometry.penTypesStartAngle,
          tertiarySpan: geometry.penTypesSpan,
          thicknessStartAngle: geometry.thicknessStartAngle,
          thicknessSpan: geometry.thicknessSpan,
        ),
        RadialHitTarget.thickness,
      );
      expect(
        geometry.hitTest(
          typePoint,
          isOpen: true,
          secondaryCount: 12,
          tertiaryCount: 4,
          hasThicknessSlider: true,
          secondaryStartAngle: geometry.compactSubmenuStartAngle(0),
          secondarySpan: geometry.compactSubmenuSpan,
          tertiaryStartAngle: geometry.penTypesStartAngle,
          tertiarySpan: geometry.penTypesSpan,
          thicknessStartAngle: geometry.thicknessStartAngle,
          thicknessSpan: geometry.thicknessSpan,
        ),
        const RadialHitTarget(RadialMenuLayer.tertiary, 2),
      );
    });

    test('thickness gauge represents the real logical pen width', () {
      expect(
        RadialMenuPainter.thicknessGaugeStrokeWidth(geometry, 0),
        RadialPenSettings.minThickness,
      );
      expect(
        RadialMenuPainter.thicknessGaugeStrokeWidth(geometry, 1),
        RadialPenSettings.maxThickness,
      );
      expect(
        RadialMenuPainter.thicknessGaugeStrokeWidth(geometry, .5),
        (RadialPenSettings.minThickness + RadialPenSettings.maxThickness) / 2,
      );
      // Even 32 px leaves outer clearance in the 62 px tertiary band at the
      // chosen gauge radius, so the preview stays clip-free at design scale.
      final outerClearance =
          geometry.tertiaryOuterRadius -
          (geometry.tertiaryInnerRadius +
              (geometry.tertiaryOuterRadius - geometry.tertiaryInnerRadius) *
                  .67);
      expect(
        RadialMenuPainter.thicknessGaugeStrokeWidth(geometry, 1) / 2,
        lessThan(outerClearance),
      );
    });
  });
}
