import 'package:flowboard_x/src/features/radial_menu/radial_menu.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const geometry = RadialMenuGeometry(Size.square(366));
  const region = Size(390, 560);

  test('compact bounds reserve only the visible center disc', () {
    final result = geometry.clampCenterToRegion(
      const Offset(10000, 10000),
      regionSize: region,
      edgePadding: 12,
      keepFullSurfaceVisible: false,
    );
    final margin = geometry.centerRadius + 12;

    expect(result.dx, closeTo(region.width - margin, .0001));
    expect(result.dy, closeTo(region.height - margin, .0001));
  });

  test('expanded bounds reserve the complete radial surface', () {
    final result = geometry.clampCenterToRegion(
      const Offset(10000, 10000),
      regionSize: region,
      edgePadding: 12,
      keepFullSurfaceVisible: true,
    );
    const fullMargin = 366 / 2 + 12;

    expect(result.dx, closeTo(region.width - fullMargin, .0001));
    expect(result.dy, closeTo(region.height - fullMargin, .0001));
  });

  test('undersized and malformed regions fall back to a finite center', () {
    final undersized = geometry.clampCenterToRegion(
      const Offset(double.nan, double.infinity),
      regionSize: const Size(240, 180),
      edgePadding: 12,
      keepFullSurfaceVisible: true,
    );

    expect(undersized, const Offset(120, 90));
    expect(undersized.dx.isFinite, isTrue);
    expect(undersized.dy.isFinite, isTrue);
  });
}
