import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/api/dto.dart';
import '../../../data/providers/bridge_provider.dart';
import '../logic/paged_query.dart';
import '../logic/task_logic.dart';

/// 任务列表窗口化 provider（P1 50k 规模档，docs/07 #105）。
///
/// 与 [todoTasksProvider] 的分工：
/// - **窗口通道**（本文件）：列表/表格/看板/矩阵/日历/Logbook 的渲染数据源，
///   每页 200 条按键集游标续拉；
/// - **全量通道**（[todoTasksProvider]）：周回顾/分诊/保存筛选器预览等确实
///   需要整份集合的流程，按需打开（不再被列表常驻 watch）。
///
/// db-change 失效链：`DbCacheTarget.tasks` 同时失效本文件全部 family——
/// 写操作后的真值收敛仍由事件驱动，窗口内不做乐观合并（有序分页下插入/
/// 删除会让游标边界与视觉顺序分叉）。

/// 窗口状态：已加载行 + 游标 + 续拉标志。
@immutable
class TaskWindowState {
  final List<TodoTask> items;

  /// 下一页游标；null = 已到尾部（或服务端未给）
  final ListCursor? nextCursor;
  final bool hasMore;

  /// 正在续拉下一页（UI 尾部 spinner）
  final bool loadingMore;

  /// 本次续拉失败（已加载窗口保留；下次滚动重试）
  final Object? error;

  const TaskWindowState({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    this.loadingMore = false,
    this.error,
  });

  TaskWindowState copyWith({
    List<TodoTask>? items,
    ListCursor? nextCursor,
    bool? hasMore,
    bool? loadingMore,
    Object? error,
    bool clearError = false,
  }) =>
      TaskWindowState(
        items: items ?? this.items,
        nextCursor: nextCursor ?? this.nextCursor,
        hasMore: hasMore ?? this.hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 单条窗口通道（family key = 分页查询规格）。
class TaskWindowNotifier extends AsyncNotifier<TaskWindowState> {
  TaskWindowNotifier(this.query);

  final PagedTaskQuery query;

  @override
  Future<TaskWindowState> build() async {
    final bridge = ref.watch(orbitBridgeProvider);
    final page = await bridge.todoTaskPage(
      query.filter,
      null,
      kTaskPageWindow,
    );
    return TaskWindowState(
      items: page.items,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
    );
  }

  /// 滚到底部预取下一页：并发守卫在 `hasMore/loadingMore` 上——
  /// Riverpod 每次读 `state.value` 是当前快照，滚动回调同帧多次触发
  /// 也只有第一次进入续拉分支。
  Future<void> loadMore() async {
    final cur = state.value;
    if (cur == null || !cur.hasMore || cur.loadingMore) return;
    final cursor = cur.nextCursor;
    if (cursor == null) return;
    state = AsyncData(cur.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await ref.read(orbitBridgeProvider).todoTaskPage(
            query.filter,
            cursor,
            kTaskPageWindow,
          );
      // 换档/失效后旧 state 可能已被替换：只追加到「仍以该游标为尾」的窗口
      final latest = state.value;
      if (latest == null) return;
      state = AsyncData(TaskWindowState(
        items: [...latest.items, ...page.items],
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
      ));
    } catch (e) {
      final latest = state.value;
      if (latest == null) return;
      state = AsyncData(latest.copyWith(loadingMore: false, error: e));
    }
  }
}

/// 列表/表格主窗口（family：每个筛选+排序组合一份，切视图换 key）。
///
/// autoDispose：切项目/切排序后旧窗口（200 行）随最后一个监听者退订释放，
/// 否则多项目来回切会把每个组合的窗口都留在内存里。
final taskWindowProvider = AsyncNotifierProvider.autoDispose
    .family<TaskWindowNotifier, TaskWindowState, PagedTaskQuery>(
        TaskWindowNotifier.new);

/// 当前窗口的可读快照（未就绪回空，避免 UI 到处 `?.value ?? []`）
final taskWindowItemsProvider =
    Provider.family<List<TodoTask>, PagedTaskQuery>((ref, query) {
  return ref.watch(taskWindowProvider(query)).value?.items ?? const [];
});

/// 主窗口总数（条幅「已加载 X / 共 Y」）：SQL COUNT 聚合，不拉行。
final taskWindowTotalProvider =
    FutureProvider.autoDispose.family<int, PagedTaskQuery>((ref, query) async {
  final overview =
      await ref.watch(orbitBridgeProvider).todoTaskOverview(query.filter);
  return overview.total;
});

/// 逾期置顶段（独立查询 + 主窗口按 id 去重）。
///
/// key 带 [nowMs]：每分钟换一格重取，既不会每帧重建，也不至于跨零点后
/// 一直用旧基准。逾期集天然有界（上限 200），重取成本恒定。
final taskOverdueProvider = FutureProvider.autoDispose
    .family<List<TodoTask>, ({PagedTaskQuery query, int nowMs})>(
        (ref, arg) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final page = await bridge.todoTaskPage(
    overdueFilterOf(arg.query, arg.nowMs),
    null,
    kOverduePageLimit,
  );
  return page.items;
});

/// 列表尾部「已完成」窗口（完成时刻倒序，卡内直显 20 条）。
final taskDoneCardProvider =
    FutureProvider.autoDispose.family<List<TodoTask>, PagedTaskQuery>(
        (ref, query) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final page = await bridge.todoTaskPage(
    doneCardFilterOf(query),
    null,
    kDoneCardLimit,
  );
  return page.items;
});

