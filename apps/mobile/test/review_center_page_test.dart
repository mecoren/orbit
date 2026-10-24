// 「回顾中心」页（F1 项目回顾节奏）：
// - 到期项目按逾期降序列出（标题/周期/上次回顾/未完成计数/逾期徽标）；
// - 「已回顾」标记后行退场（provider 失效链）；
// - 「稍后一周」暂缓后行退场；
// - 无到期项目时空态正反馈。
//
// 页头返回走 Navigator.maybePop，测试壳须有 GoRouter 祖先（同
// project_edit_page_test 的 _wrap 范式）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/review_center_page.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) {
  final router = GoRouter(
    initialLocation: '/review',
    routes: [
      GoRoute(
        path: '/review',
        builder: (_, _) => const ReviewCenterPage(),
      ),
    ],
  );
  return ProviderScope(
    overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
    child: orbitTestAppRouter(routerConfig: router),
  );
}

/// 把第一个项目拨成「周期 7 天、上次回顾 10 天前」（到期 3 天，正午基点防 DST）
void _backdateFirst(MockOrbitBridge bridge, {int interval = 7, int ago = 10}) {
  final p = bridge.store.projects.values.first;
  p['review_interval_days'] = interval;
  final n = DateTime.now();
  final noon = DateTime(n.year, n.month, n.day, 12).millisecondsSinceEpoch;
  p['review_last_at'] = noon - ago * 86400000;
}

/// 越过 MockOrbitBridge 的人为延迟（120ms）与 provider 失效后的重拉
Future<void> _settleBridge(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('到期项目列出行：标题/周期/逾期徽标；已回顾后行退场', (tester) async {
    final bridge = MockOrbitBridge();
    _backdateFirst(bridge);
    await tester.pumpWidget(_wrap(bridge));
    await _settleBridge(tester);

    expect(find.text('工作'), findsOneWidget);
    expect(find.textContaining('每周'), findsWidgets);
    expect(find.text('已逾期 3 天'), findsOneWidget);
    expect(find.text('今天到期'), findsNothing);

    // 库侧终态走同步读 store 断言：测试体内直接 await bridge 查询会撞
    // 假时钟死锁（mock 的 120ms 延迟是 fake timer，await 阻塞期间不推进）
    final project = bridge.store.projects.values.first;
    final beforeMs = DateTime.now().millisecondsSinceEpoch;
    await tester.tap(find.text('已回顾'));
    await _settleBridge(tester);
    expect(find.text('工作'), findsNothing);
    expect(find.textContaining('没有待回顾的项目'), findsOneWidget);
    expect(project['review_last_at'] as int, greaterThan(beforeMs - 60_000),
        reason: 'last_at 已推进到当前（下次到期 = 今天 + 周期）');
    expect(project['review_snooze_until'], isNull);
  });

  testWidgets('稍后一周：行退场且暂缓期间不再到期', (tester) async {
    final bridge = MockOrbitBridge();
    _backdateFirst(bridge);
    await tester.pumpWidget(_wrap(bridge));
    await _settleBridge(tester);

    await tester.tap(find.text('稍后一周'));
    await _settleBridge(tester);
    expect(find.text('工作'), findsNothing);
    final p = bridge.store.projects.values.first;
    expect(p['review_snooze_until'], isNotNull);
  });

  testWidgets('无到期项目：空态正反馈（seed 项目默认关闭回顾）', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settleBridge(tester);
    expect(find.textContaining('没有待回顾的项目'), findsOneWidget);
    expect(find.text('开始回顾'), findsNothing);
  });

  testWidgets('开始回顾打开三步向导弹层（复用周回顾组件）', (tester) async {
    final bridge = MockOrbitBridge();
    _backdateFirst(bridge);
    final project = bridge.store.projects.values.first;
    final backdatedLastAt = project['review_last_at'] as int;
    await tester.pumpWidget(_wrap(bridge));
    await _settleBridge(tester);

    await tester.tap(find.text('开始回顾'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // 向导第一步标题可见（sheet 弹层弹出即链路通；完整三步流由
    // weekly_review_sheet_test 覆盖，此处只锁回顾中心的接链）
    expect(find.text('周回顾 · 逾期任务'), findsOneWidget);
    // 半途下滑关闭不标记已回顾（行保留 + last_at 原值未推进）
    await tester.drag(
        find.text('周回顾 · 逾期任务'), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('工作'), findsOneWidget);
    expect(project['review_last_at'], backdatedLastAt,
        reason: '中途退出不推进周期');
  });
}
