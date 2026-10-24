// 「规划今天」底部抽屉（F3 阶段一）：候选归集渲染（时段/理由）、超载警示、
// 空态、只读（不写库）。算法真值在 core（Rust 单测覆盖），这里锁 mock 镜像
// 与弹层接链。弹层数据加载是 initState 异步——测试要 pump 越过 mock 120ms
// 延迟；终态断言同步读 store（测试体内 await bridge 会撞假时钟死锁）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/plan_day_sheet.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showPlanDaySheet(context),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

/// 追加未分组任务（字段形状对齐 overdue_postpone_test 的手造行；
/// id 经 newEntity 自增，以返回行里的 id 作 store 键）
void _addTask(
  MockOrbitBridge bridge,
  String title, {
  int? dueOffsetMin,
  bool myDay = false,
  int? duration,
  int priority = 0,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final n = DateTime.fromMillisecondsSinceEpoch(now);
  final dayStart =
      DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
  final t = {
    ...bridge.store.newEntity('t'),
    'title': title,
    'description': null,
    'project_id': null,
    'priority': priority,
    'status': 'pending',
    'done': 0,
    'done_at': null,
    'due_date': dueOffsetMin == null
        ? null
        : dayStart + dueOffsetMin * Duration.millisecondsPerMinute,
    'start_date': null,
    'repeat_after': 0,
    'repeat_mode': 0,
    'percent_done': 0,
    'position': 100.0,
    'is_favorite': 0,
    'my_day_date': myDay ? dayStart : null,
    'duration_minutes': duration,
    'is_deleted': 0,
    'created_at': now,
    'updated_at': now,
    'deleted_at': null,
    'version': 1,
  };
  bridge.store.tasks[t['id'] as int] = t;
}

Future<void> _pumpOpen(WidgetTester tester) async {
  await tester.tap(find.text('打开'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('候选渲染：时段 + 理由（逾期/我的一天），且不写库', (tester) async {
    final bridge = MockOrbitBridge();
    _addTask(bridge, '逾期活', dueOffsetMin: -60, duration: 30);
    _addTask(bridge, '我的一天活', myDay: true, duration: 30);
    final store0 = {
      for (final e in bridge.store.tasks.entries)
        e.key: Map<String, dynamic>.from(e.value),
    };
    await tester.pumpWidget(_wrap(bridge));
    await _pumpOpen(tester);

    expect(find.text('逾期活'), findsOneWidget);
    expect(find.text('我的一天活'), findsOneWidget);
    // seed 自带逾期行：理由文案至少一处（本用例自造的逾期活必带）
    expect(find.text('已逾期'), findsWidgets);
    expect(find.text('我的一天'), findsWidgets);
    expect(find.textContaining('剩余可排'), findsOneWidget);
    // 只读：store 任务行未被改动（start_date 仍空、due 不变）
    for (final e in bridge.store.tasks.entries) {
      final before = store0[e.key]!;
      expect(e.value['start_date'], before['start_date']);
      expect(e.value['due_date'], before['due_date']);
    }
  });

  testWidgets('超载警示：大时长任务超容量给提示条', (tester) async {
    final bridge = MockOrbitBridge();
    _clearSeedCandidates(bridge);
    _addTask(bridge, '超大活', duration: 600);
    await tester.pumpWidget(_wrap(bridge));
    await _pumpOpen(tester);

    expect(find.textContaining('超出今日剩余容量'), findsOneWidget);
  });

  testWidgets('无候选：空态正反馈', (tester) async {
    final bridge = MockOrbitBridge();
    _clearSeedCandidates(bridge);
    await tester.pumpWidget(_wrap(bridge));
    await _pumpOpen(tester);

    expect(find.textContaining('没有可规划的任务'), findsOneWidget);
  });
}

/// 清掉 seed 自带的今天相关候选（既有任务今天截止带时长兜底），
/// 供空态/超载用例从干净队列出发
void _clearSeedCandidates(MockOrbitBridge bridge) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final n = DateTime.fromMillisecondsSinceEpoch(now);
  final dayStart = DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
  bridge.store.tasks.removeWhere(
    (_, t) =>
        (t['due_date'] != null &&
            (t['due_date'] as int) >= dayStart - 7 * 86400000 &&
            (t['due_date'] as int) < dayStart + 86400000) ||
        t['my_day_date'] != null ||
        t['duration_minutes'] != null,
  );
}
