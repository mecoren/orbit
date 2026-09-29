// 设置页「节假日数据缓存」查看页回归：
// 概览统计（总数/放假补班拆分/覆盖年份/更新记账/自动开关）
// + 按年分组明细（日期/休班徽标/假日名）
// + 三处联网写入口（立即更新 / 按年份范围获取 / 更新该年）
// + 范围补写部分成功的如实上报（三计数 + 失败年份）。
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

/// 显式推进假时钟（Mock `_delay` 不排帧，`pumpAndSettle` 不会自己走完）
Future<void> _advance(WidgetTester tester, int ms) async {
  await tester.pump(Duration(milliseconds: ms));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('概览：总数/放假补班拆分/覆盖年份/自动开关', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    expect(find.text('节假日数据缓存'), findsOneWidget);
    expect(find.text('共 3 条（放假 2 · 补班 1）'), findsOneWidget);
    expect(find.textContaining('覆盖年份：2026'), findsOneWidget);
    expect(find.textContaining('上次成功更新：'), findsOneWidget);
    // 每月自动更新总开关（core 缺省开启）
    expect(find.text('每月自动更新'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('立即更新'), findsOneWidget);
    // 按年补写入口与可选区间提示（上界 = 明年，随本机当前年推导）
    final maxYear = DateTime.now().year + 1;
    expect(find.text('按年份范围获取'), findsOneWidget);
    expect(find.textContaining('可选 2013–$maxYear 年'), findsOneWidget);
  });

  testWidgets('明细：按年分组 + 日期/休班徽标/假日名 + 更新该年', (tester) async {
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
    // 年份卡标题右侧单年补写入口
    expect(find.text('更新该年'), findsOneWidget);
  });

  testWidgets('立即更新：成功 toast 并停留可收尾', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    await tester.tap(find.text('立即更新'));
    await _advance(tester, 300);
    expect(find.text('节假日数据已更新'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('自动开关：关闭后落库并回显', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await tester.tap(find.byType(Switch));
    await _advance(tester, 300);

    expect(bridge.store.holidayAutoEnabled, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.textContaining('已关闭：仅保留下面的手动更新与按年补写'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('更新该年：有数据回显行数，无数据按 AC-E7 提示「线上无数据」',
      (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await tester.tap(find.text('更新该年'));
    await _advance(tester, 300);
    expect(find.text('2026 年已更新（3 条）'), findsOneWidget);
    await drainToastTimers(tester);

    // AC-E7：空响应仍按成功处理，但必须显式提示而非静默
    bridge.store.holidayEmptyYears.add(2026);
    await tester.tap(find.text('更新该年'));
    await _advance(tester, 300);
    expect(find.text('2026 年：线上无数据'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('按年份范围获取：两级年份抽屉 → 进度弹层 → 终态汇总 toast',
      (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    await tester.tap(find.text('按年份范围获取'));
    await tester.pumpAndSettle();
    expect(find.text('起始年份'), findsOneWidget);

    // 抽屉列表 2013..明年 升序，首两项必在视口内（无需滚动）
    await tester.tap(find.text('2013 年'));
    await tester.pumpAndSettle();
    expect(find.text('结束年份'), findsOneWidget);

    await tester.tap(find.text('2014 年'));
    await tester.pumpAndSettle();
    // 进度弹层（不可遮罩关闭，带取消）
    expect(find.text('正在补写节假日'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // Mock 每年 120ms；2 年 + 收尾，显式推进假时钟让弹层自然收口
    await _advance(tester, 2000);
    expect(find.text('正在补写节假日'), findsNothing);
    // 2013/2014 均不在 Mock 预置表 → 全部「无数据」
    expect(find.text('补写完成：成功 0 年 · 无数据 2 年'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('按年份范围获取：部分成功按事实上报（三计数 + 失败年份，非 error 级）',
      (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    // 2014 模拟拉取失败；2013 不在预置表 → 无数据
    bridge.store.holidayFailedYears.add(2014);

    await tester.tap(find.text('按年份范围获取'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2013 年'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2014 年'));
    await tester.pumpAndSettle();

    await _advance(tester, 2000);
    expect(find.text('补写完成：成功 0 年 · 失败 1 年 · 无数据 1 年'), findsOneWidget);
    // 失败年份来自逐年进度事件（终态 done 只带计数）
    expect(find.text('失败年份：2014（沿用原缓存）'), findsOneWidget);
    await drainToastTimers(tester);
  });
}
