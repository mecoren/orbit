// 任务历史双口径回归：MockOrbitBridge.taskActivityList 对齐桌面
// ipc-mock（created_at 倒序、同刻按 id 倒序、limit 截断、按任务隔离），
// 加详情页「历史」区块渲染（seeded 三代 detail 行 + 新任务空态）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'package:orbit/modules/todo/logic/activity_format.dart';
import 'support/orbit_test_app.dart';

const _seededTaskTitle = '完成移动端重构方案评审';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 历史区块是详情页最末区块，600px 视口外必须滚入才进树；评论区输入框
/// 的横向 Scrollable 会在滚动中途进树，drag 目标必须钉死页面首个滚动容器
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  late MockOrbitBridge bridge;

  Future<TodoTask> seededTask() async {
    final tasks = await bridge.todoTaskList(const ListFilter(pageSize: 100));
    return tasks.firstWhere((t) => t.title == _seededTaskTitle);
  }

  setUp(() => bridge = MockOrbitBridge());

  group('taskActivityList 桥契约', () {
    test('seeded 三行：倒序 + 文案口径', () async {
      final t1 = await seededTask();
      final rows = await bridge.taskActivityList(t1.id);
      expect(rows.length, 3);
      expect(rows.map((r) => r.action).toList(),
          ['comment_add', 'update', 'create']);

      final texts =
          rows.map((r) => describeActivity(r.action, r.detail)).toList();
      expect(texts, [
        '添加评论「评审会定在周四下午两点。」',
        '更新（优先级：无 → 紧急）',
        '创建了任务',
      ]);
    });

    test('limit 截断最新 N 条', () async {
      final t1 = await seededTask();
      final rows = await bridge.taskActivityList(t1.id, limit: 2);
      expect(rows.length, 2);
      expect(rows.first.action, 'comment_add');
    });

    test('按任务隔离：无轨迹任务返回空', () async {
      final t1 = await seededTask();
      final created =
          await bridge.todoTaskCreate(TodoTaskCreateInput(title: '无痕新任务'));
      expect((await bridge.taskActivityList(created.id)), isEmpty);
      expect((await bridge.taskActivityList(t1.id)).length, 3);
    });
  });

  group('详情页历史区块', () {
    testWidgets('滚动到末区块：标题行 + 三条轨迹渲染', (tester) async {
      final t1 = await tester.runAsync(seededTask);
      await tester
          .pumpWidget(_wrap(DetailScreen(taskId: t1!.id), bridge));
      await _settle(tester);

      await _scrollTo(tester, find.text('历史'));
      expect(find.text('历史'), findsOneWidget);

      await _scrollTo(
          tester, find.text('添加评论「评审会定在周四下午两点。」').first);
      expect(find.text('创建了任务'), findsOneWidget);
      expect(find.text('更新（优先级：无 → 紧急）'), findsOneWidget);
      expect(
        find.textContaining('评审会定在周四下午两点。'),
        findsAtLeastNWidgets(2),
      );
    });

    testWidgets('新任务无轨迹：空态文案', (tester) async {
      final created = await tester.runAsync(() => bridge.todoTaskCreate(
          TodoTaskCreateInput(title: '新任务历史空态')));
      await tester
          .pumpWidget(_wrap(DetailScreen(taskId: created!.id), bridge));
      await _settle(tester);

      await _scrollTo(tester, find.text('暂无操作记录'));
      expect(find.text('历史'), findsOneWidget);
    });

    testWidgets('满档 30 条：提示 + 显示更多展到 100 后提示消失', (tester) async {
      final t1 = await tester.runAsync(seededTask);
      // 直灌内存库补足 38 条（3 seeded + 35 注入，createdAt 早于全部 seeded）
      await tester.runAsync(() async {
        for (var i = 0; i < 35; i++) {
          bridge.store.activityLog[10000 + i] = {
            'id': 10000 + i,
            'task_id': t1!.id,
            'task_title': t1.title,
            'action': 'create',
            'detail': '{}',
            'created_at': DateTime.now().millisecondsSinceEpoch - 10 * 86400000 - i,
          };
        }
      });
      await tester
          .pumpWidget(_wrap(DetailScreen(taskId: t1!.id), bridge));
      await _settle(tester);

      await _scrollTo(tester, find.text('仅显示最近 30 条操作'));
      expect(find.text('显示更多'), findsOneWidget);

      await tester.tap(find.text('显示更多'));
      await _settle(tester);
      // 38 < 100：档位展满后截断提示整体消失
      expect(find.text('仅显示最近 30 条操作'), findsNothing);
      expect(find.text('显示更多'), findsNothing);
    });
  });
}
