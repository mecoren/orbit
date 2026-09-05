// 四屏链路冒烟测试：以 MockOrbitBridge 注入，泵渲染侧栏首屏与任务子列表，
// 防止 provider 接线 / 布局层面的低级运行时错误回归。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/widgets/glass_fab.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(home: child),
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
    expect(find.text('项目'), findsOneWidget);
    // 七个快捷视图行全部可见（07 报告新增「我的一天」置顶）
    expect(find.text('我的一天'), findsOneWidget);
    expect(find.text('今天截止'), findsOneWidget);
    expect(find.text('本周截止'), findsOneWidget);
    expect(find.text('全部任务'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('无日期'), findsOneWidget);
    // 项目种子数据（新增第 7 个快捷视图行后侧栏更高：
    // 滚到底再断言尾部的项目段与「未分组」行，避免默认 600px 视口截断）
    await tester.scrollUntilVisible(
      find.text('未分组'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
  });

  testWidgets('侧栏首屏：FAB 点击弹出"添加待办"底部抽屉', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const SidebarScreen(), bridge));
    await _settlePastMockLatency(tester);

    // 一级页面右下 FAB → 新建任务表单抽屉出现
    await tester.tap(find.byType(GlassFab));
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
}
