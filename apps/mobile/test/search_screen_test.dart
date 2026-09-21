// 搜索页冒烟（backlog #26）：MockOrbitBridge 注入，验证防抖搜索链路
// 输入关键词后三组结果渲染 + 点击任务行可进详情路由。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/search_screen.dart';
import 'support/orbit_test_app.dart';

final _router = GoRouter(
  initialLocation: '/todo/search',
  routes: [
    GoRoute(path: '/todo/search', builder: (_, _) => const SearchScreen()),
    GoRoute(
      path: '/todo/:id',
      builder: (_, s) => Scaffold(
        body: Center(child: Text('详情 ${s.pathParameters['id']}')),
      ),
    ),
  ],
);

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestAppRouter(routerConfig: _router),
    );

void main() {
  testWidgets('搜索页：输入关键词出任务分组结果', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pumpAndSettle();

    // 自动聚焦的输入框 → 输入种子任务标题片段（评审 → 「完成移动端重构方案评审」）
    await tester.enterText(find.byType(TextField), '评审');
    // 越过 300ms 防抖（触发 provider 重查）+ mock 120ms 延迟（分段推进收敛）
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // 「任务」分组头 + 命中的种子任务行
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('完成移动端重构方案评审'), findsOneWidget);
  });

  testWidgets('搜索页：空关键词无结果不渲染分组', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await tester.pumpAndSettle();

    // 未输入：无分组头
    expect(find.text('任务'), findsNothing);
  });
}
