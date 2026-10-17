// 行内星标 / 我的一天改可点开关（G8，对齐桌面 task-list-view.tsx:945-79、
// task-table-view.tsx:481-519、matrix-view.tsx:347-363 的 hover 开关钮）：
// 桌面三视图行内这两枚都是**开关**（hover 显现、点按切换），移动端此前只在
// 激活时渲染只读图标、无快捷开关（写入口只在长按菜单/详情）。
//
// 移动端无 hover 的触控映射：**恒显**（未激活弱化灰、激活语义色），点按即切换
// ——桌面 hover 后长什么样，移动端就长什么样。
//
// 矩阵行只有星标（桌面 matrix-view.tsx:346 明注「无 my_day 按钮——象限格是
// 优先级工作面」），不补我的一天。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<void> _pumpList(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(
    const SubListScreen(
      query: TaskFilterInput(quickView: QuickViewKey.all),
    ),
    bridge,
  ));
  await _settlePastMockLatency(tester);
}

/// 经 ⋮ 面板切视图档
Future<void> _switchView(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('视图'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('视图'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('$label视图'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('$label视图'));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _storeTask(MockOrbitBridge bridge, String title) =>
    bridge.store.tasks.values.firstWhere((t) => t['title'] == title);

/// 目标任务行内的图标（恒显后每行都有星标/我的一天，须按行圈定点击目标）
Finder _iconInRow(String title, IconData icon) => find.descendant(
      of: find.ancestor(
        of: find.text(title),
        matching: find.byType(InkWell),
      ),
      matching: find.byIcon(icon),
    );

void main() {
  testWidgets('列表行：星标/我的一天恒显可点，点按即切换落库', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    final t = _storeTask(bridge, '完成移动端重构方案评审');
    // 种子任务 is_favorite=1、my_day_date=null
    expect(t['is_favorite'], 1);
    expect(t['my_day_date'], isNull);

    // 未激活的「我的一天」也必须恒显可点（不能只在激活时渲染）
    expect(
        _iconInRow('完成移动端重构方案评审', OrbitIcons.sunrise), findsOneWidget);
    expect(_iconInRow('完成移动端重构方案评审', OrbitIcons.star), findsOneWidget);

    // 点我的一天 → 落 my_day_date
    await tester
        .tap(_iconInRow('完成移动端重构方案评审', OrbitIcons.sunrise));
    await _settlePastMockLatency(tester);
    expect(_storeTask(bridge, '完成移动端重构方案评审')['my_day_date'],
        isNotNull);

    // 点星标 → 收藏关掉
    await tester.tap(_iconInRow('完成移动端重构方案评审', OrbitIcons.star));
    await _settlePastMockLatency(tester);
    expect(_storeTask(bridge, '完成移动端重构方案评审')['is_favorite'], 0);
  });

  testWidgets('表格行：星标/我的一天恒显可点，点按切换', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    await _switchView(tester, '表格');

    expect(
        _iconInRow('完成移动端重构方案评审', OrbitIcons.sunrise), findsOneWidget);
    await tester
        .tap(_iconInRow('完成移动端重构方案评审', OrbitIcons.sunrise));
    await _settlePastMockLatency(tester);
    expect(_storeTask(bridge, '完成移动端重构方案评审')['my_day_date'],
        isNotNull);
  });

  testWidgets('矩阵行：星标可点（无我的一天——象限格是优先级工作面）',
      (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    await _switchView(tester, '矩阵');

    expect(_iconInRow('完成移动端重构方案评审', OrbitIcons.star), findsOneWidget);
    expect(_iconInRow('完成移动端重构方案评审', OrbitIcons.sunrise), findsNothing,
        reason: '桌面 matrix-view 明注无 my_day 按钮');

    await tester.tap(_iconInRow('完成移动端重构方案评审', OrbitIcons.star));
    await _settlePastMockLatency(tester);
    expect(_storeTask(bridge, '完成移动端重构方案评审')['is_favorite'], 0);
  });
}
