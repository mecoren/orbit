import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/diagnostics_page.dart';

import 'support/orbit_test_app.dart';

/// 诊断页（docs/09 内存专项「应用内诊断分区」）
///
/// 只钉两件事：页面能渲染出两类读数，且行数来自桥的真实返回值（mock 内存库
/// 真算，不是写死的占位数字）；格式化函数单独测，避免把「1.0 MB」这类显示
/// 细节混进 widget 断言。
Widget _wrap(MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: const DiagnosticsPage()),
    );

/// mock 桥有 120ms 人为延迟：两次 400ms 推进让「加载中 → 读数」走完
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('诊断页：本地存储与运行时两类读数都渲染', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    expect(find.text('本地存储'), findsOneWidget);
    expect(find.text('数据库体积'), findsOneWidget);
    expect(find.text('墓碑行数'), findsOneWidget);
    expect(find.text('附件缓存'), findsOneWidget);
    expect(find.text('运行时'), findsOneWidget);
    expect(find.text('进程 RSS'), findsOneWidget);
  });

  testWidgets('诊断页：行数真算（任务表有活行即展示 chip）', (tester) async {
    final bridge = MockOrbitBridge();
    // testWidgets 体在 FakeAsync 区，mock 桥的 Future.delayed 需真实时钟：
    // 直连桥的断言必须走 runAsync，否则测试挂死（仓库既有踩坑记录）
    final snap = (await tester.runAsync(() => bridge.diagnosticsSnapshot()))!;
    final tasks = snap.tableRows.firstWhere((r) => r.table == 'todo_tasks');
    expect(tasks.rows, greaterThan(0), reason: 'mock 种子库应含未删任务');

    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);
    expect(find.textContaining('todo_tasks'), findsOneWidget);
  });

  test('体积与行数格式化：1024 进制进位 + 千分位 + 异常值占位', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1024 * 1024), '1 MB');
    expect(formatBytes(-1), '—');
    expect(formatCount(0), '0');
    expect(formatCount(1234), '1,234');
    expect(formatCount(1000000), '1,000,000');
  });

  // M5 诊断增强：当前/峰值 RSS + 场景标注（docs/13 §6.2 M5 第 2 点）
  testWidgets('诊断页：渲染本页峰值 RSS 与场景标注行', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    expect(find.text('本页峰值 RSS'), findsOneWidget);
    expect(find.textContaining('采样场景：'), findsOneWidget);
    expect(find.text('采样'), findsOneWidget);
  });

  testWidgets('诊断页：点采样不崩且峰值保持为已观测最大值', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    // 连续点两次采样：峰值只增不减，且不应回落到占位符
    await tester.tap(find.text('采样'));
    await tester.pump();
    await tester.tap(find.text('采样'));
    await tester.pump();

    expect(find.text('本页峰值 RSS'), findsOneWidget);
    expect(find.text('—'), findsNothing, reason: '采样后峰值应有真实读数');
  });

  testWidgets('诊断页：场景抽屉可选并回显', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(bridge));
    await _settle(tester);

    await tester.tap(find.textContaining('采样场景：'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份往返').last);
    await tester.pumpAndSettle();

    expect(find.text('采样场景：备份往返'), findsOneWidget);
  });
}
