// 「今天」页头视图选择菜单的玻璃链路性能契约（2026-11-09）
//
// 真机反馈「视图选择弹窗掉帧」：弹层宿主挂在页面树（背景捕获子树）内时，
// 库内形变承载每帧重建都会让捕获树重录整页背景快照（toImageSync），
// 640ms 入场窗口实测 40 次；同样的菜单经根 Overlay 直挂只有首帧 2 次。
// 本用例用 MiuixLayerBackdrop 的监听器数重录次数，钉住这条防回归锚点。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_page_header.dart';

import '../support/orbit_test_app.dart';

Finder _headerText(String text) => find.descendant(
  of: find.byType(OrbitPageHeader),
  matching: find.text(text),
);

Widget _host(MockOrbitBridge bridge, MiuixLayerBackdrop backdrop) =>
    ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(
        home: OrbitGlassScope(
          backdrop: backdrop,
          child: OrbitScrollAwareBackdropCapture(
            backdrop: backdrop,
            child: const SubListScreen(
              query: TaskFilterInput(quickView: QuickViewKey.today),
              showBack: false,
              titleOverride: '今天',
            ),
          ),
        ),
      ),
    );

void main() {
  setUp(() async {
    LocalPrefs.resetForTest();
    // 测试进程不会像生产壳那样预加载 OS4 shader；先装好，避免异步装载
    // 本身触发的重建混进快照计数。
    await MiuixGlassRendering.load();
  });
  tearDown(LocalPrefs.resetForTest);

  testWidgets('视图菜单入场期间不逐帧重录整页背景快照', (tester) async {
    final backdrop = MiuixLayerBackdrop();
    addTearDown(backdrop.dispose);
    var snapshots = 0;
    backdrop.addListener(() => snapshots++);

    await tester.pumpWidget(
      _host(MockOrbitBridge()..latency = Duration.zero, backdrop),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final before = snapshots;
    await tester.tap(_headerText('今天'));
    // 覆盖 320ms 形变窗 + 库内弹簧尾巴；逐帧推进才能量到中间帧的重录。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.text('近7天'), findsOneWidget, reason: '视图菜单应仍处于展开态');
    expect(
      snapshots - before,
      lessThanOrEqualTo(2),
      reason: '弹层形变窗未冻结背景捕获会逐帧 toImageSync 整页（真机掉帧主因）',
    );
    // 放行冻结窗的计时器，避免用例收尾时留下 pending Timer
    await tester.pump(const Duration(milliseconds: 100));
  });
}
