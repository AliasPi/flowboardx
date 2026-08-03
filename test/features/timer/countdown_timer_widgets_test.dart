import 'dart:async';

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
    expect(
      showLargeCount,
      1,
      reason: 'A one-minute countdown requests the large display immediately.',
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey('countdown-toolbar-button')),
      findsOneWidget,
      reason: 'Automatic presentation must pop only the setup dialog.',
    );
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

  testWidgets(
    'setup yields to the mandatory large display in the final minute',
    (tester) async {
      final time = _WidgetTimerClock();
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 61),
        now: time.now,
        scheduler: time.schedule,
      );
      addTearDown(controller.dispose);
      var showLargeCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFlowboardTheme(),
          home: Scaffold(
            body: CountdownTimerToolbarButton(
              controller: controller,
              onShowLarge: () => showLargeCount++,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('countdown-toolbar-button')));
      await tester.pumpAndSettle();
      expect(find.byType(CountdownTimerSetupDialog), findsOneWidget);

      controller.start();
      time.elapse(const Duration(seconds: 1));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(CountdownTimerSetupDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('countdown-toolbar-button')),
        findsOneWidget,
      );
      expect(showLargeCount, 1);
      expect(controller.isRunning, isTrue);
    },
  );

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

  testWidgets(
    'auto presentation requests final minute once and alarm again at zero',
    (tester) async {
      final time = _WidgetTimerClock();
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 61),
        now: time.now,
        scheduler: time.schedule,
      );
      addTearDown(controller.dispose);
      var showLargeCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CountdownTimerAutoPresentation(
            controller: controller,
            onShowLarge: () => showLargeCount++,
          ),
        ),
      );

      controller.start();
      await tester.pump();
      expect(showLargeCount, 0);

      time.elapse(const Duration(seconds: 1));
      await tester.pump();
      expect(showLargeCount, 1, reason: 'Exactly 01:00 opens the panel.');

      time.elapse(const Duration(seconds: 30));
      await tester.pump();
      expect(showLargeCount, 1, reason: 'Normal ticks do not reopen it.');

      time.elapse(const Duration(seconds: 30));
      await tester.pump();
      expect(
        showLargeCount,
        2,
        reason: '00:00 reopens the panel for acknowledgement.',
      );
      expect(controller.isAlarmActive, isTrue);
    },
  );

  testWidgets(
    'short timer opens immediately and pause-resume does not reopen it',
    (tester) async {
      final time = _WidgetTimerClock();
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 45),
        now: time.now,
        scheduler: time.schedule,
      );
      addTearDown(controller.dispose);
      var showLargeCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CountdownTimerAutoPresentation(
            controller: controller,
            onShowLarge: () => showLargeCount++,
          ),
        ),
      );

      controller.start();
      await tester.pump();
      expect(showLargeCount, 1);

      controller.pause();
      controller.start();
      await tester.pump();
      expect(
        showLargeCount,
        1,
        reason: 'The final-minute prompt is emitted once per countdown run.',
      );
    },
  );

  testWidgets('refresh after crossing a milestone requests the large panel', (
    tester,
  ) async {
    final time = _WidgetTimerClock();
    final controller = CountdownTimerController(
      initialDuration: const Duration(seconds: 65),
      now: time.now,
      scheduler: time.schedule,
    );
    addTearDown(controller.dispose);
    var showLargeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CountdownTimerAutoPresentation(
          controller: controller,
          onShowLarge: () => showLargeCount++,
        ),
      ),
    );

    controller.start();
    time.jumpWithoutCallbacks(const Duration(seconds: 6));
    controller.refresh();
    await tester.pump();
    expect(showLargeCount, 1);

    time.jumpWithoutCallbacks(const Duration(minutes: 2));
    controller.refresh();
    await tester.pump();
    expect(showLargeCount, 2);
    expect(controller.isAlarmActive, isTrue);
  });

  testWidgets('active alarm locks closing and reset until acknowledgement', (
    tester,
  ) async {
    final time = _WidgetTimerClock();
    final controller = CountdownTimerController(
      initialDuration: const Duration(seconds: 1),
      now: time.now,
      scheduler: time.schedule,
    );
    addTearDown(controller.dispose);
    var closeCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              CountdownTimerOverlay(
                controller: controller,
                bounds: const Rect.fromLTWH(0, 0, 800, 600),
                onClose: () => closeCount++,
              ),
            ],
          ),
        ),
      ),
    );

    controller.start();
    time.elapse(const Duration(seconds: 1));
    await tester.pump();

    final close = tester.widget<IconButton>(
      find.byKey(const ValueKey('countdown-overlay-close')),
    );
    expect(close.onPressed, isNull);
    expect(find.byKey(const ValueKey('countdown-overlay-reset')), findsNothing);
    expect(closeCount, 0);

    await tester.tap(
      find.byKey(const ValueKey('countdown-overlay-acknowledge-alarm')),
    );
    await tester.pump();
    expect(controller.isAlarmActive, isFalse);
    expect(
      find.byKey(const ValueKey('countdown-overlay-reset')),
      findsOneWidget,
    );
    final enabledClose = tester.widget<IconButton>(
      find.byKey(const ValueKey('countdown-overlay-close')),
    );
    expect(enabledClose.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('countdown-overlay-close')));
    expect(closeCount, 1);
  });

  testWidgets('root presenter keeps alarm acknowledgement above a modal', (
    tester,
  ) async {
    final time = _WidgetTimerClock();
    final controller = CountdownTimerController(
      initialDuration: const Duration(seconds: 1),
      now: time.now,
      scheduler: time.schedule,
    );
    final presenter = CountdownTimerOverlayPresenter();
    addTearDown(() {
      presenter.dispose();
      controller.dispose();
    });
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFlowboardTheme(),
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );

    unawaited(
      showDialog<void>(
        context: hostContext,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Text('Fremddialog', key: ValueKey('timer-foreign-dialog')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('timer-foreign-dialog')), findsOneWidget);

    controller.start();
    time.elapse(const Duration(seconds: 1));
    expect(controller.isAlarmActive, isTrue);
    expect(presenter.show(hostContext, controller: controller), isTrue);
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('countdown-overlay-acknowledge-alarm')),
    );
    await tester.pump();
    expect(
      controller.isAlarmActive,
      isFalse,
      reason: 'The older modal barrier must not cover the root timer entry.',
    );

    presenter.hide(controller: controller);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('timer-foreign-dialog'))),
    ).pop();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
    'toolbar opens the synchronized overlay while only it acknowledges alarm',
    (tester) async {
      final time = _WidgetTimerClock();
      var alarmCount = 0;
      final controller = CountdownTimerController(
        initialDuration: const Duration(seconds: 3),
        now: time.now,
        scheduler: time.schedule,
        onAlarm: () => alarmCount++,
      );
      addTearDown(controller.dispose);
      var showLargeCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFlowboardTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: Stack(
                children: [
                  Positioned(
                    left: 8,
                    top: 8,
                    child: CountdownTimerToolbarButton(
                      controller: controller,
                      onShowLarge: () => showLargeCount++,
                      showLabel: true,
                    ),
                  ),
                  CountdownTimerOverlay(
                    controller: controller,
                    bounds: const Rect.fromLTWH(0, 70, 900, 630),
                    initialRect: const Rect.fromLTWH(220, 120, 430, 220),
                    onClose: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      controller.start();
      await tester.pump();
      expect(_largeCountdownText(tester), '00:03');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('countdown-toolbar-button')),
          matching: find.text('00:03'),
        ),
        findsOneWidget,
      );

      time.elapse(const Duration(seconds: 1));
      await tester.pump();
      expect(_largeCountdownText(tester), '00:02');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('countdown-toolbar-button')),
          matching: find.text('00:02'),
        ),
        findsOneWidget,
      );

      time.elapse(const Duration(seconds: 2));
      await tester.pump();
      expect(_largeCountdownText(tester), '00:00');
      expect(alarmCount, 1);
      expect(
        find.byKey(const ValueKey('countdown-overlay-acknowledge-alarm')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('countdown-toolbar-button')),
          matching: find.text('Alarm bestätigen'),
        ),
        findsOneWidget,
      );

      time.elapse(const Duration(seconds: 2));
      expect(alarmCount, 3);
      await tester.tap(find.byKey(const ValueKey('countdown-toolbar-button')));
      await tester.pump();
      expect(showLargeCount, 1);
      expect(controller.isAlarmActive, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('countdown-overlay-acknowledge-alarm')),
      );
      await tester.pump();
      expect(controller.isAlarmActive, isFalse);
      expect(
        find.byKey(const ValueKey('countdown-overlay-acknowledge-alarm')),
        findsNothing,
      );

      time.elapse(const Duration(seconds: 5), runCanceledCallbacks: true);
      expect(alarmCount, 3);
    },
  );
}

