// 标签管理页 / 模板管理页冒烟（组织能力：此前只有「新建」，无改名/改色/删除
// 与模板 CRUD 的 UI 入口）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/routing/router_keys.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/label_manager_page.dart';
import 'package:orbit/modules/settings/template_manager_page.dart';
import 'package:orbit/shared/utils/hex_color.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: MaterialApp(navigatorKey: rootNavigatorKey, home: child),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('标签管理页：列出既有标签 + 新建入口', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const LabelManagerPage(), bridge));
    await _settle(tester);

    expect(find.text('标签管理'), findsWidgets);
    expect(find.text('紧急'), findsOneWidget);
    expect(find.text('新建标签'), findsOneWidget);
  });

  testWidgets('标签改色：点色点弹色板抽屉 → 选中后落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const LabelManagerPage(), bridge));
    await _settle(tester);

    final labelId = bridge.store.labels.values
        .firstWhere((l) => l['title'] == '紧急')['id'] as int;
    final before = bridge.store.labels[labelId]!['hex_color'] as String;

    // 行内色点（圆形 Container）即改色入口；「紧急」的色点是 #F44336
    final rowDot = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle &&
        (w.decoration as BoxDecoration).color == hexToColor(before));
    expect(rowDot, findsOneWidget);

    await tester.tap(rowDot);
    await tester.pumpAndSettle();
    expect(find.text('标签颜色'), findsOneWidget);

    // 抽屉内 8 色板：点最后一个（#6B7280，与初始色不同）
    final paletteDots = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle),
    );
    expect(paletteDots, findsWidgets);
    await tester.tap(paletteDots.last);
    await tester.pumpAndSettle();
    await _settle(tester);

    expect(bridge.store.labels[labelId]!['hex_color'],
        isNot(equals(before)));
    await _drainToast(tester);
  });

  testWidgets('模板管理页：空态 + 新建模板落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const TemplateManagerPage(), bridge));
    await _settle(tester);

    expect(find.text('任务模板'), findsWidgets);
    expect(find.text('还没有模板。'), findsOneWidget);

    await tester.tap(find.text('新建模板'));
    await tester.pumpAndSettle();

    // 表单字段用 ValueKey 定位：字段多行/多行输入框在弹层内是懒构建的，
    // 按 label 文本找 TextField 会随可视区高度漂移
    await tester.enterText(find.byKey(const ValueKey('tpl-field-name')), '周会');
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('tpl-field-title')), '准备周会材料');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await _settle(tester);

    expect(bridge.store.templates, hasLength(1));
    expect(bridge.store.templates.first.name, '周会');
    expect(bridge.store.templates.first.payload, contains('准备周会材料'));
    // 未选择的字段不应产出键（套用按「存在键」预填，写 null 会被当成值）
    expect(bridge.store.templates.first.payload,
        isNot(contains('due_offset_days')));
    expect(find.text('周会'), findsOneWidget);
    await _drainToast(tester);
  });

  testWidgets('模板管理页：名称空校验不落库', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const TemplateManagerPage(), bridge));
    await _settle(tester);

    await tester.tap(find.text('新建模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(bridge.store.templates, isEmpty);
    expect(find.text('模板名称不能为空'), findsOneWidget);
    await _drainToast(tester);
  });
}
