// 排序方向档测试（对齐桌面页头「顺序」档）：
// 1. manual 档不渲染「排序方向」行（拖拽序无方向概念，桌面同口径隐藏）；
// 2. 非 manual 档出现该行，行尾回显当前生效方向（未显式选过 = 档位默认）；
// 3. 就地展开点「降序」→ 行序反转（仅视图排序，不写库）。
// MockOrbitBridge 注入（同 task_reorder_test 的延迟越过口径）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
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

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pumpAndSettle();
}

/// 经页头 ⋮ 下拉面板切排序档（⋮ → 就地展开「排序方式」→ 点档位）
///
/// 面板 2026-10-16 加「存为视图」后条目超出 0.7 屏限高、面板内容可滚——
/// 「排序方式」及其子项可能在可视区外，点前必须 ensureVisible。
Future<void> _switchSort(WidgetTester tester, String label) async {
  await _openPanel(tester);
  await tester.ensureVisible(find.text('排序方式'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('排序方式'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('manual 档不渲染「排序方向」行（拖拽序无方向概念）', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(query: TaskFilterInput(quickView: QuickViewKey.all)),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    await _openPanel(tester);
    expect(find.text('排序方式'), findsOneWidget);
    expect(find.text('排序方向'), findsNothing);
  });

  testWidgets('切「截止时间」出现方向行（回显升序）；切降序行序反转且不写库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      const SubListScreen(query: TaskFilterInput(quickView: QuickViewKey.all)),
      bridge,
    ));
    await _settlePastMockLatency(tester);

    await _switchSort(tester, '截止时间');
    await _settlePastMockLatency(tester);

    // 两行同段（均未逾期），相对顺序随方向反转（种子 due：+1 天 vs +3 天）
    const a = '完成移动端重构方案评审';
    const b = '采购周末露营物资';
    final ascABeforeB =
        tester.getTopLeft(find.text(a)).dy < tester.getTopLeft(find.text(b)).dy;

    // 方向行出现且回显默认升序（子项收起时只有一个「升序」文本）
    await _openPanel(tester);
    expect(find.text('排序方向'), findsOneWidget);
    expect(find.text('升序'), findsOneWidget);

    // 就地展开 → 点降序（子项展开后回显 + 子项共两处「升序」）；
    // 子项选中即执行并关面板。展开后内容超出卡片 0.7 屏高上限，
    // 先 ensureVisible 让滚动容器把目标行滚进可视区再点
    await tester.ensureVisible(find.text('排序方向'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('排序方向'));
    await tester.pumpAndSettle();
    expect(find.text('升序'), findsNWidgets(2));
    await tester.ensureVisible(find.text('降序').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('降序').last);
    await tester.pumpAndSettle();

    // 行序反转（仅视图排序）
    final descABeforeB =
        tester.getTopLeft(find.text(a)).dy < tester.getTopLeft(find.text(b)).dy;
    expect(descABeforeB, isNot(ascABeforeB));

    // 重开面板：行尾回显已切「降序」
    await _openPanel(tester);
    expect(find.text('降序'), findsOneWidget);

    // 不写库：种子任务 position 保持原值
    final storeTask = bridge.store.tasks.values.firstWhere(
      (t) => t['title'] == a,
    );
    expect(storeTask['position'], 0);
  });
}
