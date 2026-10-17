// 列表面板「存为视图」（G1，对齐桌面 toolbar-menus.tsx:319 +
// saved-filter-builder.ts:111）：
// 1. 纯函数：面板筛选态 → 保存的筛选器条件 JSON（status 非 all/undone 才落键、
//    priority 等值档落 priority_min、标签档落 label_ids、收藏视图落 favorite_only）
// 2. 面板含「存为视图」项，点开即入筛选器构建抽屉（预填当前筛选），
//    命名创建后落库 savedFilterCreate。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/saved_filters_screen.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';

/// 路由壳：面板「存为视图」走 context.push 跳筛选器页，须 GoRouter 承载
GoRouter _buildRouter() => GoRouter(
      initialLocation: '/todo/tasks',
      routes: [
        GoRoute(
          path: '/todo/tasks',
          builder: (_, _) => const SubListScreen(
            query: TaskFilterInput(quickView: QuickViewKey.all),
          ),
        ),
        GoRoute(
          path: '/todo/saved-filters',
          builder: (_, s) => SavedFiltersScreen(
            initialConditions: s.extra is Map<String, dynamic>
                ? s.extra! as Map<String, dynamic>
                : null,
          ),
        ),
      ],
    );

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestAppRouter(routerConfig: _buildRouter()),
    );

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  group('filterToSavedConditions（存为视图预填，镜像桌面 toolbarToForm）', () {
    test('空筛选 → 空条件', () {
      expect(
        filterToSavedConditions(
            filters: const TaskListFilters(), quickView: null),
        isEmpty,
      );
    });

    test('状态 all/undone 丢弃、真实状态落键', () {
      expect(
        filterToSavedConditions(
          filters: const TaskListFilters(status: 'undone'),
          quickView: null,
        ),
        isEmpty,
        reason: 'undone 无对应白名单键，丢弃（桌面同口径）',
      );
      expect(
        filterToSavedConditions(
          filters: const TaskListFilters(status: 'pending'),
          quickView: null,
        )['status'],
        'pending',
      );
    });

    test('优先级等值档 → priority_min、标签档 → label_ids、收藏视图 → favorite_only',
        () {
      final cond = filterToSavedConditions(
        filters: const TaskListFilters(priority: 4, labelId: 7),
        quickView: QuickViewKey.favorite,
      );
      expect(cond['priority_min'], 4);
      expect(cond['label_ids'], [7]);
      expect(cond['favorite_only'], true);
    });
  });

  testWidgets('面板「存为视图」→ 构建抽屉预填当前筛选 → 创建落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settlePastMockLatency(tester);

    // 设一个筛选（优先级 = 高 3；不用「紧急」——种子库有同名标签会撞 chip）：
    // ⋮ → 筛选 → 优先级 chip
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    // chip 即点即生效，关掉筛选抽屉
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // 面板补「存为视图」项
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('存为视图'), findsOneWidget);
    await tester.tap(find.text('存为视图'));
    await tester.pumpAndSettle();

    // 构建抽屉（预填 priority_min=3）：命名 → 创建。
    // 「新建筛选器」页面空态按钮/入口钮/抽屉标题同名，限定抽屉内命中
    final sheetTitle = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('新建筛选器'),
    );
    expect(sheetTitle, findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '高优先视图');
    await tester.tap(find.text('创建'));
    await _settlePastMockLatency(tester);

    // 断言直接读 store（mock 的 Future.delayed 在 fake async 里需 pump 才到点，
    // await 桥方法会死等；store 是同步内存库）
    final filters = bridge.store.savedFilters;
    expect(filters, hasLength(1));
    expect(filters.first.name, '高优先视图');
    expect(filters.first.conditions, contains('priority_min'));
    await drainToastTimers(tester);
  });
}
