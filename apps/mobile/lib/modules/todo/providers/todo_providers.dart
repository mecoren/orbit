import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/api/dto.dart';
import '../../../data/providers/bridge_provider.dart';
import '../logic/paged_query.dart';
import '../logic/time_block.dart';
import 'task_window_provider.dart';

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

/// 待回顾项目清单（F1；queryKey 语义 ["todo-project","review-due"]——
/// 到期/逾期判定真值在 core，本 provider 只传「现在」；回顾写操作与
/// db-change 后经 db_invalidation 的 reviewDue 目标刷新）
final reviewDueProvider =
    FutureProvider<List<ProjectReviewStatus>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge
      .todoProjectsDueForReview(DateTime.now().millisecondsSinceEpoch);
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

/// 任务→关联计数投影（A4 只读聚合；C7 列表行「有关联」徽标消费）
///
/// 只传出边存活行总数（core 侧 GROUP BY task_id，`relation_count > 0`
/// 即有关联），不拉全量关系表；投影未就绪时调用方不渲染徽标。
final taskDependencyFlagsProvider =
    FutureProvider<List<TaskDependencyFlags>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.taskDependencyFlags();
});

/// 「有描述」任务 id 集（列表通道裁剪 description 后行内描述图标的来源）；
/// 未就绪回落空集（不渲染图标，不阻塞列表）
final taskDescriptionFlagsProvider = FutureProvider<Set<int>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final rows = await bridge.taskDescriptionFlags();
  return {for (final r in rows) r.taskId};
});

/// 「有附件」任务 id 集（#71 筛选器 has_attachment 数据源；未就绪回落空集）
final taskAttachmentFlagsProvider = FutureProvider<Set<int>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final rows = await bridge.taskAttachmentFlags();
  return {for (final r in rows) r.taskId};
});

/// 「有未完成子任务」任务 id 集（#71 筛选器 has_open_subtask 数据源；
/// 未就绪回落空集）
final taskOpenSubtaskFlagsProvider = FutureProvider<Set<int>>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final rows = await bridge.taskOpenSubtaskFlags();
  return {for (final r in rows) r.taskId};
});

/// 任务列表单次拉取上限（A5/B6，与桌面 `TASK_LIST_PAGE_SIZE` 同口径）：
/// 回退全量通道的上限（P1 窗口化后只服务回退视图）：标签筛选/标题排序/
/// 保存筛选器预览等 core 无谓词的组合仍一次取回，达到上限提示收窄范围。
const int taskListPageSize = 10000;

/// 全量任务列表（**按需**通道，P1 窗口化后不再是列表主数据源）。
///
/// 列表/表格/看板/矩阵/日历/Logbook 已改走 [taskWindowProvider] 等窗口通道；
/// 本 provider 只留给确实需要整份集合的流程：周回顾、收件箱分诊、回顾中心、
/// 保存筛选器预览、项目编辑页计数，以及上方的回退视图（标签筛选/标题排序/
/// 标签看板）。**不要在任何常驻 UI（侧栏/底栏/角标）watch 它**——那会让
/// 万行数组常驻，窗口化的内存收益归零（侧栏/底栏已改 [sidebarCountsProvider]）。
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
///
/// autoDispose：关键词 family 桶按词累积（每词一份整页结果），当前无
/// 消费点也按未来接线口径收紧——有监听才驻留。
final todoTasksSearchProvider = FutureProvider.autoDispose.family
    <List<TodoTask>, String>((ref, keyword) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoTaskList(
    ListFilter(keyword: keyword, pageSize: taskListPageSize),
  );
});

/// 任务详情聚合查询键（任务本体 + 子任务/标签/评论/关联/提醒）
///
/// autoDispose（内存收口 2026-09-25）：riverpod 3 的 family 默认**不**自动
/// 回收，浏览过的每个任务详情会常驻到进程结束；详情缓存只在详情页存活期
/// 有意义，离开即释放，重进重新拉取。
final taskDetailProvider = FutureProvider.autoDispose.family<TodoTaskDetail, int>(
  (ref, taskId) => ref.watch(orbitBridgeProvider).todoTaskGetDetail(taskId),
);

