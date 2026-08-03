import 'dart:math' as math;
import 'dart:ui' as ui;

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
    bool confineToBounds = false,
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
                  confineToBounds: confineToBounds,
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

  Future<ui.Image> createThumbnail(Color color) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(color, BlendMode.src);
    canvas.drawCircle(const Offset(60, 36), 18, Paint()..color = Colors.white);
    final picture = recorder.endRecording();
    final image = await picture.toImage(120, 72);
    picture.dispose();
    return image;
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

  testWidgets('menu animation invalidates semantics only at visibility gates', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller: controller));
    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));

    await tester.tapAt(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 20));
    final early =
        tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;
    await tester.pump(const Duration(milliseconds: 20));
    final stillEarly =
        tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;

    expect(early.openProgress, lessThan(.72));
    expect(stillEarly.openProgress, lessThan(.72));
    expect(
      stillEarly.shouldRebuildSemantics(early),
      isFalse,
      reason: 'Pure opacity/scale frames expose the same semantic controls.',
    );

    await tester.pump(const Duration(milliseconds: 180));
    final visible =
        tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;
    expect(visible.openProgress, greaterThanOrEqualTo(.72));
    expect(visible.shouldRebuildSemantics(stillEarly), isTrue);
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
    'eraser uses automatic size and removes the ink thickness slider',
    (tester) async {
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
        index: RadialMenuAction.pen.index,
        count: RadialMenuAction.values.length,
        radius: 125,
        startAngle: -math.pi / RadialMenuAction.values.length,
      );
      await tester.tapAt(pen);
      await tester.pumpAndSettle();

      const geometry = RadialMenuGeometry(Size.square(600));
      final eraser = segmentGlobalPoint(
        tester,
        index: RadialPenType.eraser.index,
        count: RadialPenType.values.length,
        radius: 256,
        startAngle: geometry.penTypesStartAngle,
        span: geometry.penTypesSpan,
      );
      await tester.tapAt(eraser);
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final size = tester.getSize(surface);
      final painter =
          tester.widget<CustomPaint>(surface).painter! as RadialMenuPainter;
      expect(controller.penSettings.type, RadialPenType.eraser);
      expect(controller.penSettings.thickness, 8);
      expect(painter.hasThicknessSlider, isFalse);
      expect(
        painter
            .semanticsBuilder(size)
            .map((entry) => entry.properties.label)
            .whereType<String>(),
        contains('Radiergummi, automatische Größe'),
      );
      expect(changes.last.type, RadialPenType.eraser);
    },
  );

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
    for (var index = 0; index < 24; index++) {
      await gesture.moveBy(const Offset(2.5, 10 / 24));
    }
    expect(
      positions,
      isEmpty,
      reason: 'Intermediate drag packets must not start persistence timers.',
    );
    await gesture.up();
    await tester.pumpAndSettle();

    final after = tester.getCenter(surface);
    expect(after.dx, closeTo(before.dx + 60, 1));
    expect(after.dy, closeTo(before.dy + 10, 1));
    expect(positions, hasLength(1));
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

  testWidgets(
    'open split menu center reaches the edge while expanded rings are clipped',
    (tester) async {
      final controller = RadialMenuController(isOpen: true);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        host(controller: controller, confineToBounds: true),
      );
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      await tester.dragFrom(tester.getCenter(surface), const Offset(4000, 0));
      await tester.pumpAndSettle();

      final viewportSize = tester.getSize(find.byType(RadialMenu));
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      final compactMargin = geometry.centerRadius + 12;
      final rect = tester.getRect(surface);
      expect(
        tester.getCenter(surface).dx,
        closeTo(viewportSize.width - compactMargin, 1),
      );
      expect(
        rect.right,
        greaterThan(viewportSize.width),
        reason: 'open rings must not reduce the center drag range',
      );
      expect(
        tester
            .widget<Stack>(
              find.byKey(const ValueKey<String>('radial-menu-region')),
            )
            .clipBehavior,
        Clip.hardEdge,
      );

      // Moving an expanded menu must not consume the next center tap.
      await tester.tapAt(tester.getCenter(surface));
      await tester.pumpAndSettle();
      expect(controller.isOpen, isFalse);
    },
  );

  testWidgets(
    'closed split menu reaches the bottom outer corner and restores it after opening',
    (tester) async {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      const regionKey = ValueKey<String>('split-menu-region');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: regionKey,
                width: 390,
                height: 560,
                child: ClipRect(
                  child: RadialMenu(
                    controller: controller,
                    confineToBounds: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final region = tester.getRect(find.byKey(regionKey));
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      final compactMargin = geometry.centerRadius + 12;

      await tester.dragFrom(
        tester.getCenter(surface),
        const Offset(4000, 4000),
      );
      await tester.pumpAndSettle();

      final compactCenter = tester.getCenter(surface);
      expect(compactCenter.dx, closeTo(region.right - compactMargin, 1));
      expect(compactCenter.dy, closeTo(region.bottom - compactMargin, 1));
      final visibleCenterDisc = Rect.fromCircle(
        center: compactCenter,
        radius: geometry.centerRadius,
      );
      expect(visibleCenterDisc.right, lessThanOrEqualTo(region.right - 11.99));
      expect(
        visibleCenterDisc.bottom,
        lessThanOrEqualTo(region.bottom - 11.99),
      );
      // The unused transparent square may be clipped; it must not dictate the
      // compact menu's drag range.
      expect(tester.getRect(surface).right, greaterThan(region.right));
      expect(tester.getRect(surface).bottom, greaterThan(region.bottom));

      controller.setOpen(true);
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(surface),
        closeToOffset(compactCenter),
        reason: 'opening rings must never pull the center away from an edge',
      );
      expect(tester.getRect(surface).right, greaterThan(region.right));
      expect(tester.getRect(surface).bottom, greaterThan(region.bottom));

      controller.setOpen(false);
      await tester.pumpAndSettle();
      expect(tester.getCenter(surface), closeToOffset(compactCenter));
    },
  );

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

  testWidgets('long press on a page preview requests its confirmed deletion', (
    tester,
  ) async {
    final controller = RadialMenuController(
      isOpen: true,
      activeBranch: RadialMenuBranch.pages,
    );
    addTearDown(controller.dispose);
    const pages = <RadialPagePreview>[
      RadialPagePreview(pageId: 'page-1', pageIndex: 0, pageNumber: 1),
      RadialPagePreview(pageId: 'page-2', pageIndex: 1, pageNumber: 2),
      RadialPagePreview(pageId: 'page-3', pageIndex: 2, pageNumber: 3),
    ];
    final selected = <int>[];
    final deleteRequests = <RadialPagePreview>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        pages: pages,
        callbacks: RadialMenuCallbacks(
          onPageSelected: selected.add,
          onPageDeleteRequested: deleteRequests.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstPreview = segmentGlobalPoint(
      tester,
      index: 0,
      count: pages.length,
      radius: 192,
      startAngle: -math.pi / pages.length,
    );
    await tester.longPressAt(firstPreview);
    await tester.pump();

    expect(deleteRequests, hasLength(1));
    expect(deleteRequests.single.pageId, pages.first.pageId);
    expect(deleteRequests.single.pageIndex, pages.first.pageIndex);
    expect(
      selected,
      isEmpty,
      reason: 'a delete long press must not also navigate to the page',
    );
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

  testWidgets(
    'five-finger rotation advances cyclically without changing menu branch',
    (tester) async {
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
      expect(controller.isOpen, isTrue);
      expect(controller.activeBranch, isNull);

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
      expect(controller.isOpen, isTrue);
      expect(controller.activeBranch, isNull);
    },
  );

  testWidgets(
    'five-finger rotation works around a fully closed menu without opening it',
    (tester) async {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final selected = <int>[];
      final openChanges = <bool>[];
      final gestureChanges = <bool>[];
      final primaryActions = <RadialMenuAction>[];
      var backgroundTaps = 0;
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
          callbacks: RadialMenuCallbacks(
            onPageSelected: selected.add,
            onMenuOpenChanged: openChanges.add,
            onFiveFingerPageGestureChanged: gestureChanges.add,
            onPrimaryAction: primaryActions.add,
          ),
          onBackgroundTap: () => backgroundTaps++,
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
        final gesture = await tester.createGesture(pointer: index + 101);
        gestures.add(gesture);
        await gesture.down(point(.08 + index * math.pi * 2 / 5));
      }

      expect(controller.isOpen, isFalse);
      expect(controller.activeBranch, isNull);
      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(
          point(.48 + index * math.pi * 2 / gestures.length),
        );
      }
      for (final gesture in gestures) {
        await gesture.up();
      }
      await tester.pump();

      expect(selected, contains(0), reason: 'last page must loop to first');
      expect(controller.isOpen, isFalse);
      expect(controller.activeBranch, isNull);
      expect(openChanges, isEmpty);
      expect(gestureChanges, <bool>[true, false]);
      expect(primaryActions, isEmpty);
      expect(backgroundTaps, 0);
    },
  );

  testWidgets(
    'four-finger wheel previews a cyclic page and commits only on release',
    (tester) async {
      final firstThumbnail = await createThumbnail(Colors.red);
      final lastThumbnail = await createThumbnail(Colors.blue);
      addTearDown(firstThumbnail.dispose);
      addTearDown(lastThumbnail.dispose);
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final selected = <int>[];
      final gestureChanges = <bool>[];
      await tester.pumpWidget(
        host(
          controller: controller,
          currentPageIndex: 3,
          pages: <RadialPagePreview>[
            RadialPagePreview(
              pageIndex: 0,
              pageNumber: 1,
              thumbnail: firstThumbnail,
            ),
            const RadialPagePreview(pageIndex: 1, pageNumber: 2),
            const RadialPagePreview(pageIndex: 2, pageNumber: 3),
            RadialPagePreview(
              pageIndex: 3,
              pageNumber: 4,
              thumbnail: lastThumbnail,
            ),
          ],
          callbacks: RadialMenuCallbacks(
            onPageSelected: selected.add,
            onFiveFingerPageGestureChanged: gestureChanges.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final topLeft = tester.getTopLeft(surface);
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      Offset point(int index, double rotation) =>
          topLeft +
          geometry.polarPoint(
            125 * geometry.scale,
            .08 + index * math.pi * 2 / 4 + rotation,
          );
      final gestures = <TestGesture>[];
      for (var index = 0; index < 4; index++) {
        final gesture = await tester.createGesture(pointer: 401 + index);
        gestures.add(gesture);
        await gesture.down(point(index, 0));
      }
      await tester.pump();

      expect(controller.isOpen, isFalse);
      expect(gestureChanges, <bool>[true]);
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-3')),
        findsOneWidget,
      );
      expect(selected, isEmpty);

      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(point(index, .24));
      }
      await tester.pumpAndSettle();

      expect(selected, isEmpty, reason: 'page selection is still provisional');
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-0')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<RawImage>(
              find.byKey(const ValueKey<String>('five-finger-page-thumbnail')),
            )
            .image,
        same(firstThumbnail),
      );

      await gestures.first.up();
      await tester.pumpAndSettle();
      expect(selected, <int>[0], reason: 'last page must loop to first');
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-0')),
        findsNothing,
      );
      for (final gesture in gestures.skip(1)) {
        await gesture.up();
      }
      await tester.pump();
      expect(gestureChanges, <bool>[true, false]);
    },
  );

  testWidgets(
    'a released five-contact session cannot reclaim with its remaining fingers',
    (tester) async {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final selected = <int>[];
      final gestureChanges = <bool>[];
      await tester.pumpWidget(
        host(
          controller: controller,
          pages: const <RadialPagePreview>[
            RadialPagePreview(pageIndex: 0, pageNumber: 1),
            RadialPagePreview(pageIndex: 1, pageNumber: 2),
            RadialPagePreview(pageIndex: 2, pageNumber: 3),
          ],
          callbacks: RadialMenuCallbacks(
            onPageSelected: selected.add,
            onFiveFingerPageGestureChanged: gestureChanges.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final topLeft = tester.getTopLeft(surface);
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      const initialAngles = <double>[0, .15, .30, .45, 1.75];
      Offset point(int index, double rotation) =>
          topLeft +
          geometry.polarPoint(
            125 * geometry.scale,
            initialAngles[index] + rotation,
          );
      final gestures = <TestGesture>[];
      for (var index = 0; index < initialAngles.length; index++) {
        final gesture = await tester.createGesture(pointer: 451 + index);
        gestures.add(gesture);
        await gesture.down(point(index, 0));
        if (index == 3) {
          expect(
            gestureChanges,
            isEmpty,
            reason: 'the deliberately clustered first four cannot claim',
          );
        }
      }
      expect(gestureChanges, <bool>[true]);

      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(point(index, .24));
      }
      await tester.pump();
      expect(selected, isEmpty);

      await gestures.first.up();
      await tester.pump();
      expect(selected, <int>[1]);
      expect(gestureChanges, <bool>[true]);

      // Pointer-up completes the claimed physical session. The remaining
      // four contacts are still suppressed until lift and must not be able to
      // claim a second page gesture merely because one of them moves.
      await gestures[1].moveTo(point(1, .28));
      await tester.pump();
      expect(gestureChanges, <bool>[true]);
      expect(selected, <int>[1]);

      for (final gesture in gestures.skip(1)) {
        await gesture.up();
      }
      await tester.pump();
      expect(gestureChanges, <bool>[true, false]);
      expect(selected, <int>[1]);
    },
  );

  testWidgets(
    'confined participant menus claim touches only inside their own region',
    (tester) async {
      final leftController = RadialMenuController();
      final rightController = RadialMenuController();
      addTearDown(leftController.dispose);
      addTearDown(rightController.dispose);
      final leftSelected = <int>[];
      final rightSelected = <int>[];
      final leftGestureChanges = <bool>[];
      final rightGestureChanges = <bool>[];
      const pages = <RadialPagePreview>[
        RadialPagePreview(pageIndex: 0, pageNumber: 1),
        RadialPagePreview(pageIndex: 1, pageNumber: 2),
        RadialPagePreview(pageIndex: 2, pageNumber: 3),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 400,
                    height: 600,
                    child: RadialMenu(
                      controller: leftController,
                      initialPosition: const Offset(400, 300),
                      edgePadding: 0,
                      confineToBounds: true,
                      pagePreviews: pages,
                      callbacks: RadialMenuCallbacks(
                        onPageSelected: leftSelected.add,
                        onFiveFingerPageGestureChanged: leftGestureChanges.add,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 400,
                    height: 600,
                    child: RadialMenu(
                      controller: rightController,
                      initialPosition: const Offset(0, 300),
                      edgePadding: 0,
                      confineToBounds: true,
                      pagePreviews: pages,
                      callbacks: RadialMenuCallbacks(
                        onPageSelected: rightSelected.add,
                        onFiveFingerPageGestureChanged: rightGestureChanges.add,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surfaces = find.byKey(
        const ValueKey<String>('radial-menu-surface'),
      );
      expect(surfaces, findsNWidgets(2));
      final leftSurface = surfaces.at(0);
      final topLeft = tester.getTopLeft(leftSurface);
      final geometry = RadialMenuGeometry(tester.getSize(leftSurface));
      const initialAngles = <double>[
        math.pi,
        math.pi * 4 / 3,
        math.pi * 5 / 3,
        math.pi * 2,
      ];
      Offset point(int index, double rotation) =>
          topLeft +
          geometry.polarPoint(
            120 * geometry.scale,
            initialAngles[index] + rotation,
          );
      final gestures = <TestGesture>[];
      for (var index = 0; index < initialAngles.length; index++) {
        final gesture = await tester.createGesture(pointer: 471 + index);
        gestures.add(gesture);
        await gesture.down(point(index, 0));
      }

      expect(leftGestureChanges, <bool>[true]);
      expect(
        rightGestureChanges,
        isEmpty,
        reason: 'the right global route must reject left-half contacts',
      );
      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(point(index, .24));
      }
      expect(leftSelected, isEmpty);
      expect(rightSelected, isEmpty);

      await gestures.first.up();
      await tester.pump();
      expect(leftSelected, <int>[1]);
      expect(rightSelected, isEmpty);
      for (final gesture in gestures.skip(1)) {
        await gesture.up();
      }
      await tester.pump();
      expect(leftGestureChanges, <bool>[true, false]);
      expect(rightGestureChanges, isEmpty);
    },
  );

  testWidgets(
    'an unclaimed participant pointer cannot cross the divider to form a gesture',
    (tester) async {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final gestureChanges = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 400,
                    height: 600,
                    child: RadialMenu(
                      controller: controller,
                      initialPosition: const Offset(400, 300),
                      edgePadding: 0,
                      confineToBounds: true,
                      pagePreviews: const <RadialPagePreview>[
                        RadialPagePreview(pageIndex: 0, pageNumber: 1),
                        RadialPagePreview(pageIndex: 1, pageNumber: 2),
                      ],
                      callbacks: RadialMenuCallbacks(
                        onFiveFingerPageGestureChanged: gestureChanges.add,
                      ),
                    ),
                  ),
                  const SizedBox(width: 400, height: 600),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final topLeft = tester.getTopLeft(surface);
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      Offset point(double angle) =>
          topLeft + geometry.polarPoint(120 * geometry.scale, angle);
      final gestures = <TestGesture>[];
      for (var index = 0; index < 4; index++) {
        final gesture = await tester.createGesture(pointer: 491 + index);
        gestures.add(gesture);
        await gesture.down(point(math.pi + index * .05));
      }
      expect(gestureChanges, isEmpty);

      // This point remains in the radial annulus, but lies across x=400 in
      // the other participant's half. It must be dropped before the relaxed
      // four-contact coverage check can claim the session.
      await gestures.last.moveTo(point(math.pi / 2));
      await tester.pump();
      expect(gestureChanges, isEmpty);

      for (final gesture in gestures) {
        await gesture.up();
      }
    },
  );

  testWidgets(
    'five-finger wheel previews the snapped real page and commits on release',
    (tester) async {
      final firstThumbnail = await createThumbnail(Colors.red);
      final secondThumbnail = await createThumbnail(Colors.green);
      final thirdThumbnail = await createThumbnail(Colors.blue);
      addTearDown(firstThumbnail.dispose);
      addTearDown(secondThumbnail.dispose);
      addTearDown(thirdThumbnail.dispose);
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final selected = <int>[];
      await tester.pumpWidget(
        host(
          controller: controller,
          pages: <RadialPagePreview>[
            RadialPagePreview(
              pageIndex: 0,
              pageNumber: 1,
              thumbnail: firstThumbnail,
            ),
            RadialPagePreview(
              pageIndex: 1,
              pageNumber: 2,
              thumbnail: secondThumbnail,
            ),
            RadialPagePreview(
              pageIndex: 2,
              pageNumber: 3,
              thumbnail: thirdThumbnail,
            ),
          ],
          callbacks: RadialMenuCallbacks(onPageSelected: selected.add),
        ),
      );
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final topLeft = tester.getTopLeft(surface);
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      Offset point(int index, double rotation) =>
          topLeft +
          geometry.polarPoint(
            125 * geometry.scale,
            .08 + index * math.pi * 2 / 5 + rotation,
          );
      final gestures = <TestGesture>[];
      for (var index = 0; index < 5; index++) {
        final gesture = await tester.createGesture(pointer: 301 + index);
        gestures.add(gesture);
        await gesture.down(point(index, 0));
      }
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-0')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<RawImage>(
              find.byKey(const ValueKey<String>('five-finger-page-thumbnail')),
            )
            .image,
        same(firstThumbnail),
      );
      expect(find.text('Seite 1'), findsOneWidget);

      // Four coherent fingertips crossing the Schmitt threshold snap exactly
      // one page. The document itself stays unchanged until release.
      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(point(index, .24));
      }
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-1')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<RawImage>(
              find.byKey(const ValueKey<String>('five-finger-page-thumbnail')),
            )
            .image,
        same(secondThumbnail),
      );
      expect(find.text('Seite 2'), findsOneWidget);

      // Small reverse jitter remains inside the detent's hysteresis band and
      // therefore cannot make the preview chatter between two pages.
      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(point(index, .16));
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-1')),
        findsOneWidget,
      );

      // Crossing the opposite threshold deliberately snaps back.
      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(point(index, .04));
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-0')),
        findsOneWidget,
      );

      // Select page two again and release to commit once.
      for (var index = 0; index < gestures.length; index++) {
        await gestures[index].moveTo(point(index, .24));
      }
      await tester.pumpAndSettle();
      await gestures.first.up();
      await tester.pumpAndSettle();
      expect(selected, <int>[1]);
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-1')),
        findsNothing,
      );
      for (final gesture in gestures.skip(1)) {
        await gesture.up();
      }
    },
  );

  testWidgets('closed five-finger rotation loops first page to last', (
    tester,
  ) async {
    final controller = RadialMenuController();
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
    Offset point(double angle) =>
        topLeft + geometry.polarPoint(125 * geometry.scale, angle);
    final gestures = <TestGesture>[];
    for (var index = 0; index < 5; index++) {
      final gesture = await tester.createGesture(pointer: index + 121);
      gestures.add(gesture);
      await gesture.down(point(.6 + index * math.pi * 2 / 5));
    }
    for (var index = 0; index < gestures.length; index++) {
      await gestures[index].moveTo(
        point(.2 + index * math.pi * 2 / gestures.length),
      );
    }
    for (final gesture in gestures) {
      await gesture.up();
    }
    await tester.pump();

    expect(selected, contains(3), reason: 'first page must loop to last');
    expect(controller.isOpen, isFalse);
    expect(controller.activeBranch, isNull);
  });

  testWidgets('disposing an active five-finger session releases suppression', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    final gestureChanges = <bool>[];
    await tester.pumpWidget(
      host(
        controller: controller,
        pages: const <RadialPagePreview>[
          RadialPagePreview(pageIndex: 0, pageNumber: 1),
          RadialPagePreview(pageIndex: 1, pageNumber: 2),
        ],
        callbacks: RadialMenuCallbacks(
          onFiveFingerPageGestureChanged: gestureChanges.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
    final topLeft = tester.getTopLeft(surface);
    final geometry = RadialMenuGeometry(tester.getSize(surface));
    final gestures = <TestGesture>[];
    for (var index = 0; index < 5; index++) {
      final gesture = await tester.createGesture(pointer: index + 141);
      gestures.add(gesture);
      await gesture.down(
        topLeft +
            geometry.polarPoint(125 * geometry.scale, index * math.pi * 2 / 5),
      );
    }
    expect(gestureChanges, <bool>[true]);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(gestureChanges, <bool>[true, false]);
    for (final gesture in gestures) {
      await gesture.up();
    }
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

  testWidgets('mouse and stylus cannot complete a five-touch page gesture', (
    tester,
  ) async {
    final controller = RadialMenuController();
    addTearDown(controller.dispose);
    final selected = <int>[];
    await tester.pumpWidget(
      host(
        controller: controller,
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
    for (var index = 0; index < 3; index++) {
      final gesture = await tester.createGesture(pointer: index + 151);
      gestures.add(gesture);
      await gesture.down(point(index * math.pi * 2 / 5));
    }
    final stylus = await tester.createGesture(
      pointer: 161,
      kind: PointerDeviceKind.stylus,
    );
    final mouse = await tester.createGesture(
      pointer: 162,
      kind: PointerDeviceKind.mouse,
    );
    gestures.addAll(<TestGesture>[stylus, mouse]);
    await stylus.down(point(math.pi * 6 / 5));
    await mouse.down(point(math.pi * 8 / 5));
    for (var index = 0; index < gestures.length; index++) {
      await gestures[index].moveTo(
        point(.5 + index * math.pi * 2 / gestures.length),
      );
    }
    for (final gesture in gestures) {
      await gesture.up();
    }
    await tester.pump();

    expect(selected, isEmpty);
    expect(controller.isOpen, isFalse);
    expect(controller.activeBranch, isNull);
  });

  testWidgets(
    'one moving finger cannot switch pages but four coherent fingers can',
    (tester) async {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final selected = <int>[];
      await tester.pumpWidget(
        host(
          controller: controller,
          pages: const <RadialPagePreview>[
            RadialPagePreview(pageIndex: 0, pageNumber: 1),
            RadialPagePreview(pageIndex: 1, pageNumber: 2),
            RadialPagePreview(pageIndex: 2, pageNumber: 3),
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
        final gesture = await tester.createGesture(pointer: 181 + index);
        gestures.add(gesture);
        await gesture.down(point(.08 + index * math.pi * 2 / 5));
      }

      await gestures.first.moveTo(point(1.48));
      await tester.pump();
      expect(selected, isEmpty, reason: 'one moving finger is not a rotation');

      for (var index = 1; index < 4; index++) {
        await gestures[index].moveTo(
          point(.48 + index * math.pi * 2 / gestures.length),
        );
      }
      await tester.pump();
      expect(selected, isEmpty, reason: 'selection commits only on release');
      expect(
        find.byKey(const ValueKey<String>('five-finger-page-preview-1')),
        findsOneWidget,
      );

      for (final gesture in gestures) {
        await gesture.up();
      }
      await tester.pump();
      expect(selected, <int>[1]);
    },
  );

  testWidgets(
    'a valid claimed rotation tolerates later broad contact estimates',
    (tester) async {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final selected = <int>[];
      final gestureChanges = <bool>[];
      await tester.pumpWidget(
        host(
          controller: controller,
          pages: const <RadialPagePreview>[
            RadialPagePreview(pageIndex: 0, pageNumber: 1),
            RadialPagePreview(pageIndex: 1, pageNumber: 2),
          ],
          callbacks: RadialMenuCallbacks(
            onPageSelected: selected.add,
            onFiveFingerPageGestureChanged: gestureChanges.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final topLeft = tester.getTopLeft(surface);
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      Offset point(double angle) =>
          topLeft + geometry.polarPoint(125 * geometry.scale, angle);

      for (var index = 0; index < 5; index++) {
        await tester.sendEventToBinding(
          PointerDownEvent(
            pointer: 231 + index,
            device: 231 + index,
            kind: PointerDeviceKind.touch,
            position: point(.08 + index * math.pi * 2 / 5),
            radiusMajor: 7,
            radiusMinor: 5,
            size: .12,
          ),
        );
      }
      expect(gestureChanges, <bool>[true]);
      for (var index = 0; index < 4; index++) {
        await tester.sendEventToBinding(
          PointerMoveEvent(
            pointer: 231 + index,
            device: 231 + index,
            kind: PointerDeviceKind.touch,
            position: point(.48 + index * math.pi * 2 / 5),
            radiusMajor: 30,
            radiusMinor: 16,
            size: .34,
          ),
        );
      }
      expect(selected, isEmpty);
      for (var index = 0; index < 5; index++) {
        await tester.sendEventToBinding(
          PointerUpEvent(
            pointer: 231 + index,
            device: 231 + index,
            kind: PointerDeviceKind.touch,
            position: point(.48 + index * math.pi * 2 / 5),
          ),
        );
      }
      expect(selected, <int>[1]);
      expect(gestureChanges, <bool>[true, false]);
    },
  );

  testWidgets(
    'clustered or broad contacts never claim the five-finger page gesture',
    (tester) async {
      final controller = RadialMenuController();
      addTearDown(controller.dispose);
      final selected = <int>[];
      final gestureChanges = <bool>[];
      await tester.pumpWidget(
        host(
          controller: controller,
          pages: const <RadialPagePreview>[
            RadialPagePreview(pageIndex: 0, pageNumber: 1),
            RadialPagePreview(pageIndex: 1, pageNumber: 2),
          ],
          callbacks: RadialMenuCallbacks(
            onPageSelected: selected.add,
            onFiveFingerPageGestureChanged: gestureChanges.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surface = find.byKey(const ValueKey<String>('radial-menu-surface'));
      final topLeft = tester.getTopLeft(surface);
      final geometry = RadialMenuGeometry(tester.getSize(surface));
      Offset point(double angle) =>
          topLeft + geometry.polarPoint(125 * geometry.scale, angle);

      // Evenly spaced contacts inside the centre are a hand/palm footprint,
      // not fingers placed around the wheel.
      for (var index = 0; index < 5; index++) {
        final position =
            topLeft +
            geometry.polarPoint(
              geometry.centerRadius * .65,
              index * math.pi * 2 / 5,
            );
        await tester.sendEventToBinding(
          PointerDownEvent(
            pointer: 191 + index,
            device: 191 + index,
            kind: PointerDeviceKind.touch,
            position: position,
            radiusMajor: 4,
            radiusMinor: 3,
            size: .1,
          ),
        );
      }
      expect(gestureChanges, isEmpty);
      for (var index = 0; index < 5; index++) {
        await tester.sendEventToBinding(
          PointerCancelEvent(
            pointer: 191 + index,
            device: 191 + index,
            kind: PointerDeviceKind.touch,
          ),
        );
      }

      final clustered = <TestGesture>[];
      for (var index = 0; index < 5; index++) {
        final gesture = await tester.createGesture(pointer: 201 + index);
        clustered.add(gesture);
        await gesture.down(point(.04 * index));
      }
      for (var index = 0; index < clustered.length; index++) {
        await clustered[index].moveTo(point(.45 + .04 * index));
      }
      for (final gesture in clustered) {
        await gesture.up();
      }

      for (var index = 0; index < 5; index++) {
        await tester.sendEventToBinding(
          PointerDownEvent(
            pointer: 221 + index,
            device: 221 + index,
            kind: PointerDeviceKind.touch,
            position: point(index * math.pi * 2 / 5),
            radiusMajor: 30,
            radiusMinor: 18,
            size: .34,
          ),
        );
      }
      for (var index = 0; index < 5; index++) {
        await tester.sendEventToBinding(
          PointerMoveEvent(
            pointer: 221 + index,
            device: 221 + index,
            kind: PointerDeviceKind.touch,
            position: point(.5 + index * math.pi * 2 / 5),
            radiusMajor: 30,
            radiusMinor: 18,
            size: .34,
          ),
        );
        await tester.sendEventToBinding(
          PointerUpEvent(
            pointer: 221 + index,
            device: 221 + index,
            kind: PointerDeviceKind.touch,
            position: point(.5 + index * math.pi * 2 / 5),
          ),
        );
      }
      await tester.pump();

      expect(selected, isEmpty);
      expect(gestureChanges, isEmpty);
      expect(controller.isOpen, isFalse);
      expect(controller.activeBranch, isNull);
    },
  );

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
