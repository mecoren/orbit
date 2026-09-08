import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/api/dto.dart';
import '../../../data/providers/bridge_provider.dart';

/// 待办模块 Riverpod 手动声明（无 codegen）
///
/// 约定（对齐原 React 版 react-query key 语义）：
/// - 列表 FutureProvider.family 携 QueryKey 参数对象；
/// - 写操作 await bridge 后由 UI 层 ref.invalidate 对应 provider；
/// - bridge.dbChanges 全量失效在 BootGate ready 后统一挂监听。

/// 项目列表（React queryKey ["todo-project","list"]）
final todoProjectsProvider = FutureProvider<List<TodoProject>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoProjectList(const ListFilter(pageSize: 1000));
});

/// 标签列表（React queryKey ["todo-label","list"]；详情页标签编辑弹层消费）
final todoLabelsProvider = FutureProvider<List<TodoLabel>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoLabelList(const ListFilter(pageSize: 1000));
});

/// 任务列表查询键（React queryKey ["todo_tasks", keyword]）
class TaskListQuery {
  final String keyword;

  const TaskListQuery({this.keyword = ''});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TaskListQuery && other.keyword == keyword;

  @override
  int get hashCode => keyword.hashCode;
}

/// 全量任务列表（客户端经 task_logic 过滤/排序出各视图数据）
final todoTasksProvider =
    FutureProvider.family<List<TodoTask>, TaskListQuery>((ref, query) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoTaskList(ListFilter(keyword: query.keyword, pageSize: 10000));
});

/// 任务详情聚合查询键（任务本体 + 子任务/标签/评论/关联/提醒）
final taskDetailProvider = FutureProvider.family<TodoTaskDetail, int>(
  (ref, taskId) => ref.watch(orbitBridgeProvider).todoTaskGetDetail(taskId),
);

/// due_date → 本地 YYYY-MM-DD 任务聚合（日历视图月历圆点/按日分组共用）。
///
/// 从 todoTasksProvider 派生而非在日历 build 里每次重算：点击选中日等
/// 局部 setState 也会触发 build，全量重聚合 + 逐日排序在千条任务下是
/// 每帧数万次比较——派生后仅在任务列表数据真正变化时重算一次。
final calendarByDayProvider = FutureProvider<Map<String, List<TodoTask>>>(
  (ref) async {
    // 保持依赖：任务列表刷新时本聚合同步重算
    final tasks =
        await ref.watch(todoTasksProvider(const TaskListQuery()).future);
    final map = <String, List<TodoTask>>{};
    for (final t in tasks) {
      final due = t.dueDate;
      if (due == null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(due);
      final key =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      (map[key] ??= []).add(t);
    }
    for (final list in map.values) {
      list.sort((a, b) {
        if (a.position != b.position) return a.position.compareTo(b.position);
        return b.createdAt.compareTo(a.createdAt);
      });
    }
    return map;
  },
);

/// 同步配置；未配置返回 null（设置页消费）
final syncConfigProvider = FutureProvider<SyncConfigView?>(
  (ref) => ref.watch(orbitBridgeProvider).syncConfigGet(),
);

/// 节假日全量（日历视图徽标；空库回落 Rust 预置 2026 表，冷启动可用。
/// 更新由 BootGate 启动的 Rust 守护 + 日历页手动更新触发，成功后 invalidate）
final holidayProvider = FutureProvider<List<HolidayInfo>>((ref) async {
  return ref.watch(orbitBridgeProvider).holidayList();
});

/// 节假日更新记账（日历工具栏「上次更新」展示）
final holidayMetaProvider = FutureProvider<HolidayMeta>((ref) async {
  return ref.watch(orbitBridgeProvider).holidayMeta();
});

/// 回收站任务列表（React queryKey ["trash","tasks"]；最近删除排最前）
final trashTasksProvider = FutureProvider<List<TodoTask>>((ref) async {
  return ref.watch(orbitBridgeProvider).trashTasksList();
});

/// 回收站元数据（回收站页保留期倒计时 + 设置页保留档位）
final trashMetaProvider = FutureProvider<TrashMeta>((ref) async {
  return ref.watch(orbitBridgeProvider).trashMeta();
});

/// 统计聚合（backlog #25 统计页；family 参数 = 热力图窗口天数）
final statsProvider = FutureProvider.family<StatsAggregate, int>((ref, days) async {
  return ref.watch(orbitBridgeProvider).statsAggregate(days: days);
});

/// 全局搜索（backlog #26 搜索页；family 参数 = 关键词，防抖后由 UI 层触发）
final searchProvider = FutureProvider.family<GlobalSearchResult, String>(
  (ref, keyword) async {
    return ref.watch(orbitBridgeProvider).globalSearch(keyword);
  },
);

/// 全量失效业务缓存（dbChanges / syncFinished(pulled>0) 时调用）
void invalidateBusinessCaches(WidgetRef ref) {
  ref.invalidate(todoProjectsProvider);
  ref.invalidate(todoLabelsProvider);
  ref.invalidate(todoTasksProvider);
  ref.invalidate(taskDetailProvider);
  ref.invalidate(syncConfigProvider);
  ref.invalidate(trashTasksProvider);
  ref.invalidate(statsProvider);
}

/// 保存的筛选器列表（#35）
final savedFiltersProvider = FutureProvider<List<TodoSavedFilter>>(
  (ref) => ref.watch(orbitBridgeProvider).savedFiltersList(),
);
