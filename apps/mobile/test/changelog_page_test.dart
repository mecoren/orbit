// 更新日志两级页面回归（关于页入口 → 列表 → 明细）：
// - 列表页：待办列表版式（版本号 + 摘要 + 右侧日期/条目数）
// - 明细页：任务详情版式（标题区 / 信息 / 摘要 / 变更分组）
// - 未知版本：失败态文案
// 数据来自 MockOrbitBridge 的单条 0.1.0 占位日志。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/about_page.dart';
import 'package:orbit/modules/settings/changelog_detail_page.dart';
import 'package:orbit/modules/settings/changelog_list_page.dart';
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

void main() {
  testWidgets('关于页：更新日志只留一行入口，不直接铺开内容', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge(), const AboutPage()));
    await tester.pumpAndSettle();

    expect(find.text('更新日志'), findsOneWidget);
    expect(find.text('查看历史版本'), findsOneWidget);
    // 版本内容只在列表页出现（关于页不再直接渲染）
    expect(find.textContaining('Mock 桥占位更新日志'), findsNothing);
    expect(find.text('v0.1.0'), findsNothing);
  });

  testWidgets('列表页：版本行 = 版本号 + 摘要 + 日期/条目数', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const ChangelogListPage()),
    );
    await _settle(tester);

    expect(find.text('更新日志'), findsOneWidget);
    expect(find.text('v0.1.0'), findsOneWidget);
    expect(find.textContaining('Mock 桥占位更新日志'), findsOneWidget);
    expect(find.text('2026-09-26'), findsOneWidget);
    expect(find.text('0 项更新'), findsOneWidget);
  });

  testWidgets('明细页：标题区 + 信息 / 摘要 / 变更分组', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const ChangelogDetailPage(version: '0.1.0')),
    );
    await _settle(tester);

    // 页头 + 标题区 + 信息行各一次
    expect(find.text('v0.1.0'), findsNWidgets(3));
    expect(find.text('发布于 2026-09-26'), findsOneWidget);
    expect(find.text('信息'), findsOneWidget);
    expect(find.text('发布日期'), findsOneWidget);
    expect(find.text('0 项'), findsOneWidget);
    expect(find.text('摘要'), findsOneWidget);
    expect(find.text('变更（0 项）'), findsOneWidget);
    expect(find.text('本版本未逐条记录变更。'), findsOneWidget);
  });

  testWidgets('明细页：未知版本给失败态', (tester) async {
    await tester.pumpWidget(
      _wrap(MockOrbitBridge(), const ChangelogDetailPage(version: '9.9.9')),
    );
    await _settle(tester);

    expect(find.text('版本记录不存在或加载失败'), findsOneWidget);
  });
}
