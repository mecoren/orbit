// 新建/编辑表单全量字段测试：字段存在性、重复规则落库、提醒同步语义
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/form_bottom_sheet.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart' show QuickViewKey;
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_section_card.dart';
import 'support/orbit_test_app.dart';
import 'package:orbit/core/theme/icon_map.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
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
  await tester.tap(find.byIcon(OrbitIcons.add));
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
  testWidgets('表单字段：信息区四行（项目/优先级/状态/重复）齐备', (tester) async {
    await _openForm(tester);

    expect(find.text('添加待办'), findsOneWidget);
    // 信息区四行为「行显值 + 点行弹抽屉」，不再行内直选
    await _scrollTo(tester, find.text('状态'));
    expect(find.text('状态'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(SectionCard), matching: find.text('未分组')),
      findsOneWidget,
    );

    // 状态行 → 三档单选抽屉 → 选中「进行中」回显到行
    await tester.tap(find.text('状态'));
    await tester.pumpAndSettle();
    // 三档选项文案：v3 起选择抽屉是 shadcn sheet（无 Material BottomSheet 祖先
    // 可限定，故不再用 byType 圈范围）。「进行中」全屏唯一；「待办」（表单行值）
    // 与「已完成」（侧栏行）会撞同名文案，退化为存在性断言
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('待办'), findsWidgets);
    expect(find.text('已完成'), findsWidgets);
    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();
    expect(find.text('进行中'), findsOneWidget);

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

  testWidgets('校验失败：标题/描述框保留错误态边框（不回退到无边框）', (tester) async {
    await _openForm(tester);

    // 空标题直接保存 → 触发校验（不落库）
    await tester.tap(find.byIcon(OrbitIcons.check));
    await tester.pumpAndSettle();

    // 回归保护：只覆盖 enabledBorder 时，错误态会回退到主题 BorderSide.none，
    // 校验失败后输入框边框直接消失（2026-09-19 实机踩坑）
    // TextFormField 不透出 decoration，取它构建出的内部 TextField
    final decoration = tester
        .widget<TextField>(find.descendant(
          of: find.byType(TextFormField).first,
          matching: find.byType(TextField),
        ))
        .decoration!;
    final errorBorder = decoration.errorBorder! as OutlineInputBorder;
    expect(errorBorder.borderSide.style, BorderStyle.solid);
    expect(errorBorder.borderSide.color, isNot(Colors.transparent));
    final focusedError = decoration.focusedErrorBorder! as OutlineInputBorder;
    expect(focusedError.borderSide.style, BorderStyle.solid);
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
    // 「无」在信息区（优先级 P0）与日期卡片（提醒未设占位）各一处——限定在
    // 日期与提醒卡片内断言（按卡片标题行定位其 SectionCard 祖先）
    final dateCard = find.ancestor(
      of: find.text('日期与提醒'),
      matching: find.byType(SectionCard),
    );
    expect(
      find.descendant(of: dateCard, matching: find.text('无')),
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

    await tester.tap(find.byIcon(OrbitIcons.check));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '快捷截止任务');
    final now = DateTime.now();
    expect(task.dueDate,
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch);
  });

  testWidgets('NLP 快速输入：标题 token 实时预览 chips + 保存应用剥离', (tester) async {
    final bridge = await _openForm(tester);

    // 输入带日期 + 优先级 token 的标题 → 预览 chips 出现
    await tester.enterText(find.byType(TextFormField).first, '明天开会 !3');
    await tester.pump();

    // chips：截止（明天日期）+ P3 优先级。
    // 图标限定在表单抽屉内：v3 图标收口后侧栏「今天截止」等行也用同一批语义图标，
    // 裸 byIcon 会同时命中背后的侧栏
    Finder inForm(Finder matching) => find.descendant(
          of: find.byType(BottomSheet).last,
          matching: matching,
        );
    expect(inForm(find.byIcon(OrbitIcons.calendar)), findsOneWidget);
    expect(inForm(find.byIcon(OrbitIcons.flag)), findsOneWidget);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final expectedY =
        '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    expect(find.text('截止 $expectedY'), findsOneWidget);

    // 保存 → 字段应用（due_date=明天零点、priority=3）+ 标题剥离
    await tester.tap(find.byIcon(OrbitIcons.check));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '开会');
    expect(task.priority, 3);
    final tomorrowZero = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    expect(task.dueDate, tomorrowZero.millisecondsSinceEpoch);
  });

  testWidgets('保存：重复行抽屉选「每天」落库 repeat_mode=1/repeat_after=1', (tester) async {
    final bridge = await _openForm(tester);

    await tester.enterText(find.byType(TextFormField).first, '重复任务A');
    // 重复行 → 共享重复编辑抽屉（预设档点选即回填并关闭，与桌面端同口径）
    await _scrollTo(tester, find.text('重复'));
    await tester.tap(find.text('重复'));
    await tester.pumpAndSettle();
    expect(find.text('自定义'), findsOneWidget);

    await tester.tap(find.text('每天'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(OrbitIcons.check));
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

  testWidgets('保存：重复抽屉自定义面板（每 3 天 + 剩 5 次）落库扩展字段', (tester) async {
    final bridge = await _openForm(tester);

    await tester.enterText(find.byType(TextFormField).first, '重复任务B');
    await _scrollTo(tester, find.text('重复'));
    await tester.tap(find.text('重复'));
    await tester.pumpAndSettle();

    // 自定义面板：间隔 3 × 天 + 结束=次数 5
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('星期几'), findsNothing);
    expect(find.text('结束'), findsOneWidget);
    expect(find.text('完成后'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('repeat_interval_field')), '3');
    await tester.tap(find.text('次数'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('repeat_end_count_field')), '5');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(OrbitIcons.check));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '重复任务B');
    expect(task.repeatMode, 1);
    expect(task.repeatAfter, 3);
    expect(task.repeatEndType, 2);
    expect(task.repeatEndParam, 5);
  });

  testWidgets('重复抽屉：有截止日期时显示「下次 M月d日」预览徽标', (tester) async {
    await _openForm(tester);

    // 截止日期快捷「今天」→ 预览锚点就位（不必走日期面板）
    await _scrollTo(tester, find.text('截止日期'));
    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('重复'));
    await tester.tap(find.text('重复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每天'));
    await tester.pumpAndSettle();

    // 规则生效 + 锚点已填 → 重开抽屉即见「下次 …」（每天 → 明天）
    await tester.tap(find.text('重复'));
    await tester.pumpAndSettle();
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    const weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];
    expect(
      find.text('下次 ${tomorrow.month}月${tomorrow.day}日'
          '（周${weekdayNames[tomorrow.weekday - 1]}）'),
      findsOneWidget,
    );
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

  // ---------- 视图内新增自动带视图标记（#39）----------

  /// 以指定快捷视图直接打开表单（模拟子列表 FAB 携 quickView 入口）
  Future<MockOrbitBridge> openFormInView(
    WidgetTester tester,
    QuickViewKey view,
  ) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
        child: orbitTestApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: IconButton(
                  icon: const Icon(OrbitIcons.add),
                  onPressed: () => showTodoFormSheet(context, quickView: view),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(OrbitIcons.add));
    await tester.pumpAndSettle();
    return bridge;
  }

  testWidgets('我的一天视图新建 → myDayDate=今天零点静默附加', (tester) async {
    final bridge = await openFormInView(tester, QuickViewKey.myDay);

    await tester.enterText(find.byType(TextFormField).first, '我的一天快建任务');
    await tester.tap(find.byIcon(OrbitIcons.check));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '我的一天快建任务');
    final now = DateTime.now();
    expect(
      task.myDayDate,
      DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
    );
  });

  testWidgets('收藏视图新建 → isFavorite=1 静默附加', (tester) async {
    final bridge = await openFormInView(tester, QuickViewKey.favorite);

    await tester.enterText(find.byType(TextFormField).first, '收藏快建任务');
    await tester.tap(find.byIcon(OrbitIcons.check));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '收藏快建任务');
    expect(task.isFavorite, 1);
  });

  testWidgets('今日截止视图新建 → 截止预填今天 18:00（#39 时刻口径）', (tester) async {
    final bridge = await openFormInView(tester, QuickViewKey.today);

    await tester.enterText(find.byType(TextFormField).first, '今日截止快建任务');
    await tester.tap(find.byIcon(OrbitIcons.check));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '今日截止快建任务');
    final now = DateTime.now();
    expect(
      task.dueDate,
      DateTime(now.year, now.month, now.day, 18).millisecondsSinceEpoch,
    );
  });

  testWidgets('无视图入口新建 → 不带任何标记（回归保护）', (tester) async {
    final bridge = await _openForm(tester); // 侧栏 FAB：quickView=null

    await tester.enterText(find.byType(TextFormField).first, '普通快建任务');
    await tester.tap(find.byIcon(OrbitIcons.check));
    await _settlePastMockLatency(tester);

    final tasks = await tester.runAsync(
      () => bridge.todoTaskList(const ListFilter()),
    );
    final task = tasks!.firstWhere((t) => t.title == '普通快建任务');
    expect(task.myDayDate, isNull);
    expect(task.isFavorite, 0);
    // 截止无预填（表单默认无截止；NLP 未命中日期词）
    expect(task.dueDate, isNull);
  });
}
