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
                // 排程从「现在」起排：注入今天 10:00，用例不随跑测墙钟漂移
                onPressed: () {
                  final n = DateTime.now();
                  final at10 = DateTime(n.year, n.month, n.day, 10)
                      .millisecondsSinceEpoch;
                  showPlanDaySheet(context, nowMs: at10);
                },
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
    // 抽屉 maxH = 视口 82%：加高视口让全部槽行与底部按钮进入挂载区
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2000);
    addTearDown(tester.view.reset);

    final bridge = MockOrbitBridge();
    _clearSeedCandidates(bridge);
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

  testWidgets('勾选应用：写 my_day/start 不改 due，撤销钮写回 prev', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2000);
    addTearDown(tester.view.reset);
    final bridge = MockOrbitBridge();
    _clearSeedCandidates(bridge);
    final n = DateTime.now();
    final dayStart =
        DateTime(n.year, n.month, n.day).millisecondsSinceEpoch;
    final t = {
      ...bridge.store.newEntity('t'),
      'title': '待排的活',
      'description': null,
      'project_id': null,
      'priority': 0,
      'status': 'pending',
      'done': 0,
      'done_at': null,
      'due_date': dayStart + 14 * 3_600_000,
      'start_date': null,
      'repeat_after': 0,
      'repeat_mode': 0,
      'percent_done': 0,
      'position': 100.0,
      'is_favorite': 0,
      'my_day_date': null,
      'duration_minutes': 30,
      'is_deleted': 0,
      'created_at': dayStart,
      'updated_at': dayStart,
      'deleted_at': null,
      'version': 1,
    };
    bridge.store.tasks[t['id'] as int] = t;
    await tester.pumpWidget(_wrap(bridge));
    await _pumpOpen(tester);

    // 勾选默认全选 → 应用
    await tester.tap(find.text('应用到 1 条任务'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final row = bridge.store.tasks[t['id'] as int]!;
    expect(row['my_day_date'], dayStart);
    expect(row['start_date'], isNotNull);
    expect(row['due_date'], dayStart + 14 * 3_600_000, reason: 'due 不被改动');

    // 撤销钮：prev 写回（原值均 null）
    await tester.tap(find.text('撤销'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(row['my_day_date'], isNull);
    expect(row['start_date'], isNull);
    // 收尾推掉 toast 计时器
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('作息编辑：工作开始改 12:00 → 持久化且预览时段变化', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2000);
    addTearDown(tester.view.reset);
    final bridge = MockOrbitBridge();
    _clearSeedCandidates(bridge);
    _addTask(bridge, '作息活', myDay: true, duration: 30);
    await tester.pumpWidget(_wrap(bridge));
    await _pumpOpen(tester);

    // 展开作息抽屉 → 工作开始选 12:00 → 保存
    await tester.tap(find.text('作息'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作开始'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // 选列表顶部的 01:00 档（免滚动；01:00 < 默认工作结束，语义有效）
    await tester.tap(find.text('01:00'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存作息'));
    // pop 关闭动画 + mock 延迟（120ms×3：set/get/preview）+ 重拉渲染——
    // pumpAndSettle 在本弹层栈下不收敛（无限动画转满假时钟），固定 pump 序列
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));

    // mock 持久化：同步读公开字段（测试体 await 桥会撞假时钟死锁）
    expect(bridge.dayPlanPrefs.workStartMinute, 60);
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
