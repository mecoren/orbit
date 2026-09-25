import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/dto.dart';
import '../todo/providers/todo_providers.dart';

/// db-change 表级失效目标（B7，与 provider 解耦的纯枚举——决策面可单测）
enum DbCacheTarget {
  /// 单份任务缓存（todoTasksProvider）
  tasks,

  /// 任务详情聚合（taskDetailProvider）
  taskDetail,

  /// 回收站任务列表
  trashTasks,

  /// 统计聚合
  stats,

  /// 全局搜索三路结果
  search,

  /// 项目 / 归档项目
  projects,
  archivedProjects,

  /// 标签列表
  labels,

  /// 任务→标签投影（列表页标签筛选与标签色点）
  taskLabelProjection,

  /// 任务→提醒投影（列表行内提醒徽标）
  taskReminderProjection,

  /// 任务→关联计数投影（列表行内「有关联」徽标）
  taskDependencyProjection,

  /// 任务→「有描述」投影（列表行内描述图标；description 在列表通道被裁剪）
  taskDescriptionProjection,

  /// 保存的筛选器
  savedFilters,

  /// 单任务历史轨迹
  taskActivity,
}

/// 表名 → 失效目标（纯函数）：空列表 = 未知表，调用方回退全量失效。
///
/// 口径（对齐桌面 `lib/db-invalidation.ts` 的 TABLE_QUERY_KEYS）：
/// - todo_tasks 联动统计/回收站/全局搜索（读路径跨表聚合）；
/// - todo_activity_log 轨迹单独一链——业务写路径的 todo_tasks 事件先于
///   轨迹 INSERT 到达，历史区块挂 todo_tasks 会竞态读旧行；
/// - 子表（标签关联/子任务）只影响详情聚合，不碰主列表；
/// - 提醒行 / 关联行例外：除详情聚合外还刷新各自的列表行投影（行内徽标读它）。
List<DbCacheTarget> planTableInvalidation(String table) => switch (table) {
      // 描述编辑走任务 UPDATE：行内描述图标位（行元信息投影）随行失效
      'todo_tasks' => const [
          DbCacheTarget.tasks,
          DbCacheTarget.taskDetail,
          DbCacheTarget.trashTasks,
          DbCacheTarget.stats,
          DbCacheTarget.search,
          DbCacheTarget.taskDescriptionProjection,
        ],
      'todo_projects' => const [
          DbCacheTarget.projects,
          DbCacheTarget.archivedProjects,
          DbCacheTarget.search,
        ],
      'todo_labels' => const [
          DbCacheTarget.labels,
          DbCacheTarget.taskDetail,
        ],
      // 标签关联改动同时影响详情聚合与列表投影（列表标签筛选/色点）
      'todo_task_labels' => const [
          DbCacheTarget.taskDetail,
          DbCacheTarget.taskLabelProjection,
        ],
      // 关联行增删另刷行内关联旗标投影（列表行读它；解除/添加关联后徽标须立即跟随）
      'todo_task_relations' => const [
          DbCacheTarget.taskDetail,
          DbCacheTarget.taskDependencyProjection,
        ],
      'todo_subtasks' => const [DbCacheTarget.taskDetail],
      // 提醒行另刷行内提醒徽标投影（列表行读它；增删提醒后徽标须立即跟随）
      'todo_reminders' => const [
          DbCacheTarget.taskDetail,
          DbCacheTarget.taskReminderProjection,
        ],
      'todo_comments' => const [
          DbCacheTarget.taskDetail,
          DbCacheTarget.search,
        ],
      // 附件挂/卸（内容寻址关联行）只影响任务详情的附件区，不碰主列表
      'todo_task_attachments' => const [DbCacheTarget.taskDetail],
      'todo_saved_filters' => const [DbCacheTarget.savedFilters],
      'todo_activity_log' => const [DbCacheTarget.taskActivity],
      _ => const [],
    };

/// 按事件表名精确失效缓存（B7）。
///
/// 此前 BootGate 对每条 db-change 一律七路全刷（项目/标签/任务/详情/同步
/// 配置/回收站/统计），勾选一条任务会把与它无关的配置与统计一起标脏重拉。
/// 返回 true 表示该表已被处理（含「零失效」的已知表）；false = 未知表
/// （未来新表 / 云同步内部表），调用方回退 [invalidateBusinessCaches]
/// 全量——宁多拉不漏刷。
bool invalidateByTable(WidgetRef ref, String table) {
  final targets = planTableInvalidation(table);
  if (targets.isEmpty) return false;
  for (final target in targets) {
    switch (target) {
      case DbCacheTarget.tasks:
        ref.invalidate(todoTasksProvider);
      case DbCacheTarget.taskDetail:
        ref.invalidate(taskDetailProvider);
      case DbCacheTarget.trashTasks:
        ref.invalidate(trashTasksProvider);
      case DbCacheTarget.stats:
        ref.invalidate(statsProvider);
      case DbCacheTarget.search:
        ref.invalidate(searchProvider);
      case DbCacheTarget.projects:
        ref.invalidate(todoProjectsProvider);
      case DbCacheTarget.archivedProjects:
        ref.invalidate(todoArchivedProjectsProvider);
      case DbCacheTarget.labels:
        ref.invalidate(todoLabelsProvider);
      case DbCacheTarget.taskLabelProjection:
        ref.invalidate(taskLabelsProjectionProvider);
      case DbCacheTarget.taskReminderProjection:
        ref.invalidate(taskRemindersProjectionProvider);
      case DbCacheTarget.taskDependencyProjection:
        ref.invalidate(taskDependencyFlagsProvider);
      case DbCacheTarget.taskDescriptionProjection:
        ref.invalidate(taskDescriptionFlagsProvider);
      case DbCacheTarget.savedFilters:
        ref.invalidate(savedFiltersProvider);
      case DbCacheTarget.taskActivity:
        ref.invalidate(taskActivityProvider);
    }
  }
  return true;
}

/// 云同步完成后的缓存失效（F42，与桌面 `useSyncInvalidation` 同口径）
///
/// 按本轮真正写入的表（`changedTables`）精确失效，替代此前
/// `pulledModules > 0` 的粗判据——后者会漏掉两类轮次：① 只拉附件
/// （附件缓存与同步表事件无关）；② 桶下载了但合并实际全 skip。
/// 附件下载数 > 0 时映射到任务详情键（附件区）。
/// 表集合缺失（旧引擎 / mock 桥）时按 pulledModules 保守全量。
void invalidateAfterSyncCaches(WidgetRef ref, SyncResultJson result) {
  if (result.skipped) return;
  final tables = <String>{...result.changedTables};
  if (result.downloadedAttachments > 0) {
    tables.add('todo_task_attachments');
  }
  if (tables.isEmpty) {
    if (result.pulledModules > 0) invalidateBusinessCaches(ref);
    return;
  }
  var allKnown = true;
  for (final table in tables) {
    if (!invalidateByTable(ref, table)) {
      allKnown = false;
      break;
    }
  }
  if (!allKnown) invalidateBusinessCaches(ref);
}

/// 该表是否影响提醒闹钟重排（todo_reminders 行本身与 todo_tasks 完成态——
/// 完成实例的提醒行随完成软删）。其余表的变更重排是纯重复工作量。
bool affectsReminderSchedule(String table) =>
    table == 'todo_reminders' || table == 'todo_tasks';

/// 该表是否影响「今天截止或已逾期」角标与小组件快照（两者都读单份任务
/// 缓存口径，只有任务表变化才需重算）。
bool affectsTaskSnapshot(String table) => table == 'todo_tasks';
