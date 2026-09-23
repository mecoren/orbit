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
      final done = (await bridge.todoTaskComplete(t.id)).task;
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
      final res = await bridge.todoTaskComplete(t.id);
      expect(res.task.isDone, isTrue);
      // 契约：推进生成的下一实例随结果返回（UI 靠它弹「已生成下一期」提示）
      expect(res.nextInstance, isNotNull);
      expect(res.nextInstance!.dueDate, due + 86400000);

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

  group('#34 重复规则扩展（when done / 结束次数 / 字段克隆）', () {
    test('when done：完成日锚定推进一个完整周期', () async {
      final bridge = MockOrbitBridge();
      // due 定在远过去：默认快进口径会把 next 推到 now 之后最近的序列点；
      // when-done 口径 = 完成时刻 + 7 天。两种口径都 > now，但 when-done
      // 的 next 与完成时刻的差恒为 7 天（快进口径差 < 7 天）。
      final due = DateTime(2020, 1, 6).millisecondsSinceEpoch; // 周一
      final t = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: '理发',
        dueDate: due,
        repeatMode: 2,
        repeatAfter: 1,
        repeatFromDone: 1,
      ));
      final beforeComplete = DateTime.now().millisecondsSinceEpoch;
      final done = (await bridge.todoTaskComplete(t.id)).task;
      expect(done.isDone, isTrue);
      final list = await bridge.todoTaskList(const ListFilter());
      final next = list.firstWhere((x) => !x.isDone && x.title == '理发');
      // 下一实例 due 在 [完成时刻, 完成时刻+7天] 窗口内且距完成 < 7 天 + 时钟容差
      final deltaFromNow = next.dueDate! - beforeComplete;
      expect(deltaFromNow, greaterThan(6 * 86400000),
          reason: 'when done 必须顺延一个完整周期（≥6 天）');
      expect(deltaFromNow, lessThan(7 * 86400000 + 60000),
          reason: 'when done 顺延恰好一个周期（容差 1 分钟）');
      expect(next.repeatFromDone, 1, reason: '规则字段随克隆');
    });

    test('结束次数：param 递减，1 时序列终结', () async {
      final bridge = MockOrbitBridge();
      final due = DateTime(2026, 9, 1).millisecondsSinceEpoch;
      final t = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: '三次课程',
        dueDate: due,
        repeatMode: 1,
        repeatAfter: 1,
        repeatEndType: 2,
        repeatEndParam: 3,
      ));
      // 第一次完成 → 剩 2 次
      await bridge.todoTaskComplete(t.id);
      var list = await bridge.todoTaskList(const ListFilter());
      var next = list.firstWhere((x) => !x.isDone && x.title == '三次课程');
      expect(next.repeatEndParam, 2, reason: '次数随推进递减');
      // 第二次 → 剩 1；第三次完成后终结（param=1 时不再克隆）
      await bridge.todoTaskComplete(next.id);
      list = await bridge.todoTaskList(const ListFilter());
      next = list.firstWhere((x) => !x.isDone && x.title == '三次课程');
      expect(next.repeatEndParam, 1);
      await bridge.todoTaskComplete(next.id);
      list = await bridge.todoTaskList(const ListFilter());
      expect(list.where((x) => !x.isDone && x.title == '三次课程').length, 0,
          reason: '次数耗尽后序列终结');
    });

    test('#37 复制：克隆字段+子任务标题，完成态与社交字段重置', () async {
      final bridge = MockOrbitBridge();
      final src = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: '周报模板',
        description: '模板内容',
        priority: 3,
        dueDate: DateTime(2026, 9, 10).millisecondsSinceEpoch,
        repeatMode: 1,
        repeatAfter: 1,
        isFavorite: 1,
      ));
      await bridge.todoSubtaskCreate(
          TodoSubtaskCreateInput(taskId: src.id, title: '步骤一'));
      // 已完成再复制（验证完成态重置）
      await bridge.todoTaskComplete(src.id);

      final copy = await bridge.todoTaskDuplicate(src.id);
      expect(copy.title, '周报模板（副本）');
      expect(copy.description, '模板内容');
      expect(copy.priority, 3);
      expect(copy.dueDate, src.dueDate);
      expect(copy.repeatMode, 1);
      expect(copy.isStarred, isTrue);
      expect(copy.isDone, isFalse, reason: '新实例完成态必须重置');

      final subs = await bridge.todoSubtaskList(const ListFilter());
      final copySubs = subs.where((s) => s.taskId == copy.id).toList();
      expect(copySubs.length, 1);
      expect(copySubs.first.title, '步骤一');
      expect(copySubs.first.done, 0);
    });

    test('星期几掩码字段随克隆保留', () async {
      final bridge = MockOrbitBridge();
      final due = DateTime(2026, 9, 1).millisecondsSinceEpoch; // 周二
      final t = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: '健身',
        dueDate: due,
        repeatMode: 2,
        repeatAfter: 1,
        repeatWeekdays: 21, // 一/三/五（bit0+2+4）
      ));
      await bridge.todoTaskComplete(t.id);
      final list = await bridge.todoTaskList(const ListFilter());
      final next = list.firstWhere((x) => !x.isDone && x.title == '健身');
      expect(next.repeatWeekdays, 21, reason: '掩码随克隆保留');
    });
  });
}
