// 顶部下拉面板（2026-09-23，页头 ⋮ 的载体）：
// - 条目成组，组间 1px 分隔线；点面板外关闭；
// - 带子项的条目在**面板内**就地展开（不另开弹层）；
// - 展开期间其余顶层条目置灰，点它们只收起子菜单、不执行该条目；
// - 点子项 = 执行并关面板；再点展开项本身 = 收起子菜单。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart';

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
          OrbitPanelItem(
            icon: OrbitIcons.success,
            label: '隐藏已完成',
            checked: false,
            onTap: () => fired.add('hide'),
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
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showOrbitDropdownPanel(
                  context,
                  topInset: 0,
                  groups: groups(),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Color? labelColor(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style?.color;

  testWidgets('打开：两组条目 + 组间分隔线 + 行尾补充文案', (tester) async {
    await open(tester);

    expect(find.text('编辑项目'), findsOneWidget);
    expect(find.text('视图'), findsOneWidget);
    expect(find.text('筛选'), findsOneWidget);
    expect(find.text('已启用 2 项'), findsOneWidget);
    // 组间 1px 分隔线（两组 → 恰一条）
    expect(find.byType(Divider), findsOneWidget);
    // 未展开时子项不在树上
    expect(find.text('看板视图'), findsNothing);
  });

  testWidgets('宽度收口：锚定面板不铺满（≤ 上限 + 外留白）', (tester) async {
    await open(tester);

    final panel = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_OrbitDropdownPanel',
    );
    final width = tester.getSize(panel).width;
    // 外留白（space8 × 2）由面板自身内边距承担，故比内容宽一档
    expect(width, lessThanOrEqualTo(orbitPanelMaxWidth + 16));
    // 也不能窄到把行尾文案挤掉：仍要明显宽于「图标 + 两字标签」
    expect(width, greaterThan(200));
  });

  testWidgets('就地展开：子项进面板、其余顶层条目置灰、展开项不着灰', (tester) async {
    await open(tester);
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    expect(find.text('列表视图'), findsOneWidget);
    expect(find.text('看板视图'), findsOneWidget);
    // 就地展开，不另开弹层：面板其余条目仍在同一层
    expect(find.text('筛选'), findsOneWidget);

    final colors = AppColors.light;
    // 其余顶层条目置灰（「此刻只在挑子项」）
    expect(labelColor(tester, '筛选'), colors.deactivatedText);
    expect(labelColor(tester, '编辑项目'), colors.deactivatedText);
    // 展开项本身与其子项保持正常层级
    expect(labelColor(tester, '视图'), colors.bodyText);
    expect(labelColor(tester, '列表视图'), colors.bodyText);
  });

  testWidgets('点子项：执行回调并关闭面板', (tester) async {
    await open(tester);
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('看板视图'));
    await tester.pumpAndSettle();

    expect(fired, ['kanban']);
    expect(find.text('筛选'), findsNothing, reason: '面板应已关闭');
  });

  testWidgets('展开后点其他顶层条目：只收起子菜单，不执行该条目', (tester) async {
    await open(tester);
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();

    expect(fired, isEmpty, reason: '置灰条目此刻不可选');
    expect(find.text('看板视图'), findsNothing, reason: '子菜单收起');
    expect(find.text('筛选'), findsOneWidget, reason: '面板仍开着');
  });

  testWidgets('再点展开项本身：收起子菜单（面板不关）', (tester) async {
    await open(tester);
    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('视图'));
    await tester.pumpAndSettle();

    expect(find.text('看板视图'), findsNothing);
    expect(find.text('编辑项目'), findsOneWidget);
    expect(fired, isEmpty);
  });

  testWidgets('点面板外：关闭且不触发任何条目', (tester) async {
    await open(tester);

    // 面板锚在右上（宽 300 / 屏宽 800），左下角空白必在面板外
    await tester.tapAt(const Offset(20, 560));
    await tester.pumpAndSettle();

    expect(find.text('编辑项目'), findsNothing);
    expect(fired, isEmpty);
  });
}