/// 单任务活动历史（详情页「历史」区块；family 参数 = 任务 id + 取数档位，
/// 档位默认 30、可展到 core clamp 上限 100——满档时 UI 提示「仅显示最近
/// N 条」。时间倒序由 core 收口。不进 invalidateBusinessCaches：
/// 全量任务列表事件会先于轨迹 INSERT 到达，靠它刷新会读到旧行，
/// 失效口只挂 boot_gate 的 todo_activity_log 事件）
///
/// autoDispose 同 [taskDetailProvider]：历史行随详情页关闭释放。
final taskActivityProvider =
    FutureProvider.autoDispose.family<List<ActivityLogRow>, ({int taskId, int limit})>(
  (ref, q) =>
      ref.watch(orbitBridgeProvider).taskActivityList(q.taskId, limit: q.limit),
);

// 时段块 / due 分桶的日历聚合已迁到范围版（见下方
// `timelineBlocksByDayRangeProvider` / `calendarByDayRangeProvider`）：
// 全量派生在 50k 档既拉全表又在每次数据变动时全表重排，已被窗口化取代。

/// 日历可见范围（本地日界毫秒，半开区间 `[fromMs, toMs)`）。
@immutable
class CalendarRange {
  final int fromMs;
  final int toMs;

  const CalendarRange({required this.fromMs, required this.toMs});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CalendarRange && fromMs == other.fromMs && toMs == other.toMs;

  @override
  int get hashCode => Object.hash(fromMs, toMs);
}

/// 范围内任务（P1 窗口化，docs/07 #105）：日历不再拉全量后内存分桶。
///
/// 两路并集（按 id 去重）：
/// - `due_date ∈ [from, to)`：月历日格/议程按 due 分桶；
/// - `start_date ∈ [from, to)`：时间轴按**块起点**分桶，显式排程块的
///   start 可能落在 due 之外（甚至无 due），只查 due 会漏块。
final calendarRangeTasksProvider = FutureProvider.autoDispose
    .family<List<TodoTask>, CalendarRange>((ref, range) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final pages = await Future.wait([
    fetchAllTaskPages(
      (cursor) => bridge.todoTaskPage(
        ListFilter(
          dueFrom: range.fromMs,
          dueTo: range.toMs,
          sortKey: 'due',
          sortDir: 'asc',
        ),
        cursor,
        kTaskPageWindow,
      ),
    ),
    fetchAllTaskPages(
      (cursor) => bridge.todoTaskPage(
        ListFilter(
          startFrom: range.fromMs,
          startTo: range.toMs,
          sortKey: 'due',
          sortDir: 'asc',
        ),
        cursor,
        kTaskPageWindow,
      ),
    ),
  ]);
  final seen = <int>{};
  return [
    for (final page in pages)
      for (final t in page)
        if (seen.add(t.id)) t,
  ];
});

/// 日历日格聚合（范围版）：`due_date` → 本地 YYYY-MM-DD。
final calendarByDayRangeProvider = FutureProvider.autoDispose
    .family<Map<String, List<TodoTask>>, CalendarRange>((ref, range) async {
  final tasks = await ref.watch(calendarRangeTasksProvider(range).future);
  final map = <String, List<TodoTask>>{};
  for (final t in tasks) {
    final due = t.dueDate;
    if (due == null) continue;
    (map[_localYmd(due)] ??= []).add(t);
  }
  for (final list in map.values) {
    list.sort((a, b) {
      if (a.position != b.position) return a.position.compareTo(b.position);
      return b.createdAt.compareTo(a.createdAt);
    });
  }
  return map;
});

