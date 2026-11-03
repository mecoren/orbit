// 任务长按菜单「日期」「优先级」快捷行（对齐桌面任务菜单顶部图标行，
// 2026-10-16）：
// 1. 长按弹操作菜单，顶部两行为「日期」「优先级」；
// 2. 「日期」→ 单选抽屉 = 快捷档（一小时后 / 今天晚些时候 / 明天 / 下周，
//    行尾时刻提示）+ 选择日期和时间 +（已有截止时）清除截止；
// 3. 点选快捷档 → 绝对时刻落库（明天 = 次日 09:00，非保时刻换算）；
// 4. 「优先级」→ 六档色点，点选写库；
// 5. 「更换项目」→ 未分组 + 各项目（项目色点，当前项由抽屉选中态标注），
//    点选写 project_id（对齐桌面右键菜单「更换项目 ▸」）。
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

    // 2026-11-03 起浮层不画标题行；恒在选项限定在弹层内查
    // （「今天晚些时候」有 22:00 截断，由纯函数用例把关）
    final popup = selectPopup();
    for (final label in ['一小时后', '下周', '选择日期和时间', '清除截止']) {
      expect(find.descendant(of: popup, matching: find.text(label)),
          findsOneWidget);
    }
    // 种子任务已有截止 → 清除截止在列；「明天」等档副标题为「周X, 09:00」
    expect(
      find.descendant(of: popup, matching: find.textContaining(', 09:00')),
      findsNWidgets(2),
    );
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

    // 2026-11-03 起单选取浮层口径：不画标题行，选项限定在弹层内查
    final popup = selectPopup();
    // 种子库有同名标签「紧急」，六档文案须限定在弹层内查（行标签色点另算）
    Finder inSheet(String text) => find.descendant(
          of: popup,
          matching: find.text(text),
        );
    for (final label in ['无', '低', '中', '高', '紧急', '立即处理']) {
      expect(inSheet(label), findsOneWidget, reason: '六档色点齐全：$label');
    }

    await tester.tap(inSheet('紧急'));
    await _settlePastMockLatency(tester);
    expect(_storeTask(bridge, '完成移动端重构方案评审')['priority'], 4);
  });

  testWidgets('更换项目：抽屉列未分组 + 各项目，点选写 project_id', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);

    final lifeId = bridge.store.projects.values
        .firstWhere((p) => p['title'] == '生活')['id'] as int;
    final t1 = _storeTask(bridge, '完成移动端重构方案评审');
    expect(t1['project_id'], isNot(lifeId), reason: '种子任务在「工作」项目下');

    await _longPress('完成移动端重构方案评审', tester);
    await tester.tap(find.text('更换项目'));
    await tester.pumpAndSettle();

    final popup = selectPopup();
    Finder inSheet(String text) => find.descendant(
          of: popup,
          matching: find.text(text),
        );
    expect(find.text('更换项目'), findsNothing, reason: '菜单已收起，浮层无标题行');
    expect(inSheet('未分组'), findsOneWidget);
    expect(inSheet('生活'), findsOneWidget);
    // 当前项（工作）由选中态标注——浮层内恰一枚选中行
    expect(selectedPopupLabels(tester), ['工作']);

    await tester.tap(inSheet('生活'));
    await _settlePastMockLatency(tester);
    expect(_storeTask(bridge, '完成移动端重构方案评审')['project_id'], lifeId);
  });
}
