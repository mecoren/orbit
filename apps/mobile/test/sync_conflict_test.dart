// 冲突败方副本链路测试（03 文档 §八 遗留项）：MockOrbitBridge 语义 + 页面冒烟。
//
// 覆盖：
// - 列表/计数（默认只回待处理）与恢复 → 离开待处理列表；
// - 忽略 / 清空 / 不存在的 id 报错；
// - SyncConflictsPage 渲染造态两条冲突（侧别文案 + 差异字段面板）；
// - 恢复走二次确认弹窗，确认后行离开待处理列表。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/sync_conflicts_page.dart';

/// 恢复成功 toast 走 WaitToast.global（需 rootNavigatorKey 的 Overlay）
Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(navigatorKey: rootNavigatorKey, home: child),
    );

/// testWidgets 的 FakeAsync 下 mock 桥 120ms 延迟需靠 pump 推进假时钟
Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  group('MockOrbitBridge 冲突败方副本语义（对齐 Rust sync_conflict_api）', () {
    test('造态两条待处理；按 resolution 过滤与计数一致', () async {
      final bridge = MockOrbitBridge();
      final all = await bridge.syncConflictList(null, 100, 0);
      expect(all.length, 2);
      expect(all.every((c) => c.resolution == 'unresolved'), isTrue);
      expect(await bridge.syncConflictCount('unresolved'), 2);
      expect(await bridge.syncConflictCount(null), 2);
      expect(await bridge.syncConflictCount('restored'), 0);
    });

    test('列表按时间倒序 + 分页参数生效', () async {
      final bridge = MockOrbitBridge();
      final all = await bridge.syncConflictList(null, 100, 0);
      expect(all.first.createdAt >= all.last.createdAt, isTrue);
      final page = await bridge.syncConflictList(null, 1, 0);
      expect(page.length, 1);
      expect(page.first.id, all.first.id);
      expect((await bridge.syncConflictList(null, 1, 1)).first.id, all.last.id);
    });

    test('恢复 = 标记 restored 且离开待处理列表', () async {
      final bridge = MockOrbitBridge();
      final rows = await bridge.syncConflictList('unresolved', 100, 0);
      final target = rows.first;

      final id = await bridge.syncConflictRestore(target.id);
      expect(id, target.id);
      expect(await bridge.syncConflictCount('unresolved'), 1);

      final restored = await bridge.syncConflictList('restored', 100, 0);
      expect(restored.single.id, target.id);
      expect(restored.single.resolution, 'restored');
      expect(restored.single.resolvedAt, greaterThan(0));
    });

    test('忽略 = 标记 dismissed；清空按 resolution 过滤', () async {
      final bridge = MockOrbitBridge();
      final rows = await bridge.syncConflictList('unresolved', 100, 0);
      await bridge.syncConflictDismiss(rows.first.id);
      expect(await bridge.syncConflictCount('dismissed'), 1);

      expect(await bridge.syncConflictClear(null), 2);
      expect(await bridge.syncConflictCount(null), 0);
    });

    test('处置不存在的 id → 抛错（对齐 Rust NotFound）', () async {
      final bridge = MockOrbitBridge();
      expect(() => bridge.syncConflictRestore(99999), throwsException);
      expect(() => bridge.syncConflictDismiss(99999), throwsException);
    });

    test('造态载荷可解析为字段表（差异面板数据源）', () async {
      final bridge = MockOrbitBridge();
      final local = (await bridge.syncConflictList(null, 100, 0))
          .firstWhere((c) => c.loserSide == 'local');
      expect(local.tableName, 'todo_tasks');
      expect(local.winnerSide, 'remote');
      expect(local.loserPayload, contains('title'));
      expect(local.winnerPayload, contains('title'));
      expect(local.loserPayload, isNot(local.winnerPayload));
    });
  });

  group('SyncConflictsPage 冒烟', () {
    testWidgets('渲染造态两条冲突 + 侧别文案 + 待处理计数', (tester) async {
      final bridge = MockOrbitBridge();
      await tester.pumpWidget(_wrap(const SyncConflictsPage(), bridge));
      await _settlePastMockLatency(tester);

      // 标题栏与分区标题同名「冲突记录」（两处各一）
      expect(find.text('冲突记录'), findsNWidgets(2));
      expect(find.text('待处理 2 条'), findsOneWidget);
      // 两条造态分别覆盖「本地被覆盖」「远端被丢弃」
      expect(find.textContaining('本端版本被他端覆盖'), findsOneWidget);
      expect(find.textContaining('他端版本被本端丢弃'), findsOneWidget);
      // 复原按钮每条一个（未处置时可见）
      expect(find.text('恢复'), findsNWidgets(2));
    });

    testWidgets('查看差异：展开后显示当前 / 被覆盖对照', (tester) async {
      final bridge = MockOrbitBridge();
      await tester.pumpWidget(_wrap(const SyncConflictsPage(), bridge));
      await _settlePastMockLatency(tester);

      await tester.tap(find.textContaining('查看差异').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('当前：'), findsWidgets);
      expect(find.textContaining('被覆盖：'), findsWidgets);
    });

    testWidgets('恢复：二次确认 → 行离开待处理列表；切「全部」可见已处置标记', (tester) async {
      final bridge = MockOrbitBridge();
      await tester.pumpWidget(_wrap(const SyncConflictsPage(), bridge));
      await _settlePastMockLatency(tester);

      await tester.tap(find.text('恢复').first);
      await tester.pumpAndSettle();
      expect(find.text('恢复为败方版本？'), findsOneWidget);

      await tester.tap(find.text('确认恢复'));
      await _settlePastMockLatency(tester);

      // 已处置 → 待处理列表只剩一条，且不再有可点的「恢复」
      expect(find.text('待处理 1 条'), findsOneWidget);
      expect(find.text('恢复'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await _settlePastMockLatency(tester);
      expect(find.text('已恢复'), findsOneWidget);

      // 排空 toast 自动消失定时器（否则 teardown 断言「Timer is still pending」）
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
