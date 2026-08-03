import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input/touch_contact_classifier.dart';
import 'radial_menu_geometry.dart';
import 'radial_menu_models.dart';
import 'radial_menu_painter.dart';

enum _DragMode { none, center, thickness, pageWheel }

/// A full-overlay radial menu. Place it above the whiteboard canvas, for example
/// with `Positioned.fill`, so its center can be dragged anywhere in the board.
/// Pixels outside the painted rings do not participate in hit testing.
class RadialMenu extends StatefulWidget {
  const RadialMenu({
    super.key,
    this.controller,
    this.callbacks = const RadialMenuCallbacks(),
    this.initialPosition,
    this.pagePreviews = const <RadialPagePreview>[],
    this.currentPageIndex = 0,
    this.pageWindowSize = 7,
    this.templateEntries = const <RadialTemplateEntry>[],
    this.palette = defaultPalette,
    this.penPresets = RadialPenPreset.defaults,
    this.theme = const RadialMenuThemeData(),
    this.labels,
    this.logoIcon = Icons.gesture_rounded,
    this.centerLogo,
    this.maxDiameter = 600,
    this.edgePadding = 12,
    this.confineToBounds = false,
    this.positionResetToken = 0,
    this.canUndo = true,
    this.canRedo = true,
  }) : assert(pageWindowSize >= 3 && pageWindowSize <= 16),
       assert(maxDiameter >= 360),
       assert(edgePadding >= 0);

  static const List<Color> defaultPalette = <Color>[
    Colors.black,
    Color(0xFF2196F3),
    Color(0xFFF44336),
    Color(0xFF4CAF50),
    Color(0xFFFFC107),
    Color(0xFF00BCD4),
    Colors.white,
    Color(0xFF9C27B0),
  ];

  final RadialMenuController? controller;
  final RadialMenuCallbacks callbacks;
  final Offset? initialPosition;
  final List<RadialPagePreview> pagePreviews;
  final int currentPageIndex;
  final int pageWindowSize;
  final List<RadialTemplateEntry> templateEntries;
  final List<Color> palette;
  final List<RadialPenPreset> penPresets;
  final RadialMenuThemeData theme;
  final RadialMenuLabels? labels;
  final IconData logoIcon;

  /// Optional branded center content. It is rendered above the center disc and
  /// excluded from pointer handling; [logoIcon] is used when this is null.
  final Widget? centerLogo;
  final double maxDiameter;
  final double edgePadding;

  /// Clips visible rings to this menu's layout region.
  ///
  /// The draggable centre always keeps only its own disc inside the region,
  /// whether the rings are open or closed. This is important in split mode:
  /// either participant can place the control at every corner of their half
  /// while expanded ring pixels are cleanly clipped at the divider or screen
  /// edge.
  final bool confineToBounds;

  /// Increment this value to move the draggable center to the middle of the
  /// currently visible board without coupling the menu to editor history.
  final int positionResetToken;

  /// Whether the document history currently contains an action that can be
  /// undone/redone. Disabled history actions are painted muted, removed from
  /// pointer hit testing and exposed as disabled accessibility controls.
  final bool canUndo;
  final bool canRedo;

  @override
  State<RadialMenu> createState() => _RadialMenuState();
}

class _RadialMenuState extends State<RadialMenu> with TickerProviderStateMixin {
  static const TouchContactClassifier _touchContactClassifier =
      TouchContactClassifier();
  static const double _fiveFingerDetent = math.pi / 10;
  static const double _fiveFingerDetentHysteresis = .70;
  static const int _minimumPageGestureFingers = 4;
  static const int _maximumPageGestureFingers = 5;

  late RadialMenuController _controller;
  late bool _ownsController;
  late final AnimationController _openAnimation;
  late final AnimationController _submenuAnimation;
  late final AnimationController _tailAnimation;
  late bool _lastOpen;
  late RadialMenuBranch? _lastBranch;

  Offset? _centerPosition;
  Offset? _displayCenterPosition;
  Size _availableSize = Size.zero;
  double _diameter = RadialMenuGeometry.designDiameter;
  _DragMode _dragMode = _DragMode.none;
  RadialHitTarget _panStartTarget = RadialHitTarget.none;
  Offset _panDownGlobalPosition = Offset.zero;
  Offset _panDownLocalPosition = Offset.zero;
  Offset _centerAtPanDown = Offset.zero;
  Offset _tapDownGlobalPosition = Offset.zero;
  double _panTravel = 0;
  bool _panStarted = false;
  double _pageWheelLastAngle = 0;
  double _pageWheelTravel = 0;
  int _pageWheelIndex = 0;
  // Global touch routing lets the five-finger page gesture start around the
  // compact center even while the painted menu rings are fully closed. It
  // observes pointers without claiming the hit test, so board ink remains
  // available for ordinary one- and two-finger interaction.
  final Map<int, Offset> _menuPointers = <int, Offset>{};
  final Map<int, double> _fiveFingerAngularTravel = <int, double>{};
  final Set<int> _pageGesturePointers = <int>{};
  final Set<int> _suppressedMenuPointers = <int>{};
  bool _fiveFingerPageGesture = false;
  int _fiveFingerStartPagePosition = 0;
  int _fiveFingerDetentPosition = 0;
  bool _suppressMenuActivation = false;
  RadialHitTarget _hovered = RadialHitTarget.none;
  RadialHitTarget _pressed = RadialHitTarget.none;
  List<RadialPagePreview>? _visiblePageSource;
  int _visiblePageCurrentIndex = -1;
  int _visiblePageWindowSize = -1;
  List<RadialPagePreview> _visiblePageSnapshot = const <RadialPagePreview>[];

