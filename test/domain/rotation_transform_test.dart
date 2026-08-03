import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flowboard_x/src/domain/domain.dart';
import 'package:flowboard_x/src/features/selection/selection_engine.dart';
import 'package:flowboard_x/src/features/editor/text_object_layout.dart';

void main() {
  final now = DateTime.utc(2026, 7, 23);

  group('Object rotation', () {
    test('maps local points, hit tests and bounds in rotated space', () {
      const transform = ObjectTransform(
        x: 10,
        y: 20,
        width: 100,
        height: 40,
        rotationRadians: math.pi / 2,
      );

      final world = transform.localToWorld(const Vec2(0, 0));
      expect(world.x, closeTo(80, .0001));
      expect(world.y, closeTo(-10, .0001));
      final localAgain = transform.worldToLocal(world);
      expect(localAgain.x, closeTo(0, .0001));
      expect(localAgain.y, closeTo(0, .0001));
      expect(transform.bounds.left, closeTo(40, .0001));
      expect(transform.bounds.top, closeTo(-10, .0001));
      expect(transform.bounds.width, closeTo(40, .0001));
      expect(transform.bounds.height, closeTo(100, .0001));
      expect(transform.containsWorld(const Vec2(60, 40)), isTrue);
      expect(transform.containsWorld(const Vec2(35, 40)), isFalse);
    });

    test('rotation and mirror flags survive document JSON round-trip', () {
      final page = BoardPage(
        id: 'page',
        name: 'Drehung',
        objects: [
          ImageObject(
            id: 'image',
            transform: const ObjectTransform(
              x: 100,
              y: 80,
              width: 320,
              height: 180,
              rotationRadians: math.pi / 3,
              flipX: true,
            ),
            assetId: 'asset',
            createdAt: now,
          ),
        ],
      );
      final document = WhiteboardDocument.create(
        id: 'rotation-json',
        now: now,
      ).copyWith(pages: [page]);
      const codec = DocumentCodec();

      final encoded = codec.encode(document);
      final transform = codec
          .decode(encoded)
          .currentPage
          .objects
          .single
          .transform;

      expect(transform.rotationRadians, closeTo(math.pi / 3, .0000001));
      expect(transform.flipX, isTrue);
      expect(transform.flipY, isFalse);
      final json = jsonDecode(encoded) as Map<String, Object?>;
      final pages = json['pages']! as List<Object?>;
      final pageJson = pages.single! as Map<String, Object?>;
      final objects = pageJson['objects']! as List<Object?>;
      final object = objects.single! as Map<String, Object?>;
      final transformJson = object['transform']! as Map<String, Object?>;
      expect(transformJson['rotationRadians'], isNotNull);
      expect(transformJson['flipX'], isTrue);
    });

    test(
      'command rotates objects, free ink and preserves local annotations',
      () {
        const originalTransform = ObjectTransform(
          x: 100,
          y: 100,
          width: 100,
          height: 50,
        );
        final freeStroke = InkStroke(
          id: 'free',
          points: const [InkPoint(x: 100, y: 100)],
          createdAt: now,
        );
        final localAnnotation = InkStroke(
          id: 'local',
          points: const [InkPoint(x: .25, y: .5)],
          width: .04,
          createdAt: now,
        );
        final page = BoardPage(
          id: 'page',
          name: 'Drehung',
          strokes: [freeStroke],
          objects: [
            ImageObject(
              id: 'image',
              transform: originalTransform,
              assetId: 'asset',
              createdAt: now,
            ),
          ],
          annotationLayers: [
            ObjectInkLayer(
              id: 'image.annotations',
              objectId: 'image',
              strokes: [localAnnotation],
            ),
          ],
        );
        final initial = WhiteboardDocument.create(
          id: 'rotation-command',
          now: now,
        ).copyWith(pages: [page]);
        final history = CommandHistory(initial);

        history.execute(
          TransformItemsCommand(
            'page',
            const ['image', 'free'],
            const TransformDelta(
              anchor: Vec2(150, 125),
              rotationRadians: math.pi / 2,
            ),
            now: now,
          ),
        );

        final rotated = history.document.currentPage;
        final object = rotated.objectById('image')!;
        expect(object.transform.rotationRadians, closeTo(math.pi / 2, .0001));
        expect(object.transform.bounds.left, closeTo(125, .0001));
        expect(object.transform.bounds.top, closeTo(75, .0001));
        expect(
          rotated.strokeById('free')!.points.single.x,
          closeTo(175, .0001),
        );
        expect(rotated.strokeById('free')!.points.single.y, closeTo(75, .0001));
        expect(
          rotated.annotationFor('image')!.strokes.single.points.single,
          localAnnotation.points.single,
        );

        history.undo();
        expect(
          history.document.currentPage.objectById('image')!.transform,
          originalTransform,
        );
        expect(
          history.document.currentPage.strokeById('free')!.points.single.x,
          100,
        );
      },
    );

    test('horizontal mirror affects scene content and is undoable', () {
      final page = BoardPage(
        id: 'page',
        name: 'Spiegel',
        strokes: [
          InkStroke(
            id: 'stroke',
            points: const [InkPoint(x: 120, y: 140)],
            createdAt: now,
          ),
        ],
        objects: [
          ShapeObject(
            id: 'shape',
            transform: const ObjectTransform(
              x: 100,
              y: 100,
              width: 100,
              height: 80,
            ),
            createdAt: now,
          ),
        ],
      );
      final initial = WhiteboardDocument.create(
        id: 'mirror-command',
        now: now,
      ).copyWith(pages: [page]);
      final history = CommandHistory(initial);

      history.execute(
        TransformItemsCommand(
          'page',
          const ['shape', 'stroke'],
          const TransformDelta(scaleX: -1, anchor: Vec2(150, 140)),
          now: now,
        ),
      );

      expect(
        history.document.currentPage.objectById('shape')!.transform.flipX,
        isTrue,
      );
      expect(
        history.document.currentPage.strokeById('stroke')!.points.single.x,
        180,
      );
      history.undo();
      expect(
        history.document.currentPage.objectById('shape')!.transform.flipX,
        isFalse,
      );
    });

    test('oriented scale follows a rotated object frame', () {
      const anchor = Vec2(100, 100);
      const delta = TransformDelta(
        scaleX: 2,
        scaleY: 1,
        anchor: anchor,
        scaleAxisRadians: math.pi / 2,
      );

      final alongRotatedX = delta.apply(const Vec2(100, 140));
      final perpendicular = delta.apply(const Vec2(140, 100));

      expect(alongRotatedX.x, closeTo(100, .0001));
      expect(alongRotatedX.y, closeTo(180, .0001));
      expect(perpendicular.x, closeTo(140, .0001));
      expect(perpendicular.y, closeTo(100, .0001));
      expect(
        TransformDelta.fromJson(delta.toJson()).scaleAxisRadians,
        closeTo(math.pi / 2, .0001),
      );
    });

    test('selection hit test rejects empty corners of a rotated AABB', () {
      final page = BoardPage(
        id: 'page',
        name: 'Treffer',
        objects: [
          ShapeObject(
            id: 'shape',
            transform: const ObjectTransform(
              x: 100,
              y: 100,
              width: 140,
              height: 20,
              rotationRadians: math.pi / 4,
            ),
            createdAt: now,
          ),
        ],
      );
      final engine = SelectionEngine();
      final bounds = page.objects.single.transform.bounds;

      expect(
        engine.candidatesAt(page, page.objects.single.transform.center),
        isNotEmpty,
      );
      expect(
        engine.candidatesAt(
          page,
          Vec2(bounds.left + 1, bounds.top + 1),
          tolerance: 0,
        ),
        isEmpty,
      );
    });

    test('text relayout keeps its orientation and mirror state', () {
      final text = TextObject(
        id: 'text',
        transform: const ObjectTransform(
          x: 40,
          y: 60,
          width: 300,
          height: 80,
          rotationRadians: math.pi / 6,
          flipX: true,
        ),
        text: 'Neu vermessener Text',
        createdAt: now,
      );

      final fitted = TextObjectLayout.fit(value: text);

      expect(fitted.rotationRadians, text.transform.rotationRadians);
      expect(fitted.flipX, isTrue);
      expect(fitted.flipY, isFalse);
    });
  });
}
