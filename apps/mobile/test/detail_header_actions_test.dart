// 详情页页头「任务操作」弹层测试：我的一天 / 收藏 / 复制 / 删除四动作
// （对齐桌面详情标题行 Sunrise/Star/Copy/Trash；移动端按列表页既有决策
// 收进 ⋮ 弹层，标签回显当前状态）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'support/orbit_test_app.dart';

late GoRouter _router;

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestAppRouter(routerConfig: _router),
    );

/// 两轮推进：落定详情 provider 与 120ms mock 延迟（与详情编辑用例同款）
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 从列表占位页 push 进详情（对齐生产导航形态：删除后的 pop 有页可回）
Future<void> _openDetail(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(bridge));
  await _settle(tester);
  _router.push('/todo/5');
  await _settle(tester);
}

/// 打开页头 ⋮ 动作弹层并点选其中的某一条目（文本定位限定在抽屉内，
/// 避免与页面正文撞词）
Future<void> _pickAction(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('任务操作'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(BottomSheet), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  late MockOrbitBridge bridge;

  setUp(() {
    bridge = MockOrbitBridge();
    _router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Center(child: Text('列表页'))),
        ),
        GoRoute(
          path: '/todo/:id',
          builder: (_, s) => DetailScreen(
            taskId: int.tryParse(s.pathParameters['id'] ?? ''),
          ),
        ),
      ],
    );
  });

  testWidgets('页头 ⋮ → 我的一天 toggle → my_day_date 落今天零点 / 再点清空', (tester) async {
    await _openDetail(tester, bridge);

    // 种子任务 5 未加入我的一天 → 菜单首项为「加入我的一天」
    await _pickAction(tester, '加入我的一天');
    await _settle(tester);

    final now = DateTime.now();
    final detail = await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(
      detail!.myDayDate,
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
    );

    // 再开弹层：标签翻转为「移出我的一天」，点选后清空
    await _pickAction(tester, '移出我的一天');
    await _settle(tester);
    final after = await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(after!.myDayDate, isNull);
  });

  testWidgets('页头 ⋮ → 收藏 toggle → is_favorite 翻转', (tester) async {
    await _openDetail(tester, bridge);

    // 种子任务 5 已收藏（is_favorite=1）→ 菜单显示「取消收藏」
    await _pickAction(tester, '取消收藏');
    await _settle(tester);

    final detail = await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(detail!.isFavorite, 0);
  });

  testWidgets('页头 ⋮ → 复制任务 → 任务数 +1 且落到副本详情', (tester) async {
    await _openDetail(tester, bridge);

    final before = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );

    await _pickAction(tester, '复制任务');
    await _settle(tester);

    final after = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    expect(after!.length, before!.length + 1);
    // pushReplacement 落到副本详情：页头/标题区带「（副本）」标题
    expect(find.textContaining('（副本）'), findsWidgets);

    await drainToastTimers(tester);
  });

  testWidgets('页头 ⋮ → 删除 → 取消不删、确认后返回列表且任务出列', (tester) async {
    await _openDetail(tester, bridge);

    // 先取消：验证不删
    await _pickAction(tester, '删除');
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('删除任务')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: sheet, matching: find.text('取消')));
    await _settle(tester);
    // mock 的 getDetail 不过滤墓碑（对齐 core 单行通道），以 is_deleted 判删否
    final afterCancel =
        await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(afterCancel!.isDeleted, 0);

    // 再确认：删除后返回列表占位页
    await _pickAction(tester, '删除');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('删除'),
      ),
    );
    await _settle(tester);

    expect(find.text('列表页'), findsOneWidget);
    final afterDelete =
        await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(afterDelete!.isDeleted, 1);
  });
}
