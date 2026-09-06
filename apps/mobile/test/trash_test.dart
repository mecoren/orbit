// 回收站链路测试：MockOrbitBridge 软删语义 + trash 三方法 + TrashScreen 页面冒烟。
//
// 覆盖回收站功能的关键行为（对齐 Rust trash_api 语义）：
// - 删除任务 = 软删（列表消失、回收站可见、deleted_at 记录）；
// - 恢复 = 回收站清空、任务列表回归；
// - 彻底删除 = 物理移除（不可恢复）；
// - 清空 = 全部墓碑物理删除；
// - TrashScreen 渲染：空态文案 / 墓碑行 + 保留期倒计时副标题 / 标题栏「清空」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/trash_screen.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(home: child),
    );

/// testWidgets 的 FakeAsync 下桥的 120ms 延迟需靠 pump 推进假时钟才能完成
///（body 里裸 await bridge 调用会永不完成——mock _delay 是真 Timer）。
Future<void> _bridgeCall(WidgetTester tester, Future<void> call) async {
  final f = call;
  await tester.pump(const Duration(milliseconds: 300));
  await f;
}

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  group('MockOrbitBridge 回收站语义（对齐 Rust trash_api）', () {
    test('删除 = 软删进回收站，任务列表不再可见', () async {
      final bridge = MockOrbitBridge();
      final tasks = await bridge.todoTaskList(const ListFilter(pageSize: 1000));
      final victim = tasks.first;
      expect(victim.isDeleted, 0);

      await bridge.todoTaskDelete(victim.id);

      final live = await bridge.todoTaskList(const ListFilter(pageSize: 1000));
      expect(live.any((t) => t.id == victim.id), isFalse);
      final trashed = await bridge.trashTasksList();
      expect(trashed.any((t) => t.id == victim.id), isTrue);
      final row = trashed.firstWhere((t) => t.id == victim.id);
      expect(row.isDeleted, 1);
      expect(row.deletedAt, isNotNull);
    });

    test('恢复 = 回收站清空、任务列表回归', () async {
      final bridge = MockOrbitBridge();
      final tasks = await bridge.todoTaskList(const ListFilter(pageSize: 1000));
      final victim = tasks.first;
      await bridge.todoTaskDelete(victim.id);

      final restored = await bridge.trashTaskRestore(victim.id);
      expect(restored.isDeleted, 0);
      expect(restored.deletedAt, isNull);

      final live = await bridge.todoTaskList(const ListFilter(pageSize: 1000));
      expect(live.any((t) => t.id == victim.id), isTrue);
      expect((await bridge.trashTasksList()).isEmpty, isTrue);
    });

    test('恢复不在回收站的任务 → 抛错', () async {
      final bridge = MockOrbitBridge();
      final tasks = await bridge.todoTaskList(const ListFilter(pageSize: 1000));
      expect(() => bridge.trashTaskRestore(tasks.first.id), throwsException);
    });

    test('彻底删除 = 物理移除，恢复不可达', () async {
      final bridge = MockOrbitBridge();
      final tasks = await bridge.todoTaskList(const ListFilter(pageSize: 1000));
      final victim = tasks.first;
      await bridge.todoTaskDelete(victim.id);
      await bridge.trashTaskPurge(victim.id);

      expect((await bridge.trashTasksList()).isEmpty, isTrue);
      expect(
        () => bridge.trashTaskRestore(victim.id),
        throwsException,
      );
    });

    test('清空回收站 = 全部墓碑物理删除', () async {
      final bridge = MockOrbitBridge();
      final tasks = await bridge.todoTaskList(const ListFilter(pageSize: 1000));
      for (final t in tasks.take(2)) {
        await bridge.todoTaskDelete(t.id);
      }
      final n = await bridge.trashPurgeAll();
      expect(n, 2);
      expect((await bridge.trashTasksList()).isEmpty, isTrue);
    });

    test('保留档位读写 + 非法档位拒绝', () async {
      final bridge = MockOrbitBridge();
      expect((await bridge.trashMeta()).retentionDays, 30);
      await bridge.trashSetRetentionDays(0);
      expect((await bridge.trashMeta()).retentionDays, 0);
      await bridge.trashSetRetentionDays(90);
      expect((await bridge.trashMeta()).retentionDays, 90);
      expect(() => bridge.trashSetRetentionDays(15), throwsException);
    });
  });

  group('TrashScreen 页面冒烟', () {
    testWidgets('空态：回收站是空文案 + 无「清空」按钮', (tester) async {
      final bridge = MockOrbitBridge();
      await tester.pumpWidget(_wrap(const TrashScreen(), bridge));
      await _settlePastMockLatency(tester);

      expect(find.text('回收站'), findsOneWidget);
      expect(find.textContaining('回收站是空的'), findsOneWidget);
      expect(find.text('清空'), findsNothing);
    });

    testWidgets('有墓碑：渲染任务行 + 倒计时副标题 + 清空按钮', (tester) async {
      final bridge = MockOrbitBridge();
      // 预置墓碑：list + delete 各是一次 120ms 延迟调用，逐次推进假时钟
      final tasksFuture = bridge.todoTaskList(const ListFilter(pageSize: 1000));
      await tester.pump(const Duration(milliseconds: 300));
      final tasks = await tasksFuture;
      final victim = tasks.first;
      await _bridgeCall(tester, bridge.todoTaskDelete(victim.id));

      await tester.pumpWidget(_wrap(const TrashScreen(), bridge));
      await _settlePastMockLatency(tester);

      expect(find.text(victim.title), findsOneWidget);
      expect(find.textContaining('天后自动清除'), findsOneWidget);
      expect(find.text('清空'), findsOneWidget);
    });
  });
}
