// 开源组件双级页面回归（关于页入口 → 列表 → 详情）：
// - 列表页：筛选与排序分组 + 分段卡片行（移动端隐藏前端来源条目）
// - 筛选：来源切 Flutter 后仅剩 Flutter 条目
// - 排序：名称 A→Z 改变行顺序
// - 详情页：基础信息 / 说明 / 链接；未知组件给空态
// 数据来自 MockOrbitBridge 的 6 条占位清单。
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/about_page.dart';
import 'package:orbit/modules/settings/oss_component_detail_page.dart';
import 'package:orbit/modules/settings/oss_components_page.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_preference.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_list_card.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge, Widget home) => ProviderScope(
  overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
  child: orbitTestApp(home: home),
);

/// 越过 mock 的 120ms 桥延迟
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

Future<void> _selectDropdown(
  WidgetTester tester,
  String currentLabel,
  String optionLabel,
) async {
  await tester.tap(find.text(currentLabel));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byKey(orbitDropdownPopupKey),
      matching: find.text(optionLabel),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('关于页：开源组件与开源许可各自单行箭头入口', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge(), const AboutPage()));
    await tester.pumpAndSettle();

    expect(find.text('开源组件'), findsOneWidget);
    expect(find.text('查看开源组件'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    expect(find.text('查看开源许可'), findsOneWidget);
  });

  testWidgets('列表页：筛选/排序分组与两类来源条目', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const OssComponentsPage()),
    );
    await _settle(tester);

    expect(find.text('开源组件'), findsOneWidget);
    expect(find.text('筛选与排序'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('排序'), findsOneWidget);
    // 前端（桌面壳）条目在移动端隐藏
    expect(find.text('react'), findsNothing);
    expect(find.text('@scope/demo'), findsNothing);
    expect(find.text('tauri'), findsOneWidget);
    expect(find.text('flutter_miuix'), findsOneWidget);
  });

  testWidgets('筛选卡与列表卡同宽（只保留一层水平留白）', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const OssComponentsPage()),
    );
    await _settle(tester);

    final filterCard = tester.getSize(find.byType(MiuixCard).first);
    final listCard = tester.getSize(find.byType(OrbitCardSegment).first);
    expect(filterCard.width, listCard.width);
  });

  testWidgets('筛选来源后只保留对应条目', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const OssComponentsPage()),
    );
    await _settle(tester);

    await _selectDropdown(tester, '全部来源', 'Flutter');

    expect(find.text('flutter_miuix'), findsOneWidget);
    expect(find.text('go_router'), findsOneWidget);
    expect(find.text('react'), findsNothing);
    expect(find.text('tauri'), findsNothing);
  });

  testWidgets('名称 A→Z 改变列表顺序', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const OssComponentsPage()),
    );
    await _settle(tester);

    await _selectDropdown(tester, '默认排序', '名称 A→Z');

    final flutterY = tester.getTopLeft(find.text('flutter_miuix')).dy;
    final goRouterY = tester.getTopLeft(find.text('go_router')).dy;
    final tauriY = tester.getTopLeft(find.text('tauri')).dy;
    expect(flutterY, lessThan(goRouterY));
    expect(goRouterY, lessThan(tauriY));
  });

  testWidgets('详情页：基础信息 / 说明 / 链接', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const OssComponentDetailPage(name: 'tauri')),
    );
    await _settle(tester);

    expect(find.text('tauri'), findsOneWidget);
    expect(find.text('基础信息'), findsOneWidget);
    expect(find.text('说明'), findsOneWidget);
    expect(find.text('链接'), findsOneWidget);
    // 首卡来源胶囊 + 基础信息行各一次
    expect(find.text('Rust'), findsNWidgets(2));
    expect(find.text('2'), findsOneWidget);
    expect(find.text('https://github.com/tauri-apps/tauri'), findsOneWidget);
  });

  testWidgets('详情页：未知组件给空态', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const OssComponentDetailPage(name: 'missing')),
    );
    await _settle(tester);

    expect(find.text('组件记录不存在或加载失败'), findsOneWidget);
  });
}
