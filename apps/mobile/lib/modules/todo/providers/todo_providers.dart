import 'package:flutter/foundation.dart';
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

/// 归档项目列表（React queryKey ["todo-project","archived"] 对齐；
/// 侧栏归档区数据源，归档切换后双失效刷新）
final todoArchivedProjectsProvider =
    FutureProvider<List<TodoProject>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoProjectListArchived();
});

/// 标签列表（React queryKey ["todo-label","list"]；详情页标签编辑弹层消费）
final todoLabelsProvider = FutureProvider<List<TodoLabel>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoLabelList(const ListFilter(pageSize: 1000));
});

/// 任务→标签投影（A4 只读聚合；列表页标签筛选与卡片/表格标签色点消费）
///
/// 一次往返替代「列表 N 次 todoTaskLabelList」，投影未就绪时调用方回落
/// 无标签点渲染（不阻塞列表）。
final taskLabelsProjectionProvider =
    FutureProvider<List<TaskLabelsProjection>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.taskLabelsProjection();
});

/// 任务→提醒投影（A4 只读聚合；列表行内提醒徽标消费）
///
/// 一次往返替代「列表 N 次 todoReminderList」；投影未就绪时调用方回落
/// 不渲染徽标（不阻塞列表）。core 侧已滤软删并按 remind_at 升序。
final taskRemindersProjectionProvider =
    FutureProvider<List<TaskRemindersProjection>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.taskRemindersProjection();
});

/// 任务列表单次拉取上限（A5/B6，与桌面 `TASK_LIST_PAGE_SIZE` 同口径）：
/// 单份缓存与列表页「不完整」条幅共用——结果集达到它即意味着还有未取到的
/// 任务，条幅按此判定而非另开 count 接口。
const int taskListPageSize = 10000;

/// 全量任务列表（B6 单份缓存）：全 App 唯一一份万行全量，各视图
/// （侧栏计数 / 子列表 / 日历 / 保存筛选 / 角标）经 task_logic 派生过滤，
/// 不再按参数分叉缓存——family 时代每个 keyword 都留一份万行副本。
///
/// 关键词查询**不走本 provider**：单份缓存是列裁剪产物（keyword 空时
/// description 不随行传输），在其上做客户端关键词过滤会把「按描述搜索」
/// 静默变成恒无结果——那正是桌面 6c6c2b0 修掉的缺陷的移动端镜像。
/// 列表内关键词一律走 [todoTasksSearchProvider] 服务端通道。
final todoTasksProvider = FutureProvider<List<TodoTask>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoTaskList(const ListFilter(pageSize: taskListPageSize));
});

/// 列表关键词服务端通道（B6 保留）：keyword 非空 → core SQL LIKE
/// （title + description，description 仅在 keyword 非空时随行传输）。
/// 保留给列表内搜索类入口（docs/05 §4.2 未接线设计稿的「搜索展开」），
/// 禁止用 [todoTasksProvider] 缓存做客户端关键词过滤（见其文档注释）。
final todoTasksSearchProvider =
    FutureProvider.family<List<TodoTask>, String>((ref, keyword) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoTaskList(
    ListFilter(keyword: keyword, pageSize: taskListPageSize),
  );
});

/// 任务详情聚合查询键（任务本体 + 子任务/标签/评论/关联/提醒）
final taskDetailProvider = FutureProvider.family<TodoTaskDetail, int>(
  (ref, taskId) => ref.watch(orbitBridgeProvider).todoTaskGetDetail(taskId),
);

/// 单任务活动历史（详情页「历史」区块；family 参数 = 任务 id + 取数档位，
/// 档位默认 30、可展到 core clamp 上限 100——满档时 UI 提示「仅显示最近
/// N 条」。时间倒序由 core 收口。不进 invalidateBusinessCaches：
/// 全量任务列表事件会先于轨迹 INSERT 到达，靠它刷新会读到旧行，
/// 失效口只挂 boot_gate 的 todo_activity_log 事件）
final taskActivityProvider =
    FutureProvider.family<List<ActivityLogRow>, ({int taskId, int limit})>(
  (ref, q) =>
      ref.watch(orbitBridgeProvider).taskActivityList(q.taskId, limit: q.limit),
);

