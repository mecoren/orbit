// 备份与恢复页冒烟（数据安全兜底）：卡片渲染 + 导出链路 + 自动备份档位切换。
//
// 两个测试基建约束（同 trash_test）：
// - Mock 延迟为真 Timer，FakeAsync 下需用 pump 推进假时钟；
// - WaitToast 无人点击时挂 2.6s 自动收起 Timer，用例末尾必须推过它，
//   否则触发 framework 的「Timer 仍在等待」断言。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/backup_page.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      // rootNavigatorKey：WaitToast 经全局 Navigator Overlay 插入
      child:
          orbitTestApp(home: const BackupPage()),
    );

/// 跨过 mock 的 120ms 延迟与随后的一次刷新 setState
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 把 WaitToast 的自动收起 Timer 推掉（用例收尾必调）
Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('首屏卡片渲染：备份 / 恢复 / 自动备份', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    expect(find.text('备份'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('自动备份'), findsOneWidget);
    expect(find.text('导出本地备份'), findsOneWidget);
    expect(find.text('备份到云端'), findsOneWidget);
    expect(find.text('从本地文件恢复'), findsOneWidget);
    expect(find.text('从云端副本恢复'), findsOneWidget);
    // 未配置云同步：云端清单不可用提示，但不阻断其余卡
    expect(find.textContaining('云端副本不可用'), findsOneWidget);
  });

  testWidgets('未解锁同步密码时导出给出可读错误提示', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    await tester.tap(find.text('导出本地备份'));
    await _settle(tester);

    expect(find.textContaining('导出失败'), findsOneWidget);
    expect(find.textContaining('同步加密未解锁'), findsOneWidget);
    await _drainToast(tester);
  });

  testWidgets('解锁后导出：成功提示 + 本机备份清单落一份', (tester) async {
    // 直接置内存态而非 await syncCryptoInit：FakeAsync 下测试体里 await
    // 真 Timer 的桥调用会永不完成（假时钟未推进）
    final bridge = MockOrbitBridge()
      ..store.syncPasswordSet = true
      ..store.syncUnlocked = true
      ..store.syncPassword = 'sync-pass';
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await tester.tap(find.text('导出本地备份'));
    await _settle(tester);

    expect(find.textContaining('已导出本地备份'), findsOneWidget);
    expect(bridge.store.localBackups, hasLength(1));
    await _drainToast(tester);
  });

  testWidgets('自动备份：默认关闭，切到「每天」后出现时刻行', (tester) async {
    await tester.pumpWidget(_wrap(MockOrbitBridge()));
    await _settle(tester);

    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('时刻'), findsNothing);

    await tester.tap(find.text('关闭'));
    // 选择抽屉有入场动画，未 settle 时点击会落空
    await tester.pumpAndSettle();
    await tester.tap(find.text('每天'));
    await _settle(tester);

    expect(find.text('时刻'), findsOneWidget);
    expect(find.text('03:00'), findsOneWidget);
  });
}
