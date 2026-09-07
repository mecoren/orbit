// 新建/编辑表单全量字段测试：字段存在性、重复规则落库、提醒同步语义
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/form_bottom_sheet.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/shared/widgets/section_card.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(home: child),
    );

/// 推进假时钟越过 MockOrbitBridge 的 120ms 人为延迟，再收敛帧
Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 打开侧栏首屏并点击 FAB，返回注入的 bridge
Future<MockOrbitBridge> _openForm(WidgetTester tester) async {
  final bridge = MockOrbitBridge();
  await tester.pumpWidget(_wrap(const SidebarScreen(), bridge));
  await _settlePastMockLatency(tester);
  await tester.tap(find.byIcon(Icons.add_rounded));
  await tester.pumpAndSettle();
  return bridge;
}

/// 抽屉 ListView 懒构建：字段多于一屏，滚到目标可见再断言/交互。
/// scrollUntilVisible 只保证元素进树（懒构建会预建视口外 item），
/// 不保证真正滚入视口——按目标矩形底边判断，超出则继续补滚。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
  for (var i = 0; i < 8; i++) {
    // 测试视口高 600，留 20px 余量确保可命中点击
    if (tester.getRect(finder).bottom <= 580) break;
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -100));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('表单字段：状态/开始日期/提醒时间/重复齐备', (tester) async {
    await _openForm(tester);

    expect(find.text('添加待办'), findsOneWidget);
    expect(find.text('状态'), findsOneWidget);
    // 状态三档 chips（背景侧栏可能重名，限定 ChoiceChip 内断言）
    Finder statusChip(String label) => find.descendant(
          of: find.byType(ChoiceChip),
          matching: find.text(label),
        );
    expect(statusChip('待办'), findsOneWidget);
    expect(statusChip('进行中'), findsOneWidget);
    expect(statusChip('已完成'), findsOneWidget);

    // 下方字段需滚动到可视区再断言
    await _scrollTo(tester, find.text('开始日期'));
    expect(find.text('开始日期'), findsOneWidget);
    // 结束日期行已移除（end_date 字段随 0004 迁移删除，日期口径=截止/开始）
    expect(find.text('结束日期'), findsNothing);
    await _scrollTo(tester, find.text('提醒时间'));
    expect(find.text('提醒时间'), findsOneWidget);
    await _scrollTo(tester, find.text('重复'));
    expect(find.text('重复'), findsOneWidget);
    // 颜色字段已随 97d3eab 移除（桌面改看板标签展示，颜色经项目/标签承载）
    expect(find.text('颜色'), findsNothing);
  });

  testWidgets('日期与提醒卡片：截止/开始/提醒行齐备 + 截止行内快捷胶囊', (tester) async {
    await _openForm(tester);

    await _scrollTo(tester, find.text('日期与提醒'));
    expect(find.text('日期与提醒'), findsOneWidget);

    // 快捷胶囊限定在 SectionCard 内（侧栏快捷视图也有「今天」）
    expect(
      find.descendant(
          of: find.byType(SectionCard), matching: find.text('今天')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byType(SectionCard), matching: find.text('明天')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byType(SectionCard), matching: find.text('下周')),
      findsOneWidget,
    );

    // 开始日期默认当天 → 值行显示今天；结束日期已移除，提醒未设值 → 占位「无」
    final today = DateTime.now();
    final todayYmd =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    expect(
      find.descendant(of: find.byType(SectionCard), matching: find.text(todayYmd)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(SectionCard), matching: find.text('无')),
      findsOneWidget,
    );
  });

  testWidgets('截止日期：快捷胶囊「今天」→ 落库当日零点', (tester) async {
    final bridge = await _openForm(tester);

    await tester.enterText(find.byType(TextFormField).first, '快捷截止任务');
    await _scrollTo(tester, find.text('截止日期'));
    await tester.tap(find
        .descendant(of: find.byType(SectionCard), matching: find.text('今天')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.check_rounded));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '快捷截止任务');
    final now = DateTime.now();
    expect(task.dueDate,
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch);
  });

  testWidgets('保存：选择「每天」重复落库 repeat_mode=1/repeat_after=1', (tester) async {
    final bridge = await _openForm(tester);

    await tester.enterText(find.byType(TextFormField).first, '重复任务A');
    await _scrollTo(tester, find.text('每天'));
    await tester.tap(find.text('每天'));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.check_rounded));
    await _settlePastMockLatency(tester);

    // testWidgets 体在 FakeAsync 区，bridge 的 Future.delayed 需真实时钟：
    // 用 runAsync 执行，否则 await 永不完成（测试挂死）
    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '重复任务A');
    expect(task.repeatMode, 1);
    expect(task.repeatAfter, 1);
  });

  // 颜色校验用例已随颜色字段移除而删除（97d3eab：桌面看板标签方案，
  // 任务级颜色不再由表单/详情编辑，hex 校验逻辑随字段一并下线）

  testWidgets('日期选择：wait-home 面板（月历+确认/清除）选日回显', (tester) async {
    await _openForm(tester);

    // 滚到开始日期行，点行唤起 wait 面板
    await _scrollTo(tester, find.text('开始日期'));
    await tester.tap(find.text('开始日期'));
    await tester.pumpAndSettle();

    // wait 面板特征：周标签 + 确认/清除按钮 + 视图切换标题
    expect(find.text('一'), findsOneWidget);
    expect(find.text('日'), findsOneWidget);
    expect(find.text('确认'), findsOneWidget);
    expect(find.text('清除'), findsOneWidget);

    // 点当月 15 号 → 确认 → chip 回显 YYYY-MM-15
    await tester.tap(find.text('15'));
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    final expected =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-15';
    expect(find.text(expected), findsOneWidget);
  });

  group('syncTaskReminder（桌面端同语义：清空删/变更删旧建新/未动跳过）', () {
    late MockOrbitBridge bridge;

    setUp(() => bridge = MockOrbitBridge());

    Future<TodoReminder?> firstReminderOf(int taskId) async {
      final rows = await bridge.todoReminderList(const ListFilter());
      return rows.where((r) => r.taskId == taskId && r.isDeleted == 0).firstOrNull;
    }

    test('新建：设置提醒 → 建立提醒', () async {
      // 用高位 id 避开 mock 种子任务（种子 t1 已带一条提醒）
      const taskId = 901;
      const remindAt = 1750000000000;
      await syncTaskReminder(bridge, taskId, remindAt, null);

      final r = await firstReminderOf(taskId);
      expect(r, isNotNull);
      expect(r!.remindAt, remindAt);
    });

    test('清空：已有提醒 → 删除', () async {
      const taskId = 902;
      final created = await bridge.todoReminderCreate(
        const TodoReminderCreateInput(taskId: taskId, remindAt: 1750000000000),
      );
      await syncTaskReminder(bridge, taskId, null, created);

      expect(await firstReminderOf(taskId), isNull);
    });

    test('变更：删旧建新', () async {
      const taskId = 903;
      final old = await bridge.todoReminderCreate(
        const TodoReminderCreateInput(taskId: taskId, remindAt: 111),
      );
      const newAt = 222;
      await syncTaskReminder(bridge, taskId, newAt, old);

      final r = await firstReminderOf(taskId);
      expect(r, isNotNull);
      expect(r!.id, isNot(old.id));
      expect(r.remindAt, newAt);
    });

    test('未动：跳过（同 id 原地不动）', () async {
      const taskId = 904;
      final old = await bridge.todoReminderCreate(
        const TodoReminderCreateInput(taskId: taskId, remindAt: 999),
      );
      await syncTaskReminder(bridge, taskId, 999, old);

      final r = await firstReminderOf(taskId);
      expect(r!.id, old.id);
    });
  });
}
