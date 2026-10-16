// 任务长按菜单「日期」「优先级」快捷行（对齐桌面任务菜单顶部图标行，
// 2026-10-16）：
// 1. 长按弹操作菜单，顶部两行为「日期」「优先级」；
// 2. 「日期」→ 单选抽屉 = 快捷档（一小时后 / 今天晚些时候 / 明天 / 下周，
//    行尾时刻提示）+ 选择日期和时间 +（已有截止时）清除截止；
// 3. 点选快捷档 → 绝对时刻落库（明天 = 次日 09:00，非保时刻换算）；
// 4. 「优先级」→ 六档色点，点选写库。
// 「今天晚些时候」有 22:00 截断（墙钟相关，跑测时刻漂移），其取舍由
// task_logic_test 的纯函数用例把关，本文件只断言恒在项。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 长按第一行（越过 500ms 长按阈值）后原地松手 → 兜出操作菜单
Future<void> _longPress(String title, WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(find.text(title)));
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _pumpList(WidgetTester tester, MockOrbitBridge bridge) async {
  await tester.pumpWidget(_wrap(
    const SubListScreen(
      query: TaskFilterInput(quickView: QuickViewKey.all),
    ),
    bridge,
  ));
  await _settlePastMockLatency(tester);
}

Map<String, dynamic> _storeTask(MockOrbitBridge bridge, String title) =>
    bridge.store.tasks.values.firstWhere((t) => t['title'] == title);

void main() {
  testWidgets('长按菜单顶部两行：日期 / 优先级；日期抽屉含快捷档', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);

    await _longPress('完成移动端重构方案评审', tester);
    expect(find.text('日期'), findsOneWidget);
    expect(find.text('优先级'), findsOneWidget);

    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();

    expect(find.text('设置截止时间'), findsOneWidget);
    // 恒在快捷档（「今天晚些时候」有 22:00 截断，由纯函数用例把关）
    expect(find.text('一小时后'), findsOneWidget);
    expect(find.text('下周'), findsOneWidget);
    expect(find.text('选择日期和时间'), findsOneWidget);
    // 种子任务已有截止 → 清除截止在列；「明天」行尾提示为「周X, 09:00」
    expect(find.text('清除截止'), findsOneWidget);
    expect(find.textContaining(', 09:00'), findsNWidgets(2));
  });

  testWidgets('日期快捷档「明天」：次日 09:00 绝对时刻落库（非保时刻）',
      (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);

    // 种子截止 = 次日零点（dueIn(1)），点选后应覆盖为次日 09:00
    await _longPress('完成移动端重构方案评审', tester);
    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('明天').last);
    await _settlePastMockLatency(tester);

    final now = DateTime.now();
    final expectMs = DateTime(now.year, now.month, now.day + 1, 9)
        .millisecondsSinceEpoch;
    expect(_storeTask(bridge, '完成移动端重构方案评审')['due_date'], expectMs);
    // 行右侧日期列随之刷新为带时刻形态
    expect(find.text('明天 09:00'), findsOneWidget);
  });

  testWidgets('日期快捷档「清除截止」：写 null 进 store', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);

    await _longPress('完成移动端重构方案评审', tester);
    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除截止'));
    await _settlePastMockLatency(tester);

    expect(_storeTask(bridge, '完成移动端重构方案评审')['due_date'], isNull);
  });

  testWidgets('优先级快捷行：六档点选写库（种子 pri3 → 紧急 pri4）', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);

    await _longPress('完成移动端重构方案评审', tester);
    await tester.tap(find.text('优先级'));
    await tester.pumpAndSettle();

    expect(find.text('设置优先级'), findsOneWidget);
    // 种子库有同名标签「紧急」，六档文案须限定在弹层内查（行标签色点另算）
    Finder inSheet(String text) => find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(text),
        );
    for (final label in ['无', '低', '中', '高', '紧急', '立即处理']) {
      expect(inSheet(label), findsOneWidget, reason: '六档色点齐全：$label');
    }

    await tester.tap(inSheet('紧急'));
    await _settlePastMockLatency(tester);
    expect(_storeTask(bridge, '完成移动端重构方案评审')['priority'], 4);
  });
}
