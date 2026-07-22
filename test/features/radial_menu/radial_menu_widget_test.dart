import 'dart:math' as math;

import 'package:flowboard_x/src/features/radial_menu/radial_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    required RadialMenuController controller,
    RadialMenuCallbacks callbacks = const RadialMenuCallbacks(),
    List<RadialPagePreview> pages = const <RadialPagePreview>[],
    int currentPageIndex = 0,
    List<RadialTemplateEntry> templates = const <RadialTemplateEntry>[],
    VoidCallback? onBackgroundTap,
    bool canUndo = true,
    bool canRedo = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 800,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBackgroundTap,
                ),
              ),
              Positioned.fill(
                child: RadialMenu(
                  controller: controller,
                  callbacks: callbacks,
                  pagePreviews: pages,
                  currentPageIndex: currentPageIndex,
                  templateEntries: templates,
                  canUndo: canUndo,
                  canRedo: canRedo,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Offset segmentGlobalPoint(
    WidgetTester tester, {
    required int index,
    required int count,
    required double radius,
    double startAngle = 0,
    double span = math.pi * 2,
  }) {
    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final size = tester.getSize(surface);
    final geometry = RadialMenuGeometry(size);
    return tester.getTopLeft(surface) +
        geometry.pointForSegment(
          index: index,
          count: count,
          radius: radius * geometry.scale,
          startAngle: startAngle,
          span: span,
        );
  }

  testWidgets('center toggles the menu and exposes ordered semantics', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    final openChanges = <bool>[];

    await tester.pumpWidget(
      host(
        controller: controller,
        callbacks: RadialMenuCallbacks(onMenuOpenChanged: openChanges.add),
      ),
    );

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    await tester.tapAt(tester.getCenter(surface));
    await tester.pumpAndSettle();

    expect(controller.isOpen, isTrue);
    expect(openChanges, <bool>[true]);
    final customPaint = tester.widget<CustomPaint>(surface);
    final painter = customPaint.painter! as RadialMenuPainter;
    final semanticLabels = painter
        .semanticsBuilder(tester.getSize(surface))
        .map((entry) => entry.properties.label)
        .toSet();
    expect(semanticLabels, containsAll(<String>{'Stift', 'Wiederholen'}));

    await tester.tapAt(tester.getCenter(surface));
    await tester.pumpAndSettle();
    expect(controller.isOpen, isFalse);
    expect(controller.activeBranch, isNull);
    expect(openChanges, <bool>[true, false]);
  });

  testWidgets('pen opens rings two and three and updates real settings', (
    tester,
  ) async {
    final controller = RadialMenuController(isOpen: true);
    addTearDown(controller.dispose);
    final changes = <RadialPenSettings>[];

    await tester.pumpWidget(
      host(
        controller: controller,
        callbacks: RadialMenuCallbacks(onPenSettingsChanged: changes.add),
      ),
    );
    await tester.pumpAndSettle();

    final pen = segmentGlobalPoint(
      tester,
      index: 0,
      count: 10,
      radius: 125,
      startAngle: -math.pi / 10,
    );
    await tester.tapAt(pen);
    await tester.pumpAndSettle();
    expect(controller.activeBranch, RadialMenuBranch.pen);

    final secondaryCount =
        RadialMenu.defaultPalette.length + 1 + RadialPenPreset.defaults.length;
    const geometry = RadialMenuGeometry(Size.square(600));
    final blue = segmentGlobalPoint(
      tester,
      index: 1,
      count: secondaryCount,
      radius: 192,
      startAngle: geometry.compactSubmenuStartAngle(RadialMenuAction.pen.index),
      span: geometry.compactSubmenuSpan,
    );
    await tester.tapAt(blue);
    await tester.pump();
    expect(controller.penSettings.color, const Color(0xFF2196F3));

    final straight = segmentGlobalPoint(
      tester,
      index: RadialPenType.straight.index,
      count: RadialPenType.values.length,
      radius: 256,
      startAngle: geometry.penTypesStartAngle,
      span: geometry.penTypesSpan,
    );
    await tester.tapAt(straight);
    await tester.pump();

    expect(controller.penSettings.type, RadialPenType.straight);
    expect(changes, hasLength(2));
  });

  testWidgets(
    'pen colors and types are single panels with independent inner targets',
    (tester) async {
      final controller = RadialMenuController(isOpen: true);
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller: controller));
      await tester.pumpAndSettle();

      final pen = segmentGlobalPoint(
        tester,
        index: RadialMenuAction.pen.index,
        count: RadialMenuAction.values.length,
        radius: 125,
        startAngle: -math.pi / RadialMenuAction.values.length,
      );
      await tester.tapAt(pen);
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final size = tester.getSize(surface);
      final geometry = RadialMenuGeometry(size);
      final painter =
          tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;
      final colorCount =
          RadialMenu.defaultPalette.length +
          1 +
          RadialPenPreset.defaults.length;

      expect(painter.secondaryCount, 1, reason: 'one continuous color panel');
      expect(painter.tertiaryCount, 1, reason: 'one continuous pen-type panel');
      for (var index = 0; index < colorCount; index++) {
        final point = geometry.pointForSegment(
          index: index,
          count: colorCount,
          radius:
              (geometry.secondaryInnerRadius + geometry.secondaryOuterRadius) /
              2,
          startAngle: geometry.compactSubmenuStartAngle(
            RadialMenuAction.pen.index,
          ),
          span: geometry.compactSubmenuSpan,
        );
        expect(
          painter.hitTargetAt(point, size),
          RadialHitTarget(RadialMenuLayer.secondary, index),
        );
      }
      for (var index = 0; index < RadialPenType.values.length; index++) {
        final point = geometry.pointForSegment(
          index: index,
          count: RadialPenType.values.length,
          radius:
              (geometry.tertiaryInnerRadius + geometry.tertiaryOuterRadius) / 2,
          startAngle: geometry.penTypesStartAngle,
          span: geometry.penTypesSpan,
        );
        expect(
          painter.hitTargetAt(point, size),
          RadialHitTarget(RadialMenuLayer.tertiary, index),
        );
      }

      final selectedLabels = painter
          .semanticsBuilder(size)
          .where((entry) => entry.properties.selected == true)
          .map((entry) => entry.properties.label)
          .toSet();
      expect(
        selectedLabels,
        containsAll(<String>{'Stift', 'Schwarz', 'Normal'}),
      );
    },
  );

  testWidgets('first tap after an editor rebuild reaches animated submenu', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    var backgroundTaps = 0;
    await tester.pumpWidget(
      host(controller: controller, onBackgroundTap: () => backgroundTaps++),
    );
    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    await tester.tapAt(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 16));

    final pen = segmentGlobalPoint(
      tester,
      index: 0,
      count: 10,
      radius: 125,
      startAngle: -math.pi / 10,
    );
    await tester.tapAt(pen);
    await tester.pump(const Duration(milliseconds: 16));

    final secondaryCount =
        RadialMenu.defaultPalette.length + 1 + RadialPenPreset.defaults.length;
    const geometry = RadialMenuGeometry(Size.square(600));
    final blue = segmentGlobalPoint(
      tester,
      index: 1,
      count: secondaryCount,
      radius: 192,
      startAngle: geometry.compactSubmenuStartAngle(RadialMenuAction.pen.index),
      span: geometry.compactSubmenuSpan,
    );
    await tester.tapAt(blue);
    await tester.pump();

    expect(controller.penSettings.color, const Color(0xFF2196F3));
    expect(backgroundTaps, 0);
  });

  testWidgets('dragging the center persists a free bounded position', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    final positions = <Offset>[];

    await tester.pumpWidget(
      host(
        controller: controller,
        callbacks: RadialMenuCallbacks(onPositionChanged: positions.add),
      ),
    );
    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final before = tester.getCenter(surface);

    final gesture = await tester.startGesture(before);
    await gesture.moveBy(const Offset(60, 10));
    await gesture.up();
    await tester.pumpAndSettle();

    final after = tester.getCenter(surface);
    expect(after.dx, closeTo(before.dx + 60, 1));
    expect(after.dy, closeTo(before.dy + 10, 1));
    expect(positions, isNotEmpty);
    expect(positions.last, closeToOffset(after));
  });

  testWidgets('closed center reaches every viewport edge without being lost', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller));
    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final viewportSize = tester.getSize(find.byType(RadialMenu));
    final geometry = RadialMenuGeometry(tester.getSize(surface));
    final margin = geometry.centerRadius + 12;

    await tester.dragFrom(
      tester.getCenter(surface),
      const Offset(-2000, -2000),
    );
    await tester.pumpAndSettle();
    final topLeft = tester.getCenter(surface);
    expect(topLeft.dx, closeTo(margin, 1));
    expect(topLeft.dy, closeTo(margin, 1));

    await tester.dragFrom(topLeft, const Offset(4000, 4000));
    await tester.pumpAndSettle();
    final bottomRight = tester.getCenter(surface);
    expect(bottomRight.dx, closeTo(viewportSize.width - margin, 1));
    expect(bottomRight.dy, closeTo(viewportSize.height - margin, 1));
  });

  testWidgets('transparent corners keep whiteboard input available', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    var backgroundTaps = 0;
    await tester.pumpWidget(
      host(controller: controller, onBackgroundTap: () => backgroundTaps++),
    );

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    await tester.tapAt(tester.getTopLeft(surface) + const Offset(15, 15));
    await tester.pump();

    expect(backgroundTaps, 1);
  });

  testWidgets('page actions navigate and expose the cyclic page wheel', (
    tester,
  ) async {
    final controller = RadialMenuController(isOpen: true);
    addTearDown(controller.dispose);
    final actions = <RadialMenuAction>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        pages: const <RadialPagePreview>[
          RadialPagePreview(pageIndex: 0, pageNumber: 1),
          RadialPagePreview(pageIndex: 1, pageNumber: 2),
          RadialPagePreview(pageIndex: 2, pageNumber: 3),
        ],
        callbacks: RadialMenuCallbacks(onPrimaryAction: actions.add),
      ),
    );
    await tester.pumpAndSettle();

    final next = segmentGlobalPoint(
      tester,
      index: RadialMenuAction.nextPage.index,
      count: 10,
      radius: 125,
      startAngle: -math.pi / 10,
    );
    await tester.tapAt(next);
    await tester.pumpAndSettle();

    expect(actions, <RadialMenuAction>[RadialMenuAction.nextPage]);
    expect(controller.activeBranch, RadialMenuBranch.pages);
    expect(controller.expandedPrimary, RadialMenuAction.nextPage);
  });

  testWidgets('page wheel rotates in both directions and loops at page zero', (
    tester,
  ) async {
    final controller = RadialMenuController(
      isOpen: true,
      activeBranch: RadialMenuBranch.pages,
    );
    addTearDown(controller.dispose);
    final selected = <int>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        pages: const <RadialPagePreview>[
          RadialPagePreview(pageIndex: 0, pageNumber: 1),
          RadialPagePreview(pageIndex: 1, pageNumber: 2),
          RadialPagePreview(pageIndex: 2, pageNumber: 3),
          RadialPagePreview(pageIndex: 3, pageNumber: 4),
        ],
        callbacks: RadialMenuCallbacks(onPageSelected: selected.add),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final topLeft = tester.getTopLeft(surface);
    final geometry = RadialMenuGeometry(tester.getSize(surface));
    Offset wheelPoint(double angle) =>
        topLeft + geometry.polarPoint(192 * geometry.scale, angle);

    final clockwise = await tester.startGesture(wheelPoint(0));
    await clockwise.moveTo(wheelPoint(.18));
    await clockwise.moveTo(wheelPoint(.38));
    await clockwise.up();
    await tester.pump();
    expect(selected, contains(1));

    selected.clear();
    final counterClockwise = await tester.startGesture(wheelPoint(0));
    await counterClockwise.moveTo(wheelPoint(-.18));
    await counterClockwise.moveTo(wheelPoint(-.38));
    await counterClockwise.up();
    await tester.pump();
    expect(selected, contains(3));
  });

  testWidgets('page click-wheel stays continuous across twelve o clock', (
    tester,
  ) async {
    final controller = RadialMenuController(
      isOpen: true,
      activeBranch: RadialMenuBranch.pages,
    );
    addTearDown(controller.dispose);
    final selected = <int>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        pages: const <RadialPagePreview>[
          RadialPagePreview(pageIndex: 0, pageNumber: 1),
          RadialPagePreview(pageIndex: 1, pageNumber: 2),
          RadialPagePreview(pageIndex: 2, pageNumber: 3),
          RadialPagePreview(pageIndex: 3, pageNumber: 4),
        ],
        callbacks: RadialMenuCallbacks(onPageSelected: selected.add),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final topLeft = tester.getTopLeft(surface);
    final geometry = RadialMenuGeometry(tester.getSize(surface));
    Offset wheelPoint(double angle) =>
        topLeft + geometry.polarPoint(192 * geometry.scale, angle);

    final gesture = await tester.startGesture(wheelPoint(6.1));
    for (final angle in <double>[6.25, .1, .3, .5, .7, .9, 1.2]) {
      await gesture.moveTo(wheelPoint(angle));
    }
    await gesture.up();
    await tester.pump();

    expect(selected, containsAllInOrder(<int>[1, 2, 3, 0]));
  });

  testWidgets('templates are selected directly from their second ring', (
    tester,
  ) async {
    final controller = RadialMenuController(isOpen: true);
    addTearDown(controller.dispose);
    const template = RadialTemplateEntry(
      id: 'mind-map',
      label: 'Mindmap',
      source: RadialTemplateSource.builtIn,
    );
    final selected = <RadialTemplateEntry>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        templates: const <RadialTemplateEntry>[template],
        callbacks: RadialMenuCallbacks(onTemplateSelected: selected.add),
      ),
    );
    await tester.pumpAndSettle();

    final templatesParent = segmentGlobalPoint(
      tester,
      index: RadialMenuAction.templates.index,
      count: 10,
      radius: 125,
      startAngle: -math.pi / 10,
    );
    await tester.tapAt(templatesParent);
    await tester.pumpAndSettle();
    expect(controller.activeBranch, RadialMenuBranch.templates);

    const geometry = RadialMenuGeometry(Size.square(600));
    final templateTarget = segmentGlobalPoint(
      tester,
      index: 0,
      count: 1,
      radius: 192,
      startAngle: geometry.compactSubmenuStartAngle(
        RadialMenuAction.templates.index,
      ),
      span: geometry.compactSubmenuSpan,
    );
    await tester.tapAt(templateTarget);
    await tester.pump();
    expect(selected, <RadialTemplateEntry>[template]);
  });

  testWidgets('five-finger rotation opens the wheel and advances cyclically', (
    tester,
  ) async {
    final controller = RadialMenuController(isOpen: true);
    addTearDown(controller.dispose);
    final selected = <int>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        currentPageIndex: 3,
        pages: const <RadialPagePreview>[
          RadialPagePreview(pageIndex: 0, pageNumber: 1),
          RadialPagePreview(pageIndex: 1, pageNumber: 2),
          RadialPagePreview(pageIndex: 2, pageNumber: 3),
          RadialPagePreview(pageIndex: 3, pageNumber: 4),
        ],
        callbacks: RadialMenuCallbacks(onPageSelected: selected.add),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final topLeft = tester.getTopLeft(surface);
    final geometry = RadialMenuGeometry(tester.getSize(surface));
    Offset point(double angle) =>
        topLeft + geometry.polarPoint(125 * geometry.scale, angle);
    final gestures = <TestGesture>[];
    for (var index = 0; index < 5; index++) {
      final gesture = await tester.createGesture(pointer: index + 1);
      gestures.add(gesture);
      await gesture.down(point(.08 + index * math.pi * 2 / 5));
    }
    expect(controller.activeBranch, RadialMenuBranch.pages);

    for (var index = 0; index < gestures.length; index++) {
      await gestures[index].moveTo(
        point(.48 + index * math.pi * 2 / gestures.length),
      );
    }
    for (final gesture in gestures) {
      await gesture.up();
    }
    await tester.pump();

    expect(selected, contains(0));
    expect(controller.activeBranch, RadialMenuBranch.pages);
  });

  testWidgets('five simultaneous styluses never trigger the page gesture', (
    tester,
  ) async {
    final controller = RadialMenuController(isOpen: true);
    addTearDown(controller.dispose);
    final selected = <int>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        currentPageIndex: 1,
        pages: const <RadialPagePreview>[
          RadialPagePreview(pageIndex: 0, pageNumber: 1),
          RadialPagePreview(pageIndex: 1, pageNumber: 2),
        ],
        callbacks: RadialMenuCallbacks(onPageSelected: selected.add),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final topLeft = tester.getTopLeft(surface);
    final geometry = RadialMenuGeometry(tester.getSize(surface));
    Offset point(double angle) =>
        topLeft + geometry.polarPoint(125 * geometry.scale, angle);
    final gestures = <TestGesture>[];
    for (var index = 0; index < 5; index++) {
      final gesture = await tester.createGesture(
        pointer: index + 31,
        kind: PointerDeviceKind.stylus,
      );
      gestures.add(gesture);
      await gesture.down(point(.08 + index * math.pi * 2 / 5));
    }
    for (var index = 0; index < gestures.length; index++) {
      await gestures[index].moveTo(
        point(.48 + index * math.pi * 2 / gestures.length),
      );
    }
    for (final gesture in gestures) {
      await gesture.up();
    }
    await tester.pump();

    expect(controller.activeBranch, isNull);
    expect(selected, isEmpty);
  });

  testWidgets('pen opens with normal black 8 px and collapses on second tap', (
    tester,
  ) async {
    final controller = RadialMenuController(
      isOpen: true,
      selectedPrimary: RadialMenuAction.selection,
      penSettings: const RadialPenSettings(
        color: Colors.red,
        thickness: 20,
        type: RadialPenType.marker,
      ),
    );
    addTearDown(controller.dispose);
    final penChanges = <RadialPenSettings>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        callbacks: RadialMenuCallbacks(onPenSettingsChanged: penChanges.add),
      ),
    );
    await tester.pumpAndSettle();
    final pen = segmentGlobalPoint(
      tester,
      index: RadialMenuAction.pen.index,
      count: 10,
      radius: 125,
      startAngle: -math.pi / 10,
    );

    await tester.tapAt(pen);
    await tester.pumpAndSettle();
    expect(controller.activeBranch, RadialMenuBranch.pen);
    expect(controller.penSettings, const RadialPenSettings());
    expect(penChanges, <RadialPenSettings>[const RadialPenSettings()]);

    await tester.tapAt(pen);
    await tester.pumpAndSettle();
    expect(controller.activeBranch, isNull);
    expect(controller.penSettings, const RadialPenSettings());
  });

  testWidgets('selection fan defaults to rectangle and has one active value', (
    tester,
  ) async {
    final controller = RadialMenuController(
      isOpen: true,
      selectionTool: RadialSelectionTool.lasso,
    );
    addTearDown(controller.dispose);
    final selectionChanges = <RadialSelectionTool>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        callbacks: RadialMenuCallbacks(
          onSelectionToolChanged: selectionChanges.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final selection = segmentGlobalPoint(
      tester,
      index: RadialMenuAction.selection.index,
      count: 10,
      radius: 125,
      startAngle: -math.pi / 10,
    );
    await tester.tapAt(selection);
    await tester.pumpAndSettle();
    expect(controller.selectionTool, RadialSelectionTool.rectangle);

    const geometry = RadialMenuGeometry(Size.square(600));
    final lasso = segmentGlobalPoint(
      tester,
      index: RadialSelectionTool.lasso.index,
      count: RadialSelectionTool.values.length,
      radius: 192,
      startAngle: geometry.compactSubmenuStartAngle(
        RadialMenuAction.selection.index,
      ),
      span: geometry.compactSubmenuSpan,
    );
    await tester.tapAt(lasso);
    await tester.pump();
    expect(controller.selectionTool, RadialSelectionTool.lasso);
    expect(selectionChanges.last, RadialSelectionTool.lasso);

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final painter =
        tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;
    final selectedLabels = painter
        .semanticsBuilder(tester.getSize(surface))
        .where((entry) => entry.properties.selected == true)
        .map((entry) => entry.properties.label)
        .toSet();
    expect(selectedLabels, <String>{'Auswahl', 'Auswahllasso'});
  });

  testWidgets('insert defaults to geometry and rectangle', (tester) async {
    final controller = RadialMenuController(
      isOpen: true,
      insertCategory: RadialInsertCategory.pdf,
      shapeKind: RadialShapeKind.triangle,
    );
    addTearDown(controller.dispose);
    final shapes = <RadialShapeKind>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        callbacks: RadialMenuCallbacks(onShapeRequested: shapes.add),
      ),
    );
    await tester.pumpAndSettle();
    final insert = segmentGlobalPoint(
      tester,
      index: RadialMenuAction.insert.index,
      count: 10,
      radius: 125,
      startAngle: -math.pi / 10,
    );
    await tester.tapAt(insert);
    await tester.pumpAndSettle();

    expect(controller.activeBranch, RadialMenuBranch.insert);
    expect(controller.insertCategory, RadialInsertCategory.geometry);
    expect(controller.shapeKind, RadialShapeKind.rectangle);
    expect(shapes, <RadialShapeKind>[RadialShapeKind.rectangle]);

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final painter =
        tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;
    final selectedLabels = painter
        .semanticsBuilder(tester.getSize(surface))
        .where((entry) => entry.properties.selected == true)
        .map((entry) => entry.properties.label)
        .toSet();
    expect(selectedLabels, <String>{'Einfügen', 'Geometrie', 'Rechteck'});
  });

  testWidgets('unavailable undo and redo are disabled and not tappable', (
    tester,
  ) async {
    final controller = RadialMenuController(isOpen: true);
    addTearDown(controller.dispose);
    final actions = <RadialMenuAction>[];

    await tester.pumpWidget(
      host(
        controller: controller,
        canUndo: false,
        canRedo: false,
        callbacks: RadialMenuCallbacks(onPrimaryAction: actions.add),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final size = tester.getSize(surface);
    final topLeft = tester.getTopLeft(surface);
    final geometry = RadialMenuGeometry(size);
    Offset primaryPoint(RadialMenuAction action) => geometry.pointForSegment(
      index: action.index,
      count: RadialMenuAction.values.length,
      radius: (geometry.primaryInnerRadius + geometry.primaryOuterRadius) / 2,
      startAngle: -math.pi / RadialMenuAction.values.length,
    );
    final painter =
        tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;

    expect(
      painter.hitTargetAt(primaryPoint(RadialMenuAction.undo), size),
      RadialHitTarget.none,
    );
    expect(
      painter.hitTargetAt(primaryPoint(RadialMenuAction.redo), size),
      RadialHitTarget.none,
    );
    for (final action in <RadialMenuAction>[
      RadialMenuAction.undo,
      RadialMenuAction.redo,
    ]) {
      await tester.tapAt(topLeft + primaryPoint(action));
      await tester.pump();
    }
    expect(actions, isEmpty);

    final semantics = painter.semanticsBuilder(size);
    for (final label in <String>['Rückgängig', 'Wiederholen']) {
      final properties = semantics
          .singleWhere((entry) => entry.properties.label == label)
          .properties;
      expect(properties.enabled, isFalse);
      expect(properties.onTap, isNull);
    }

    await tester.pumpWidget(
      host(
        controller: controller,
        canUndo: true,
        canRedo: true,
        callbacks: RadialMenuCallbacks(onPrimaryAction: actions.add),
      ),
    );
    await tester.pump();
    for (final action in <RadialMenuAction>[
      RadialMenuAction.undo,
      RadialMenuAction.redo,
    ]) {
      await tester.tapAt(topLeft + primaryPoint(action));
      await tester.pump();
    }
    expect(actions, <RadialMenuAction>[
      RadialMenuAction.undo,
      RadialMenuAction.redo,
    ]);
  });

  testWidgets('table, PDF and cover execute from Ring 2 without Ring 3', (
    tester,
  ) async {
    final controller = RadialMenuController(
      isOpen: true,
      activeBranch: RadialMenuBranch.insert,
      insertCategory: RadialInsertCategory.geometry,
      tableSize: const RadialTableSize(3, 4),
    );
    addTearDown(controller.dispose);
    final tables = <RadialTableSize>[];
    final pdfs = <RadialPdfImportMode>[];
    final covers = <RadialCoverDirection>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        callbacks: RadialMenuCallbacks(
          onTableRequested: tables.add,
          onPdfRequested: pdfs.add,
          onCoverRequested: covers.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final size = tester.getSize(surface);
    final geometry = RadialMenuGeometry(size);
    final topLeft = tester.getTopLeft(surface);
    Offset categoryPoint(RadialInsertCategory category) =>
        geometry.pointForSegment(
          index: category.index,
          count: RadialInsertCategory.values.length,
          radius:
              (geometry.secondaryInnerRadius + geometry.secondaryOuterRadius) /
              2,
          startAngle: geometry.compactSubmenuStartAngle(
            RadialMenuAction.insert.index,
          ),
          span: geometry.compactSubmenuSpan,
        );

    await tester.tapAt(topLeft + categoryPoint(RadialInsertCategory.table));
    await tester.pump();
    expect(controller.insertCategory, RadialInsertCategory.table);
    expect(tables, <RadialTableSize>[const RadialTableSize(3, 4)]);
    expect(
      (tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter)
          .tertiaryCount,
      0,
    );

    await tester.tapAt(topLeft + categoryPoint(RadialInsertCategory.pdf));
    await tester.pump();
    expect(pdfs, <RadialPdfImportMode>[RadialPdfImportMode.allPages]);
    expect(
      (tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter)
          .tertiaryCount,
      0,
    );

    await tester.tapAt(topLeft + categoryPoint(RadialInsertCategory.cover));
    await tester.pump();
    expect(covers, <RadialCoverDirection>[RadialCoverDirection.horizontal]);
    expect(
      (tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter)
          .tertiaryCount,
      0,
    );
  });
}

Matcher closeToOffset(Offset expected) => predicate<Offset>(
  (actual) =>
      (actual.dx - expected.dx).abs() < 1 &&
      (actual.dy - expected.dy).abs() < 1,
  'within one logical pixel of $expected',
);
