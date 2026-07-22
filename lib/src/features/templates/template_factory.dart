import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../../domain/model/board_object.dart';
import '../../domain/model/document.dart';
import '../../domain/model/geometry.dart';
import '../../domain/model/ink.dart';

class TemplateDefinition {
  const TemplateDefinition({
    required this.kind,
    required this.title,
    required this.description,
    required this.iconName,
  });

  final TemplateKind kind;
  final String title;
  final String description;
  final String iconName;
}

class TemplateFactory {
  TemplateFactory({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  static const definitions = [
    TemplateDefinition(
      kind: TemplateKind.overlappingCircles,
      title: 'Zwei Kreise',
      description: 'Vergleich mit gemeinsamer Schnittmenge',
      iconName: 'overlap',
    ),
    TemplateDefinition(
      kind: TemplateKind.mindMap,
      title: 'Mindmap',
      description: 'Zentrum mit sechs verbundenen Ideenblasen',
      iconName: 'hub',
    ),
    TemplateDefinition(
      kind: TemplateKind.primarySchoolLines,
      title: 'Grundschullinien',
      description: 'Schreiblinien mit farbiger Grundlinie',
      iconName: 'lines',
    ),
    TemplateDefinition(
      kind: TemplateKind.vennDiagram,
      title: 'Venn-Diagramm',
      description: 'Drei Mengen und ihre Schnittbereiche',
      iconName: 'venn',
    ),
  ];

  final Uuid _uuid;

  BoardPage createPage(TemplateKind kind, {required int pageNumber}) {
    final pageId = _uuid.v4();
    final generated = switch (kind) {
      TemplateKind.overlappingCircles => _overlappingCircles(),
      TemplateKind.mindMap => _mindMap(),
      TemplateKind.primarySchoolLines => _schoolLines(),
      TemplateKind.vennDiagram => _venn(),
    };
    return BoardPage(
      id: pageId,
      name: 'Seite $pageNumber · ${_title(kind)}',
      objects: generated.$1,
      strokes: generated.$2,
      template: TemplateInstance(id: _uuid.v4(), kind: kind),
    );
  }

  (List<BoardObject>, List<InkStroke>) _overlappingCircles() => (
    [
      _ellipse(520, 270, 560, 560, fill: 0x1F35A7FF, stroke: 0xFF267BC5),
      _ellipse(840, 270, 560, 560, fill: 0x1FF4AF4B, stroke: 0xFFD68A20),
    ],
    const [],
  );

  (List<BoardObject>, List<InkStroke>) _venn() => (
    [
      _ellipse(520, 190, 520, 520, fill: 0x1F4A90E2, stroke: 0xFF2F70BB),
      _ellipse(870, 190, 520, 520, fill: 0x1FEA6A6A, stroke: 0xFFC54B4B),
      _ellipse(695, 480, 520, 520, fill: 0x1F55B881, stroke: 0xFF358B5D),
    ],
    const [],
  );

  (List<BoardObject>, List<InkStroke>) _mindMap() {
    const center = Vec2(960, 540);
    const bubbles = [
      ObjectTransform(x: 280, y: 160, width: 330, height: 170),
      ObjectTransform(x: 795, y: 100, width: 330, height: 170),
      ObjectTransform(x: 1310, y: 160, width: 330, height: 170),
      ObjectTransform(x: 280, y: 750, width: 330, height: 170),
      ObjectTransform(x: 795, y: 810, width: 330, height: 170),
      ObjectTransform(x: 1310, y: 750, width: 330, height: 170),
    ];
    final objects = <BoardObject>[
      _ellipse(770, 410, 380, 260, fill: 0x224DE2B1, stroke: 0xFF209A76),
      for (final bubble in bubbles)
        ShapeObject(
          id: _uuid.v4(),
          transform: bubble,
          shape: ShapeKind.ellipse,
          fillArgb: 0x0F000000,
          strokeArgb: 0xFF66737B,
          strokeWidth: 4,
        ),
    ];
    const centerRadius = Vec2(190, 130);
    final strokes = <InkStroke>[
      for (final bubble in bubbles)
        _line(
          _ellipseBoundary(center, centerRadius, bubble.bounds.center),
          _ellipseBoundary(bubble.bounds.center, const Vec2(165, 85), center),
          width: 4,
          color: 0xFF66737B,
        ),
    ];
    return (objects, strokes);
  }

  (List<BoardObject>, List<InkStroke>) _schoolLines() {
    final strokes = <InkStroke>[];
    for (var group = 0; group < 8; group++) {
      final top = 100.0 + group * 120;
      strokes
        ..add(
          _line(Vec2(100, top), Vec2(1820, top), width: 2, color: 0xFF9AC7F5),
        )
        ..add(
          _line(
            Vec2(100, top + 40),
            Vec2(1820, top + 40),
            width: 1.5,
            color: 0xFFAFCFEB,
          ),
        )
        ..add(
          _line(
            Vec2(100, top + 80),
            Vec2(1820, top + 80),
            width: 2.5,
            color: 0xFFE18484,
          ),
        );
    }
    return (const [], strokes);
  }

  ShapeObject _ellipse(
    double x,
    double y,
    double width,
    double height, {
    required int fill,
    required int stroke,
  }) => ShapeObject(
    id: _uuid.v4(),
    transform: ObjectTransform(x: x, y: y, width: width, height: height),
    shape: width == height ? ShapeKind.circle : ShapeKind.ellipse,
    fillArgb: fill,
    strokeArgb: stroke,
    strokeWidth: 5,
  );

  InkStroke _line(
    Vec2 from,
    Vec2 to, {
    required double width,
    required int color,
  }) => InkStroke(
    id: _uuid.v4(),
    points: [
      InkPoint(x: from.x, y: from.y),
      InkPoint(x: to.x, y: to.y),
    ],
    colorArgb: color,
    width: width,
    type: InkToolType.straightLine,
    authorId: 'template',
  );

  Vec2 _ellipseBoundary(Vec2 center, Vec2 radii, Vec2 toward) {
    final dx = toward.x - center.x;
    final dy = toward.y - center.y;
    final denominator =
        (dx * dx) / (radii.x * radii.x) + (dy * dy) / (radii.y * radii.y);
    if (denominator <= 0) return center;
    final scale = 1 / math.sqrt(denominator);
    return Vec2(center.x + dx * scale, center.y + dy * scale);
  }

  String _title(TemplateKind kind) =>
      definitions.firstWhere((definition) => definition.kind == kind).title;
}
