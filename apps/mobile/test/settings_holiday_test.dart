// 设置页「日历与节假日」卡回归（docs/07 #59 / docs/10 §A-6）：
// 每日固定更新时刻的读（holidayMeta.fixedHour）与写（holidaySetFixedHour）双向打通。
// 桥位此前双端均就绪（移动 FRB 生成物 + 桌面命令）但 UI 零消费。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/settings_screen.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: const SettingsScreen()),
    );

/// 越过 Mock 120ms 延迟并收敛帧
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 设置页多于一屏（视口 600）：让目标落在页头之下、视口下沿之上。
///
/// 两个坑：①设置页是 `ListView(children:)`（即时构建，全树已存在），
/// `dragUntilVisible` 立即返回**不做任何滚动**；②单向补滚只判下沿会过冲，
/// 把目标顶到页头（56px，Stack 覆盖）之下 → 点击落空报 hit test 警告。
/// 故此处按「低于页头 / 高于下沿」双向收敛。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(ListView);
  await tester.dragUntilVisible(finder, scrollable, const Offset(0, -160));
  await tester.pumpAndSettle();
  for (var i = 0; i < 10; i++) {
    final rect = tester.getRect(finder);
    if (rect.top >= 80 && rect.bottom <= 580) break;
    await tester.drag(scrollable, Offset(0, rect.top < 80 ? 120 : -120));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('日历与节假日：默认 08:00 → 选 21:00 落库并回显', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await _scrollTo(tester, find.text('每日更新时刻'));
    expect(find.text('每日更新时刻'), findsOneWidget);
    // 值行读 holidayMeta.fixedHour（core 缺省 08:00）
    expect(find.text('08:00'), findsOneWidget);

    await tester.tap(find.text('每日更新时刻'));
    await tester.pumpAndSettle();

    // 抽屉已开：标题与值行同名「每日更新时刻」，故应有两处
    expect(find.text('每日更新时刻'), findsNWidgets(2));

    // 0-23 整点档位；抽屉内容超一屏（shrinkWrap + 0.6 屏高上限），
    // 远端档位需在抽屉内滚动后才可见（页面 ListView 在前、抽屉在后，取 last）
    expect(find.text('08:00'), findsWidgets);
    await tester.dragUntilVisible(
      find.text('21:00'),
      find.byType(ListView).last,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('21:00'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('21:00'));
    await tester.pumpAndSettle();

    expect(bridge.store.holidayFixedHour, 21);
    // 抽屉关闭后值行回显新时刻
    expect(find.text('21:00'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('日历与节假日：重进页面回读已存的时刻', (tester) async {
    final bridge = MockOrbitBridge()..store.holidayFixedHour = 6;
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await _scrollTo(tester, find.text('每日更新时刻'));
    expect(find.text('06:00'), findsOneWidget);
  });
}
