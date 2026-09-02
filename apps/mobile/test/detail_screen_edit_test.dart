// 明细页全字段可编辑测试：开始/结束日期、重复、提醒增改删
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'package:orbit/shared/widgets/app_month_calendar.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(home: child),
    );

Future<void> _settle(WidgetTester tester) async {
  // 两轮推进：第一轮让详情 provider 就绪并构建信息区（此时才启动
  // todoProjectsProvider 的 120ms mock 延迟），第二轮把它推完，
  // 避免测试结束时残留 pending timer
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 详情页是懒构建 SliverList，提醒区默认在 600px 视口外不会进树，
/// 交互前必须先把目标滚入视口
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300);
  await tester.pumpAndSettle();
}

/// 点击月历里的日期格：限定在 AppMonthCalendar 内，避免与时间
/// 步进器的时/分数字文本（如恰好 minute==15）撞 find.text
Future<void> _tapDay(WidgetTester tester, String day) async {
  await tester.tap(
    find.descendant(of: find.byType(AppMonthCalendar), matching: find.text(day)).first,
  );
}

void main() {
  late MockOrbitBridge bridge;

  Future<TodoTaskDetail> detailOf(int id) => bridge.todoTaskGetDetail(id);

  Future<List<TodoReminder>> remindersOf(int taskId) async {
    final rows = await bridge.todoReminderList(const ListFilter());
    return rows.where((r) => r.taskId == taskId && r.isDeleted == 0).toList();
  }

  setUp(() => bridge = MockOrbitBridge());

  testWidgets('信息区：开始日期/结束日期/重复 三行齐备', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    expect(find.text('信息'), findsOneWidget);
    expect(find.text('开始日期'), findsOneWidget);
    expect(find.text('结束日期'), findsOneWidget);
    expect(find.text('重复'), findsOneWidget);
    // 颜色行已随 97d3eab 移除（桌面改看板标签展示，颜色经项目/标签承载）
    expect(find.text('颜色'), findsNothing);
  });

  testWidgets('重复：弹层选「每天」→ repeat_mode/after 落库', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    // 点重复行值（初始「不重复」）唤起编辑弹层
    await tester.tap(find.text('不重复'));
    await tester.pumpAndSettle();
    expect(find.text('每天'), findsOneWidget);

    await tester.tap(find.text('每天'));
    await tester.pumpAndSettle();

    final detail = await tester.runAsync(() => detailOf(5));
    expect(detail!.repeatMode, 1);
    expect(detail.repeatAfter, 1);
  });

  testWidgets('开始日期：wait 面板选 15 号 → start_date 落库零点', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    await tester.tap(find.text('开始日期'));
    await tester.pumpAndSettle();

    // wait 面板：选当月 15 号 → 确认
    expect(find.text('确认'), findsOneWidget);
    await _tapDay(tester, '15');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    final detail = await tester.runAsync(() => detailOf(5));
    final now = DateTime.now();
    final expected =
        DateTime(now.year, now.month, 15).millisecondsSinceEpoch;
    expect(detail!.startDate, expected);
  });

  testWidgets('提醒：添加按钮 → 面板选日 → 提醒数 +1', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    final before =
        (await tester.runAsync(() => remindersOf(5)))!.length;

    await _scrollTo(tester, find.text('添加提醒'));
    expect(find.text('添加提醒'), findsOneWidget);

    await tester.tap(find.text('添加提醒'));
    await tester.pumpAndSettle();
    await _tapDay(tester, '15');
    await tester.tap(find.text('确认'));
    await _settle(tester);

    final after = (await tester.runAsync(() => remindersOf(5)))!.length;
    expect(after, before + 1);
  });

  testWidgets('提醒：点行编辑 → 删旧建新（id 变化）', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    final before = (await tester.runAsync(() => remindersOf(5)))!;
    expect(before.length, 1);

    // 基础屏上唯一含冒号的文本即提醒时间（信息区日期走 formatYmd 无时分）；
    // scrollUntilVisible 的目标不能链 .first——目标未进树时 evaluate
    // 内部先取 first 会抛 No element，等滚到位再取
    await _scrollTo(tester, find.textContaining(':'));
    await tester.tap(find.textContaining(':').first);
    await tester.pumpAndSettle();

    // 改选 20 号 → 确认（初始时间非 20 日零点 → 必然变化）
    await _tapDay(tester, '20');
    await tester.tap(find.text('确认'));
    await _settle(tester);

    final after = (await tester.runAsync(() => remindersOf(5)))!;
    expect(after.length, 1);
    expect(after.first.id, isNot(before.first.id));
  });

  testWidgets('提醒：删除图标 → 提醒数 -1', (tester) async {
    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
    await _settle(tester);

    expect(
        (await tester.runAsync(() => remindersOf(5)))!.length, 1);

    await _scrollTo(tester, find.textContaining(':'));

    // IconButton+close 只在子任务/提醒两区出现且提醒在后，
    // 信息区清空按钮是裸 Icon 非 IconButton 不会误中；取 .last 即提醒的删除
    await tester.tap(
      find.widgetWithIcon(IconButton, Icons.close_rounded).last,
    );
    await _settle(tester);

    expect(
        (await tester.runAsync(() => remindersOf(5)))!.length, 0);
  });
}
