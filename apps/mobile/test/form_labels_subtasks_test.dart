// 新建表单「标签」「子任务」字段（G5，对齐桌面 task-form-sheet 的
// TagsField / SubtasksField）：
// 1. 新建表单含「标签」「子任务」两区块；
// 2. 标签多选抽屉勾选 + 子任务添加 → 保存后挂载标签关联与子任务。
// 注：仅**新建态**出这两区块（桌面同口径：footerContent 里 `!task` 才渲染）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/form_bottom_sheet.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settlePastMockLatency(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

Future<MockOrbitBridge> _openForm(WidgetTester tester) async {
  final bridge = MockOrbitBridge();
  await tester.pumpWidget(_wrap(
    Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showTodoFormSheet(context),
          child: const Text('开表单'),
        ),
      ),
    ),
    bridge,
  ));
  await _settlePastMockLatency(tester);
  await tester.tap(find.text('开表单'));
  await tester.pumpAndSettle();
  return bridge;
}

/// 表单主滚动容器 = 抽屉内容 ListView 的 Scrollable。
/// **不能用 `Scrollable.last`**：输入框 EditableText 自带内层 Scrollable
/// 会顶替树序末位（见 form_bottom_sheet_test 同名注释）。
final Finder _formScrollable = find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

/// 滚到目标可见（表单长，字段多于一屏；口径同 form_bottom_sheet_test）
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  // 目标可能在视口上方（懒构建卸载后向下滚找不到）——双向先挂进树
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_formScrollable, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_formScrollable, const Offset(0, 200));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  for (var i = 0; i < 8; i++) {
    if (tester.getRect(finder).bottom <= 580) break;
    await tester.drag(_formScrollable, const Offset(0, -100));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('新建表单含 标签 / 子任务 两区块', (tester) async {
    await _openForm(tester);

    await _scrollTo(tester, find.text('标签'));
    expect(find.text('标签'), findsOneWidget);
    await _scrollTo(tester, find.text('子任务'));
    expect(find.text('子任务'), findsOneWidget);
  });

  testWidgets('标签勾选 + 子任务添加 → 保存后挂载到新任务', (tester) async {
    final bridge = await _openForm(tester);
    await tester.enterText(find.byType(TextFormField).first, '带标签的任务');
    await tester.pumpAndSettle();

    // 标签：点区块「选择」开多选抽屉 → 勾「阅读」（避开「紧急」——NLP 预览
    // chip 与种子标签同名，会干扰命中）→ 点「完成」收抽屉
    await _scrollTo(tester, find.text('标签'));
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读'));
    await _settlePastMockLatency(tester);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 子任务：输入 + 添加 → 行内可见
    await _scrollTo(tester, find.text('子任务'));
    await tester.enterText(find.byType(TextField).last, '第一步调研');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('第一步调研'), findsOneWidget);

    // 保存（页头 ✓，tooltip 保存）
    await tester.tap(find.byTooltip('保存'));
    await _settlePastMockLatency(tester);

    // 断言落库（同步读 store：mock 桥 Future.delayed 在 fake async 里
    // await 会死等，store 是同步内存库）
    final tasks = bridge.store.tasks.values
        .where((t) => t['title'] == '带标签的任务')
        .toList();
    expect(tasks, hasLength(1));
    final id = tasks.first['id'] as int;
    final readId = bridge.store.labels.values
        .firstWhere((l) => l['title'] == '阅读')['id'] as int;
    expect(bridge.store.taskLabels[id]?.containsKey(readId), isTrue,
        reason: '标签关联已挂载');
    expect(
      bridge.store.subtasks.values
          .any((s) => s['task_id'] == id && s['title'] == '第一步调研'),
      isTrue,
      reason: '子任务已建立',
    );
    await drainToastTimers(tester);
  });
}