/// 时间轴聚合（范围版）：按块的**起点日**分桶（口径见 `task_time_block`）。
final timelineBlocksByDayRangeProvider = FutureProvider.autoDispose
    .family<Map<String, List<TodoTask>>, CalendarRange>((ref, range) async {
  final tasks = await ref.watch(calendarRangeTasksProvider(range).future);
  final map = <String, List<TodoTask>>{};
  for (final t in tasks) {
    final block = taskTimeBlock(t);
    if (block == null) continue;
    (map[_localYmd(block.startMs)] ??= []).add(t);
  }
  // 组内按块起点升序（同一刻按 id 稳定）
  for (final list in map.values) {
    list.sort((a, b) {
      final sa = taskTimeBlock(a)!.startMs;
      final sb = taskTimeBlock(b)!.startMs;
      if (sa != sb) return sa.compareTo(sb);
      return a.id.compareTo(b.id);
    });
  }
  return map;
});

String _localYmd(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

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

/// 节假日范围补写进度流（设置页「按年份范围获取」进度条/取消按钮消费）
///
/// 注意：bridge 侧 `holidayProgress` 是**每次订阅新建一条** Rust→Dart 流，
/// 因此不要在多处重复 watch；设置页单点消费即可。
final holidayProgressProvider = StreamProvider<HolidayProgress>((ref) {
  return ref.watch(orbitBridgeProvider).holidayProgress;
});

/// 回收站任务列表（React queryKey ["trash","tasks"]；最近删除排最前）
final trashTasksProvider = FutureProvider<List<TodoTask>>((ref) async {
  return ref.watch(orbitBridgeProvider).trashTasksList();
});

/// 回收站元数据（回收站页保留期倒计时 + 设置页保留档位）
final trashMetaProvider = FutureProvider<TrashMeta>((ref) async {
  return ref.watch(orbitBridgeProvider).trashMeta();
});

/// 每日摘要偏好（G3；设置页开关 + 目标时刻）
final digestPrefsProvider = FutureProvider<DigestPrefs>((ref) async {
  return ref.watch(orbitBridgeProvider).digestPrefs();
});

/// 每日摘要计数（G3；设置页「当前口径预览」）
final digestSummaryProvider = FutureProvider<DigestSummary>((ref) async {
  return ref.watch(orbitBridgeProvider).digestSummary();
});

/// 统计聚合（backlog #25 统计页；family 参数 = 热力图年份，
/// 2026-09-10 对齐 wait-home：当前年滚动 365 天、历史年完整年）
///
/// autoDispose：切过多少年就存多少份聚合（含 365 天任务数组），
/// 只保留当前在看的年份，翻旧年重新聚合。
final statsProvider =
    FutureProvider.autoDispose.family<StatsAggregate, int>((ref, year) async {
  return ref.watch(orbitBridgeProvider).statsAggregate(year: year);
});

/// 全局搜索（backlog #26 搜索页；family 参数 = 关键词，防抖后由 UI 层触发）
///
/// autoDispose：搜索词 family 桶按词累积，历史关键词（含其中的任务/
/// 项目快照）不应常驻——只有当前关键词驻留，回退重搜重拉。
final searchProvider = FutureProvider.autoDispose.family
    <GlobalSearchResult, String>(
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
  ref.invalidate(taskDependencyFlagsProvider);
  ref.invalidate(taskDescriptionFlagsProvider);
  ref.invalidate(taskAttachmentFlagsProvider);
  ref.invalidate(taskOpenSubtaskFlagsProvider);
  ref.invalidate(todoTasksProvider);
  // 窗口化家族（P1）：列表/表格/看板/逾期/完成卡/总览/侧栏计数
  ref.invalidate(taskWindowProvider);
  ref.invalidate(taskWindowTotalProvider);
  ref.invalidate(taskOverdueProvider);
  ref.invalidate(taskDoneCardProvider);
  ref.invalidate(taskDoneTotalProvider);
  ref.invalidate(taskTodayStripProvider);
  ref.invalidate(taskBoardProvider);
  ref.invalidate(taskOverviewProvider);
  ref.invalidate(sidebarCountsProvider);
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
