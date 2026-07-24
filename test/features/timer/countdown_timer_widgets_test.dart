import 'package:flowboard_x/src/app/app_theme.dart';
import 'package:flowboard_x/src/features/timer/countdown_timer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('toolbar setup applies a preset and starts the timer', (
    tester,
  ) async {
    final controller = CountdownTimerController();
    addTearDown(controller.dispose);
    var showLargeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: CountdownTimerToolbarButton(
              controller: controller,
              onShowLarge: () => showLargeCount++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('countdown-toolbar-button')));
    await tester.pumpAndSettle();
    expect(find.text('Timer'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '1 min'));
    await tester.pump();
    expect(find.text('01:00'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('countdown-setup-start-pause')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('countdown-setup-start-pause')));
    await tester.pump();

    expect(controller.configuredDuration, const Duration(minutes: 1));
    expect(controller.isRunning, isTrue);
    expect(showLargeCount, 0);
    controller.dispose();
  });

  testWidgets('large action applies edits and requests the non-modal overlay', (
    tester,
  ) async {
    final controller = CountdownTimerController();
    addTearDown(controller.dispose);
    var showLargeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Scaffold(
          body: CountdownTimerSetupDialog(
            controller: controller,
            onShowLarge: () => showLargeCount++,
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '10 min'));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('countdown-setup-show-large')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('countdown-setup-show-large')));
    await tester.pump();

    expect(showLargeCount, 1);
    expect(controller.configuredDuration, const Duration(minutes: 10));
    expect(controller.isRunning, isFalse);
  });

  testWidgets('setup remains usable with a small viewport and large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 520);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final controller = CountdownTimerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.5)),
          child: child!,
        ),
        home: Scaffold(
          body: CountdownTimerSetupDialog(
            controller: controller,
            onShowLarge: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('countdown-setup-start-pause')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('countdown-setup-start-pause')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlay leaves the board interactive outside its rectangle', (
    tester,
  ) async {
    final controller = CountdownTimerController();
    addTearDown(controller.dispose);
    var boardTapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('board-under-timer'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => boardTapCount++,
                  ),
                ),
                CountdownTimerOverlay(
                  controller: controller,
                  bounds: const Rect.fromLTWH(0, 0, 800, 600),
                  initialRect: const Rect.fromLTWH(100, 100, 400, 220),
                  onClose: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    expect(boardTapCount, 1);

    await tester.tapAt(const Offset(250, 220));
    await tester.pump();
    expect(boardTapCount, 1);
  });

  testWidgets('overlay can be moved, resized and remains inside its bounds', (
    tester,
  ) async {
    final controller = CountdownTimerController();
    addTearDown(controller.dispose);
    final reportedRects = <Rect>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: Stack(
              children: [
                CountdownTimerOverlay(
                  controller: controller,
                  bounds: const Rect.fromLTWH(0, 0, 800, 600),
                  initialRect: const Rect.fromLTWH(100, 100, 400, 220),
                  onClose: () {},
                  onRectChanged: reportedRects.add,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final overlay = find.byKey(const ValueKey('countdown-large-overlay'));
    expect(tester.getTopLeft(overlay), const Offset(100, 100));
    expect(tester.getSize(overlay), const Size(400, 220));

    await tester.drag(
      find.byKey(const ValueKey('countdown-overlay-resize-handle')),
      const Offset(100, 80),
    );
    await tester.pump();
    expect(tester.getSize(overlay), const Size(500, 300));

    await tester.drag(
      find.byKey(const ValueKey('countdown-overlay-drag-handle')),
      const Offset(900, 900),
    );
    await tester.pump();
    expect(tester.getTopLeft(overlay), const Offset(300, 300));
    expect(reportedRects, isNotEmpty);
    expect(reportedRects.last, const Rect.fromLTWH(300, 300, 500, 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlay controls start, pause and reset the same controller', (
    tester,
  ) async {
    final controller = CountdownTimerController(
      initialDuration: const Duration(minutes: 2),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              CountdownTimerOverlay(
                controller: controller,
                bounds: const Rect.fromLTWH(0, 0, 800, 600),
                onClose: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('02:00'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('countdown-overlay-start-pause')),
    );
    await tester.pump();
    expect(controller.isRunning, isTrue);

    await tester.tap(
      find.byKey(const ValueKey('countdown-overlay-start-pause')),
    );
    await tester.pump();
    expect(controller.isPaused, isTrue);

    await tester.tap(find.byKey(const ValueKey('countdown-overlay-reset')));
    await tester.pump();
    expect(controller.status, CountdownTimerStatus.idle);
    expect(controller.remaining, const Duration(minutes: 2));
  });
}
