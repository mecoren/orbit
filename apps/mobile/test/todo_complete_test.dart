// todoTaskComplete 桥契约回归：MockOrbitBridge 完成语义对齐
// crates/orbit-core/src/api/todo_api.rs::complete_todo_task——
// 普通任务仅标记完成；重复任务克隆下一实例（子任务复制标题、完成态重置）；
// 已完成任务幂等跳过（不重复推进）。
// store 带 6 条种子任务，计数断言一律取完成前后的差值。
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/api/dto.dart';

Future<int> liveTaskCount(MockOrbitBridge bridge) async =>
    (await bridge.todoTaskList(const ListFilter())).length;

void main() {
  group('MockOrbitBridge todoTaskComplete（对齐 Rust complete_todo_task）', () {
    test('普通任务：标记完成，不生成下一实例', () async {
      final bridge = MockOrbitBridge();
      final before = await liveTaskCount(bridge);
      final t = await bridge.todoTaskCreate(
        const TodoTaskCreateInput(title: '普通任务'),
      );
      final done = await bridge.todoTaskComplete(t.id);
      expect(done.isDone, isTrue);
      expect(done.status, 'done');
      expect(done.doneAt, isNotNull);
      expect(await liveTaskCount(bridge), before + 1);
    });

    test('重复任务：完成生成下一实例，原实例标记完成', () async {
      final bridge = MockOrbitBridge();
      final before = await liveTaskCount(bridge);
      final now = DateTime.now();
      final due = now.millisecondsSinceEpoch + 86400000; // 明天到期
      final t = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: '每天任务',
        dueDate: due,
        repeatMode: 1,
        repeatAfter: 1,
      ));
      await bridge.todoSubtaskCreate(
        TodoSubtaskCreateInput(taskId: t.id, title: '子任务甲'),
      );
      final done = await bridge.todoTaskComplete(t.id);
      expect(done.isDone, isTrue);

      final all = await bridge.todoTaskList(const ListFilter());
      // 原实例 + 下一实例
      expect(all.length, before + 2);
      final next = all.firstWhere((x) => !x.isDone && x.title == '每天任务');
      // due 推进一步；重复规则带到下一实例
      expect(next.dueDate, due + 86400000);
      expect(next.repeatMode, 1);

      // 子任务克隆到下一实例，完成态重置
      final subs = await bridge.todoSubtaskList(const ListFilter());
      final nextSubs = subs.where((s) => s.taskId == next.id).toList();
      expect(nextSubs.length, 1);
      expect(nextSubs.first.title, '子任务甲');
      expect(nextSubs.first.isDone, isFalse);
    });

    test('已完成任务再完成：幂等，不重复推进', () async {
      final bridge = MockOrbitBridge();
      final before = await liveTaskCount(bridge);
      final t = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: '每天任务',
        dueDate: DateTime.now().millisecondsSinceEpoch,
        repeatMode: 1,
        repeatAfter: 1,
      ));
      await bridge.todoTaskComplete(t.id);
      await bridge.todoTaskComplete(t.id); // 幂等
      // 两次完成仍只有 1 个下一实例
      expect(await liveTaskCount(bridge), before + 2);
    });

    test('回收站任务完成被拒绝', () async {
      final bridge = MockOrbitBridge();
      final t = await bridge.todoTaskCreate(
        const TodoTaskCreateInput(title: '回收站任务'),
      );
      await bridge.todoTaskDelete(t.id);
      await expectLater(bridge.todoTaskComplete(t.id), throwsException);
    });
  });
}
