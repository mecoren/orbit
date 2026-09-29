// 设置页「日历与节假日」卡回归（docs/07 #59 / docs/10 §A-6）：
// 每月自动更新总开关的读（holidayMeta.autoEnabled，缺省开启）与写
// （holidaySetAutoEnabled）双向打通。
//
// 「每日固定更新时刻」口径已随对齐 PiggyCount 下线（改为每月一次 + 总开关），
// 原 08:00 值行/时刻抽屉用例一并删除。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/settings_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_section_card.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: const SettingsScreen()),
    );

/// 越过 Mock 120ms 延迟并收敛帧（写 + invalidate 后重取记账是两段延迟，双跑）
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
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

/// 「日历与节假日」卡内的开关（按卡片作用域取，避免与其它卡开关串号）
Finder _holidaySwitch() => find.descendant(
      of: find.ancestor(
        of: find.text('日历与节假日'),
        matching: find.byType(SectionCard),
      ),
      matching: find.byType(Switch),
    );

void main() {
  testWidgets('日历与节假日：默认开启 → 关闭后落库并回显', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await _scrollTo(tester, find.text('每月自动更新'));
    expect(find.text('每月自动更新'), findsOneWidget);
    // core 缺省开启（cfg_kv 无键按 1 处理），Mock 同口径
    expect(bridge.store.holidayAutoEnabled, isTrue);
    expect(tester.widget<Switch>(_holidaySwitch()).value, isTrue);
    expect(find.textContaining('每月自动联网更新一次'), findsOneWidget);

    await tester.tap(_holidaySwitch());
    await _settle(tester);

    expect(bridge.store.holidayAutoEnabled, isFalse);
    expect(tester.widget<Switch>(_holidaySwitch()).value, isFalse);
    expect(find.textContaining('自动更新已关闭'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('日历与节假日：关闭态重进页面回读已存开关', (tester) async {
    final bridge = MockOrbitBridge()..store.holidayAutoEnabled = false;
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await _scrollTo(tester, find.text('每月自动更新'));
    expect(tester.widget<Switch>(_holidaySwitch()).value, isFalse);
    expect(find.textContaining('自动更新已关闭'), findsOneWidget);
  });
}
