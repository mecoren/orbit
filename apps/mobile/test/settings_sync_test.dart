import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:orbit/core/routing/app_router.dart' show pageSlideFromRight;
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/settings_screen.dart';
import 'package:orbit/modules/settings/sync_settings_page.dart';

void main() {
  // appRouter 是带导航状态的全局单例，直接复用会在用例间串路由；
  // 测试内自建独立路由（与 router_transition_test.dart 同模式），
  // 转场复用 pageSlideFromRight 保证与生产路径一致。
  GoRouter buildRouter() => GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => pageSlideFromRight(
              const SettingsScreen(),
              key: state.pageKey,
            ),
          ),
          GoRoute(
            path: '/settings/sync',
            pageBuilder: (context, state) => pageSlideFromRight(
              const SyncSettingsPage(),
              key: state.pageKey,
            ),
          ),
        ],
      );

  testWidgets('settings exposes cloud sync setup when not configured', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          orbitBridgeProvider.overrideWithValue(MockOrbitBridge()),
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('未配置同步引擎'), findsOneWidget);
    expect(find.text('云同步设置'), findsOneWidget);
    await tester.tap(find.text('云同步设置'));
    await tester.pumpAndSettle();

    expect(find.text('云同步配置'), findsOneWidget);
    expect(find.byType(TextFormField), findsAtLeast(4));
  });
}
