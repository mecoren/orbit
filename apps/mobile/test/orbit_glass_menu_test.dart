// OS4 玻璃「按钮 → 菜单」形变弹层（2026-11-02，页头右上角 ⋮ 的载体）：
// - 点按钮展开一级菜单（条目渲染 + 组间分隔 + 行尾副文案）；
// - 带 children 的条目堆叠展开二级面板（首行「返回上级」，选中档打勾）；
// - 点子项 = 执行回调并整层关闭；返回上级 = 收回一级、一级不关；
// - 点面板外 = 关闭且不触发条目。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_menu.dart';

import 'support/orbit_test_app.dart';

void main() {
  final fired = <String>[];

  setUp(fired.clear);

  List<List<OrbitPanelItem>> groups() => [
    [
      OrbitPanelItem(
        icon: OrbitIcons.edit,
        label: '编辑项目',
        onTap: () => fired.add('edit'),
      ),
      OrbitPanelItem(
        icon: OrbitIcons.list,
        label: '视图',
        children: [
          OrbitPanelItem(
            icon: OrbitIcons.list,
            label: '列表视图',
            checked: true,
            onTap: () => fired.add('list'),
          ),
          OrbitPanelItem(
            icon: OrbitIcons.kanban,
            label: '看板视图',
            onTap: () => fired.add('kanban'),
          ),
        ],
      ),
    ],
    [
      OrbitPanelItem(
        icon: OrbitIcons.filterList,
        label: '筛选',
        trailingLabel: '已启用 2 项',
        onTap: () => fired.add('filter'),
      ),
    ],
  ];

  Widget host() => orbitTestApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topRight,
        child: OrbitGlassMenuButton(
          groupsBuilder: groups,
          tooltip: '更多操作',
          icon: const Icon(OrbitIcons.moreVertical),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
  }

  /// 在弹层条目里按文案找 [MiuixGlassPopupItem]（一级与二级同型）
  MiuixGlassPopupItem popupItem(WidgetTester tester, String text) =>
      tester.widget<MiuixGlassPopupItem>(
        find.ancestor(
          of: find.text(text),
          matching: find.byType(MiuixGlassPopupItem),
        ),
      );

  testWidgets('打开：一级条目 + 组间分隔 + 行尾副文案；子项未展开', (tester) async {
    await open(tester);

    expect(find.text('编辑项目'), findsOneWidget);
    expect(find.text('视图'), findsOneWidget);
    expect(find.text('筛选'), findsOneWidget);
    expect(find.text('已启用 2 项'), findsOneWidget);
    // 两组 → 恰一条分隔线；未展开时二级面板内容不在树上
    expect(find.byType(Divider), findsOneWidget);
    expect(find.text('看板视图'), findsNothing);
    expect(find.text('返回上级'), findsNothing);
  });

  testWidgets('二级面板：堆叠展开、首行返回上级、选中档打勾', (tester) async {
    await open(tester);
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    expect(find.text('返回上级'), findsOneWidget);
    expect(find.text('列表视图'), findsOneWidget);
    expect(find.text('看板视图'), findsOneWidget);
    // 一级菜单仍在（堆叠而非替换）
    expect(find.text('编辑项目'), findsOneWidget);
    expect(popupItem(tester, '列表视图').selected, isTrue);
    expect(popupItem(tester, '看板视图').selected, isFalse);
  });

  testWidgets('返回上级：收回二级，一级菜单不关', (tester) async {
    await open(tester);
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('返回上级'));
    await tester.pumpAndSettle();

    expect(find.text('看板视图'), findsNothing);
    expect(find.text('编辑项目'), findsOneWidget, reason: '一级菜单仍开着');
    expect(fired, isEmpty);
  });

  testWidgets('点子项：执行回调并整层关闭', (tester) async {
    await open(tester);
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('看板视图'));
    await tester.pumpAndSettle();

    expect(fired, ['kanban']);
    expect(find.text('编辑项目'), findsNothing, reason: '整层应已关闭');
    expect(find.text('看板视图'), findsNothing);
  });

  testWidgets('点一级叶子条目：执行回调并关闭', (tester) async {
    await open(tester);

    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();

    expect(fired, ['filter']);
    expect(find.text('编辑项目'), findsNothing);
  });

  testWidgets('点面板外：关闭且不触发任何条目', (tester) async {
    await open(tester);

    // 菜单锚在右上，左下角空白必在面板外
    await tester.tapAt(const Offset(20, 560));
    await tester.pumpAndSettle();

    expect(find.text('编辑项目'), findsNothing);
    expect(fired, isEmpty);
  });

  testWidgets('任意触发件：标题式触发开菜单，选条目回调并关闭', (tester) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: OrbitGlassMenu(
              groupsBuilder: groups,
              anchorContent: const Text('快捷视图'),
              triggerBuilder: (onTap) =>
                  InkWell(onTap: onTap, child: const Text('快捷视图')),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('快捷视图'));
    await tester.pumpAndSettle();
    expect(find.text('编辑项目'), findsOneWidget);

    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    expect(fired, ['filter']);
    expect(find.text('编辑项目'), findsNothing);
  });
}
