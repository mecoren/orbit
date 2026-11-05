// 详情页输入可用性回归：标题 / 描述 / 信息区档位 / 子任务草稿 / 关联搜索
//
// 重构前这些入口的共性故障：点击外部当帧卸载标题输入框、描述 maxLines:null
// 在 Flexible 里拿不到确定高度、两个子任务输入框争焦点、关联搜索弹层手搓
// 键盘避让把输入框挤走、信息区三行「只读」无法编辑。本文件逐项守住修法。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_spinner.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_text_field.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

/// 两轮推进：详情 provider + todoProjectsProvider 的 mock 延迟都结算完
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 滚进视口中部：详情页是懒构建列表，且玻璃页头会吃掉贴顶点击。
/// [finder] 允许多个候选（scrollUntilVisible 只判空），[target] 用于收敛与点击。
Future<void> _scrollTo(
  WidgetTester tester,
  Finder finder, {
  Finder? target,
}) async {
  await tester.scrollUntilVisible(finder, 300);
  await tester.pumpAndSettle();
  final focused = target ?? finder;
  for (var i = 0; i < 12; i++) {
    final rect = tester.getRect(focused);
    if (rect.top >= 80 && rect.bottom <= 580) break;
    await tester.drag(
      find.byType(Scrollable).first,
      Offset(0, rect.top < 80 ? 100 : -100),
    );
    await tester.pumpAndSettle();
  }
}

Finder _titleInput() => find.byWidgetPredicate(
      (w) => w is OrbitTextField && w.maxLines == 2,
    );

Finder _subtaskDraftInput() => find.byWidgetPredicate(
      (w) => w is OrbitTextField && w.hintText == '子任务标题',
    );

void main() {
  late MockOrbitBridge bridge;

  setUp(() => bridge = MockOrbitBridge());

  testWidgets('标题原地编辑：整行可点、输入不被点外部销毁、保存落库', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    final editEntry = find.byIcon(OrbitIcons.edit);
    expect(editEntry, findsOneWidget, reason: '标题行常驻编辑入口');
    await tester.tap(editEntry);
    await tester.pumpAndSettle();

    expect(_titleInput(), findsOneWidget);
    expect(
      tester.widget<OrbitTextField>(_titleInput()).onTapOutside,
      isNull,
      reason: '点空白处立即卸载输入框会让标题「刚点就没了」',
    );

    await tester.enterText(_titleInput(), '重构后的任务标题');
    await tester.pump();
    await tester.tap(find.byTooltip('保存标题'));
    await _settle(tester);

    final detail = await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(detail!.title, '重构后的任务标题');
  });

  testWidgets('描述编辑：多行输入有界，保存后落库', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    final editEntry = find.text('编辑').first;
    await _scrollTo(tester, find.text('编辑'), target: editEntry);
    await tester.tap(editEntry);
    await tester.pumpAndSettle();
    expect(find.text('编辑描述'), findsOneWidget);

    final descInput = find.byWidgetPredicate(
      (w) => w is OrbitTextField && w.maxLines == 12,
    );
    expect(descInput, findsOneWidget);
    expect(
      tester.widget<OrbitTextField>(descInput).maxLines,
      isNotNull,
      reason: 'maxLines:null 会让输入区在 Flexible 里失去确定高度',
    );

    await tester.enterText(descInput, '重构后的描述');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await _settle(tester);

    final detail = await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(detail!.description, '重构后的描述');
  });

  testWidgets('信息区：预计时长从只读改为档位行，点选即落库', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    await _scrollTo(tester, find.text('预计时长'));
    await tester.tap(find.text('预计时长'));
    await tester.pumpAndSettle();

    final popup = dropdownPopup();
    expect(popup, findsOneWidget);
    final option = find.descendant(
      of: popup,
      matching: find.text('30 分钟'),
    );
    expect(option, findsOneWidget);
    await tester.tap(option);
    await _settle(tester);

    final detail = await tester.runAsync(() => bridge.todoTaskGetDetail(5));
    expect(detail!.durationMinutes, 30);
  });

  testWidgets('子任务草稿：两个入口互斥，取消后输入框收起', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    await _scrollTo(tester, find.text('添加子任务'));
    await tester.tap(find.text('添加子任务'));
    await tester.pumpAndSettle();

    expect(_subtaskDraftInput(), findsOneWidget);
    expect(find.byTooltip('取消添加'), findsOneWidget);

    await tester.tap(find.byTooltip('取消添加'));
    await tester.pumpAndSettle();
    expect(_subtaskDraftInput(), findsNothing);
  });

  testWidgets('关联搜索：抽屉输入框可编辑且能发起搜索', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    await _scrollTo(tester, find.byTooltip('添加关联'));
    await tester.tap(find.byTooltip('添加关联'));
    await tester.pumpAndSettle();

    expect(find.text('关联任务'), findsOneWidget);
    final searchInput = find.byWidgetPredicate(
      (w) => w is OrbitTextField && w.label == '搜索任务标题',
    );
    expect(searchInput, findsOneWidget);

    await tester.enterText(searchInput, '评审');
    await tester.pump();
    expect(find.text('评审'), findsOneWidget);

    await tester.tap(find.byTooltip('搜索任务'));
    await _settle(tester);
    expect(find.byType(OrbitSpinner), findsNothing, reason: '搜索已结算');
  });
}
