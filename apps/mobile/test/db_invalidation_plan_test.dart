import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/shell/db_invalidation.dart';

/// B7 db-change 表级失效：决策面纯函数单测
/// （invalidateByTable 的 provider 落点是 ref.invalidate 转发，决策与转发
/// 分离后此处锁住语义——未知表回退、轨迹单独一链、子表不碰主列表）
void main() {
  group('planTableInvalidation', () {
    test('未知表返回空计划（调用方回退全量）', () {
      expect(planTableInvalidation('cfg_kv'), isEmpty);
      expect(planTableInvalidation('mock'), isEmpty);
    });

    test('todo_tasks 联动任务/详情/回收站/统计/搜索', () {
      final plan = planTableInvalidation('todo_tasks');
      expect(plan, containsAll(<DbCacheTarget>[
        DbCacheTarget.tasks,
        DbCacheTarget.taskDetail,
        DbCacheTarget.trashTasks,
        DbCacheTarget.stats,
        DbCacheTarget.search,
      ]));
      // 不越界：项目/标签/筛选器/轨迹不因任务变化失效
      expect(plan, isNot(contains(DbCacheTarget.labels)));
      expect(plan, isNot(contains(DbCacheTarget.projects)));
      expect(plan, isNot(contains(DbCacheTarget.taskActivity)));
    });

    test('todo_activity_log 只失效轨迹一条链（不碰主列表）', () {
      expect(planTableInvalidation('todo_activity_log'),
          [DbCacheTarget.taskActivity]);
    });

    test('纯详情子表只影响详情聚合', () {
      for (final table in [
        'todo_task_relations',
        'todo_subtasks',
        'todo_reminders',
      ]) {
        expect(planTableInvalidation(table), [DbCacheTarget.taskDetail],
            reason: table);
      }
    });

    test('todo_task_labels 联动详情与列表标签投影', () {
      // 列表页支持按标签筛选并把标签色点画进看板/表格卡片，
      // 关联行增删必须同时刷新投影，否则筛选结果与色点会读到旧集合
      expect(planTableInvalidation('todo_task_labels'),
          [DbCacheTarget.taskDetail, DbCacheTarget.taskLabelProjection]);
    });

    test('todo_comments 联动详情与全局搜索', () {
      expect(planTableInvalidation('todo_comments'),
          [DbCacheTarget.taskDetail, DbCacheTarget.search]);
    });

    test('todo_projects / todo_labels / todo_saved_filters 各自消费方', () {
      expect(
        planTableInvalidation('todo_projects'),
        [
          DbCacheTarget.projects,
          DbCacheTarget.archivedProjects,
          DbCacheTarget.search,
        ],
      );
      expect(planTableInvalidation('todo_labels'),
          [DbCacheTarget.labels, DbCacheTarget.taskDetail]);
      expect(planTableInvalidation('todo_saved_filters'),
          [DbCacheTarget.savedFilters]);
    });
  });

  group('派生刷新判定', () {
    test('闹钟重排只受提醒行与任务表影响', () {
      expect(affectsReminderSchedule('todo_reminders'), isTrue);
      expect(affectsReminderSchedule('todo_tasks'), isTrue);
      expect(affectsReminderSchedule('todo_activity_log'), isFalse);
      expect(affectsReminderSchedule('todo_labels'), isFalse);
    });

    test('角标/小组件快照只看任务表', () {
      expect(affectsTaskSnapshot('todo_tasks'), isTrue);
      expect(affectsTaskSnapshot('todo_reminders'), isFalse);
      expect(affectsTaskSnapshot('todo_projects'), isFalse);
    });
  });
}
