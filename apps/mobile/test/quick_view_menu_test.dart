// 页头「视图菜单」：选中档写入本机偏好，退出重进仍停在上一档（2026-11-07）
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/quick_view_prefs.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_page_header.dart';

import 'support/orbit_test_app.dart';

const _todayQuery = TaskFilterInput(quickView: QuickViewKey.today);

Widget _app(MockOrbitBridge bridge) => ProviderScope(
  overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
  child: orbitTestApp(
    home: const SubListScreen(
      query: _todayQuery,
      showBack: false,
      titleOverride: '今天',
    ),
  ),
);

/// 推进假时钟越过 MockOrbitBridge 的 120ms 人为延迟，再收敛帧
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 页头标题（视图菜单触发件）上的文字
Finder _headerText(String text) => find.descendant(
  of: find.byType(OrbitPageHeader),
  matching: find.text(text),
);

void main() {
  setUp(LocalPrefs.resetForTest);
  tearDown(LocalPrefs.resetForTest);

  testWidgets('视图菜单选中档写入本机偏好，标题跟随档名', (tester) async {
    await tester.pumpWidget(_app(MockOrbitBridge()));
    await _settle(tester);
    expect(_headerText('今天'), findsOneWidget);

    // 点页头标题展开视图菜单 → 选「近7天」
    await tester.tap(_headerText('今天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('近7天'));
    await _settle(tester);

    expect(LocalPrefs.getString(quickViewPrefsKey), QuickViewKey.week.name);
    expect(_headerText('近7天'), findsOneWidget);
  });

  testWidgets('退出重进仍停在上一档（initState 读本机偏好播种）', (tester) async {
    // 模拟上次在视图菜单里选了「收藏」（真实重启从 prefs.json 读回同值）。
    // 不 await：`setString` 同步写内存表，落盘在 testWidgets 的 fake async 里
    // 走不通（无 path_provider 插件），await 会挂住整条用例
    unawaited(LocalPrefs.setString(quickViewPrefsKey, QuickViewKey.favorite.name));

    await tester.pumpWidget(_app(MockOrbitBridge()));
    await _settle(tester);

    expect(_headerText('收藏'), findsOneWidget);
    expect(_headerText('今天'), findsNothing);
  });

  testWidgets('切回「今天」写回本位，重启不残留上一档', (tester) async {
    unawaited(LocalPrefs.setString(quickViewPrefsKey, QuickViewKey.week.name));

    await tester.pumpWidget(_app(MockOrbitBridge()));
    await _settle(tester);
    expect(_headerText('近7天'), findsOneWidget);

    await tester.tap(_headerText('近7天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天'));
    await _settle(tester);

    expect(LocalPrefs.getString(quickViewPrefsKey), QuickViewKey.today.name);
    expect(_headerText('今天'), findsOneWidget);
  });
}
