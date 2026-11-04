// 外观页回归（2026-11-04 下拉面板改用库内 OS4 玻璃弹层后）：
// 1) 选中判据必须用原始档位键（system/light/dark 等），不能用中文文案
//    （`themeLabel`/`fontSizeLabel` 与 SelectItem.value 永不相等，弹层会
//    一项都不打勾——2026-11-03 外观页截图暴露）；
// 2) 四行尾随位是「当前档 + 上下双箭头」：值取自 items 里与 current 相等的
//    label，不在这里渲染就等于没有回显；
// 3) 强调色行必须始终显示当前 #RRGGBB——默认色 #4E8CFF 不在 10 色预设板里，
//    靠弹层注入「当前色」项兜底，否则尾随值与弹层对勾双双落空。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/modules/settings/appearance_page.dart';
import 'package:orbit/shared/utils/hex_color.dart';

import 'support/orbit_test_app.dart';

void main() {
  testWidgets('外观页：字号弹层回勾当前档（原始值匹配，非中文标签）', (tester) async {
    await tester.pumpWidget(orbitTestApp(home: const AppearancePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('字号'));
    await tester.pumpAndSettle();

    expect(dropdownPopup(), findsOneWidget);
    expect(selectedDropdownLabels(tester), ['标准'], reason: '默认字号档必须回勾「标准」');
  });

  testWidgets('外观页：主题弹层回勾当前档（默认跟随系统）', (tester) async {
    await tester.pumpWidget(orbitTestApp(home: const AppearancePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('主题模式'));
    await tester.pumpAndSettle();

    expect(selectedDropdownLabels(tester), ['跟随系统']);
  });

  testWidgets('外观页：四行尾随当前档（含强调色 #RRGGBB）', (tester) async {
    await tester.pumpWidget(orbitTestApp(home: const AppearancePage()));
    await tester.pumpAndSettle();

    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    expect(find.text('常规'), findsOneWidget);
    expect(find.text(colorToHex(OrbitAccents.themeAccent)), findsOneWidget);
  });

  testWidgets('外观页：强调色弹层回勾当前色 + 自定义入口', (tester) async {
    await tester.pumpWidget(orbitTestApp(home: const AppearancePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('强调色'));
    await tester.pumpAndSettle();

    expect(dropdownPopup(), findsOneWidget);
    expect(selectedDropdownLabels(tester), [
      colorToHex(OrbitAccents.themeAccent),
    ]);
    expect(find.text('自定义…'), findsOneWidget);
  });
}
