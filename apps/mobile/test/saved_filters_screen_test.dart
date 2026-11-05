// 保存的筛选器：构建抽屉里的「状态 / 优先级 / 项目 / 标签 / 提醒 / 附件 /
// 未完成子任务」一律走设置页同款下拉偏好行（行内常驻当前值 + 上下双箭头），
// 不再是「状态：全部 >」这种手搓值行。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/saved_filters_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_preference.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
  overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
  child: orbitTestApp(home: const SavedFiltersScreen()),
);

void main() {
  testWidgets('新建筛选器抽屉：状态/优先级走下拉偏好行', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建筛选器').last);
    await tester.pumpAndSettle();

    // 抽屉内两行偏好：行内常驻当前档
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('优先级'), findsOneWidget);
    expect(find.text('全部状态'), findsOneWidget);
    expect(find.text('全部优先级'), findsOneWidget);

    // 状态行就地展开：四档，当前档打勾
    await tester.tap(find.text('全部状态'));
    await tester.pumpAndSettle();
    expect(dropdownPreferencePopupRows(), findsNWidgets(4));
    expect(selectedDropdownPreferenceLabels(tester), ['全部状态']);

    // 弹层条目文字不是 Text，按浮层行位置点第 3 档（进行中）
    await tester.tapAt(tester.getCenter(dropdownPreferencePopupRows().at(2)));
    await tester.pumpAndSettle();
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('全部状态'), findsNothing);
  });

  /// 2026-11-05：项目 / 标签 / 提醒 / 附件 / 未完成子任务五行原先各自手搓
  /// 「值 + 右箭头」（项目/标签是多选 InkWell，另三行是底部三态抽屉），
  /// 与上方状态/优先级不同档。现统一成同款行样式（双箭头 + 尾随值）；
  /// 日期四行（截止≥ / 截止＜ / 创建≥ / 完成≥）同样收进这套行。
  testWidgets('全表单统一为下拉偏好行样式（尾随值 + 上下双箭头）', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建筛选器').last);
    await tester.pumpAndSettle();

    // 行标题都在（无值态）
    for (final label in [
      '状态',
      '优先级',
      '截止≥',
      '截止＜',
      '创建≥',
      '完成≥',
      '项目',
      '标签',
      '提醒',
      '附件',
      '未完成子任务',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label 行标题应在');
    }

    // 双箭头是这套行样式的判据：状态/优先级 2 + 日期 4 + 项目/标签 2 + 三态 3
    expect(
      find.byType(MiuixDropdownArrowEndAction),
      findsNWidgets(11),
      reason: '十一行都应是下拉偏好行样式（上下双箭头），不得残留右箭头',
    );

    // 三态行就地展开玻璃菜单，当前档「不限」打勾。
    // 长表单超出 600 视口，「提醒」在屏幕外，先滚进可视区再点
    await tester.scrollUntilVisible(
      find.text('提醒'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('提醒'));
    await tester.pumpAndSettle();
    expect(dropdownPreferencePopupRows(), findsNWidgets(3));
    expect(selectedDropdownPreferenceLabels(tester), ['不限']);
  });

  /// 日期行有值时，行尾 X **顶替**上下双箭头（不并排、不占两格）——
  /// 用户改完立刻能在原位清空。
  testWidgets('日期有值：X 顶替箭头位置', (tester) async {
    // 带初始条件 → 首帧后自动弹构建抽屉并预填（「保存为筛选器」预填链）
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(MockOrbitBridge())],
        child: orbitTestApp(
          home: const SavedFiltersScreen(
            initialConditions: {'due_from': 1762272000000},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.byType(MiuixBasicComponent), findsWidgets, reason: '抽屉已弹出');
    // 有值那一行少了箭头（11 → 10），说明 X 顶替了它的位置
    expect(
      find.byType(MiuixDropdownArrowEndAction).evaluate().length,
      10,
      reason: '日期有值行应以 X 顶替双箭头',
    );
  });
}
