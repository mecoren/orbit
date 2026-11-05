// 通知历史页：类型过滤走设置页同款下拉偏好行（行内当前值 + 上下双箭头 +
// 就地展开玻璃菜单），不再是「类型：全部」按钮 + 底部抽屉。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/notification_history_page.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_button.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: const NotificationHistoryPage()),
    );

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  setUp(LocalPrefs.resetForTest);

  testWidgets('类型行：默认全部，点行就地展开并在选中后回写过滤', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _flush(tester);

    // 行内尾随值常驻可见；旧按钮文案已移除
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('类型：全部'), findsNothing);

    // 点行就地展开：五个档位（全部/到期/推迟/完成/跳过），当前档打勾
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(dropdownPreferencePopupRows(), findsNWidgets(5));
    expect(selectedDropdownPreferenceLabels(tester), ['全部']);

    // 选第 2 档「到期」：行内尾随值回写，列表按 kind 重新过滤
    // （弹层条目文字不是 Text，按浮层行位置点击）
    await tester.tapAt(tester.getCenter(dropdownPreferencePopupRows().at(1)));
    await tester.pumpAndSettle();
    expect(find.text('全部'), findsNothing);
    // 行内尾随值 + 列表徽标各一处「到期」
    expect(find.text('到期'), findsNWidgets(2));
    expect(find.text('推迟'), findsNothing);
    expect(find.text('完成'), findsNothing);

    await drainToastTimers(tester);
  });

  testWidgets('清空：有记录时可用', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _flush(tester);

    final clear = tester.widget<OrbitButton>(
      find.widgetWithText(OrbitButton, '清空'),
    );
    expect(clear.onPressed, isNotNull);
  });

  testWidgets('清空：0 条时禁用（与桌面端口径一致）', (tester) async {
    final bridge = MockOrbitBridge();
    bridge.store.notificationLog.clear();
    await tester.pumpWidget(_wrap(bridge));
    await _flush(tester);

    final clear = tester.widget<OrbitButton>(
      find.widgetWithText(OrbitButton, '清空'),
    );
    expect(clear.onPressed, isNull);
    expect(find.text('暂无通知历史'), findsOneWidget);
  });
}