  @override
  void initState() {
    super.initState();
    _attachController(widget.controller);
    _lastOpen = _controller.isOpen;
    _lastBranch = _controller.activeBranch;
    _openAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 210),
      value: _controller.isOpen ? 1 : 0,
    );
    _submenuAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
      reverseDuration: const Duration(milliseconds: 130),
      value: _controller.activeBranch == null ? 0 : 1,
    );
    _tailAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    );
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleGlobalPointerEvent,
    );
  }

  void _attachController(RadialMenuController? supplied) {
    _ownsController = supplied == null;
    _controller = supplied ?? RadialMenuController();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant RadialMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_onControllerChanged);
      if (_ownsController) _controller.dispose();
      _attachController(widget.controller);
      _lastOpen = _controller.isOpen;
      _lastBranch = _controller.activeBranch;
      _openAnimation.value = _controller.isOpen ? 1 : 0;
      _submenuAnimation.value = _controller.activeBranch == null ? 0 : 1;
    }
    if (oldWidget.positionResetToken != widget.positionResetToken &&
        !_availableSize.isEmpty) {
      final centered = _clampCenter(
        Offset(_availableSize.width / 2, _availableSize.height / 2),
      );
      _centerPosition = centered;
      _displayCenterPosition = centered;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.callbacks.onPositionChanged?.call(centered);
      });
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_lastOpen != _controller.isOpen) {
      _lastOpen = _controller.isOpen;
      if (_controller.isOpen) {
        unawaited(_openAnimation.forward());
      } else {
        unawaited(_openAnimation.reverse());
      }
      unawaited(_tailAnimation.forward(from: 0));
      widget.callbacks.onMenuOpenChanged?.call(_controller.isOpen);
    }
    if (_lastBranch != _controller.activeBranch) {
      _lastBranch = _controller.activeBranch;
      if (_controller.activeBranch == null) {
        unawaited(_submenuAnimation.reverse());
      } else {
        unawaited(_submenuAnimation.forward(from: 0));
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleGlobalPointerEvent,
    );
    if (_suppressMenuActivation) {
      widget.callbacks.onFiveFingerPageGestureChanged?.call(false);
    }
    _fiveFingerPageGesture = false;
    _suppressMenuActivation = false;
    _menuPointers.clear();
    _fiveFingerAngularTravel.clear();
    _pageGesturePointers.clear();
    _suppressedMenuPointers.clear();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _openAnimation.dispose();
    _submenuAnimation.dispose();
    _tailAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final fallback = MediaQuery.sizeOf(context);
        _availableSize = Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : fallback.width,
          constraints.hasBoundedHeight
              ? constraints.maxHeight
              : fallback.height,
        );
        final shortest = _availableSize.shortestSide;
        _diameter = math.min(
          widget.maxDiameter,
          math.max(1, shortest - widget.edgePadding * 2),
        );
        _centerPosition ??= _clampCenter(
          widget.initialPosition ??
              Offset(_availableSize.width / 2, _availableSize.height / 2),
          keepFullSurfaceVisible: false,
        );
        // Opening rings never changes the draggable centre. In a constrained
        // split region, only the portions of those rings outside the owning
        // participant's half are clipped.
        _centerPosition = _clampCenter(
          _centerPosition!,
          keepFullSurfaceVisible: false,
        );
        _displayCenterPosition = _clampCenter(_centerPosition!);

        return Stack(
          key: const ValueKey<String>('radial-menu-region'),
          clipBehavior: widget.confineToBounds ? Clip.hardEdge : Clip.none,
          children: <Widget>[
            Positioned(
              left: _displayCenterPosition!.dx - _diameter / 2,
              top: _displayCenterPosition!.dy - _diameter / 2,
              width: _diameter,
              height: _diameter,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: Listenable.merge(<Listenable>[
                    _openAnimation,
                    _submenuAnimation,
                    _tailAnimation,
                  ]),
                  builder: (BuildContext context, Widget? child) {
                    return _buildSurface(context);
                  },
                ),
              ),
            ),
            if (_fiveFingerPageGesture &&
                _pageWheelIndex >= 0 &&
                _pageWheelIndex < widget.pagePreviews.length)
              _buildFiveFingerPagePreview(widget.pagePreviews[_pageWheelIndex]),
          ],
        );
      },
    );
  }

  Widget _buildFiveFingerPagePreview(RadialPagePreview page) {
    final scale = (_availableSize.shortestSide / 800).clamp(.78, 1.15);
    final width = (184 * scale).clamp(148.0, 212.0);
    final height = (146 * scale).clamp(122.0, 168.0);
    final center = _displayCenterPosition ?? _availableSize.center(Offset.zero);
    const gap = 22.0;
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    final preferAbove = center.dy >= _availableSize.height / 2;
    final desiredTop = preferAbove
        ? center.dy - geometry.centerRadius - gap - height
        : center.dy + geometry.centerRadius + gap;
    final maximumTop = math.max(
      widget.edgePadding,
      _availableSize.height - height - widget.edgePadding,
    );
    final top = desiredTop.clamp(widget.edgePadding, maximumTop);
    final maximumLeft = math.max(
      widget.edgePadding,
      _availableSize.width - width - widget.edgePadding,
    );
    final left = (center.dx - width / 2).clamp(widget.edgePadding, maximumLeft);

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Semantics(
          liveRegion: true,
          label:
              '${page.semanticLabel ?? 'Seite ${page.pageNumber}'}, ausgew\u00e4hlt',
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 110),
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: Curves.easeIn,
            child: DecoratedBox(
              key: ValueKey<String>(
                'five-finger-page-preview-${page.pageIndex}',
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF171D1C),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: widget.theme.activeColor.withValues(alpha: .95),
                  width: 2,
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x59000000),
                    blurRadius: 18,
                    offset: Offset(0, 7),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 9, 9, 8),
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: ColoredBox(
                          color: page.backgroundColor,
                          child: SizedBox.expand(
                            child: page.thumbnail == null
                                ? const Icon(
                                    Icons.description_outlined,
                                    color: Color(0xFF64706E),
                                    size: 38,
                                  )
                                : RawImage(
                                    key: const ValueKey<String>(
                                      'five-finger-page-thumbnail',
                                    ),
                                    image: page.thumbnail,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      'Seite ${page.pageNumber}',
                      key: const ValueKey<String>('five-finger-page-number'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSurface(BuildContext context) {
    final labels = widget.labels ?? RadialMenuLabels.german();
    final visiblePages = _visiblePagePreviews();
    final painter = RadialMenuPainter(
      isOpen: _controller.isOpen,
      branch: _controller.activeBranch,
      expandedPrimary: _controller.expandedPrimary,
      selectedPrimary: _controller.selectedPrimary,
      penSettings: _controller.penSettings,
      selectionTool: _controller.selectionTool,
      insertCategory: _controller.insertCategory,
      shapeKind: _controller.shapeKind,
      tableSize: _controller.tableSize,
      palette: _effectivePalette,
      presets: widget.penPresets,
      pagePreviews: visiblePages,
      currentPageIndex: widget.currentPageIndex,
      templateEntries: widget.templateEntries,
      surfaceSize: Size.square(_diameter),
      openProgress: _openAnimation.value,
      submenuProgress: _submenuAnimation.value,
      tailRotation: _tailAnimation.value,
      hovered: _hovered,
      pressed: _pressed,
      theme: widget.theme,
      labels: labels,
      logoIcon: widget.centerLogo == null ? widget.logoIcon : null,
      onSemanticActivate: (target) => unawaited(_activateTarget(target)),
      onSemanticThicknessChanged: _setThickness,
      textDirection: Directionality.of(context),
      canUndo: widget.canUndo,
      canRedo: widget.canRedo,
    );

    return MouseRegion(
      hitTestBehavior: HitTestBehavior.deferToChild,
      cursor: _hovered.isInteractive
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onExit: (_) => _setHovered(RadialHitTarget.none),
      child: Listener(
        onPointerHover: (event) {
          _setHovered(
            painter.hitTargetAt(event.localPosition, Size.square(_diameter)),
          );
        },
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onTapDown: (details) {
            _tapDownGlobalPosition = details.globalPosition;
            final target = painter.hitTargetAt(
              details.localPosition,
              Size.square(_diameter),
            );
            if (_pressed != target) setState(() => _pressed = target);
          },
          onTapUp: (details) {
            if (_suppressMenuActivation) {
              if (_pressed.isInteractive) {
                setState(() => _pressed = RadialHitTarget.none);
              }
              return;
            }
            final target = painter.hitTargetAt(
              details.localPosition,
              Size.square(_diameter),
            );
            final travel =
                (details.globalPosition - _tapDownGlobalPosition).distance;
            final shouldActivate =
                _pressed.isInteractive &&
                travel <= 36 &&
                (target == _pressed ||
                    target.layer == _pressed.layer ||
                    target == RadialHitTarget.none);
            final activationTarget = _pressed;
            setState(() => _pressed = RadialHitTarget.none);
            if (shouldActivate) unawaited(_activateTarget(activationTarget));
          },
          onTapCancel: () {
            if (_pressed.isInteractive) {
              setState(() => _pressed = RadialHitTarget.none);
            }
          },
          onLongPressStart: (details) {
            if (_suppressMenuActivation ||
                _controller.activeBranch != RadialMenuBranch.pages ||
                widget.pagePreviews.length <= 1) {
              return;
            }
            final target = painter.hitTargetAt(
              details.localPosition,
              Size.square(_diameter),
            );
            if (target.layer != RadialMenuLayer.secondary) return;
            final pages = _visiblePagePreviews();
            if (target.index < 0 || target.index >= pages.length) return;
            if (_pressed.isInteractive) {
              setState(() => _pressed = RadialHitTarget.none);
            }
            widget.callbacks.onPageDeleteRequested?.call(pages[target.index]);
          },
          onPanDown: (details) {
            _panStartTarget = painter.hitTargetAt(
              details.localPosition,
              Size.square(_diameter),
            );
            _panDownGlobalPosition = details.globalPosition;
            _panDownLocalPosition = details.localPosition;
            _centerAtPanDown = _displayCenterPosition!;
            _panTravel = 0;
            _panStarted = false;
          },
          onPanStart: (details) {
            if (_fiveFingerPageGesture) return;
            _panStarted = true;
            _panTravel =
                (details.globalPosition - _panDownGlobalPosition).distance;
            if (_panStartTarget.layer == RadialMenuLayer.center) {
              _dragMode = _DragMode.center;
            } else if (_panStartTarget.layer == RadialMenuLayer.thickness) {
              _dragMode = _DragMode.thickness;
            } else if (_controller.activeBranch == RadialMenuBranch.pages &&
                _panStartTarget.layer == RadialMenuLayer.secondary &&
                widget.pagePreviews.length > 1) {
              _dragMode = _DragMode.pageWheel;
            } else {
              _dragMode = _DragMode.none;
            }
            if (_dragMode == _DragMode.thickness) {
              _setThicknessFromPosition(details.localPosition);
            } else if (_dragMode == _DragMode.center) {
              _moveCenterTo(
                _centerAtPanDown +
                    (details.globalPosition - _panDownGlobalPosition),
              );
            } else if (_dragMode == _DragMode.pageWheel) {
              _beginPageWheel(_panDownLocalPosition);
              _updatePageWheel(details.localPosition);
            }
          },
          onPanUpdate: (details) {
            if (_fiveFingerPageGesture) return;
            _panTravel += details.delta.distance;
            switch (_dragMode) {
              case _DragMode.center:
                _moveCenterTo(_displayCenterPosition! + details.delta);
              case _DragMode.thickness:
                _setThicknessFromPosition(details.localPosition);
              case _DragMode.pageWheel:
                _updatePageWheel(details.localPosition);
              case _DragMode.none:
                break;
            }
          },
          onPanEnd: (_) => _finishDrag(commitTapFallback: true),
          onPanCancel: () => _finishDrag(),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CustomPaint(
                key: const ValueKey<String>('radial-menu-surface'),
                painter: painter,
                size: Size.square(_diameter),
                isComplex: true,
                willChange:
                    _openAnimation.isAnimating ||
                    _submenuAnimation.isAnimating ||
                    _tailAnimation.isAnimating,
              ),
              if (widget.centerLogo != null)
                IgnorePointer(
                  child: ExcludeSemantics(
                    child: Center(
                      child: SizedBox.square(
                        dimension: 43 * (_diameter / 600),
                        child: FittedBox(child: widget.centerLogo),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _finishDrag({bool commitTapFallback = false}) {
    // Tap and pan recognizers share the same pointer arena. A rejected pan can
    // receive onPanCancel immediately before onTapUp on some Android panels.
    // It must not clear the tap's pressed target, otherwise that first tap is
    // swallowed and the user has to choose the segment a second time.
    if (!_panStarted) {
      _dragMode = _DragMode.none;
      _panStartTarget = RadialHitTarget.none;
      _panTravel = 0;
      return;
    }
    final completedMode = _dragMode;
    final fallbackTarget =
        commitTapFallback &&
            _panStarted &&
            _dragMode == _DragMode.none &&
            _panTravel <= 36 &&
            _panStartTarget.isInteractive
        ? _panStartTarget
        : RadialHitTarget.none;
    _dragMode = _DragMode.none;
    _panStartTarget = RadialHitTarget.none;
    _panTravel = 0;
    _panStarted = false;
    _pageWheelTravel = 0;
    if (_pressed.isInteractive) {
      setState(() => _pressed = RadialHitTarget.none);
    }
    if (completedMode == _DragMode.center && _centerPosition != null) {
      // Persist the final position once. Calling this callback for every
      // pointer packet used to cancel and recreate the editor's debounce timer
      // at stylus frequency while the radial menu was being dragged.
      widget.callbacks.onPositionChanged?.call(_centerPosition!);
    }
    if (fallbackTarget.isInteractive) {
      unawaited(_activateTarget(fallbackTarget));
    }
  }

  void _moveCenterTo(Offset requested) {
    final next = _clampCenter(requested);
    if (next == _centerPosition && next == _displayCenterPosition) return;
    setState(() {
      _centerPosition = next;
      _displayCenterPosition = next;
    });
  }

  void _setHovered(RadialHitTarget target) {
    if (_hovered == target || !mounted) return;
    setState(() => _hovered = target);
  }

  Future<void> _activateTarget(RadialHitTarget target) async {
    switch (target.layer) {
      case RadialMenuLayer.center:
        if (_controller.isOpen) {
          _controller.setBranch(null);
          _controller.setOpen(false);
        } else {
          _controller.setBranch(null);
          _controller.setOpen(true);
        }
      case RadialMenuLayer.primary:
        if (target.index < 0 ||
            target.index >= RadialMenuAction.values.length) {
          return;
        }
        final action = RadialMenuAction.values[target.index];
        if ((action == RadialMenuAction.undo && !widget.canUndo) ||
            (action == RadialMenuAction.redo && !widget.canRedo)) {
          return;
        }
        final previousPen = _controller.penSettings;
        final previousSelection = _controller.selectionTool;
        _controller.activatePrimary(action);
        widget.callbacks.onPrimaryAction?.call(action);
        if (_controller.penSettings != previousPen) {
          widget.callbacks.onPenSettingsChanged?.call(_controller.penSettings);
        }
        if (_controller.selectionTool != previousSelection) {
          widget.callbacks.onSelectionToolChanged?.call(
            _controller.selectionTool,
          );
        }
        if (action == RadialMenuAction.insert &&
            _controller.activeBranch == RadialMenuBranch.insert) {
          widget.callbacks.onShapeRequested?.call(_controller.shapeKind);
        }
      case RadialMenuLayer.secondary:
        await _activateSecondary(target.index);
      case RadialMenuLayer.tertiary:
        _activateTertiary(target.index);
      case RadialMenuLayer.thickness:
      case RadialMenuLayer.none:
        return;
    }
  }

  Future<void> _activateSecondary(int index) async {
    switch (_controller.activeBranch) {
      case RadialMenuBranch.pen:
        final palette = _effectivePalette;
        if (index >= 0 && index < palette.length) {
          _updatePen(_controller.penSettings.copyWith(color: palette[index]));
          return;
        }
        if (index == palette.length) {
          final picker = widget.callbacks.onCustomColorRequested;
          if (picker == null) return;
          try {
            final selected = await picker(_controller.penSettings.color);
            if (selected != null && mounted) {
              _updatePen(_controller.penSettings.copyWith(color: selected));
            }
          } catch (error, stackTrace) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: 'radial_menu',
                context: ErrorDescription(
                  'while opening the custom color picker',
                ),
              ),
            );
          }
          return;
        }
        final presetIndex = index - palette.length - 1;
        if (presetIndex >= 0 && presetIndex < widget.penPresets.length) {
          _updatePen(widget.penPresets[presetIndex].settings);
        }
      case RadialMenuBranch.selection:
        if (index >= 0 && index < RadialSelectionTool.values.length) {
          final tool = RadialSelectionTool.values[index];
          _controller.setSelectionTool(tool);
          widget.callbacks.onSelectionToolChanged?.call(tool);
        }
      case RadialMenuBranch.templates:
        if (index >= 0 && index < widget.templateEntries.length) {
          widget.callbacks.onTemplateSelected?.call(
            widget.templateEntries[index],
          );
        }
      case RadialMenuBranch.pages:
        final pages = _visiblePagePreviews();
        if (index >= 0 && index < pages.length) {
          widget.callbacks.onPageSelected?.call(pages[index].pageIndex);
        }
      case RadialMenuBranch.insert:
        if (index >= 0 && index < RadialInsertCategory.values.length) {
          final category = RadialInsertCategory.values[index];
          _controller.setInsertCategory(category);
          switch (category) {
            case RadialInsertCategory.geometry:
              _controller.setShapeKind(RadialShapeKind.rectangle);
              widget.callbacks.onShapeRequested?.call(_controller.shapeKind);
            case RadialInsertCategory.image:
              // Image source remains the only insert choice that needs the
              // outer ring in addition to geometry.
              break;
            case RadialInsertCategory.table:
              widget.callbacks.onTableRequested?.call(_controller.tableSize);
            case RadialInsertCategory.pdf:
              // The editor first chooses a file and can therefore show real
              // page previews instead of generic Ring-3 choices.
              widget.callbacks.onPdfRequested?.call(
                RadialPdfImportMode.allPages,
              );
            case RadialInsertCategory.cover:
              // Covers start in the broadly useful horizontal reveal mode;
              // direction and size remain editable on the board.
              widget.callbacks.onCoverRequested?.call(
                RadialCoverDirection.horizontal,
              );
          }
        }
      case RadialMenuBranch.export:
        if (index >= 0 && index < RadialExportAction.values.length) {
          widget.callbacks.onExportRequested?.call(
            RadialExportAction.values[index],
          );
        }
      case null:
        return;
    }
  }

  void _activateTertiary(int index) {
    if (_controller.activeBranch == RadialMenuBranch.pen) {
      if (index >= 0 && index < RadialPenType.values.length) {
        final type = RadialPenType.values[index];
        _updatePen(_controller.penSettings.copyWith(type: type));
        if (type == RadialPenType.eraser) {
          // Erasing is a complete tool, not another configurable pen family.
          // Keep the primary ring available, but dismiss the colour/type fan
          // immediately so selecting the eraser never appears to open another
          // Stift/Marker/Gestrichelt/Gerade/Radierer choice.
          _controller.setBranch(null);
        }
      }
      return;
    }
    if (_controller.activeBranch != RadialMenuBranch.insert) return;

    switch (_controller.insertCategory) {
      case RadialInsertCategory.geometry:
        if (index >= 0 && index < RadialShapeKind.values.length) {
          final shape = RadialShapeKind.values[index];
          _controller.setShapeKind(shape);
          widget.callbacks.onShapeRequested?.call(shape);
        }
      case RadialInsertCategory.image:
        if (index >= 0 && index < RadialImageSource.values.length) {
          widget.callbacks.onImageRequested?.call(
            RadialImageSource.values[index],
          );
        }
      case RadialInsertCategory.table ||
          RadialInsertCategory.pdf ||
          RadialInsertCategory.cover:
        // These categories execute from Ring 2 and never expose Ring 3.
        return;
    }
  }

  void _setThicknessFromPosition(Offset position) {
    if (_controller.penSettings.type == RadialPenType.eraser) return;
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    final fraction = geometry.arcFractionFor(
      position,
      startAngle: geometry.compactSubmenuStartAngle(RadialMenuAction.pen.index),
      span: geometry.thicknessSpan,
    );
    final thickness =
        RadialPenSettings.minThickness +
        fraction *
            (RadialPenSettings.maxThickness - RadialPenSettings.minThickness);
    _setThickness((thickness * 2).roundToDouble() / 2);
  }

  void _setThickness(double thickness) {
    if (_controller.penSettings.type == RadialPenType.eraser) return;
    _updatePen(_controller.penSettings.copyWith(thickness: thickness));
  }

  void _updatePen(RadialPenSettings settings) {
    if (_controller.penSettings == settings) return;
    _controller.setPenSettings(settings);
    widget.callbacks.onPenSettingsChanged?.call(_controller.penSettings);
  }

  List<Color> get _effectivePalette {
    if (widget.palette.contains(Colors.black)) return widget.palette;
    return <Color>[Colors.black, ...widget.palette];
  }

  List<RadialPagePreview> _visiblePagePreviews() {
    final pages = widget.pagePreviews;
    if (pages.isEmpty) return const <RadialPagePreview>[];
    if (identical(_visiblePageSource, pages) &&
        _visiblePageCurrentIndex == widget.currentPageIndex &&
        _visiblePageWindowSize == widget.pageWindowSize) {
      return _visiblePageSnapshot;
    }
    final current = widget.currentPageIndex.clamp(0, pages.length - 1);
    final window = math.min(widget.pageWindowSize, pages.length);
    final clockwise = window ~/ 2;
    final counterClockwise = window - clockwise - 1;
    final result = <RadialPagePreview>[pages[current]];
    for (var distance = 1; distance <= clockwise; distance++) {
      result.add(pages[(current + distance) % pages.length]);
    }
    for (var distance = counterClockwise; distance >= 1; distance--) {
      result.add(pages[(current - distance) % pages.length]);
    }
    _visiblePageSource = pages;
    _visiblePageCurrentIndex = widget.currentPageIndex;
    _visiblePageWindowSize = widget.pageWindowSize;
    return _visiblePageSnapshot = List<RadialPagePreview>.unmodifiable(result);
  }

  void _beginPageWheel(Offset position) {
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    _pageWheelLastAngle = geometry.angleFor(position);
    _pageWheelTravel = 0;
    _pageWheelIndex = widget.pagePreviews.isEmpty
        ? 0
        : _pagePositionFor(widget.currentPageIndex);
  }

  void _handleGlobalPointerEvent(PointerEvent event) {
    // A stylus, inverted stylus or mouse must never count as one of the five
    // fingers. This is especially important while several pupils write at
    // once on a large panel.
    if (event.kind != PointerDeviceKind.touch) return;
    if (event is PointerDownEvent) {
      _handleFiveFingerPointerDown(event);
    } else if (event is PointerMoveEvent) {
      _handleFiveFingerPointerMove(event);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _handleFiveFingerPointerEnd(event);
    }
  }

  void _handleFiveFingerPointerDown(PointerDownEvent event) {
    // Once a five-finger session started, additional fingers are suppressed
    // until every participant is up but do not alter the rotation average.
    if (_suppressMenuActivation) {
      _suppressedMenuPointers.add(event.pointer);
      return;
    }
    // Some digitizers expose the lower edge of a fist as several neighbouring
    // touch contacts. Those contacts belong to the board eraser and must not
    // be consumed as a five-finger page command.
    // Individual fingertips on large infrared/capacitive boards are
    // sometimes reported just above the ordinary broad-touch threshold. Only
    // reject unambiguously palm-sized contacts here; compact-cluster and
    // angular-coverage checks below still keep a fist from claiming pages.
    if (_touchContactClassifier.isStrongBroadTouch(event)) return;
    if (widget.pagePreviews.length < 2 ||
        _menuPointers.length >= _maximumPageGestureFingers ||
        !_isInFiveFingerGestureZone(event.position)) {
      return;
    }
    _menuPointers[event.pointer] = event.position;
    _tryStartFiveFingerPageGesture();
  }

  void _tryStartFiveFingerPageGesture() {
    if (_fiveFingerPageGesture ||
        _suppressMenuActivation ||
        _menuPointers.length < _minimumPageGestureFingers ||
        _menuPointers.length > _maximumPageGestureFingers ||
        !_hasFiveFingerAngularCoverage()) {
      return;
    }

    _fiveFingerPageGesture = true;
    _suppressMenuActivation = true;
    _pageGesturePointers
      ..clear()
      ..addAll(_menuPointers.keys);
    _suppressedMenuPointers.addAll(_pageGesturePointers);
    widget.callbacks.onFiveFingerPageGestureChanged?.call(true);
    _dragMode = _DragMode.none;
    _panStartTarget = RadialHitTarget.none;
    _panStarted = false;
    _panTravel = 0;
    _pageWheelTravel = 0;
    _pageWheelIndex = _pagePositionFor(widget.currentPageIndex);
    _fiveFingerStartPagePosition = _pageWheelIndex;
    _fiveFingerDetentPosition = 0;
    _fiveFingerAngularTravel
      ..clear()
      ..addEntries(
        _pageGesturePointers.map((pointer) => MapEntry(pointer, 0.0)),
      );
    // Deliberately do not open the menu or mutate its branch. The floating
    // preview is the only added surface while the five contacts are held.
    if (mounted) {
      setState(() {
        if (_pressed.isInteractive) _pressed = RadialHitTarget.none;
      });
    }
  }

  void _handleFiveFingerPointerMove(PointerMoveEvent event) {
    final previous = _menuPointers[event.pointer];
    if (previous == null) return;
    if (!_fiveFingerPageGesture &&
        (_touchContactClassifier.isStrongBroadTouch(event) ||
            !_isInFiveFingerGestureZone(event.position))) {
      _menuPointers.remove(event.pointer);
      _fiveFingerAngularTravel.remove(event.pointer);
      return;
    }
    _menuPointers[event.pointer] = event.position;
    if (!_fiveFingerPageGesture) _tryStartFiveFingerPageGesture();
    if (!_fiveFingerPageGesture ||
        !_pageGesturePointers.contains(event.pointer)) {
      return;
    }
    final center = _globalMenuCenter;
    if (center == null) return;
    var delta =
        _angleAround(center, event.position) - _angleAround(center, previous);
    if (delta > math.pi) delta -= math.pi * 2;
    if (delta < -math.pi) delta += math.pi * 2;
    _fiveFingerAngularTravel[event.pointer] =
        (_fiveFingerAngularTravel[event.pointer] ?? 0) + delta;
    _emitCoherentFiveFingerDetents();
  }

  void _handleFiveFingerPointerEnd(PointerEvent event) {
    final wasGesturePointer = _pageGesturePointers.contains(event.pointer);
    _menuPointers.remove(event.pointer);
    _fiveFingerAngularTravel.remove(event.pointer);
    _suppressedMenuPointers.remove(event.pointer);
    if (_fiveFingerPageGesture && wasGesturePointer) {
      if (event is PointerUpEvent) {
        _commitFiveFingerPageGesture();
      } else {
        _cancelFiveFingerPageGesture();
      }
    }
    if (_suppressMenuActivation && _suppressedMenuPointers.isEmpty) {
      _menuPointers.clear();
      _fiveFingerAngularTravel.clear();
      // Per-pointer gesture routes (including onTapUp) run before global
      // routes, so it is safe to release arbitration synchronously here.
      _suppressMenuActivation = false;
      widget.callbacks.onFiveFingerPageGestureChanged?.call(false);
    }
  }

  Offset? get _globalMenuCenter {
    if (_displayCenterPosition == null || _availableSize.isEmpty) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(_displayCenterPosition!);
  }

  bool _isInFiveFingerGestureZone(Offset globalPosition) {
    final center = _globalMenuCenter;
    if (center == null) return false;
    if (widget.confineToBounds) {
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        return false;
      }
      final local = renderObject.globalToLocal(globalPosition);
      if (!local.dx.isFinite ||
          !local.dy.isFinite ||
          !(Offset.zero & renderObject.size).contains(local)) {
        return false;
      }
    }
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    final radius = (globalPosition - center).distance;
    // Keep the centre free for normal menu activation and for clustered palm
    // contacts. The outer tolerance includes Ring 3 when it is visible.
    return radius >= geometry.centerRadius * .9 &&
        radius <= geometry.tertiaryOuterRadius + 24 * geometry.scale;
  }

  bool _hasFiveFingerAngularCoverage() {
    final center = _globalMenuCenter;
    if (center == null ||
        _menuPointers.length < _minimumPageGestureFingers ||
        _menuPointers.length > _maximumPageGestureFingers) {
      return false;
    }
    final angles =
        _menuPointers.values
            .map((position) => _angleAround(center, position))
            .toList(growable: false)
          ..sort();
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    var maximumPairDistance = 0.0;
    final positions = _menuPointers.values.toList(growable: false);
    for (var first = 0; first < positions.length; first++) {
      for (var second = first + 1; second < positions.length; second++) {
        maximumPairDistance = math.max(
          maximumPairDistance,
          (positions[first] - positions[second]).distance,
        );
      }
    }
    if (maximumPairDistance < geometry.centerRadius * 1.6) return false;
    var largestGap = 0.0;
    for (var index = 0; index < angles.length; index++) {
      final current = angles[index];
      final next = index + 1 < angles.length
          ? angles[index + 1]
          : angles.first + math.pi * 2;
      largestGap = math.max(largestGap, next - current);
    }
    // At a screen edge or split divider, users can physically reach only a
    // quadrant of the wheel. Ninety degrees of coverage plus the pair-distance
    // requirement still rejects a compact fist cluster while making four
    // genuine fingertips usable at every legal menu position.
    return largestGap <= math.pi * 1.5;
  }

  void _emitCoherentFiveFingerDetents() {
    final pageCount = widget.pagePreviews.length;
    final pointerCount = _pageGesturePointers.length;
    if (pageCount < 2 ||
        pointerCount < _minimumPageGestureFingers ||
        pointerCount > _maximumPageGestureFingers ||
        _fiveFingerAngularTravel.length != pointerCount) {
      return;
    }
    final requiredSupport = math.max(3, pointerCount - 1);
    var changed = false;
    while (true) {
      final values = _fiveFingerAngularTravel.values.toList(growable: false)
        ..sort();
      final forwardThreshold =
          (_fiveFingerDetentPosition + _fiveFingerDetentHysteresis) *
          _fiveFingerDetent;
      final backwardThreshold =
          (_fiveFingerDetentPosition - _fiveFingerDetentHysteresis) *
          _fiveFingerDetent;
      final forwardSupport = values
          .where((value) => value >= forwardThreshold)
          .length;
      final backwardSupport = values
          .where((value) => value <= backwardThreshold)
          .length;
      final direction = forwardSupport >= requiredSupport
          ? 1
          : backwardSupport >= requiredSupport
          ? -1
          : 0;
      if (direction == 0) break;
      _fiveFingerDetentPosition += direction;
      _pageWheelIndex =
          (_fiveFingerStartPagePosition + _fiveFingerDetentPosition) %
          pageCount;
      changed = true;

      // One pointer event may represent a large hardware-coalesced move. The
      // loop catches up all crossed detents, but the support threshold still
      // requires four coherent fingertips for every step.
      if (_fiveFingerDetentPosition.abs() > pageCount * 100) {
        break;
      }
    }
    if (!changed) return;
    unawaited(HapticFeedback.selectionClick());
    if (mounted) setState(() {});
  }

  void _cancelFiveFingerPageGesture() {
    if (!_fiveFingerPageGesture) return;
    _fiveFingerPageGesture = false;
    _pageWheelTravel = 0;
    _fiveFingerDetentPosition = 0;
    _fiveFingerAngularTravel.clear();
    _pageGesturePointers.clear();
    if (mounted) setState(() {});
  }

  void _commitFiveFingerPageGesture() {
    if (!_fiveFingerPageGesture) return;
    final selectedPage =
        _pageWheelIndex != _fiveFingerStartPagePosition &&
            _pageWheelIndex >= 0 &&
            _pageWheelIndex < widget.pagePreviews.length
        ? widget.pagePreviews[_pageWheelIndex].pageIndex
        : null;
    _cancelFiveFingerPageGesture();
    if (selectedPage != null) {
      widget.callbacks.onPageSelected?.call(selectedPage);
    }
  }

  static double _angleAround(Offset center, Offset position) {
    final delta = position - center;
    var angle = math.atan2(delta.dy, delta.dx) + math.pi / 2;
    if (angle < 0) angle += math.pi * 2;
    return angle % (math.pi * 2);
  }

  int _pagePositionFor(int pageIndex) {
    final exact = widget.pagePreviews.indexWhere(
      (preview) => preview.pageIndex == pageIndex,
    );
    return exact >= 0
        ? exact
        : pageIndex.clamp(0, widget.pagePreviews.length - 1);
  }

  void _updatePageWheel(Offset position) {
    final pageCount = widget.pagePreviews.length;
    if (pageCount < 2) return;
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    final angle = geometry.angleFor(position);
    var delta = angle - _pageWheelLastAngle;
    if (delta > math.pi) delta -= math.pi * 2;
    if (delta < -math.pi) delta += math.pi * 2;
    _pageWheelLastAngle = angle;
    _pageWheelTravel += delta;

    _emitPageWheelDetents();
  }

  void _emitPageWheelDetents() {
    final pageCount = widget.pagePreviews.length;
    if (pageCount < 2) return;
    // About 17 degrees per detent feels deliberate on a large touch display
    // while still allowing a quick circular sweep through many pages.
    const detent = math.pi / 10.5;
    while (_pageWheelTravel.abs() >= detent) {
      final direction = _pageWheelTravel > 0 ? 1 : -1;
      _pageWheelTravel -= detent * direction;
      _pageWheelIndex = (_pageWheelIndex + direction) % pageCount;
      widget.callbacks.onPageSelected?.call(
        widget.pagePreviews[_pageWheelIndex].pageIndex,
      );
    }
  }

  Offset _clampCenter(Offset requested, {bool? keepFullSurfaceVisible}) {
    if (_availableSize.isEmpty) return requested;
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    return geometry.clampCenterToRegion(
      requested,
      regionSize: _availableSize,
      edgePadding: widget.edgePadding,
      // A menu's draggable object is its centre disc. Expanded rings may be
      // clipped, but must never reduce the usable drag range in a participant
      // half. Explicit true remains available for one-off callers.
      keepFullSurfaceVisible: keepFullSurfaceVisible ?? false,
    );
  }
}
