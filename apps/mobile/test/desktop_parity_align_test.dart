// 双端对齐第三批交叉验证（docs/07 #87 / docs/12 §4.3）：
// 1. 详情/表单把状态切到「已完成」必须走 todoTaskComplete（重复任务推进下一实例），
//    不得用普通 update 绕过引擎；新建即完成同理（不能只写 status=done 而 done=0）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'package:orbit/modules/todo/form_bottom_sheet.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_info_row.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 表单/详情主滚动容器（避免 EditableText 内层 Scrollable 顶替树序末位）
final Finder _formScrollable = find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_formScrollable, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  // 双向收敛：仅判下沿会把目标顶到页头浮层之下，点击会被页头吃掉
  for (var i = 0; i < 12; i++) {
    final rect = tester.getRect(finder);
    if (rect.top >= 80 && rect.bottom <= 580) break;
    await tester.drag(_formScrollable, Offset(0, rect.top < 80 ? 100 : -100));
    await tester.pumpAndSettle();
  }
}

/// 信息区某行的值文本（限定在包含 [label] 的 InfoTile 内）
Finder _tileValue(String label, String value) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(InfoTile)),
      matching: find.text(value),
    );

/// 把重复规则写进种子任务 5（详情/表单用例共用）
void _seedRepeatingTask(MockOrbitBridge bridge) {
  bridge.store.tasks[5]!['repeat_mode'] = 1;
  bridge.store.tasks[5]!['repeat_after'] = 1;
  bridge.store.tasks[5]!['due_date'] =
      DateTime.now().millisecondsSinceEpoch + 86400000;
}

List<Map<String, dynamic>> _spawnedOf(
  MockOrbitBridge bridge,
  String title,
  int originId,
) =>
    [
      for (final t in bridge.store.tasks.values)
        if (t['title'] == title &&
            t['id'] != originId &&
            t['is_deleted'] == 0)
          t,
    ];

void main() {
  group('完成引擎接入（状态切到已完成）', () {
    testWidgets('详情信息区状态选「已完成」→ 重复任务生成下一期', (tester) async {
      final bridge = MockOrbitBridge();
      _seedRepeatingTask(bridge);
      final title = bridge.store.tasks[5]!['title'] as String;
      final before = bridge.store.tasks.length;

      await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
      await _settle(tester);

      await tester.tap(_tileValue('状态', '待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成'));
      await _settle(tester);

      expect(bridge.store.tasks.length, before + 1,
          reason: '完成走 todoTaskComplete，重复规则必须推进下一实例');
      expect(bridge.store.tasks[5]!['done'], 1);
      expect(bridge.store.tasks[5]!['status'], 'done');
      final spawned = _spawnedOf(bridge, title, 5);
      expect(spawned, hasLength(1));
      expect(spawned.single['status'], 'pending');
      expect(spawned.single['done'], 0);
      await drainToastTimers(tester);
    });

    testWidgets('详情已完成 → 状态改「进行中」落 doing（不回落 pending）',
        (tester) async {
      final bridge = MockOrbitBridge();
      bridge.store.tasks[5]!['status'] = 'done';
      bridge.store.tasks[5]!['done'] = 1;
      bridge.store.tasks[5]!['done_at'] =
          DateTime.now().millisecondsSinceEpoch;

      await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
      await _settle(tester);

      await tester.tap(_tileValue('状态', '已完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进行中'));
      await _settle(tester);

      expect(bridge.store.tasks[5]!['status'], 'doing',
          reason: 'done → 进行中必须落目标状态，不能回落 pending');
      expect(bridge.store.tasks[5]!['done'], 0);
      expect(bridge.store.tasks[5]!['done_at'], isNull);
      await drainToastTimers(tester);
    });

    testWidgets('编辑表单状态改「已完成」→ 保存后同样推进重复实例', (tester) async {
      final bridge = MockOrbitBridge();
      _seedRepeatingTask(bridge);
      final title = bridge.store.tasks[5]!['title'] as String;
      final before = bridge.store.tasks.length;

      await tester.pumpWidget(_wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showTodoFormSheet(context, editingTaskId: 5),
              child: const Text('编辑任务'),
            ),
          ),
        ),
        bridge,
      ));
      await _settle(tester);
      await tester.tap(find.text('编辑任务'));
      await tester.pumpAndSettle();

      await _scrollTo(tester, _tileValue('状态', '待办'));
      await tester.tap(_tileValue('状态', '待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('保存'));
      await _settle(tester);

      expect(bridge.store.tasks.length, before + 1,
          reason: '编辑表单跨 done 边界必须走完成引擎');
      expect(bridge.store.tasks[5]!['done'], 1);
      expect(_spawnedOf(bridge, title, 5), hasLength(1));
      await drainToastTimers(tester);
    });

    testWidgets('新建表单选「已完成」→ 落 done=1/done_at（不再 status=done 而 done=0）',
        (tester) async {
      final bridge = MockOrbitBridge();
      await tester.pumpWidget(_wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTodoFormSheet(context),
              child: const Text('新建任务'),
            ),
          ),
        ),
        bridge,
      ));
      await _settle(tester);
      await tester.tap(find.text('新建任务'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, '新建即完成');
      await tester.pumpAndSettle();
      await _scrollTo(tester, _tileValue('状态', '待办'));
      await tester.tap(_tileValue('状态', '待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('保存'));
      await _settle(tester);

      final created = bridge.store.tasks.values
          .firstWhere((t) => t['title'] == '新建即完成');
      expect(created['status'], 'done');
      expect(created['done'], 1,
          reason: '新建即完成必须走完成引擎，不能只写 status');
      expect(created['done_at'], isNotNull);
      await drainToastTimers(tester);
    });
  });
}