/// 「已完成 N」总数（卡头计数）：与窗口分页不共用，SQL 聚合单取。
final taskDoneTotalProvider =
    FutureProvider.autoDispose.family<int, PagedTaskQuery>((ref, query) async {
  final overview = await ref
      .watch(orbitBridgeProvider)
      .todoTaskOverview(doneCardFilterOf(query));
  return overview.total;
});

/// 今日上下文条数据源（窗口化后不再从主窗口推断）。
///
/// 合并两路有界查询：
/// - 今日截止的未完成任务（容量口径只看这部分）；
/// - 最近完成的 200 条（`done_at` 倒序取今日完成数——今天完成超过 200 条
///   才会少报，属可接受上界）。
/// 未完成任务排前，供 [todayLoadMinutes] 与今日完成计数共用一份列表。
final taskTodayStripProvider =
    FutureProvider.autoDispose.family<List<TodoTask>, int>((ref, nowMs) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final dayEnd = dayStart + 86400000;

  final results = await Future.wait([
    bridge.todoTaskPage(
      ListFilter(done: false, dueFrom: dayStart, dueTo: dayEnd),
      null,
      kOverduePageLimit,
    ),
    bridge.todoTaskPage(
      ListFilter(done: true, sortKey: 'done_at', sortDir: 'desc'),
      null,
      kOverduePageLimit,
    ),
  ]);
  final seen = <int>{};
  final merged = <TodoTask>[];
  for (final page in results) {
    for (final t in page.items) {
      if (seen.add(t.id)) merged.add(t);
    }
  }
  return merged;
});

/// 看板/四象限窗口（family：分组维度 + 查询规格 + 本地日界）。
///
/// `dayStart/dayEnd` 进 key：跨零点自动换一档重算 due 五分桶与「紧急」界。
@immutable
class BoardQuery {
  final PagedTaskQuery query;
  final TodoBoardGroupBy groupBy;
  final int dayStart;
  final int dayEnd;

  const BoardQuery({
    required this.query,
    required this.groupBy,
    required this.dayStart,
    required this.dayEnd,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BoardQuery &&
          query == other.query &&
          groupBy == other.groupBy &&
          dayStart == other.dayStart &&
          dayEnd == other.dayEnd;

  @override
  int get hashCode => Object.hash(query, groupBy, dayStart, dayEnd);
}

final taskBoardProvider = FutureProvider.autoDispose
    .family<TodoTaskBoardResult, BoardQuery>((ref, arg) async {
  final bridge = ref.watch(orbitBridgeProvider);
  return bridge.todoTaskBoard(
    arg.query.filter,
    arg.groupBy,
    kBoardPageLimit,
    arg.dayStart,
    arg.dayEnd,
  );
});

/// 任务总览（任意谓词）：侧栏计数/项目角标/条幅总数共用。
final taskOverviewProvider = FutureProvider.autoDispose
    .family<TodoTaskOverview, ListFilter>((ref, filter) async {
  return ref.watch(orbitBridgeProvider).todoTaskOverview(filter);
});

/// 侧栏计数（A5 收敛）：此前由万行全量数组单遍聚合，窗口化后改 SQL 聚合。
///
/// 7 次 COUNT 聚合并行（都走 `is_deleted` 基线索引），换取常驻内存里
/// 不再有一份万行任务数组。`undoneByProject` 取其中任意一次（接口口径为
/// 全局未完成，不受 filter 影响）。
final sidebarCountsProvider = FutureProvider<SidebarCounts>((ref) async {
  final bridge = ref.watch(orbitBridgeProvider);
  final now = DateTime.now();
  final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  final dayEnd = dayStart + 86400000;
  final weekEnd = dayEnd + 6 * 86400000;

  final counts = await Future.wait([
    bridge.todoTaskOverview(const ListFilter(done: false)),
    bridge.todoTaskOverview(const ListFilter(done: true)),
    bridge.todoTaskOverview(ListFilter(done: false, dueTo: dayEnd)),
    bridge.todoTaskOverview(ListFilter(done: false, dueTo: weekEnd)),
    bridge.todoTaskOverview(
        const ListFilter(done: false, favoriteOnly: true)),
    bridge.todoTaskOverview(ListFilter(done: false, myDayToday: dayStart)),
    bridge.todoTaskOverview(const ListFilter(done: false, hasDue: false)),
  ]);

  final all = counts[0].total;
  final byProject = <int, int>{
    for (final b in counts[0].undoneByProject)
      if (b.projectId != null) b.projectId!: b.count,
  };
  return SidebarCounts(
    quickView: {
      QuickViewKey.all: all,
      QuickViewKey.undone: all,
      QuickViewKey.done: counts[1].total,
      QuickViewKey.today: counts[2].total,
      QuickViewKey.week: counts[3].total,
      QuickViewKey.favorite: counts[4].total,
      QuickViewKey.myDay: counts[5].total,
      QuickViewKey.nodate: counts[6].total,
    },
    undoneByProject: byProject,
  );
});
