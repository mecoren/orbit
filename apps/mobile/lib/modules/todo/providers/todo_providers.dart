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

/// 全量失效业务缓存（dbChanges / syncFinished(pulled>0) 时调用）
void invalidateBusinessCaches(WidgetRef ref) {
  ref.invalidate(todoProjectsProvider);
  ref.invalidate(todoLabelsProvider);
  ref.invalidate(todoTasksProvider);
  ref.invalidate(taskDetailProvider);
  ref.invalidate(syncConfigProvider);
}
