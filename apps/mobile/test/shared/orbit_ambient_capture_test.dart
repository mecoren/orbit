// 常驻加载动效的背景捕获契约（2026-11-09）
//
// 审计发现：骨架呼吸与 spinner 都是「无界逐帧重绘」，位于捕获子树内时
// 每帧都会让整页背景快照重录（40 帧探针实测 40 次），与视图菜单形变窗
// 同根因。滚动/键盘/锚定弹层三档窗口都拦不住它们——加载态没有滚动通知、
// 没有键盘、没有弹层。由 `OrbitCapturePause` 在组件挂载期持有一个暂停令牌，
// 加载结束释放并补录一次；本用例钉住「常驻动画期零重录」。下拉刷新等待态
// 的绕行点是第三处同源常驻动画，一并纳入守卫。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_page_header.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_pull_to_refresh.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_skeleton.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_spinner.dart';

import '../support/orbit_test_app.dart';

Widget _host(MiuixLayerBackdrop backdrop, Widget body) => orbitTestApp(
  home: OrbitGlassScope(
    backdrop: backdrop,
    child: OrbitScrollAwareBackdropCapture(
      backdrop: backdrop,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: body),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: OrbitPageHeader(title: '审计'),
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() async {
    await MiuixGlassRendering.load();
  });

  for (final scenario in <(String, Widget, Type)>[
    ('骨架呼吸', const Center(child: OrbitSkeleton.line(width: 200)), OrbitSkeleton),
    ('常驻 spinner', const Center(child: OrbitSpinner(size: 32)), OrbitSpinner),
  ]) {
    final (name, body, widgetType) = scenario;
    testWidgets('$name 期间不逐帧重录整页背景快照', (tester) async {
      final backdrop = MiuixLayerBackdrop();
      addTearDown(backdrop.dispose);
      var snapshots = 0;
      backdrop.addListener(() => snapshots++);

      await tester.pumpWidget(_host(backdrop, body));
      await tester.pump(const Duration(milliseconds: 300));
      final before = snapshots;

      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(find.byType(widgetType), findsOneWidget, reason: '$name 应仍在树上');
      expect(
        snapshots - before,
        lessThanOrEqualTo(2),
        reason: '$name 是常驻逐帧动画，未冻结捕获会每帧 toImageSync 整页',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('下拉刷新等待期不逐帧重录整页背景快照', (tester) async {
    final backdrop = MiuixLayerBackdrop();
    addTearDown(backdrop.dispose);
    var snapshots = 0;
    backdrop.addListener(() => snapshots++);
    final never = Completer<void>();

    await tester.pumpWidget(
      _host(
        backdrop,
        OrbitPullToRefresh(
          onRefresh: () => never.future,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [SizedBox(height: 800)],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('正在刷新…'), findsOneWidget, reason: '应停在刷新等待态');
    final before = snapshots;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      snapshots - before,
      lessThanOrEqualTo(2),
      reason: '刷新期绕行点常驻逐帧重绘，未冻结捕获会每帧 toImageSync 整页',
    );

    never.complete();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
