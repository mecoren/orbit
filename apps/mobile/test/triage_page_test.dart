// 「收件箱分诊」页（F2）widget 冒烟：归入项目落库出队 / 今天 18 点 /
// 撤销拉回 / 删除进回收站 / 空收件箱正反馈。
//
// 页头返回走 Navigator.maybePop，测试壳须有 GoRouter 祖先（同
// review_center_page_test 的 _wrap 范式）；终态断言走同步读 store
//（测试体内 await bridge 会撞假时钟死锁）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/triage_page.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) {
  final router = GoRouter(
    initialLocation: '/triage',
    routes: [
      GoRoute(
        path: '/triage',
        builder: (_, _) => const TriagePage(),
      ),
    ],
  );
  return ProviderScope(
    overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
    child: orbitTestAppRouter(routerConfig: router),
  );
}

/// 清掉 seed 自带的未分组任务（mock 种子里有「未分组想法」等行，
/// 队列序由 position 决定——不清会让断言错位到 seed 卡上）
void _clearSeededUngrouped(MockOrbitBridge bridge) {
  bridge.store.tasks.removeWhere((_, t) => t['project_id'] == null);
}

/// 追加一条未分组任务到 mock store（字段形状对齐 store.task 工厂的最小集）
Map<String, dynamic> _addUngrouped(MockOrbitBridge bridge, String title,
    {double position = 500}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final t = {
    ...bridge.store.newEntity('t'),
    'title': title,
    'description': null,
    'project_id': null,
    'priority': 0,
    'status': 'pending',
    'done': 0,
    'done_at': null,
    'due_date': null,
    'start_date': null,
    'repeat_after': 0,
    'repeat_mode': 0,
    'percent_done': 0,
    'position': position,
    'is_favorite': 0,
    'my_day_date': null,
    'is_deleted': 0,
    'created_at': now,
    'updated_at': now,
    'deleted_at': null,
    'version': 1,
  };
  bridge.store.tasks[t['id'] as int] = t;
  return t;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('归入项目：抽屉选项目落库出队，下一张卡就位', (tester) async {
    final bridge = MockOrbitBridge();
    _clearSeededUngrouped(bridge);
    final first = _addUngrouped(bridge, '分诊甲');
    _addUngrouped(bridge, '分诊乙', position: 600);
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    expect(find.text('分诊甲'), findsOneWidget);
    expect(find.text('0 / 2'), findsOneWidget);

    await tester.tap(find.text('归入项目…'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // seed 项目「工作」出现在抽屉里
    await tester.tap(find.text('工作'));
    await _settle(tester);

    // 出队到下一张 + 库侧 project_id 落库
    expect(find.text('分诊乙'), findsOneWidget);
    expect(bridge.store.tasks[first['id'] as int]!['project_id'], isNotNull);
  });

  testWidgets('今天：due 落当日 18 点并出队到清空正反馈', (tester) async {
    final bridge = MockOrbitBridge();
    _clearSeededUngrouped(bridge);
    final task = _addUngrouped(bridge, '排期甲');
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await tester.tap(find.text('今天'));
    await _settle(tester);

    expect(find.textContaining('收件箱已清空'), findsOneWidget);
    expect(find.textContaining('已分诊 1'), findsOneWidget);
    final due = bridge.store.tasks[task['id'] as int]!['due_date'] as int;
    final d = DateTime.fromMillisecondsSinceEpoch(due);
    expect(d.hour, 18);
    expect(d.minute, 0);
    expect(d.day, DateTime.now().day);
  });

  testWidgets('撤销：归入项目后页头撤销拉回卡片并回未分组', (tester) async {
    final bridge = MockOrbitBridge();
    _clearSeededUngrouped(bridge);
    final task = _addUngrouped(bridge, '分诊甲');
    _addUngrouped(bridge, '分诊乙', position: 600);
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await tester.tap(find.text('归入项目…'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作'));
    await _settle(tester);
    expect(find.text('分诊乙'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await _settle(tester);
    // 卡片拉回（撤销 move 后 0/2 回到分诊甲）+ 库侧回未分组
    expect(find.text('分诊甲'), findsOneWidget);
    expect(bridge.store.tasks[task['id'] as int]!['project_id'], isNull);
  });

  testWidgets('删除：确认抽屉 → 软删进回收站（is_deleted=1）', (tester) async {
    final bridge = MockOrbitBridge();
    _clearSeededUngrouped(bridge);
    final task = _addUngrouped(bridge, '待删甲');
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除', findRichText: true).last);
    await _settle(tester);

    expect(find.textContaining('收件箱已清空'), findsOneWidget);
    expect(bridge.store.tasks[task['id'] as int]!['is_deleted'], 1);
    // 收尾推掉撤销 toast 计时器
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('空收件箱：直接给清空正反馈', (tester) async {
    final bridge = MockOrbitBridge();
    _clearSeededUngrouped(bridge);
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);
    expect(find.textContaining('收件箱已清空'), findsOneWidget);
    expect(find.text('归入项目…'), findsNothing);
  });
}
