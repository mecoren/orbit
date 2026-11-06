// 悬浮新建钮：玻璃档三态（OS4 采样 / 首帧未就绪 / 无采样器）+ 点击长按语义。
// 2026-11-06 真机反馈「怎么没有玻璃效果」：原实现仅在有采样器且快照就绪时
// 才走玻璃，否则定格成实心强调色圆片，故三态一律不允许回落实心。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_fab.dart';
import 'support/orbit_test_app.dart';

void _noop() {}

Widget _harness(Widget child) => orbitTestApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('实心档：miuix FAB + 强调色底，不叠玻璃', (tester) async {
    await tester.pumpWidget(
      _harness(
        const OrbitFab(onPressed: _noop, accentColor: Color(0xFF4E8CFF)),
      ),
    );

    expect(find.byType(MiuixFloatingActionButton), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('玻璃档无采样器：走实时模糊，不回退实心 FAB', (tester) async {
    await tester.pumpWidget(
      _harness(
        const OrbitFab(
          onPressed: _noop,
          accentColor: Color(0xFF4E8CFF),
          glass: true,
        ),
      ),
    );

    expect(find.byType(MiuixFloatingActionButton), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('玻璃档快照未就绪（首帧）：仍是实时模糊，不落成实心', (tester) async {
    final backdrop = MiuixLayerBackdrop();
    addTearDown(backdrop.dispose);

    await tester.pumpWidget(
      _harness(
        OrbitFab(
          onPressed: _noop,
          accentColor: const Color(0xFF4E8CFF),
          glass: true,
          backdrop: backdrop,
        ),
      ),
    );

    expect(backdrop.snapshot, isNull);
    expect(find.byType(MiuixFloatingActionButton), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('玻璃档：点击与长按都生效', (tester) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(
      _harness(
        OrbitFab(
          onPressed: () => taps++,
          onLongPress: () => longPresses++,
          accentColor: const Color(0xFF4E8CFF),
          glass: true,
        ),
      ),
    );

    await tester.tap(find.byIcon(OrbitIcons.add));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 1);

    await tester.longPress(find.byIcon(OrbitIcons.add));
    await tester.pump(const Duration(milliseconds: 400));
    expect(longPresses, 1);
  });
}
