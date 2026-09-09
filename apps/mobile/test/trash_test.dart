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
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/trash_screen.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(home: child),
    );

/// 撤销 toast 需挂 rootNavigatorKey 的 Overlay（WaitToast.global 经全局
/// Navigator 插入；普通 _wrap 的 MaterialApp 无 key 时 toast 静默不显示）
Widget _wrapWithNavKey(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(navigatorKey: rootNavigatorKey, home: child),
    );

/// testWidgets 的 FakeAsync 下桥的 120ms 延迟需靠 pump 推进假时钟才能完成
///（body 里裸 await bridge 调用会永不完成——mock _delay 是真 Timer）。
/// 泛型版：带返回值的桥调用同模式（先 pump 推进假时钟再 await）。
Future<T> _bridgeCallT<T>(WidgetTester tester, Future<T> call) async {
  await tester.pump(const Duration(milliseconds: 300));
  return call;
}

Future<void> _bridgeCall(WidgetTester tester, Future<void> call) async {
  await tester.pump(const Duration(milliseconds: 300));
  await call;
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

    // ── 可撤销彻底删除（2026-09-09：purge 延迟提交 + toast 撤销按钮）──

    testWidgets('彻底删除：5s 窗口内点撤销 → 行恢复且库未删', (tester) async {
      final bridge = MockOrbitBridge();
      final tasksFuture = bridge.todoTaskList(const ListFilter(pageSize: 1000));
      await tester.pump(const Duration(milliseconds: 300));
      final tasks = await tasksFuture;
      final victim = tasks.first;
      await _bridgeCall(tester, bridge.todoTaskDelete(victim.id));

      await tester.pumpWidget(_wrapWithNavKey(const TrashScreen(), bridge));
      await _settlePastMockLatency(tester);

      // 长按行弹操作菜单 → 「彻底删除」→ 确认（确认钮文案与菜单项同名，
      // 弹窗 content 为含标题的长句用 textContaining 锁定弹窗本体）
      await tester.longPress(find.text(victim.title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('彻底删除').first); // 菜单项
      await tester.pumpAndSettle();
      expect(find.textContaining('确定要彻底删除'), findsOneWidget);
      await tester.tap(find.text('彻底删除').last); // AlertDialog 确认钮
      await tester.pumpAndSettle();

      // 乐观隐藏：列表行消失（toast description 里仍有标题副本，故按列表行
      // 样式口径改用 findsNWidgets——ListTile 行的 title 是 15px，toast 描述 12px）
      final rowTitle = find
          .byWidgetPredicate((w) => w is Text && w.data == victim.title && w.style?.fontSize == 15);
      expect(rowTitle, findsNothing);
      expect(find.text('撤销'), findsOneWidget);

      // 点撤销 → 行恢复；数据仍在库（延迟提交被取消）
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(rowTitle, findsOneWidget);
      final trashed = await _bridgeCallT(tester, bridge.trashTasksList());
      expect(trashed.any((t) => t.id == victim.id), isTrue);
    });

    testWidgets('彻底删除：不点撤销 → 5s 窗口过后真提交（物理删除）', (tester) async {
      final bridge = MockOrbitBridge();
      final tasksFuture = bridge.todoTaskList(const ListFilter(pageSize: 1000));
      await tester.pump(const Duration(milliseconds: 300));
      final tasks = await tasksFuture;
      final victim = tasks.first;
      await _bridgeCall(tester, bridge.todoTaskDelete(victim.id));

      await tester.pumpWidget(_wrapWithNavKey(const TrashScreen(), bridge));
      await _settlePastMockLatency(tester);

      // 长按行 → 菜单「彻底删除」→ 确认
      await tester.longPress(find.text(victim.title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('彻底删除').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('确定要彻底删除'), findsOneWidget);
      await tester.tap(find.text('彻底删除').last);
      await tester.pumpAndSettle();
      final rowTitle2 = find
          .byWidgetPredicate((w) => w is Text && w.data == victim.title && w.style?.fontSize == 15);
      expect(rowTitle2, findsNothing);

      // 推进假时钟过 5s 窗口 → timer fire 触发提交（_commitPurge 内部
      // invalidate 后 provider 重查的 120ms 真 Timer 一并推掉再 settle）
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      // 提交后 invalidate 已触发 provider 重查，须再推 300ms 假时钟让重查完成
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final trashed = await _bridgeCallT(tester, bridge.trashTasksList());
      expect(trashed.isEmpty, isTrue);
      // 恢复不可达的库语义已由上方纯 test 用例「彻底删除 = 物理移除」覆盖，
      // 此处不再重复异步断言（FakeAsync 下未捕获 zone error 会直接炸测试体）
    });
  });
}
