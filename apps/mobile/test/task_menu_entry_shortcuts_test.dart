// 任务长按菜单「设置提醒 / 添加评论 / 修改标签 / 标记完成」快捷项
//（对齐桌面 task-context-menu.tsx 的同名菜单项，G2/G3/G4/G7）：
// 1. 长按菜单含四项；点「设置提醒」→ 相对档抽屉 → 落库提醒行；
// 2. 「添加评论」→ 输入抽屉 → 保存落库评论；
// 3. 「修改标签」→ 多选抽屉（勾选即建/删关联，可连选）→ 落库关联；
// 4. 「标记完成」→ 未完成任务落 done=1（对齐桌面「标记完成/标记未完成」）。
// 种子任务「完成移动端重构方案评审」自带 1 条提醒 / 1 条评论 / 「紧急」标签
// 关联，故断言一律用前后差值；标签用未关联的「阅读」验证建/删。
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

int _taskId(MockOrbitBridge bridge, String title) =>
    bridge.store.tasks.values.firstWhere((t) => t['title'] == title)['id']
        as int;

Map<String, dynamic> _storeTask(MockOrbitBridge bridge, String title) =>
    bridge.store.tasks.values.firstWhere((t) => t['title'] == title);

int _reminderCount(MockOrbitBridge bridge, int taskId) => bridge
    .store.reminders.values
    .where((r) => r['task_id'] == taskId && r['is_deleted'] == 0)
    .length;

int _commentCount(MockOrbitBridge bridge, int taskId) => bridge
    .store.comments.values
    .where((c) => c['task_id'] == taskId && c['is_deleted'] == 0)
    .length;

/// 长按菜单加长后（13 项）底部三项在 600 高测试视口外，先滚到可见再点
Future<void> _tapInMenu(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('长按菜单含 设置提醒 / 添加评论 / 修改标签 / 标记完成 四项',
      (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);

    await _longPress('完成移动端重构方案评审', tester);
    expect(find.text('设置提醒'), findsOneWidget);
    expect(find.text('添加评论'), findsOneWidget);
    expect(find.text('修改标签'), findsOneWidget);
    expect(find.text('标记完成'), findsOneWidget);
  });

  testWidgets('标记完成 → 未完成任务落 done=1（对齐桌面同名菜单项）',
      (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    final t = _storeTask(bridge, '完成移动端重构方案评审');
    expect(t['done'], 0);

    await _longPress('完成移动端重构方案评审', tester);
    await _tapInMenu(tester, '标记完成');
    await _settlePastMockLatency(tester);

    expect(_storeTask(bridge, '完成移动端重构方案评审')['done'], 1);
    await drainToastTimers(tester);
  });

  testWidgets('设置提醒 → 相对档抽屉点选 → 提醒落库', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    final id = _taskId(bridge, '完成移动端重构方案评审');
    final before = _reminderCount(bridge, id);

    await _longPress('完成移动端重构方案评审', tester);
    await _tapInMenu(tester, '设置提醒');

    // 相对档抽屉（桌面 DateTimePicker 相对档同口径；种子任务有截止 →
    // 「截止前 1 小时」等档在列）
    expect(find.text('提醒时间'), findsOneWidget);
    expect(find.text('截止前 1 小时'), findsOneWidget);
    expect(find.text('自定义时间…'), findsOneWidget);

    await tester.tap(find.text('截止前 1 小时'));
    await _settlePastMockLatency(tester);

    expect(_reminderCount(bridge, id), before + 1,
        reason: '点选相对档即落库一条提醒');
    await drainToastTimers(tester);
  });

  testWidgets('添加评论 → 输入抽屉保存 → 评论落库', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    final id = _taskId(bridge, '完成移动端重构方案评审');
    final before = _commentCount(bridge, id);

    await _longPress('完成移动端重构方案评审', tester);
    await _tapInMenu(tester, '添加评论');

    await tester.enterText(find.byType(TextField).first, '进展顺利');
    await tester.tap(find.text('保存'));
    await _settlePastMockLatency(tester);

    expect(_commentCount(bridge, id), before + 1);
    expect(
      bridge.store.comments.values
          .any((c) => c['task_id'] == id && c['content'] == '进展顺利'),
      isTrue,
    );
    await drainToastTimers(tester);
  });

  testWidgets('修改标签 → 多选抽屉勾选即建关联、取消即删', (tester) async {
    final bridge = MockOrbitBridge();
    await _pumpList(tester, bridge);
    final id = _taskId(bridge, '完成移动端重构方案评审');
    final readId = bridge.store.labels.values
        .firstWhere((l) => l['title'] == '阅读')['id'] as int;
    expect(bridge.store.taskLabels[id]?.containsKey(readId) ?? false, isFalse,
        reason: '「阅读」初始未关联');

    await _longPress('完成移动端重构方案评审', tester);
    await _tapInMenu(tester, '修改标签');

    expect(find.text('修改标签'), findsOneWidget, reason: '菜单收起后只剩抽屉标题');
    // 限定弹层内命中（行内标签 chip 同名会干扰）
    Finder inSheet(String text) => find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(text),
        );
    await tester.tap(inSheet('阅读'));
    await _settlePastMockLatency(tester);
    expect(bridge.store.taskLabels[id]?.containsKey(readId), isTrue,
        reason: '勾选即建关联');

    // 取消勾选即删关联（抽屉内连选口径：不关抽屉）
    await tester.tap(inSheet('阅读'));
    await _settlePastMockLatency(tester);
    expect(bridge.store.taskLabels[id]?.containsKey(readId) ?? false, isFalse,
        reason: '取消勾选即删关联');
    await drainToastTimers(tester);
  });
}
