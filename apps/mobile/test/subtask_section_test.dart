// M10 子任务多层嵌套：详情页 _SubtasksSection widget 回归
// （与桌面 e2e/subtask-nesting.spec.ts 同口径：缩进几何 + 行内加子级 +
// 提到顶层 + 删除整棵子树；壳复用 detail_screen_edit_test 的 DetailScreen
// + MockOrbitBridge 装配）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'support/orbit_test_app.dart';

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

/// 收尾：推进假时钟排空 mock 桥延迟计时器——懒加载区块（如附件区）在滚动
/// 中才构建，其 Future.delayed(120ms) 不会因 pumpAndSettle 完成，
/// flutter_test 的「A Timer is still pending」正是它
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 把「子任务」区滚到舒适位置（甲行落在 y∈[150,350] 的视口中部）
///
/// 不用 scrollUntilVisible 的整步拖拽：它的单步 delta 会把目标整步推过头
/// （overshoot 最多一整个 delta，行被顶到页头遮挡区/负坐标，tap 命中失败）。
/// 本函数按当前几何自行决定方向与步长，并处理懒构建（未进树时先往下滚）。
Future<void> _scrollToSubtasks(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    final built = find.text('甲').evaluate().isNotEmpty;
    if (built) {
      final y = tester.getTopLeft(find.text('甲')).dy;
      if (y >= 150 && y <= 350) return;
      await tester.drag(
        find.byType(Scrollable).first,
        Offset(0, y < 150 ? 80 : -80),
      );
    } else {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -150));
    }
    await tester.pumpAndSettle();
  }
}

/// 发起桥调用 → 先推进假时钟越过 mock 120ms 延迟 → 再 await
/// （testWidgets 里裸 await 桥 Future 会死锁：假时钟只有 tester.pump 推进，
/// 同 sync_settings_page_test 的 _probe 纪律）
Future<T> _probe<T>(WidgetTester tester, Future<T> future) async {
  await tester.pump(const Duration(milliseconds: 300));
  return future;
}

/// 有界推进（不 AndSettle）——shadcn 抽屉/浮层动画在测试壳可能不收敛，
/// 此时 pumpAndSettle 会**挂死**（同步循环，测试超时都杀不掉）。
/// 仅用于浮层存续期间；浮层关闭后仍可用 _flushTimers 收敛
Future<void> _pump(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
}

/// 行标题左缘（缩进挂在行容器 padding.left = depth*16，标题随行平移）
double _titleLeft(WidgetTester tester, String title) =>
    tester.getTopLeft(find.text(title)).dx;

/// 某一行（标题 → 最近的 Row 祖先）；行尾按钮按行定位，避免多行同名撞车
Finder _row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(Row),
    );

/// 找指定 tooltip 的 IconButton（移动端行尾按钮常驻可见，无桌面 hover 门槛）
Finder _iconButton(String tooltip) => find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == tooltip,
    );

/// 行内/顶层添加框（hintText 定位；标题输入框在页面顶部，不能按类型取）
Finder _subtitleInput() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '子任务标题',
    );

void main() {
  late MockOrbitBridge bridge;
  late int taskId;

  setUp(() async {
    bridge = MockOrbitBridge();
    final t = await bridge.todoTaskCreate(TodoTaskCreateInput(title: '嵌套父'));
    taskId = t.id;
    // 种子两层：甲 → 乙
    final a = await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: taskId, title: '甲'));
    await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: taskId, title: '乙', parentUuid: a.uuid));
  });

  testWidgets('两层缩进渲染：乙比甲右移 16px，进度条按全树计数', (tester) async {
    await tester.pumpWidget(_wrap(DetailScreen(taskId: taskId), bridge));
    await _settle(tester);
    await _scrollToSubtasks(tester);

    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    expect(_titleLeft(tester, '乙') - _titleLeft(tester, '甲'), 16.0);
    expect(find.text('0/2'), findsOneWidget, reason: '计数口径 = 全树活行');
    await _flushTimers(tester);
  });

  testWidgets('行内加子级：乙下输入标题提交 → 丁落库且缩进再深一层', (tester) async {
    await tester.pumpWidget(_wrap(DetailScreen(taskId: taskId), bridge));
    await _settle(tester);
    await _scrollToSubtasks(tester);

    await tester
        .tap(find.descendant(of: _row('乙'), matching: _iconButton('添加子级')));
    await tester.pumpAndSettle();
    await tester.enterText(_subtitleInput(), '丁');
    await tester.pump();
    await tester.tap(_iconButton('确定'));
    await _settle(tester);

    expect(find.text('丁'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget, reason: '丁已进全树计数');
    expect(_titleLeft(tester, '丁') - _titleLeft(tester, '乙'), 16.0);
    await _flushTimers(tester);
  });

  testWidgets('提到顶层：乙回顶层左缘，丁保持挂在乙下', (tester) async {
    await tester.pumpWidget(_wrap(DetailScreen(taskId: taskId), bridge));
    await _settle(tester);
    await _scrollToSubtasks(tester);

    // 先加一个子级，制造「提顶层后子孙跟随」的场景
    await tester
        .tap(find.descendant(of: _row('乙'), matching: _iconButton('添加子级')));
    await tester.pumpAndSettle();
    await tester.enterText(_subtitleInput(), '丁');
    await tester.pump();
    await tester.tap(_iconButton('确定'));
    await _settle(tester);

    await tester
        .tap(find.descendant(of: _row('乙'), matching: _iconButton('提到顶层')));
    await _flushTimers(tester);
    await _flushTimers(tester);

    final leftJia = _titleLeft(tester, '甲');
    final leftYi = _titleLeft(tester, '乙');
    final leftDing = _titleLeft(tester, '丁');
    expect(leftYi, leftJia, reason: '乙回顶层（与甲同左缘）');
    expect(leftDing - leftYi, 16.0, reason: '丁仍挂在乙下（相对缩进不变）');
    await drainToastTimers(tester); // 「已提到顶层」toast 的 2.6s 关闭计时器
    await _flushTimers(tester);
  });

  testWidgets('删除甲：确认抽屉展示子树规模 → 确认后整棵子树从详情消失', (tester) async {
    await tester.pumpWidget(_wrap(DetailScreen(taskId: taskId), bridge));
    await _settle(tester);
    await _scrollToSubtasks(tester);

    await tester.tap(find.descendant(
        of: _row('甲'), matching: _iconButton('删除子任务')));
    // shadcn 确认抽屉：入场动画在本测试壳不收敛（pumpAndSettle 会挂死），
    // 用有界 pump 推进（同 orbit_sheets_test 口径）
    await _pump(tester);
    await _pump(tester);

    // 确认抽屉（shadcn sheet）：说明文案带子树规模
    expect(find.text('删除子任务'), findsWidgets);
    expect(find.textContaining('其下 1 个子任务将一并删除'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await _pump(tester);
    await _pump(tester);
    await _pump(tester);

    expect(find.text('甲'), findsNothing);
    expect(find.text('乙'), findsNothing, reason: '整棵子树随删');
    final live = await _probe(
        tester, bridge.todoSubtaskList(const ListFilter(pageSize: 100)));
    expect(live.where((s) => s.taskId == taskId), isEmpty);
    await drainToastTimers(tester);
    await _flushTimers(tester);
  });
}
