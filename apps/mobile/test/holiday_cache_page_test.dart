// 设置页「节假日数据缓存」查看页回归：
// 概览统计（总数/放假补班拆分/覆盖年份/更新记账）+ 按年分组明细（日期/休班徽标/假日名）。
// 数据形状对齐 MockOrbitBridge 节假日假数据（2026 表节选 3 行）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/holiday_cache_page.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: const HolidayCachePage()),
    );

/// 越过 FutureProvider 落定并收敛帧
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('概览：总数/放假补班拆分/覆盖年份/更新时刻', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    expect(find.text('节假日数据缓存'), findsOneWidget);
    expect(find.text('共 3 条（放假 2 · 补班 1）'), findsOneWidget);
    expect(find.textContaining('覆盖年份：2026'), findsOneWidget);
    // mock 记账 fixedHour 取 store 缺省 8，上次成功更新取固定戳
    expect(find.textContaining('每日更新时刻：08:00'), findsOneWidget);
    expect(find.textContaining('上次成功更新：'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
  });

  testWidgets('明细：按年分组 + 日期/休班徽标/假日名', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    expect(find.text('2026 年（3 条）'), findsOneWidget);
    expect(find.text('元旦'), findsOneWidget);
    expect(find.text('初一'), findsOneWidget);
    expect(find.text('元旦后补班'), findsOneWidget);
    expect(find.text('休'), findsNWidgets(2));
    expect(find.text('班'), findsOneWidget);
    // 行内日期去前导零
    expect(find.text('1月1日'), findsOneWidget);
    expect(find.text('2月17日'), findsOneWidget);
  });

  testWidgets('立即更新：成功 toast 并停留可收尾', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    await tester.tap(find.text('立即更新'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('节假日数据已更新'), findsOneWidget);
    await drainToastTimers(tester);
  });
}
