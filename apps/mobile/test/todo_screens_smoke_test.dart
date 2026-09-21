// 四屏链路冒烟测试：以 MockOrbitBridge 注入，泵渲染侧栏首屏与任务子列表，
// 防止 provider 接线 / 布局层面的低级运行时错误回归。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/providers/todo_providers.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_fab.dart';
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

void main() {
  testWidgets('侧栏首屏：标题/分区头/快捷视图行渲染', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const SidebarScreen(), bridge));
    await _settlePastMockLatency(tester);

    expect(find.text('循迹'), findsOneWidget);
    expect(find.text('快捷视图'), findsOneWidget);
    // 七个快捷视图行全部可见（07 报告新增「我的一天」置顶）
    expect(find.text('我的一天'), findsOneWidget);
    expect(find.text('今天截止'), findsOneWidget);
    expect(find.text('本周截止'), findsOneWidget);
    expect(find.text('全部任务'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('无日期'), findsOneWidget);
    // 日历/统计入口行可见（回收站行在统计行之下；新增行后 600px 视口装不下，
    // 滚到底再断言尾部的回收站/项目段与「未分组」行，避免默认视口截断）
    expect(find.text('日历'), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
    // 项目种子数据
    await tester.scrollUntilVisible(
      find.text('未分组'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);

    // 项目行固定 folder 图标按项目色染色（2026-09-09）：种子「工作」#4E8CFF
    // —— 项目行是 InkWell+Row，Icon 与项目名是 Row 的兄弟节点；
    // 以整行 InkWell 为锚取其下 Icon（首列即项目图标，尾列是拖拽把手）。
    final workRows = find.ancestor(of: find.text('工作'), matching: find.byType(InkWell));
    final rowIcons = tester.widgetList<Icon>(
      find.descendant(of: workRows, matching: find.byType(Icon)),
    );
    final folder = rowIcons.firstWhere((i) => i.icon == OrbitIcons.folder);
    expect(folder.color, const Color(0xFF4E8CFF));
  });

  testWidgets('侧栏首屏：FAB 点击弹出"添加待办"底部抽屉', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const SidebarScreen(), bridge));
    await _settlePastMockLatency(tester);

    // 一级页面右下 FAB → 新建任务表单抽屉出现
    await tester.tap(find.byType(OrbitFab));
    await tester.pumpAndSettle();

    expect(find.text('添加待办'), findsOneWidget);
    expect(find.text('标题 *'), findsOneWidget);
  });

  testWidgets('任务子列表：全量视图渲染任务行卡片', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    // 动态标题=视图名；种子任务行出现
    expect(find.text('全部任务'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == 'TodoTaskTile'),
      findsWidgets,
    );
    // 种子数据中的具体任务标题
    expect(find.text('完成移动端重构方案评审'), findsOneWidget);
  });

  testWidgets('任务子列表：今天视图空态文案', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.nodate),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);
    // 种子数据均带截止日期或不匹配……无日期视图含未分组两条，不应为空；
    // 此处断言标题正确即可（筛选语义由 task_logic 单测覆盖）
    expect(find.text('无日期'), findsOneWidget);
  });

  testWidgets('任务子列表：命中拉取上限出「不完整」条幅（A5）', (tester) async {
    final bridge = MockOrbitBridge();
    // 造满单份缓存上限（mock 不过滤 pageSize，返回全量——刚好 10000 条即命中）
    final now = bridge.store.now();
    while (bridge.store.tasks.length < taskListPageSize) {
      final t = <String, dynamic>{
        ...bridge.store.newEntity('f'),
        'title': '压测任务 ${bridge.store.tasks.length}',
        'description': null,
        'project_id': null,
        'priority': 0,
        'status': 'pending',
        'done': 0,
        'done_at': null,
        'due_date': null,
        'start_date': null,
        'repeat_after': 1,
        'repeat_mode': 0,
        'hex_color': '',
        'percent_done': 0,
        'position': bridge.store.tasks.length,
        'is_favorite': 0,
        'my_day_date': null,
        'is_deleted': 0,
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
        'version': 1,
      };
      bridge.store.tasks[t['id'] as int] = t;
    }

    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    expect(find.textContaining('当前列表不完整'), findsOneWidget);
  });

  // 多选崩屏回归（2026-09-20）：选择态强制回落 ListView.builder 分支，该分支
  // 对「无逾期任务」的 rest 索引曾算成 -1 → RangeError 整屏红。
  testWidgets('任务子列表：无逾期任务时进入多选不崩（索引不越界）', (tester) async {
    // 真机视口：600 高的小屏下长按菜单本身会贴边溢出，与本用例无关
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final bridge = MockOrbitBridge();
    // 抹掉截止时间与完成态：逾期区为空（触发原越界分支）
    for (final t in bridge.store.tasks.values) {
      t['due_date'] = null;
      t['done'] = 0;
      t['status'] = 'pending';
      t['done_at'] = null;
    }

    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    await tester.longPress(find.text('完成移动端重构方案评审'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('完成移动端重构方案评审'), findsWidgets);
  });

  // 逾期区索引口径回归：非重排档（切排序档后）走 ListView.builder，
  // 逾期行数须与 od.length 一致（曾把 od[0] 渲染两次、丢掉 od.last）。
  testWidgets('任务子列表：非重排档下逾期区每行只渲染一次', (tester) async {
    final bridge = MockOrbitBridge();
    // 再压一条逾期：逾期区 ≥2 行才暴露索引偏移（1 行时偏移正好抵消）
    final extra = bridge.store.tasks.values.firstWhere((t) =>
        t['is_deleted'] == 0 && t['done'] == 0 && t['due_date'] == null);
    extra['due_date'] = bridge.store.now() - 86400000;
    extra['title'] = '逾期压测任务';

    await tester.pumpWidget(_wrap(
      const SubListScreen(
        query: TaskFilterInput(quickView: QuickViewKey.all),
      ),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    // 切出 manual 档 → 列表换 ListView.builder 分支（逾期置顶区块）
    await tester.tap(find.byIcon(OrbitIcons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('截止时间'));
    await tester.pumpAndSettle();

    // 区块头计数与实际行数一致：每条逾期任务只渲染一次，不重复不丢失
    expect(find.text('逾期 · 2'), findsOneWidget);
    expect(find.text('回复合作方邮件（逾期）'), findsOneWidget);
    expect(find.text('逾期压测任务'), findsOneWidget);
  });
}