String? _largeCountdownText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('countdown-large-value')))
    .data;

final class _WidgetTimerClock {
  Duration _elapsed = Duration.zero;
  final List<_WidgetWakeUp> _wakeUps = <_WidgetWakeUp>[];

  Duration now() => _elapsed;

  CountdownWakeUp schedule(Duration delay, VoidCallback callback) {
    final wakeUp = _WidgetWakeUp(_elapsed + delay, callback);
    _wakeUps.add(wakeUp);
    return wakeUp;
  }

  void jumpWithoutCallbacks(Duration duration) => _elapsed += duration;

  void elapse(Duration duration, {bool runCanceledCallbacks = false}) {
    final target = _elapsed + duration;
    while (true) {
      final pending =
          _wakeUps
              .where(
                (entry) =>
                    !entry.fired &&
                    entry.due <= target &&
                    (runCanceledCallbacks || !entry.canceled),
              )
              .toList()
            ..sort((a, b) => a.due.compareTo(b.due));
      if (pending.isEmpty) break;
      final wakeUp = pending.first;
      _elapsed = wakeUp.due;
      wakeUp.fired = true;
      wakeUp.callback();
    }
    _elapsed = target;
  }
}

final class _WidgetWakeUp implements CountdownWakeUp {
  _WidgetWakeUp(this.due, this.callback);

  final Duration due;
  final VoidCallback callback;
  bool canceled = false;
  bool fired = false;

  @override
  void cancel() => canceled = true;
}
