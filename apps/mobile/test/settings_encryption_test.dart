import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/settings_screen.dart';
import 'support/orbit_test_app.dart' show drainToastTimers, orbitTestApp;

/// 安全卡的平台能力分支（ADR 0001）：Android 目标是明文 SQLite，
/// 「开启加密」依赖的 `sqlcipher_export` 必然报 no such function——入口接在
/// 必败路径上，失败回滚还可能留下「meta 已写、库仍是明文」的混合态。
void main() {
  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [orbitBridgeProvider.overrideWithValue(MockOrbitBridge())],
        child: orbitTestApp(home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 安全卡在设置页 ListView 下半部：拖动逼出懒构建，直到锚点行出现。
  Future<void> dragToSecurityCard(WidgetTester tester) async {
    final scrollable = find.byType(ListView).first;
    for (var i = 0; i < 20; i++) {
      if (find.text('数据库为明文').evaluate().isNotEmpty) return;
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pumpAndSettle();
    }
  }

  /// debug 平台变量必须在 testWidgets body 结束前复位：Flutter 的
  /// `debugAssertAllFoundationVarsUnset` 早于 package:test 的 tearDown 执行。
  Future<void> onPlatform(
    WidgetTester tester,
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await pumpSettings(tester);
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('Android 明文库不摆必败的「开启加密」入口，改给只读说明',
      (tester) async {
    await onPlatform(tester, TargetPlatform.android, () async {
      await dragToSecurityCard(tester);

      expect(find.textContaining('本机加密暂不可用'), findsOneWidget);
      expect(find.text('开启加密（设置主密码）'), findsNothing);
      expect(find.textContaining('后续版本提供'), findsOneWidget);
      await drainToastTimers(tester);
    });
  });

  testWidgets('非 Android 平台仍保留开启加密入口', (tester) async {
    await onPlatform(tester, TargetPlatform.iOS, () async {
      await dragToSecurityCard(tester);

      expect(find.text('开启加密（设置主密码）'), findsOneWidget);
      expect(find.textContaining('本机加密暂不可用'), findsNothing);
      await drainToastTimers(tester);
    });
  });
}
