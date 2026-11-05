// 外观页回归（2026-11-05 行组件改为 OrbitDropdownPreference、弹层与「今天」
// 页头 ⋮ 菜单同一套玻璃菜单口径后）：
// 1) 选中判据必须用原始档位键（system/light/dark 等）换算下标，不能用中文
//    文案匹配（Appearance.themeValue 等返回档位键，与 label 永不相等）；
// 2) 四行尾随位是「当前档 + 上下双箭头」：库内偏好行从选中项 text 回显，
//    弹层选中态由 item.selected 驱动，漏配就等于没有回显/没有对勾；
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

    expect(dropdownPreferencePopupRows(), findsWidgets);
    expect(selectedDropdownPreferenceLabels(tester), ['标准'],
        reason: '默认字号档必须回勾「标准」');
  });

  testWidgets('外观页：主题弹层回勾当前档（默认跟随系统）', (tester) async {
    await tester.pumpWidget(orbitTestApp(home: const AppearancePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('主题模式'));
    await tester.pumpAndSettle();

    expect(selectedDropdownPreferenceLabels(tester), ['跟随系统']);
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

    expect(dropdownPreferencePopupRows(), findsWidgets);
    expect(selectedDropdownPreferenceLabels(tester), [
      colorToHex(OrbitAccents.themeAccent),
    ]);
    expect(find.text('自定义…'), findsOneWidget);
  });
}
