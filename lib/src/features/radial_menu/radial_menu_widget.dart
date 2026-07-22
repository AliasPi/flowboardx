import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
  late RadialMenuController _controller;
  late bool _ownsController;
  late final AnimationController _openAnimation;
  late final AnimationController _submenuAnimation;
  late final AnimationController _tailAnimation;
  late bool _lastOpen;
  late RadialMenuBranch? _lastBranch;

  Offset? _centerPosition;
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
  final Map<int, Offset> _menuPointers = <int, Offset>{};
  bool _fiveFingerPageGesture = false;
  bool _suppressMenuActivation = false;
  RadialHitTarget _hovered = RadialHitTarget.none;
  RadialHitTarget _pressed = RadialHitTarget.none;

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
        );
        _centerPosition = _clampCenter(_centerPosition!);

        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: _centerPosition!.dx - _diameter / 2,
              top: _centerPosition!.dy - _diameter / 2,
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
          ],
        );
      },
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
        onPointerDown: _handleMenuPointerDown,
        onPointerMove: _handleMenuPointerMove,
        onPointerUp: _handleMenuPointerEnd,
        onPointerCancel: _handleMenuPointerEnd,
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
          onPanDown: (details) {
            _panStartTarget = painter.hitTargetAt(
              details.localPosition,
              Size.square(_diameter),
            );
            _panDownGlobalPosition = details.globalPosition;
            _panDownLocalPosition = details.localPosition;
            _centerAtPanDown = _centerPosition!;
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
                _moveCenterTo(_centerPosition! + details.delta);
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
    if (fallbackTarget.isInteractive) {
      unawaited(_activateTarget(fallbackTarget));
    }
  }

  void _moveCenterTo(Offset requested) {
    final next = _clampCenter(requested);
    if (next == _centerPosition) return;
    setState(() => _centerPosition = next);
    widget.callbacks.onPositionChanged?.call(next);
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
        _updatePen(
          _controller.penSettings.copyWith(type: RadialPenType.values[index]),
        );
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
    return List<RadialPagePreview>.unmodifiable(result);
  }

  void _beginPageWheel(Offset position) {
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    _pageWheelLastAngle = geometry.angleFor(position);
    _pageWheelTravel = 0;
    _pageWheelIndex = widget.pagePreviews.isEmpty
        ? 0
        : widget.currentPageIndex.clamp(0, widget.pagePreviews.length - 1);
  }

  void _handleMenuPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _menuPointers[event.pointer] = event.localPosition;
    if (_fiveFingerPageGesture ||
        _menuPointers.length < 5 ||
        !_controller.isOpen ||
        widget.pagePreviews.length < 2) {
      return;
    }
    _fiveFingerPageGesture = true;
    _suppressMenuActivation = true;
    _dragMode = _DragMode.none;
    _panStarted = false;
    _pageWheelTravel = 0;
    _pageWheelIndex = widget.currentPageIndex.clamp(
      0,
      widget.pagePreviews.length - 1,
    );
    _controller.setBranch(RadialMenuBranch.pages);
    if (_pressed.isInteractive && mounted) {
      setState(() => _pressed = RadialHitTarget.none);
    }
  }

  void _handleMenuPointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    final previous = _menuPointers[event.pointer];
    _menuPointers[event.pointer] = event.localPosition;
    if (!_fiveFingerPageGesture ||
        previous == null ||
        _menuPointers.length < 5) {
      return;
    }
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    var delta =
        geometry.angleFor(event.localPosition) - geometry.angleFor(previous);
    if (delta > math.pi) delta -= math.pi * 2;
    if (delta < -math.pi) delta += math.pi * 2;
    _pageWheelTravel += delta / _menuPointers.length;
    _emitPageWheelDetents();
  }

  void _handleMenuPointerEnd(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _menuPointers.remove(event.pointer);
    if (_fiveFingerPageGesture && _menuPointers.length < 5) {
      _fiveFingerPageGesture = false;
      _pageWheelTravel = 0;
    }
    if (_menuPointers.isEmpty && _suppressMenuActivation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _menuPointers.isEmpty) {
          _suppressMenuActivation = false;
        }
      });
    }
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
      widget.callbacks.onPageSelected?.call(_pageWheelIndex);
    }
  }

  Offset _clampCenter(Offset requested) {
    if (_availableSize.isEmpty) return requested;
    final geometry = RadialMenuGeometry(Size.square(_diameter));
    final margin = geometry.centerRadius + widget.edgePadding;
    final minX = margin;
    final maxX = _availableSize.width - margin;
    final minY = margin;
    final maxY = _availableSize.height - margin;
    return Offset(
      minX <= maxX ? requested.dx.clamp(minX, maxX) : _availableSize.width / 2,
      minY <= maxY ? requested.dy.clamp(minY, maxY) : _availableSize.height / 2,
    );
  }
}
