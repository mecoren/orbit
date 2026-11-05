// 保存的筛选器：构建抽屉里的「状态 / 优先级」走设置页同款下拉偏好行
// （行内常驻当前档 + 上下双箭头 + 就地玻璃菜单），不再是「状态：全部 >」按钮。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/saved_filters_screen.dart';

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
}
