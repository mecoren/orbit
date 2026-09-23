// 无障碍口径（2026-09-22 批次）：
// - 操作按钮一律带读屏标签（IconButton.tooltip；行内色点用 Tooltip 包裹）；
// - 色板热区 48（touchTarget），视觉尺寸不变（外层 Padding 补齐）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/label_manager_page.dart';
import 'package:orbit/modules/todo/project_edit_page.dart';
import 'package:orbit/modules/todo/sidebar_screen.dart';
import 'package:orbit/shared/utils/hex_color.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_info_row.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_page_header.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 收尾：推掉 MockOrbitBridge 的人为延迟计时器。
///
/// `tester.pump(d)` 先推进假时钟、再画这一帧，于是**帧内**新建的 120ms
/// 延迟定时器不会被本次 pump 跑掉（`todo_screens_smoke_test` 靠后续交互
/// 顺带越过）。用例在断言后立即结束的必须显式再推一轮，否则收尾命中
/// flutter_test 的「A Timer is still pending」断言。
Future<void> _drainMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

/// 色点热区层边长：热区靠外层 Padding 补白，故取色点**最近**一层 Padding。
///
/// 用 `findAncestorWidgetOfExactType`（文档保证返回最近祖先）而非
/// `find.ancestor(...).first`——后者返回整条祖先链，`.first` 命中哪一层
/// 取决于遍历顺序（曾取到包的整行 Padding，量出 640×56）。
double _heatArea(WidgetTester tester, Finder dot) {
  final pad = tester.element(dot).findAncestorWidgetOfExactType<Padding>();
  expect(pad, isNotNull, reason: '色点外层应有补热区的 Padding');
  return tester.getSize(find.byWidget(pad!)).width;
}

/// 范围内的圆形色点（色板格）。
Finder _circleDotsIn(Finder scope) => find.descendant(
      of: scope,
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle),
    );

void main() {
  testWidgets('页头：菜单/返回钮有读屏标签', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: OrbitPageHeader(title: 'x', showMenu: true)),
    ));
    expect(find.byTooltip('菜单'), findsOneWidget);

    await tester.pumpWidget(orbitTestApp(
      home: const Scaffold(body: OrbitPageHeader(title: 'x')),
    ));
    // showBack 默认 true
    expect(find.byTooltip('返回'), findsOneWidget);
  });

  testWidgets('信息行清除钮有读屏标签', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(body: InfoTile(label: '截止', value: '明天', onClear: () {})),
    ));
    expect(find.byTooltip('清除'), findsOneWidget);
  });

  testWidgets('侧栏设置钮有读屏标签', (tester) async {
    await tester.pumpWidget(_wrap(const SidebarScreen(), MockOrbitBridge()));
    await _settle(tester);
    expect(find.byTooltip('设置'), findsOneWidget);
    await _drainMockLatency(tester);
  });

  testWidgets('标签行色点：更换标签 + 热区 48', (tester) async {
    await tester.pumpWidget(_wrap(const LabelManagerPage(), MockOrbitBridge()));
    await _settle(tester);

    expect(find.byTooltip('更换颜色'), findsWidgets);
    // 热区 = Tooltip 下 InkWell 的实际尺寸（视觉 16 + 透明边 16×2）
    final cell = find.byTooltip('更换颜色').first;
    expect(tester.getSize(cell), const Size(48, 48));
    await _drainMockLatency(tester);
  });

  testWidgets('标签色板弹层：色点热区 48，视觉 40 不变', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const LabelManagerPage(), bridge));
    await _settle(tester);

    final labelId = bridge.store.labels.values
        .firstWhere((l) => l['title'] == '紧急')['id'] as int;
    final before = bridge.store.labels[labelId]!['hex_color'] as String;
    final rowDot = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle &&
        (w.decoration as BoxDecoration).color == hexToColor(before));
    await tester.tap(rowDot);
    await tester.pumpAndSettle();
    expect(find.text('标签颜色'), findsOneWidget);

    final dot = _circleDotsIn(find.byType(BottomSheet)).first;
    expect(tester.getSize(dot), const Size(40, 40));
    expect(_heatArea(tester, dot), 48);
    await _drainMockLatency(tester);
  });

  testWidgets('编辑项目整页：色点热区 48，视觉 32 不变', (tester) async {
    final bridge = MockOrbitBridge();
    final projectId = bridge.store.projects
        .values
        .firstWhere((p) => p['title'] == '工作')['id'] as int;

    // 编辑项目 2026-09-23 由对话框升级为整页（页面内有 context.pop()），
    // 故测试壳必须是带 GoRouter 的路由壳
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('返回页')),
        ),
        GoRoute(
          path: '/edit',
          builder: (_, _) => ProjectEditPage(projectId: projectId),
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestAppRouter(routerConfig: router),
    ));
    await _settle(tester);

    // 热区 = 外层 Padding 补出的 48（视觉 32 不变）
    final dot = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle &&
        (w.decoration as BoxDecoration).color == hexToColor('#EF4444'));
    expect(tester.getSize(dot), const Size(32, 32));
    expect(_heatArea(tester, dot), 48);
  });
}
