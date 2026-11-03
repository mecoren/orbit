// 外观页的选择弹层回归：
// 1) 选中判据必须用原始档位键（system/light/dark 等），不能用中文文案
//    （`themeLabel`/`fontSizeLabel` 与 SelectItem.value 永不相等，弹层会
//    一项都不打勾——2026-11-03 外观页截图暴露）；
// 2) 弹层与页头 ⋮ 菜单同源（OrbitDropdownPanelView 行），当前档回勾。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/settings/appearance_page.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('外观页：字号弹层回勾当前档（原始值匹配，非中文标签）', (tester) async {
    await tester.pumpWidget(orbitTestApp(home: const AppearancePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('字号'));
    await tester.pumpAndSettle();

    expect(selectPopup(), findsOneWidget);
    expect(selectedPopupLabels(tester), ['标准'],
        reason: '默认字号档必须回勾「标准」');
  });

  testWidgets('外观页：主题弹层回勾当前档（默认跟随系统）', (tester) async {
    await tester.pumpWidget(orbitTestApp(home: const AppearancePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('主题模式'));
    await tester.pumpAndSettle();

    expect(selectedPopupLabels(tester), ['跟随系统']);
  });
}