/// due_date → 本地 YYYY-MM-DD 任务聚合（日历视图月历圆点/按日分组共用）。
///
/// 从 todoTasksProvider 派生而非在日历 build 里每次重算：点击选中日等
/// 局部 setState 也会触发 build，全量重聚合 + 逐日排序在千条任务下是
/// 每帧数万次比较——派生后仅在任务列表数据真正变化时重算一次。
final calendarByDayProvider = FutureProvider<Map<String, List<TodoTask>>>(
  (ref) async {
    // 保持依赖：任务列表刷新时本聚合同步重算
    final tasks = await ref.watch(todoTasksProvider.future);
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

/// 统计聚合（backlog #25 统计页；family 参数 = 热力图年份，
/// 2026-09-10 对齐 wait-home：当前年滚动 365 天、历史年完整年）
final statsProvider = FutureProvider.family<StatsAggregate, int>((ref, year) async {
  return ref.watch(orbitBridgeProvider).statsAggregate(year: year);
});

/// 全局搜索（backlog #26 搜索页；family 参数 = 关键词，防抖后由 UI 层触发）
final searchProvider = FutureProvider.family<GlobalSearchResult, String>(
  (ref, keyword) async {
    return ref.watch(orbitBridgeProvider).globalSearch(keyword);
  },
);

/// 全量失效业务缓存（**仅**未知表回退与 syncFinished(pulled>0) 时调用）：
/// 本地 db-change 走 B7 表级精确失效（modules/shell/db_invalidation.dart），
/// 不再整包全刷；云同步拉取合并的写入不产生 db-change 事件，仍需此全量口。
void invalidateBusinessCaches(WidgetRef ref) {
  ref.invalidate(todoProjectsProvider);
  ref.invalidate(todoArchivedProjectsProvider);
  ref.invalidate(todoLabelsProvider);
  ref.invalidate(taskLabelsProjectionProvider);
  ref.invalidate(taskRemindersProjectionProvider);
  ref.invalidate(todoTasksProvider);
  ref.invalidate(taskDetailProvider);
  ref.invalidate(taskActivityProvider);
  ref.invalidate(syncConfigProvider);
  ref.invalidate(trashTasksProvider);
  ref.invalidate(statsProvider);
  ref.invalidate(savedFiltersProvider);
  ref.invalidate(searchProvider);
}

/// 下拉刷新共用回调（主列表 / 侧栏 / 统计 / 回收站四页的 `RefreshIndicator`）
///
/// 本地优先应用里「刷新」分两步，顺序不能反：
/// 1. 本地缓存立即重读——即使第 2 步失败或未配置云同步，用户也一定看到一次
///    真正的重新查询，手势不会白拉；
/// 2. 已配置云同步时再跑一轮手动同步——拉取合并写入不产生 db-change 事件
///    （结果经 cloudSyncNow 返回值直达，ADR 0003），必须在此显式失效后
///    云端改动才会出现在列表里。
///
/// 同步失败**不在此弹错**：下拉是探索性手势，且第 1 步已保证本地数据最新；
/// 同步配置/锁定/密钥问题由设置页与顶栏云同步状态入口负责表达。
Future<void> pullToRefresh(WidgetRef ref) async {
  invalidateBusinessCaches(ref);

  SyncConfigView? config;
  try {
    config = await ref.read(syncConfigProvider.future);
  } catch (_) {
    return; // 配置查询尚未落定：只做本地重读
  }
  if (config == null) return; // 未配置云同步：本地重读即刷新

  try {
    await ref.read(orbitBridgeProvider).cloudSyncNow(origin: 'manual');
    ref.invalidate(syncConfigProvider);
    invalidateBusinessCaches(ref);
  } catch (e) {
    debugPrint('[pullToRefresh] cloud sync failed: $e');
  }
}

/// 保存的筛选器列表（#35）
final savedFiltersProvider = FutureProvider<List<TodoSavedFilter>>(
  (ref) => ref.watch(orbitBridgeProvider).savedFiltersList(),
);
