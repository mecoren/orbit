import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/test_data_page.dart';

import 'support/orbit_test_app.dart';

/// 测试数据页（仅 debug 入口；桌面「设置 → 测试数据」同口径）
///
/// 钉三件事：mock 桥按 uuid 前缀幂等生成/清除、手工数据不受影响、
/// 页面两步确认后结果卡片能回显。真 Rust 侧的批量写入由 core 单测覆盖。
Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: const TestDataPage()),
    );

/// 走完 3 秒冷静期：确认钮从「请阅读后果（3s）」回落为正式文案
Future<void> _passHold(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump();
}

void main() {
  test('mock 测试数据：生成/清除按 uuid 前缀收敛，手工数据不受影响', () async {
    final bridge = MockOrbitBridge();
    final manual = await bridge.todoTaskCreate(
      const TodoTaskCreateInput(title: '手工任务'),
    );
    final before = (await bridge.todoTaskList(const ListFilter())).length;

    final seeded = await bridge.devSeedDemoData(const DevSeedPlan(tasks: 120));
    expect(seeded.created.tasks, 120);
    expect(seeded.created.projects, 2);
    expect(seeded.created.labels, 2);
    expect(seeded.created.subtasks, greaterThan(0));
    expect(seeded.created.reminders, greaterThan(0));
    expect(seeded.created.comments, greaterThan(0));
    expect(seeded.created.taskLabels, greaterThan(0));
    expect(seeded.created.taskRelations, greaterThan(0));

    final rows = await bridge.todoTaskList(const ListFilter());
    expect(rows.length, greaterThan(before));
    expect(rows.any((t) => t.id == manual.id), isTrue, reason: '手工任务保留');

    // 幂等：重复生成先清上一批示例行，不叠数据
    final again = await bridge.devSeedDemoData(const DevSeedPlan(tasks: 120));
    expect(again.cleared.tasks, 120);
    expect((await bridge.todoTaskList(const ListFilter())).length,
        greaterThan(before));

    final cleared = await bridge.devSeedClear();
    expect(cleared.removed.tasks, 120);
    final finalRows = await bridge.todoTaskList(const ListFilter());
    expect(finalRows.length, before, reason: '示例行清空、手工数据保留');
    expect(finalRows.any((t) => t.title.startsWith('【示例】')), isFalse);
    expect(finalRows.any((t) => t.id == manual.id), isTrue);
  });

  testWidgets('测试数据页：生成与清除都走两步确认，结果卡回显', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pumpAndSettle();

    expect(find.text('生成规模'), findsOneWidget);
    expect(find.text('一键生成'), findsOneWidget);
    expect(find.text('清除示例'), findsOneWidget);

    // 第一步说明范围 → 第二步再次确认；每步都有 3 秒冷静期，第二步取消不写库
    await tester.tap(find.text('一键生成'));
    await tester.pumpAndSettle();
    expect(find.text('生成示例数据（第 1 步 / 共 2 步）'), findsOneWidget);
    expect(find.text('请阅读后果（3s）'), findsOneWidget);
    await _passHold(tester);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('再次确认生成（第 2 步 / 共 2 步）'), findsOneWidget);
    expect(find.text('请阅读后果（3s）'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('生成结果'), findsNothing, reason: '第二步取消不得写库');

    // 两步都确认（且各自走完冷静期）后才执行
    await tester.tap(find.text('一键生成'));
    await tester.pumpAndSettle();
    await _passHold(tester);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await _passHold(tester);
    await tester.tap(find.text('确认生成'));
    await tester.pumpAndSettle();

    expect(find.text('生成结果'), findsOneWidget);
    expect(find.text('任务（含回收站）'), findsOneWidget);
    await drainToastTimers(tester);

    await tester.tap(find.text('清除示例'));
    await tester.pumpAndSettle();
    expect(find.text('清除示例数据（第 1 步 / 共 2 步）'), findsOneWidget);
    await _passHold(tester);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('再次确认清除（第 2 步 / 共 2 步）'), findsOneWidget);
    await _passHold(tester);
    await tester.tap(find.text('确认清除'));
    await tester.pumpAndSettle();

    expect(find.text('清理结果'), findsOneWidget);
    expect(find.text('生成结果'), findsNothing);
    await drainToastTimers(tester);
  });
}
