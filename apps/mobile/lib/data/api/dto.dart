import 'dart:convert';

/// 数据传输对象（DTO）
///
/// 与 crates/orbit-core serde 模型字段一一对应，snake_case 直传；
/// 自 apps/desktop/src/lib/tauri.ts 的 TS 接口镜像而来。
///
/// 时间戳约定：Unix 毫秒（Rust i64）。

// ---------- 通用列表过滤条件 ----------

class ListFilter {
  final String? keyword;
  final int page;
  final int pageSize;

  /// 完成态过滤：true = 仅已完成，false = 仅未完成，null = 不过滤
  final bool? done;

  /// 状态等值（pending/doing/done）
  final String? status;

  /// 优先级下限（priority >= 此值）
  final int? priorityMin;

  /// 优先级等值（工具栏单值档；与 [priorityMin] 不同语义）
  final int? priorityEq;

  /// 项目 id 等值
  final int? projectId;

  /// 项目 id **集合**（清单文件夹聚合）：非空时优先于 [projectId]；
  /// 空集合 = 空结果（不是不过滤）
  final List<int>? projectIds;

  /// 仅收藏
  final bool? favoriteOnly;

  /// 我的一天：仅 my_day_date = 今天本地零点（调用方算好传入）
  final int? myDayToday;

  /// 未分组视图：true = project_id IS NULL
  final bool? ungrouped;

  /// 排除早于此时刻的截止（保留无截止行）：逾期置顶段独立取走后，
  /// 主列表用它避免同一行渲染两次
  final int? excludeDueBefore;

  /// 是否有截止：false = due_date IS NULL（日历「未排期」区）
  final bool? hasDue;

  /// 排序键（P1 键集分页）：manual/due/priority/created/done_at；
  /// title 依赖 localeCompare 拼音序，SQL 复刻不了，该档走全量通道
  final String? sortKey;

  /// 排序方向 asc/desc；null = 各档默认方向
  final String? sortDir;

  /// 截止区间下界（毫秒，含）：日历按可见范围取数
  final int? dueFrom;

  /// 截止区间上界（毫秒，不含）
  final int? dueTo;

  /// 开始区间下界（毫秒，含）：日历时间轴按块起点取数
  final int? startFrom;

  /// 开始区间上界（毫秒，不含）
  final int? startTo;

  /// 标签集合（**任一命中**）：保存筛选器 `label_ids` 与列表内标签筛选共用
  /// 同一谓词。空集合 = 不过滤（条件里「没选标签」不等于清空列表）。
  final List<int>? labelIds;

  /// 有提醒：true = 至少一条活提醒行，false = 一条也没有
  final bool? hasReminder;

  /// 有附件（`todo_task_attachments` 活行）；语义同上
  final bool? hasAttachment;

  /// 有未完成子任务；语义同上
  final bool? hasOpenSubtask;

  /// 创建时间下界（毫秒，含）：保存筛选器 `created_from`
  final int? createdFrom;

  /// 完成时间下界（毫秒，含；隐含只看已完成）：保存筛选器 `done_from`
  final int? doneFrom;

  const ListFilter({
    this.keyword,
    this.page = 1,
    this.pageSize = 500,
    this.done,
    this.status,
    this.priorityMin,
    this.priorityEq,
    this.projectId,
    this.projectIds,
    this.favoriteOnly,
    this.myDayToday,
    this.ungrouped,
    this.excludeDueBefore,
    this.hasDue,
    this.sortKey,
    this.sortDir,
    this.dueFrom,
    this.dueTo,
    this.startFrom,
    this.startTo,
    this.labelIds,
    this.hasReminder,
    this.hasAttachment,
    this.hasOpenSubtask,
    this.createdFrom,
    this.doneFrom,
  });

  /// 复制并按需覆盖字段（未给出的字段原样保留）。
  ///
  /// [done] 例外：`done: null` 也是有效值（放开完成态过滤），故用
  /// [clearDone] 显式表达——逾期段「强制未完成」与主通道「放开完成态」
  /// 的差异只在这一位。
  ListFilter copyWith({
    bool? done,
    bool clearDone = false,
    int? page,
    int? pageSize,
    int? excludeDueBefore,
    int? dueFrom,
    int? dueTo,
    int? startFrom,
    int? startTo,
    String? sortKey,
    String? sortDir,
  }) => ListFilter(
    keyword: keyword,
    page: page ?? this.page,
    pageSize: pageSize ?? this.pageSize,
    done: clearDone ? null : (done ?? this.done),
    status: status,
    priorityMin: priorityMin,
    priorityEq: priorityEq,
    projectId: projectId,
    projectIds: projectIds,
    favoriteOnly: favoriteOnly,
    myDayToday: myDayToday,
    ungrouped: ungrouped,
    excludeDueBefore: excludeDueBefore ?? this.excludeDueBefore,
    hasDue: hasDue,
    sortKey: sortKey ?? this.sortKey,
    sortDir: sortDir ?? this.sortDir,
    dueFrom: dueFrom ?? this.dueFrom,
    dueTo: dueTo ?? this.dueTo,
    startFrom: startFrom ?? this.startFrom,
    startTo: startTo ?? this.startTo,
    // 保存筛选器谓词没有「就地改」的场景，原样透传防丢键
    labelIds: labelIds,
    hasReminder: hasReminder,
    hasAttachment: hasAttachment,
    hasOpenSubtask: hasOpenSubtask,
    createdFrom: createdFrom,
    doneFrom: doneFrom,
  );

  /// bridge 载荷（FRB/ipc 同名 snake_case）
  Map<String, dynamic> toJson() => {
    'keyword': keyword,
    'page': page,
    'page_size': pageSize,
    'done': done,
    'status': status,
    'priority_min': priorityMin,
    'priority_eq': priorityEq,
    'project_id': projectId,
    'project_ids': projectIds,
    'favorite_only': favoriteOnly,
    'my_day_today': myDayToday,
    'ungrouped': ungrouped,
    'exclude_due_before': excludeDueBefore,
    'has_due': hasDue,
    'sort_key': sortKey,
    'sort_dir': sortDir,
    'due_from': dueFrom,
    'due_to': dueTo,
    'start_from': startFrom,
    'start_to': startTo,
    'label_ids': labelIds,
    'has_reminder': hasReminder,
    'has_attachment': hasAttachment,
    'has_open_subtask': hasOpenSubtask,
    'created_from': createdFrom,
    'done_from': doneFrom,
  };

  static bool _sameIds(List<int>? a, List<int>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ListFilter &&
          keyword == other.keyword &&
          page == other.page &&
          pageSize == other.pageSize &&
          done == other.done &&
          status == other.status &&
          priorityMin == other.priorityMin &&
          priorityEq == other.priorityEq &&
          projectId == other.projectId &&
          _sameIds(projectIds, other.projectIds) &&
          favoriteOnly == other.favoriteOnly &&
          myDayToday == other.myDayToday &&
          ungrouped == other.ungrouped &&
          excludeDueBefore == other.excludeDueBefore &&
          hasDue == other.hasDue &&
          sortKey == other.sortKey &&
          sortDir == other.sortDir &&
          dueFrom == other.dueFrom &&
          dueTo == other.dueTo &&
          startFrom == other.startFrom &&
          startTo == other.startTo &&
          _sameIds(labelIds, other.labelIds) &&
          hasReminder == other.hasReminder &&
          hasAttachment == other.hasAttachment &&
          hasOpenSubtask == other.hasOpenSubtask &&
          createdFrom == other.createdFrom &&
          doneFrom == other.doneFrom;

  // 20 个字段已超出 Object.hash 的位参上限，改 hashAll（保序、支持任意长度）
  @override
  int get hashCode => Object.hashAll([
    keyword,
    page,
    pageSize,
    done,
    status,
    priorityMin,
    priorityEq,
    projectId,
    projectIds == null ? null : Object.hashAll(projectIds!),
    favoriteOnly,
    myDayToday,
    ungrouped,
    excludeDueBefore,
    hasDue,
    sortKey,
    sortDir,
    dueFrom,
    dueTo,
    startFrom,
    startTo,
    labelIds == null ? null : Object.hashAll(labelIds!),
    hasReminder,
    hasAttachment,
    hasOpenSubtask,
    createdFrom,
    doneFrom,
  ]);
}

/// 键集分页游标（镜像 Rust ListCursor）
class ListCursor {
  final String sortKey;
  final String dir;

  /// 主排序键值（position/priority/createdAt/dueDate）；due 档 null = 无截止尾段
  final double? key;

  /// 次排序键（仅 priority 档：同优先级按 position 升序）
  final double? key2;
  final int id;

  const ListCursor({
    required this.sortKey,
    required this.dir,
    required this.key,
    required this.key2,
    required this.id,
  });
}

/// 任务分页结果（镜像 Rust TodoTaskPage）
class TodoTaskPage {
  final List<TodoTask> items;
  final ListCursor? nextCursor;
  final bool hasMore;

  const TodoTaskPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });
}

/// 单个项目的未完成计数
class TodoProjectUndone {
  final int? projectId;
  final int count;

  const TodoProjectUndone({required this.projectId, required this.count});
}

/// 任务总览（镜像 Rust TodoTaskOverview）
class TodoTaskOverview {
  final int total;
  final List<TodoProjectUndone> undoneByProject;

  const TodoTaskOverview({required this.total, required this.undoneByProject});
}

/// 看板/四象限分组维度（镜像 Rust `BoardGroupBy`）。
///
/// 标签档没有对应项：列定义随任务标签动态变化，窗口内的标签会让空列消失，
/// 故标签档仍走全量通道（与桌面 `boardGroupBy` 判定同口径）。
enum TodoBoardGroupBy { project, status, priority, due, quadrant }

/// 看板单列（镜像 Rust TodoTaskBoardGroup）
class TodoTaskBoardGroup {
  /// 组键（与 core `board_group_expr` 逐字一致：项目 = `{id}`/`ungrouped`、
  /// 优先级 = `pri:{n}`、截止 = `due:{bucket}`、四象限 = `{quadrant}`）
  final String key;

  /// 组总数（不受每列上限影响）
  final int total;
  final List<TodoTask> items;

  const TodoTaskBoardGroup({
    required this.key,
    required this.total,
    required this.items,
  });
}

/// 看板/四象限窗口结果（镜像 Rust TodoTaskBoard）
class TodoTaskBoardResult {
  final List<TodoTaskBoardGroup> groups;
  final int total;

  const TodoTaskBoardResult({required this.groups, required this.total});
}

/// 更新载荷构建约定（对齐 Rust `Option<Option<T>>` 三态语义）：
/// ```dart
/// final patch = <String, Object?>{
///   'title': '新标题',   // 更新该字段
///   'due_date': null,    // 清空该字段（显式 null）
///   // 不写键           // 跳过该字段
/// };
/// await bridge.todoTaskUpdate(id, encodePatch(patch));
/// ```
String encodePatch(Map<String, Object?> patch) => jsonEncode(patch);

// ---------- todo_projects ----------

class TodoProject {
  final int id;
  final String uuid;
  final String title;
  final String? description;
  final String hexColor;
  final double sortOrder;

  /// M8 上级文件夹（父项目）的同步主键 uuid；null = 顶层
  final String? parentUuid;

  /// F1 回顾周期（天）；null/0 = 关闭（7=每周 14=每两周 30=每月）
  final int? reviewIntervalDays;

  /// 上次回顾时间（毫秒）；null = 从未回顾
  final int? reviewLastAt;

  /// 回顾暂缓截止（毫秒，本地零点口径）；null = 未暂缓
  final int? reviewSnoozeUntil;

  /// 项目归档标记：0 活跃 1 已归档（默认列表排除，侧栏归档区）
  final int isArchived;
  final int isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final int version;

  const TodoProject({
    required this.id,
    required this.uuid,
    required this.title,
    required this.description,
    required this.hexColor,
    required this.sortOrder,
    required this.parentUuid,
    this.reviewIntervalDays,
    this.reviewLastAt,
    this.reviewSnoozeUntil,
    required this.isArchived,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
  });

  factory TodoProject.fromJson(Map<String, dynamic> j) => TodoProject(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    title: j['title'] as String,
    description: j['description'] as String?,
    hexColor: j['hex_color'] as String,
    sortOrder: (j['sort_order'] as num).toDouble(),
    parentUuid: normalizeParentUuid(j['parent_uuid'] as String?),
    reviewIntervalDays: (j['review_interval_days'] as num?)?.toInt(),
    reviewLastAt: (j['review_last_at'] as num?)?.toInt(),
    reviewSnoozeUntil: (j['review_snooze_until'] as num?)?.toInt(),
    isArchived: (j['is_archived'] as int?) ?? 0,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
  );
}

/// F1 回顾状态行（core project_review_api::ProjectReviewStatus 的 Dart 镜像）
class ProjectReviewStatus {
  final TodoProject project;

  /// 到期日序号（days since epoch，本地时区日界）
  final int dueDayIndex;

  /// 已逾期天数（0 = 今天到期）
  final int overdueDays;

  /// 项目内未完成且未软删的任务数
  final int openTaskCount;

  const ProjectReviewStatus({
    required this.project,
    required this.dueDayIndex,
    required this.overdueDays,
    required this.openTaskCount,
  });
}

// ---------- F3 日排程（阶段一只读预览，ADR 0013） ----------

/// 排程偏好（相对今天零点的分钟；阶段一双端传默认值）
class DayPlanPrefs {
  final int workStartMinute;
  final int workEndMinute;
  final int lunchStartMinute;
  final int lunchEndMinute;
  final int granularityMinutes;
  final int defaultTaskMinutes;
  final bool includeOverdue;

  const DayPlanPrefs({
    required this.workStartMinute,
    required this.workEndMinute,
    required this.lunchStartMinute,
    required this.lunchEndMinute,
    required this.granularityMinutes,
    required this.defaultTaskMinutes,
    required this.includeOverdue,
  });

  /// 默认作息：09:00-18:00，午休 12:00-13:00，15 分钟粒度，无时长兜底 30 分钟
  static const DayPlanPrefs defaults = DayPlanPrefs(
    workStartMinute: 9 * 60,
    workEndMinute: 18 * 60,
    lunchStartMinute: 12 * 60,
    lunchEndMinute: 13 * 60,
    granularityMinutes: 15,
    defaultTaskMinutes: 30,
    includeOverdue: true,
  );
}

/// 单个排程建议（时段 + 任务 + 可解释理由）
class PlanSlot {
  final int taskId;
  final String title;
  final int startMs;
  final int endMs;
  final int durationMinutes;
  final String reason;

  const PlanSlot({
    required this.taskId,
    required this.title,
    required this.startMs,
    required this.endMs,
    required this.durationMinutes,
    required this.reason,
  });
}

/// 未排入任务与原因
class UnscheduledTask {
  final int taskId;
  final String title;
  final String reason;

  const UnscheduledTask({
    required this.taskId,
    required this.title,
    required this.reason,
  });
}

/// 应用输入单条（预览结果中勾选的槽位）
class ApplySlotInput {
  final int taskId;
  final int startMs;

  const ApplySlotInput({required this.taskId, required this.startMs});
}

/// 单行应用结果（撤销快照：prev 值经既有更新通道写回）
class AppliedRow {
  final int taskId;
  final int? prevStartDate;
  final int? prevMyDayDate;

  const AppliedRow({
    required this.taskId,
    required this.prevStartDate,
    required this.prevMyDayDate,
  });
}

/// 应用结果
class ApplyResult {
  final List<AppliedRow> applied;

  const ApplyResult({required this.applied});
}

/// 日排程预览（只读）
class DayPlan {
  final List<PlanSlot> slots;
  final List<UnscheduledTask> unscheduled;

  /// 今天剩余可排容量（分钟，已扣午休与已过时段）
  final int capacityMinutes;

  /// 候选任务总时长（分钟）
  final int loadMinutes;
  final bool overloaded;
  final int dayStartMs;

  const DayPlan({
    required this.slots,
    required this.unscheduled,
    required this.capacityMinutes,
    required this.loadMinutes,
    required this.overloaded,
    required this.dayStartMs,
  });
}

/// 空白串归一为 null（M8 上级文件夹口径，与 core `normalize_parent_uuid` 一致）：
/// 表单清空上级可能提交 "" 而非 null，两侧树构建只认 null 为顶层
String? normalizeParentUuid(String? raw) {
  final trimmed = raw?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

class TodoProjectCreateInput {
  final String title;
  final String? description;
  final String? hexColor;
  final double? sortOrder;

  /// M8 上级文件夹 uuid；null / 空白串 = 顶层
  final String? parentUuid;

  const TodoProjectCreateInput({
    required this.title,
    this.description,
    this.hexColor,
    this.sortOrder,
    this.parentUuid,
  });
}

// ---------- todo_tasks ----------

class TodoTask {
  final int id;
  final String uuid;
  final String title;
  final String? description;
  final int? projectId;
  final int priority;
  final String status;
  final int done;
  final int? doneAt;
  final int? dueDate;
  final int? startDate;
  final int repeatAfter;
  final int repeatMode;

  /// #34 重复规则扩展：星期几位掩码 bit0=周一…bit6=周日（仅周档生效）
  final int repeatWeekdays;

  /// 结束条件 0=永不 1=按日期 2=按次数
  final int repeatEndType;

  /// 结束参数：日期型=结束日 ms / 次数型=剩余次数
  final int repeatEndParam;

  /// when done：0=锚定原 due 推进 1=按完成日推进
  final int repeatFromDone;

  /// 月重复模式（#72）：0=按日号 1=按第N个星期X（仅 MONTHLY 生效）
  final int repeatMonthMode;

  /// 月内第几个星期（#72）：1-5/6=末，0=未指定回落日号
  final int repeatNthWeek;
  final double percentDone;
  final double position;
  final int isFavorite;

  /// 我的一天：加入当天本地零点 ms；null = 不在任何一天的 My Day
  final int? myDayDate;

  /// 任务预计时长（分钟，M9 阶段一）；null = 未设置
  final int? durationMinutes;
  final int isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final int version;

  const TodoTask({
    required this.id,
    required this.uuid,
    required this.title,
    required this.description,
    required this.projectId,
    required this.priority,
    required this.status,
    required this.done,
    required this.doneAt,
    required this.dueDate,
    required this.startDate,
    required this.repeatAfter,
    required this.repeatMode,
    required this.repeatWeekdays,
    required this.repeatEndType,
    required this.repeatEndParam,
    required this.repeatFromDone,
    required this.repeatMonthMode,
    required this.repeatNthWeek,
    required this.percentDone,
    required this.position,
    required this.isFavorite,
    required this.myDayDate,
    required this.durationMinutes,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
  });

  /// 就地字段覆盖（分诊页快照队列的本地更新用；可空字段配 clear* 旗标——
  /// Dart 无法区分「没传」与「传 null」，与 BackupPrefs.copyWith 同款惯例）
  TodoTask copyWith({
    int? projectId,
    bool clearProjectId = false,
    int? priority,
    int? dueDate,
    bool clearDueDate = false,
  }) => TodoTask(
    id: id,
    uuid: uuid,
    title: title,
    description: description,
    projectId: clearProjectId ? null : (projectId ?? this.projectId),
    priority: priority ?? this.priority,
    status: status,
    done: done,
    doneAt: doneAt,
    dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
    startDate: startDate,
    repeatAfter: repeatAfter,
    repeatMode: repeatMode,
    repeatWeekdays: repeatWeekdays,
    repeatEndType: repeatEndType,
    repeatEndParam: repeatEndParam,
    repeatFromDone: repeatFromDone,
    repeatMonthMode: repeatMonthMode,
    repeatNthWeek: repeatNthWeek,
    percentDone: percentDone,
    position: position,
    isFavorite: isFavorite,
    myDayDate: myDayDate,
    durationMinutes: durationMinutes,
    isDeleted: isDeleted,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    version: version,
  );

  factory TodoTask.fromJson(Map<String, dynamic> j) => TodoTask(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    title: j['title'] as String,
    description: j['description'] as String?,
    projectId: j['project_id'] as int?,
    priority: j['priority'] as int,
    status: j['status'] as String,
    done: j['done'] as int,
    doneAt: j['done_at'] as int?,
    dueDate: j['due_date'] as int?,
    startDate: j['start_date'] as int?,
    repeatAfter: j['repeat_after'] as int,
    repeatMode: j['repeat_mode'] as int,
    repeatWeekdays: (j['repeat_weekdays'] as int?) ?? 0,
    repeatEndType: (j['repeat_end_type'] as int?) ?? 0,
    repeatEndParam: (j['repeat_end_param'] as int?) ?? 0,
    repeatFromDone: (j['repeat_from_done'] as int?) ?? 0,
    repeatMonthMode: (j['repeat_month_mode'] as int?) ?? 0,
    repeatNthWeek: (j['repeat_nth_week'] as int?) ?? 0,
    percentDone: (j['percent_done'] as num).toDouble(),
    position: (j['position'] as num).toDouble(),
    isFavorite: j['is_favorite'] as int,
    myDayDate: j['my_day_date'] as int?,
    durationMinutes: j['duration_minutes'] as int?,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
  );

  /// 列表通道瘦行构造（内存治理 A2）：core 的 `TodoTaskListItem` 不含 10 列
  /// （uuid / repeat_after / 六个更细的 repeat_* / deleted_at / version），
  /// App 模型（详情/表单/重复编辑页共用）保留字段并在此统一回落默认值。
  ///
  /// **列表视图对这 10 个字段零消费**（清单与核实结论见 core 侧
  /// `TodoTaskListItem` 文档与 docs/09 §4.3）；新增列表消费点前必须重新核实，
  /// 需要这些列时改走 `todoTaskGet` / `todoTaskGetDetail`（单行全列路径）。
  const TodoTask.listRow({
    required this.id,
    required this.title,
    this.description,
    this.projectId,
    required this.priority,
    required this.status,
    required this.done,
    this.doneAt,
    this.dueDate,
    this.startDate,
    required this.repeatMode,
    required this.percentDone,
    required this.position,
    required this.isFavorite,
    this.myDayDate,
    this.durationMinutes,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
  }) : uuid = '',
       repeatAfter = 0,
       repeatWeekdays = 0,
       repeatEndType = 0,
       repeatEndParam = 0,
       repeatFromDone = 0,
       repeatMonthMode = 0,
       repeatNthWeek = 0,
       deletedAt = null,
       version = 0;

  /// 列表通道 JSON → App 模型（mock 桥用；真桥走 `_mapTaskRow` 直映 FRB DTO）。
  /// 读的键与 `TodoTaskListItem` 一致，被裁 10 列**不读**（回落默认值）。
  factory TodoTask.fromListJson(Map<String, dynamic> j) => TodoTask.listRow(
    id: j['id'] as int,
    title: j['title'] as String,
    description: j['description'] as String?,
    projectId: j['project_id'] as int?,
    priority: j['priority'] as int,
    status: j['status'] as String,
    done: j['done'] as int,
    doneAt: j['done_at'] as int?,
    dueDate: j['due_date'] as int?,
    startDate: j['start_date'] as int?,
    repeatMode: j['repeat_mode'] as int,
    percentDone: (j['percent_done'] as num).toDouble(),
    position: (j['position'] as num).toDouble(),
    isFavorite: j['is_favorite'] as int,
    myDayDate: j['my_day_date'] as int?,
    durationMinutes: j['duration_minutes'] as int?,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
  );

  /// 任务是否已完成（done=1）
  bool get isDone => done == 1;

  /// 是否收藏/星标
  bool get isStarred => isFavorite == 1;

  /// 是否在今天加入的「我的一天」（按日判断；昨天加入自动退出，微软 To Do 同款）
  bool get isInMyDay {
    final raw = myDayDate;
    if (raw == null) return false;
    final today = DateTime.now();
    final zero = DateTime(
      today.year,
      today.month,
      today.day,
    ).millisecondsSinceEpoch;
    return raw == zero;
  }
}

class TodoTaskCreateInput {
  final String title;
  final String? description;
  final int? projectId;
  final int? priority;
  final String? status;
  final int? done;
  final int? doneAt;
  final int? dueDate;
  final int? startDate;
  final int? repeatAfter;
  final int? repeatMode;
  final int? repeatWeekdays;
  final int? repeatEndType;
  final int? repeatEndParam;
  final int? repeatFromDone;
  final int? repeatMonthMode;
  final int? repeatNthWeek;
  final double? position;
  final int? isFavorite;
  final int? myDayDate;

  /// 预计时长（分钟）；null = 不设置
  final int? durationMinutes;

  const TodoTaskCreateInput({
    required this.title,
    this.description,
    this.projectId,
    this.priority,
    this.status,
    this.done,
    this.doneAt,
    this.dueDate,
    this.startDate,
    this.repeatAfter,
    this.repeatMode,
    this.repeatWeekdays,
    this.repeatEndType,
    this.repeatEndParam,
    this.repeatFromDone,
    this.repeatMonthMode,
    this.repeatNthWeek,
    this.position,
    this.isFavorite,
    this.myDayDate,
    this.durationMinutes,
  });
}

/// 统一完成命令结果（镜像 Rust CompleteTaskResult，与桌面 CompleteTaskResult 同构）：
/// [nextInstance] 为重复任务推进生成的下一实例（普通任务为 null）——
/// UI 层用它做「已生成下一期」提示。
class CompleteTaskResult {
  final TodoTask task;
  final TodoTask? nextInstance;

  const CompleteTaskResult({required this.task, this.nextInstance});
}

// ---------- todo_subtasks ----------

class TodoSubtask {
  final int id;
  final String uuid;
  final int taskId;
  final String title;
  final int done;
  final int? doneAt;
  final double position;

  /// 上级子任务（父）uuid；null = 顶层（M10 多层嵌套，同任务内）
  final String? parentUuid;
  final int isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final int version;

  const TodoSubtask({
    required this.id,
    required this.uuid,
    required this.taskId,
    required this.title,
    required this.done,
    required this.doneAt,
    required this.position,
    this.parentUuid,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
  });

  factory TodoSubtask.fromJson(Map<String, dynamic> j) => TodoSubtask(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    taskId: j['task_id'] as int,
    title: j['title'] as String,
    done: j['done'] as int,
    doneAt: j['done_at'] as int?,
    position: (j['position'] as num).toDouble(),
    parentUuid: j['parent_uuid'] as String?,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
  );

  bool get isDone => done == 1;
}

class TodoSubtaskCreateInput {
  final int taskId;
  final String title;
  final double? position;

  /// 挂到哪个子任务下（父的 uuid）；null = 顶层。须与 taskId 同任务
  final String? parentUuid;

  const TodoSubtaskCreateInput({
    required this.taskId,
    required this.title,
    this.position,
    this.parentUuid,
  });
}

// ---------- todo_labels ----------

class TodoLabel {
  final int id;
  final String uuid;
  final String title;
  final String hexColor;
  final int isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final int version;

  const TodoLabel({
    required this.id,
    required this.uuid,
    required this.title,
    required this.hexColor,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
  });

  factory TodoLabel.fromJson(Map<String, dynamic> j) => TodoLabel(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    title: j['title'] as String,
    hexColor: j['hex_color'] as String,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
  );
}

class TodoLabelCreateInput {
  final String title;
  final String? hexColor;

  const TodoLabelCreateInput({required this.title, this.hexColor});
}

/// 详情聚合中的标签（携带关联表主键）
class TaskLabelWithId extends TodoLabel {
  final int taskLabelId;

  const TaskLabelWithId({
    required super.id,
    required super.uuid,
    required super.title,
    required super.hexColor,
    required super.isDeleted,
    required super.createdAt,
    required super.updatedAt,
    required super.deletedAt,
    required super.version,
    required this.taskLabelId,
  });

  factory TaskLabelWithId.fromJson(Map<String, dynamic> j) => TaskLabelWithId(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    title: j['title'] as String,
    hexColor: j['hex_color'] as String,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
    taskLabelId: j['task_label_id'] as int,
  );
}

// ---------- todo_task_labels ----------

class TodoTaskLabelCreateInput {
  final int taskId;
  final int labelId;

  const TodoTaskLabelCreateInput({required this.taskId, required this.labelId});
}

// ---------- todo_comments ----------

class TodoComment {
  final int id;
  final String uuid;
  final int taskId;
  final String content;
  final int isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final int version;

  const TodoComment({
    required this.id,
    required this.uuid,
    required this.taskId,
    required this.content,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
  });

  factory TodoComment.fromJson(Map<String, dynamic> j) => TodoComment(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    taskId: j['task_id'] as int,
    content: j['content'] as String,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
  );
}

class TodoCommentCreateInput {
  final int taskId;
  final String content;

  const TodoCommentCreateInput({required this.taskId, required this.content});
}

// ---------- todo_task_relations ----------

class TodoTaskRelation {
  final int id;
  final String uuid;
  final int taskId;
  final int otherTaskId;
  final String relationType;
  final int isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final int version;

  const TodoTaskRelation({
    required this.id,
    required this.uuid,
    required this.taskId,
    required this.otherTaskId,
    required this.relationType,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
  });

  factory TodoTaskRelation.fromJson(Map<String, dynamic> j) => TodoTaskRelation(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    taskId: j['task_id'] as int,
    otherTaskId: j['other_task_id'] as int,
    relationType: j['relation_type'] as String,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
  );
}

class TodoTaskRelationCreateInput {
  final int taskId;
  final int otherTaskId;
  final String relationType;

  const TodoTaskRelationCreateInput({
    required this.taskId,
    required this.otherTaskId,
    required this.relationType,
  });
}

// ---------- todo_reminders ----------

class TodoReminder {
  final int id;
  final String uuid;
  final int taskId;
  final int remindAt;

  /// 持续提醒标记（G2）：1 = 未完成则按 5 分钟间隔顺延重排（响到完成为止）
  final int isConstant;
  final int isDeleted;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final int version;

  /// 关联任务标题（P2 提醒升级：系统闹钟通知正文用）。
  /// Rust todo_reminders_list 不含任务列——由桥层消费方 join 任务表
  /// 填充；直取列表时为 null（通知正文回退应用名）。
  final String? reminderTitle;

  const TodoReminder({
    required this.id,
    required this.uuid,
    required this.taskId,
    required this.remindAt,
    required this.isConstant,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
    this.reminderTitle,
  });

  /// 是否持续提醒（响到完成为止）
  bool get constant => isConstant == 1;

  factory TodoReminder.fromJson(Map<String, dynamic> j) => TodoReminder(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    taskId: j['task_id'] as int,
    remindAt: j['remind_at'] as int,
    isConstant: (j['is_constant'] as int?) ?? 0,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
    reminderTitle: j['reminder_title'] as String?,
  );

  /// 携带任务标题的副本（join 后填充用）
  TodoReminder withTitle(String? title) => TodoReminder(
    id: id,
    uuid: uuid,
    taskId: taskId,
    remindAt: remindAt,
    isConstant: isConstant,
    isDeleted: isDeleted,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    version: version,
    reminderTitle: title,
  );
}

class TodoReminderCreateInput {
  final int taskId;
  final int remindAt;

  /// 持续提醒标记（G2）；默认 0 = 一次性
  final int isConstant;

  const TodoReminderCreateInput({
    required this.taskId,
    required this.remindAt,
    this.isConstant = 0,
  });
}

// ---------- 任务列表投影聚合（A4，只读：FRB todo.rs 三投影的手写镜像） ----------

/// 行内标签 chip 最小载荷（core ProjectedTaskLabel 镜像：展示三列）
class ProjectedTaskLabel {
  final int id;
  final String title;
  final String hexColor;

  const ProjectedTaskLabel({
    required this.id,
    required this.title,
    required this.hexColor,
  });

  factory ProjectedTaskLabel.fromJson(Map<String, dynamic> j) =>
      ProjectedTaskLabel(
        id: j['id'] as int,
        title: j['title'] as String,
        hexColor: j['hex_color'] as String,
      );
}

/// 单任务的标签分组（组内按 label id 升序）
class TaskLabelsProjection {
  final int taskId;
  final List<ProjectedTaskLabel> labels;

  const TaskLabelsProjection({required this.taskId, required this.labels});

  factory TaskLabelsProjection.fromJson(Map<String, dynamic> j) =>
      TaskLabelsProjection(
        taskId: j['task_id'] as int,
        labels: (j['labels'] as List)
            .map((e) => ProjectedTaskLabel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 行内提醒最小载荷（core ProjectedReminder 镜像）
class ProjectedReminder {
  final int id;
  final int remindAt;

  const ProjectedReminder({required this.id, required this.remindAt});

  factory ProjectedReminder.fromJson(Map<String, dynamic> j) =>
      ProjectedReminder(id: j['id'] as int, remindAt: j['remind_at'] as int);
}

/// 单任务的提醒分组（组内按 remind_at 升序）
class TaskRemindersProjection {
  final int taskId;
  final List<ProjectedReminder> reminders;

  const TaskRemindersProjection({
    required this.taskId,
    required this.reminders,
  });

  factory TaskRemindersProjection.fromJson(Map<String, dynamic> j) =>
      TaskRemindersProjection(
        taskId: j['task_id'] as int,
        reminders: (j['reminders'] as List)
            .map((e) => ProjectedReminder.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 单任务的关联计数旗标（core TaskDependencyFlags 镜像；C7 行内关联徽标消费）
class TaskDependencyFlags {
  final int taskId;

  /// 出边存活行总数（> 0 即「有关联」）
  final int relationCount;

  const TaskDependencyFlags({
    required this.taskId,
    required this.relationCount,
  });

  factory TaskDependencyFlags.fromJson(Map<String, dynamic> j) =>
      TaskDependencyFlags(
        taskId: j['task_id'] as int,
        relationCount: j['relation_count'] as int,
      );
}

/// 「有描述」任务 id 位（列表通道裁剪 description 后行内描述图标的来源；
/// 只出有描述的行，无描述任务缺位即 false）
class TaskDescriptionFlag {
  final int taskId;

  const TaskDescriptionFlag({required this.taskId});

  factory TaskDescriptionFlag.fromJson(Map<String, dynamic> j) =>
      TaskDescriptionFlag(taskId: j['task_id'] as int);
}

/// 任务存在旗标一位（#71 筛选器存在键数据源；只出有行的任务，缺位即 false；
/// 附件 / 未完成子任务两投影共用同一形状）
class TaskExistenceFlag {
  final int taskId;

  const TaskExistenceFlag({required this.taskId});

  factory TaskExistenceFlag.fromJson(Map<String, dynamic> j) =>
      TaskExistenceFlag(taskId: j['task_id'] as int);
}

// ---------- 复杂查询：任务详情聚合 ----------

class TodoTaskDetail extends TodoTask {
  final List<TodoSubtask> subtasks;
  final List<TaskLabelWithId> labels;
  final List<TodoComment> comments;
  final List<TodoTaskRelation> relations;
  final List<TodoReminder> reminders;

  const TodoTaskDetail({
    required super.id,
    required super.uuid,
    required super.title,
    required super.description,
    required super.projectId,
    required super.priority,
    required super.status,
    required super.done,
    required super.doneAt,
    required super.dueDate,
    required super.startDate,
    required super.repeatAfter,
    required super.repeatMode,
    required super.repeatWeekdays,
    required super.repeatEndType,
    required super.repeatEndParam,
    required super.repeatFromDone,
    required super.repeatMonthMode,
    required super.repeatNthWeek,
    required super.percentDone,
    required super.position,
    required super.isFavorite,
    required super.myDayDate,
    required super.durationMinutes,
    required super.isDeleted,
    required super.createdAt,
    required super.updatedAt,
    required super.deletedAt,
    required super.version,
    required this.subtasks,
    required this.labels,
    required this.comments,
    required this.relations,
    required this.reminders,
  });

  factory TodoTaskDetail.fromJson(Map<String, dynamic> j) => TodoTaskDetail(
    id: j['id'] as int,
    uuid: j['uuid'] as String,
    title: j['title'] as String,
    description: j['description'] as String?,
    projectId: j['project_id'] as int?,
    priority: j['priority'] as int,
    status: j['status'] as String,
    done: j['done'] as int,
    doneAt: j['done_at'] as int?,
    dueDate: j['due_date'] as int?,
    startDate: j['start_date'] as int?,
    repeatAfter: j['repeat_after'] as int,
    repeatMode: j['repeat_mode'] as int,
    repeatWeekdays: (j['repeat_weekdays'] as int?) ?? 0,
    repeatEndType: (j['repeat_end_type'] as int?) ?? 0,
    repeatEndParam: (j['repeat_end_param'] as int?) ?? 0,
    repeatFromDone: (j['repeat_from_done'] as int?) ?? 0,
    repeatMonthMode: (j['repeat_month_mode'] as int?) ?? 0,
    repeatNthWeek: (j['repeat_nth_week'] as int?) ?? 0,
    percentDone: (j['percent_done'] as num).toDouble(),
    position: (j['position'] as num).toDouble(),
    isFavorite: j['is_favorite'] as int,
    myDayDate: j['my_day_date'] as int?,
    durationMinutes: j['duration_minutes'] as int?,
    isDeleted: j['is_deleted'] as int,
    createdAt: j['created_at'] as int,
    updatedAt: j['updated_at'] as int,
    deletedAt: j['deleted_at'] as int?,
    version: j['version'] as int,
    subtasks: (j['subtasks'] as List)
        .map((e) => TodoSubtask.fromJson(e as Map<String, dynamic>))
        .toList(),
    labels: (j['labels'] as List)
        .map((e) => TaskLabelWithId.fromJson(e as Map<String, dynamic>))
        .toList(),
    comments: (j['comments'] as List)
        .map((e) => TodoComment.fromJson(e as Map<String, dynamic>))
        .toList(),
    relations: (j['relations'] as List)
        .map((e) => TodoTaskRelation.fromJson(e as Map<String, dynamic>))
        .toList(),
    reminders: (j['reminders'] as List)
        .map((e) => TodoReminder.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

// ---------- 同步域 ----------

class SyncCryptoStatus {
  final bool hasPassword;
  final bool isUnlocked;

  const SyncCryptoStatus({required this.hasPassword, required this.isUnlocked});

  factory SyncCryptoStatus.fromJson(Map<String, dynamic> j) => SyncCryptoStatus(
    hasPassword: j['has_password'] as bool,
    isUnlocked: j['is_unlocked'] as bool,
  );
}

/// crypto bundle（SyncCryptoMeta，全 Base64 字段）
class SyncCryptoBundle {
  final String salt;
  final String encryptedDataKey;
  final String dataKeyNonce;
  final int iterations;

  const SyncCryptoBundle({
    required this.salt,
    required this.encryptedDataKey,
    required this.dataKeyNonce,
    required this.iterations,
  });

  Map<String, dynamic> toJson() => {
    'salt': salt,
    'encrypted_data_key': encryptedDataKey,
    'data_key_nonce': dataKeyNonce,
    'iterations': iterations,
  };

  factory SyncCryptoBundle.fromJson(Map<String, dynamic> j) => SyncCryptoBundle(
    salt: j['salt'] as String,
    encryptedDataKey: j['encrypted_data_key'] as String,
    dataKeyNonce: j['data_key_nonce'] as String,
    iterations: j['iterations'] as int,
  );
}

typedef SyncEngineKind = String; // "webdav" | "s3"

class SyncConfigView {
  final int id;
  final String engine;
  final String endpoint;
  final String bucket;
  final String region;
  final String username;
  final bool passwordSet;
  final String basePath;
  final int intervalMinutes;
  final bool autoSyncEnabled;
  final bool syncOnChange;
  final bool skipTlsVerify;
  final int timeoutSeconds;

  /// F80：仅提示已设置（令牌本身打码不下发）
  final bool sessionTokenSet;
  final int? lastSyncedAt;

  const SyncConfigView({
    required this.id,
    required this.engine,
    required this.endpoint,
    required this.bucket,
    required this.region,
    required this.username,
    required this.passwordSet,
    required this.basePath,
    required this.intervalMinutes,
    required this.autoSyncEnabled,
    required this.syncOnChange,
    required this.skipTlsVerify,
    required this.timeoutSeconds,
    this.sessionTokenSet = false,
    required this.lastSyncedAt,
  });

  factory SyncConfigView.fromJson(Map<String, dynamic> j) => SyncConfigView(
    id: j['id'] as int,
    engine: j['engine'] as String,
    endpoint: j['endpoint'] as String,
    bucket: j['bucket'] as String,
    region: j['region'] as String,
    username: j['username'] as String,
    passwordSet: j['password_set'] as bool,
    basePath: j['base_path'] as String,
    intervalMinutes: j['interval_minutes'] as int,
    autoSyncEnabled: j['auto_sync_enabled'] as bool,
    syncOnChange: j['sync_on_change'] as bool,
    skipTlsVerify: j['skip_tls_verify'] as bool,
    timeoutSeconds: j['timeout_seconds'] as int,
    sessionTokenSet: (j['session_token_set'] as bool?) ?? false,
    lastSyncedAt: j['last_synced_at'] as int?,
  );
}

/// 云同步执行结果（Rust result_to_json 序列化）
class SyncResultJson {
  final int pushedModules;
  final int pulledModules;
  final int uploadedAttachments;
  final int downloadedAttachments;
  final int durationMs;
  final bool skipped;
  final List<String> errors;

  /// S28：冲突裁决数（merge LWW/复活裁决计数透传，多设备并发编辑的可见度）。
  /// F77：补声明——core 一直下发，此前两端壳都未解析；旧引擎/ mock 缺失时为 0。
  final int conflicts;

  /// 本轮 pull 真正写入的表集合（F42：按表精确失效缓存的依据；
  /// 旧引擎/ mock 不提供时为空 → 调用方回退 pulledModules 判据）
  final List<String> changedTables;

  const SyncResultJson({
    required this.pushedModules,
    required this.pulledModules,
    required this.uploadedAttachments,
    required this.downloadedAttachments,
    required this.durationMs,
    required this.skipped,
    required this.errors,
    this.conflicts = 0,
    this.changedTables = const [],
  });

  factory SyncResultJson.fromJson(Map<String, dynamic> j) => SyncResultJson(
    pushedModules: j['pushed_modules'] as int,
    pulledModules: j['pulled_modules'] as int,
    uploadedAttachments: j['uploaded_attachments'] as int,
    downloadedAttachments: j['downloaded_attachments'] as int,
    durationMs: j['duration_ms'] as int,
    skipped: j['skipped'] as bool,
    errors: (j['errors'] as List).cast<String>(),
    conflicts: (j['conflicts'] as num?)?.toInt() ?? 0,
    changedTables: (j['changed_tables'] as List?)?.cast<String>() ?? const [],
  );
}

// ---------- 节假日（cfg_holidays 缓存；用户需求：日历视图联网更新节假日） ----------

/// 节假日行（date YYYY-MM-DD + 放假/补班标记 + 名称）
class HolidayInfo {
  final String date;
  final int year;

  /// true = 放假日；false = 调休补班日（要上班的周末）
  final bool isHoliday;
  final String name;

  const HolidayInfo({
    required this.date,
    required this.year,
    required this.isHoliday,
    required this.name,
  });
}

/// 节假日更新记账（上次更新/尝试时间、失败次数、自动更新开关；日历工具栏展示用）
class HolidayMeta {
  /// 上次「自动更新范围内年份」成功更新（ms；0 = 从未成功）
  final int lastUpdateMs;

  /// 上次尝试（ms；0 = 从未尝试）
  final int lastAttemptMs;

  /// 连续失败次数（成功后清零）
  final int failureCount;

  /// 自动更新总开关（关闭后仅手动 / 按年补写）
  final bool autoEnabled;

  const HolidayMeta({
    required this.lastUpdateMs,
    required this.lastAttemptMs,
    required this.failureCount,
    required this.autoEnabled,
  });
}

/// 按单年补写结果（记账 + 该年实际行数；`rowCount == 0` = 该年线上无数据）
class HolidayYearOutcome {
  final HolidayMeta meta;
  final int rowCount;

  const HolidayYearOutcome({required this.meta, required this.rowCount});
}

/// 按年范围补写结果汇总
class HolidayRangeSummary {
  /// 成功写入（含空响应）的年份数
  final int ok;

  /// 获取失败的年份数（含熔断后未尝试的年份）
  final int failed;

  /// 成功但线上无数据的年份数
  final int empty;

  /// 是否被中途取消
  final bool cancelled;

  const HolidayRangeSummary({
    required this.ok,
    required this.failed,
    required this.empty,
    required this.cancelled,
  });
}

/// 范围补写进度（FRB `HolidayProgressDto` 平铺镜像：`phase` 区分阶段，其余字段按阶段有效）
///
/// 字段名带阶段前缀，与 Rust 侧同口径——core 的 `Year.ok`（bool：该年成功）与
/// `Done.ok`（u32：成功年份数）平铺后会撞名，故分别落为 `yearOk` / `okCount`。
class HolidayProgress {
  /// 阶段：`starting` / `year` / `done` / `error`
  final String phase;

  /// 总年份数（starting / year 阶段有效）
  final int total;

  /// 当前年份（year 阶段有效）
  final int year;

  /// 已结算年份数（year 阶段有效）
  final int done;

  /// 该年是否拉取成功（year 阶段有效）
  final bool yearOk;

  /// 该年是否线上无数据（year 阶段有效）
  final bool yearEmpty;

  /// 成功写入（含空响应）的年份数（done 阶段有效）
  final int okCount;

  /// 获取失败的年份数（done 阶段有效）
  final int failed;

  /// 是否被中途取消（done 阶段有效）
  final bool cancelled;

  /// 错误信息（error 阶段有效）
  final String message;

  const HolidayProgress({
    required this.phase,
    required this.total,
    required this.year,
    required this.done,
    required this.yearOk,
    required this.yearEmpty,
    required this.okCount,
    required this.failed,
    required this.cancelled,
    required this.message,
  });
}

/// 回收站元数据（回收站页 + 设置页保留档位；FRB trash.rs 镜像）
class TrashMeta {
  /// 保留天数（0 = 永久；默认 30，档位 7/30/90/0）
  final int retentionDays;

  /// 上次 TTL 自动清理时间（ms；0 = 从未执行）
  final int lastPurgeMs;

  const TrashMeta({required this.retentionDays, required this.lastPurgeMs});
}

/// 最新版本清单（#107 检查更新；FRB update.rs 镜像）
class UpdateInfo {
  /// 清单版本号（不带 `v` 前缀）
  final String version;

  /// 发布日期（ISO 8601）
  final String? pubDate;

  /// 更新说明（Markdown 原文）
  final String? notes;

  /// 发布页地址（检查失败/需要手动下载时的兜底）
  final String downloadUrl;

  const UpdateInfo({
    required this.version,
    required this.pubDate,
    required this.notes,
    required this.downloadUrl,
  });
}

/// TTL 清理统计（回收站「立即清理」；FRB trash.rs 镜像）
class TrashPurgeStats {
  /// 物理删除的墓碑行数
  final int purged;

  /// 因同步守卫跳过的行数（删除尚未 push 到云端，清了有复活风险）
  final int guarded;

  /// 本次是否实际执行了清理
  final bool ran;

  const TrashPurgeStats({
    required this.purged,
    required this.guarded,
    required this.ran,
  });
}

/// 每日摘要提醒偏好（G3；FRB digest.rs 镜像，存 cfg_kv 本机设置不随云同步）
class DigestPrefs {
  /// 总开关（默认 false：打扰型功能需显式开启）
  final bool enabled;

  /// 目标小时（0–23）
  final int hour;

  /// 目标分钟（0–59）
  final int minute;

  const DigestPrefs({
    required this.enabled,
    required this.hour,
    required this.minute,
  });

  /// 默认值（与 Rust digest_api 一致：关闭 + 08:00）
  static const DigestPrefs fallback = DigestPrefs(
    enabled: false,
    hour: 8,
    minute: 0,
  );

  /// "HH:mm"（补零；供 TimeOfDay / 展示复用）
  String get label =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// 每日摘要计数（FRB digest.rs 镜像：今日截止 / 逾期 / 今日完成）
class DigestSummary {
  final int dueToday;
  final int overdue;
  final int doneToday;

  const DigestSummary({
    required this.dueToday,
    required this.overdue,
    required this.doneToday,
  });
}

/// 统计总览卡（backlog #25；FRB stats.rs 镜像）
class StatsOverview {
  final int total;
  final int pending;
  final int done;
  final int doneLast7d;
  final int doneLast30d;

  const StatsOverview({
    required this.total,
    required this.pending,
    required this.done,
    required this.doneLast7d,
    required this.doneLast30d,
  });
}

/// 热力图单格（本地日期 YYYY-MM-DD）
class StatsHeatmapCell {
  final String date;
  final int count;

  const StatsHeatmapCell({required this.date, required this.count});
}

/// 热力图数据（按年窗口逐日计数，含零完成日；2026-09-10 对齐 wait-home）
class StatsHeatmap {
  /// 热力图年份（入参回显）
  final int year;
  final String startDate;
  final String endDate;
  final List<StatsHeatmapCell> cells;

  const StatsHeatmap({
    required this.year,
    required this.startDate,
    required this.endDate,
    required this.cells,
  });
}

/// 连续完成天数（streak）
class StatsStreak {
  final int current;
  final int best;
  final bool doneToday;

  const StatsStreak({
    required this.current,
    required this.best,
    required this.doneToday,
  });
}

/// 项目分布行（title null = 未分组）
class StatsProjectRow {
  final int? projectId;
  final String? projectTitle;
  final String? projectHexColor;
  final int doneCount;
  final int pendingCount;

  const StatsProjectRow({
    required this.projectId,
    required this.projectTitle,
    this.projectHexColor,
    required this.doneCount,
    required this.pendingCount,
  });
}

/// 优先级分布行（0-4）
class StatsPriorityRow {
  final int priority;
  final int doneCount;
  final int pendingCount;

  const StatsPriorityRow({
    required this.priority,
    required this.doneCount,
    required this.pendingCount,
  });
}

/// 星期分布行（0=周一 … 6=周日）
class StatsWeekdayRow {
  final int weekday;
  final int doneCount;

  const StatsWeekdayRow({required this.weekday, required this.doneCount});
}

/// 一次性统计聚合（统计页单次调用）
class StatsAggregate {
  final StatsOverview overview;
  final StatsHeatmap heatmap;
  final StatsStreak streak;
  final List<StatsProjectRow> byProject;
  final List<StatsPriorityRow> byPriority;
  final List<StatsWeekdayRow> byWeekday;

  /// 热力图可选年份（升序；有完成记录的年份，空则 [当前年]）
  final List<int> availableYears;

  const StatsAggregate({
    required this.overview,
    required this.heatmap,
    required this.streak,
    required this.byProject,
    required this.byPriority,
    required this.byWeekday,
    required this.availableYears,
  });
}

/// 全局搜索评论命中行（backlog #26）
class CommentSearchHit {
  final int commentId;
  final int taskId;
  final String taskTitle;
  final String content;
  final int createdAt;

  const CommentSearchHit({
    required this.commentId,
    required this.taskId,
    required this.taskTitle,
    required this.content,
    required this.createdAt,
  });
}

/// 全局搜索三路聚合结果（任务/项目/评论；backlog #26）
class GlobalSearchResult {
  final List<TodoTask> tasks;
  final List<TodoProject> projects;
  final List<CommentSearchHit> comments;

  const GlobalSearchResult({
    required this.tasks,
    required this.projects,
    required this.comments,
  });
}

/// 任务附件视图（07 排查报告后续批次：内容寻址；镜像桌面 TaskAttachmentView）
class TaskAttachmentView {
  final int linkId;
  final String linkUuid;
  final String hash;
  final String originalName;
  final String mimeType;
  final int sizeBytes;

  /// 0 = 尚未从云端拉回（本机无文件），打开入口置灰
  final int isLocalCached;

  const TaskAttachmentView({
    required this.linkId,
    required this.linkUuid,
    required this.hash,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    required this.isLocalCached,
  });
}

/// 本地未使用附件行（存储清理页；FRB asset.rs 镜像）
///
/// 「未使用」= 无任何存活任务引用的本地账本行——通常是卸下附件后
/// 还没来得及被 GC 回收的二进制。
class UnusedAttachment {
  final String hash;
  final String originalName;
  final String mimeType;
  final int sizeBytes;

  /// 0 = 尚未上传云端（删除后其他设备无法找回）
  final int isUploaded;

  /// 0 = 本机无文件（只剩账本行，无需清理磁盘）
  final int isLocalCached;
  final int createdAt;

  const UnusedAttachment({
    required this.hash,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
    required this.isUploaded,
    required this.isLocalCached,
    required this.createdAt,
  });
}

/// 云端孤儿附件行（docs/15；云端清理清单）
///
/// 与 [TaskAttachmentView] 的区别：这是**云端对象**，不是任务挂载行——
/// 体积有密文/明文两个来源，[kind] 标明整包/分片布局。
class CloudUnusedAttachmentView {
  final String hash;

  /// 密文体积；WebDAV 分片形态为 0（目录条目没有长度）
  final int cipherBytes;

  /// 服务端最后修改时间（Unix 秒；<=0 表示不可得）
  final int lastModified;

  /// whole / chunked / both
  final String kind;

  final String originalName;

  /// 本地账本明文体积（0 = 账本无该行）
  final int sizeBytes;

  final int isLocalCached;
  final int isUploaded;

  const CloudUnusedAttachmentView({
    required this.hash,
    required this.cipherBytes,
    required this.lastModified,
    required this.kind,
    required this.originalName,
    required this.sizeBytes,
    required this.isLocalCached,
    required this.isUploaded,
  });

  /// 展示体积：密文优先，WebDAV 分片回退本地明文（与桌面 `cloudItemBytes` 同口径）
  int get displayBytes => cipherBytes > 0 ? cipherBytes : sizeBytes;

  /// 清单显示名：账本无原始文件名时用 hash 前 12 位
  String get label => originalName.trim().isNotEmpty
      ? originalName
      : '${hash.substring(0, 12)}…';

  /// 云端形态文案（删除覆盖两种布局，不能让用户以为只删一份）
  String get kindLabel => switch (kind) {
    'chunked' => '分片',
    'both' => '整包+分片',
    _ => '整包',
  };
}

/// 云端孤儿扫描结果
class CloudUnusedScanResult {
  final List<CloudUnusedAttachmentView> items;

  /// 清单 epoch：删除时原样回传做 CAS（不一致说明云端刚有他端 push）
  final int epoch;

  /// 年龄窗口（秒），UI 文案用「仅含 N 天前的对象」
  final int minAgeSecs;

  const CloudUnusedScanResult({
    required this.items,
    required this.epoch,
    required this.minAgeSecs,
  });
}

/// 云端孤儿删除结果
class CloudUnusedDeleteResult {
  final int deletedAssets;
  final int deletedObjects;
  final int skippedReferenced;
  final int localRowsCleaned;
  final bool staleManifest;
  final List<String> errors;

  const CloudUnusedDeleteResult({
    required this.deletedAssets,
    required this.deletedObjects,
    required this.skippedReferenced,
    required this.localRowsCleaned,
    required this.staleManifest,
    required this.errors,
  });
}

/// 孤儿数据分桶回收结果（docs/07 #96 尾款；镜像 core `OrphanChunkGcResult`）
///
/// `deletedBuckets` 含「原本已不存在」的对象——云端删除对不存在的键按成功计，
/// 故它读作「本轮确认无引用的桶数」而不是「本次真正删掉的字节数」。
class OrphanChunkGcResult {
  final int deletedBuckets;
  final List<String> errors;

  const OrphanChunkGcResult({
    required this.deletedBuckets,
    required this.errors,
  });
}

/// 同步进度事件（镜像 core `SyncProgress`；与桌面 `SyncProgressEvent` 同形）
///
/// 压平成「`phase` 判别 + 其余字段可空」而非 sealed class 家族：FRB 侧的
/// `SyncProgressDto` 就是单一 struct（core 的内部标签 enum 不能直接镜像），
/// 手写镜像照抄同一形状才能零转换直连。判据全在 `phase` 上。
///
/// **文案直接用 `displayText`**（core `SyncProgress::display_text` 单点产出），
/// 不在 Dart 侧再拼一套——双端各拼一份必然漂移（桌面 `syncProgressText`
/// 是既有实现，不动它，但移动端不重复造）。
class SyncProgress {
  /// starting / pushing / pulling / merging / local_data_applied / attachments / done / error
  final String phase;

  /// background / manual / exit
  final String origin;

  /// 模块显示名（pushing/pulling/merging）；attachments 档借来放 upload/download
  final String? displayName;
  final int? current;
  final int? total;
  final String? message;

  /// 估算百分比 0–100
  final int percent;

  /// 可直接展示的整句文案（core 同口径）
  final String displayText;

  const SyncProgress({
    required this.phase,
    required this.origin,
    this.displayName,
    this.current,
    this.total,
    this.message,
    required this.percent,
    required this.displayText,
  });

  /// 终态：done / error（订阅方据此收进度条）
  bool get isTerminal => phase == 'done' || phase == 'error';

  /// 手动触发的同步（设置页只关心这一档；后台自动同步不该在页面上闪进度）
  bool get isManual => origin == 'manual';
}

/// 人类可读大小（移动端附件行展示；与桌面 humanSize 同口径）
String humanFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 保存的筛选器（#35；镜像桌面 TodoSavedFilter）
class TodoSavedFilter {
  final int id;
  final String uuid;
  final String name;

  /// 条件 JSON：{status?, priority_min?, project_ids?, label_ids?, due_within_days?, due_overdue?, favorite_only?}
  final String conditions;

  const TodoSavedFilter({
    required this.id,
    required this.uuid,
    required this.name,
    required this.conditions,
  });
}

/// 任务模板（竞品矩阵高价值缺口；镜像桌面 TodoTemplate）
class TodoTemplate {
  final int id;
  final String uuid;
  final String name;

  /// 模板内容 JSON：{title?, notes?, priority?, due_offset_days?, subtasks?}——套用时按存在键预填
  final String payload;

  const TodoTemplate({
    required this.id,
    required this.uuid,
    required this.name,
    required this.payload,
  });
}

/// 冲突败方副本（03 文档 §八 遗留项；镜像桌面 SyncConflictEntry）
///
/// 纯本地表（不随云同步、不进备份）：多端并发改同一记录时把败方整行快照留档，
/// 供设置页查看差异并「恢复为败方版本」。payload 为整行字段快照 JSON 字符串。
class SyncConflict {
  final int id;
  final String tableName;
  final String recordUuid;
  final String recordTitle;

  /// lww 时间戳裁决 / tie_version 同毫秒按 version 裁决
  final String decision;

  /// 败方归属：local 本地被覆盖 / remote 远端被丢弃
  final String loserSide;
  final String winnerSide;
  final String loserPayload;
  final String winnerPayload;
  final int loserUpdatedAt;
  final int winnerUpdatedAt;

  /// unresolved 未处理 / restored 已恢复 / dismissed 已忽略
  final String resolution;
  final int createdAt;
  final int resolvedAt;

  const SyncConflict({
    required this.id,
    required this.tableName,
    required this.recordUuid,
    required this.recordTitle,
    required this.decision,
    required this.loserSide,
    required this.winnerSide,
    required this.loserPayload,
    required this.winnerPayload,
    required this.loserUpdatedAt,
    required this.winnerUpdatedAt,
    required this.resolution,
    required this.createdAt,
    required this.resolvedAt,
  });
}

/// ICS 日历导出结果（#4；FRB ics_export.rs 镜像）
class IcsExportView {
  final String content;
  final List<IcsTableCount> tableCounts;
  final String suggestedFilename;

  const IcsExportView({
    required this.content,
    required this.tableCounts,
    required this.suggestedFilename,
  });
}

/// ICS 导出表计数项（FRB IcsTableCount 镜像）
class IcsTableCount {
  final String table;
  final int count;

  const IcsTableCount({required this.table, required this.count});
}

/// Android 桌面小组件任务行（#3；FRB widget.rs 镜像，RemoteViews 最小字段集）
class WidgetTodoItem {
  final int id;
  final String uuid;
  final String title;
  final int priority;
  final int done;

  const WidgetTodoItem({
    required this.id,
    required this.uuid,
    required this.title,
    required this.priority,
    required this.done,
  });
}

/// 任务活动日志行（FRB ActivityLogRow 镜像；todo_activity_log 本地轨迹表，
/// 不随云同步——各端各自记录过程态）
class ActivityLogRow {
  final int id;

  /// 任务行被 purge 后可为 null（taskTitle 留快照仍可展示）
  final int? taskId;
  final String taskTitle;
  final String action;

  /// 附加 JSON：{"fields"/"changes"/"label"/"target"} 四代形状（格式化在 logic/activity_format.dart）
  final String detail;
  final int createdAt;

  const ActivityLogRow({
    required this.id,
    this.taskId,
    required this.taskTitle,
    required this.action,
    required this.detail,
    required this.createdAt,
  });

  factory ActivityLogRow.fromJson(Map<String, dynamic> j) => ActivityLogRow(
    id: j['id'] as int,
    taskId: j['task_id'] as int?,
    taskTitle: j['task_title'] as String,
    action: j['action'] as String,
    detail: j['detail'] as String,
    createdAt: j['created_at'] as int,
  );
}

// =============================================================================
// 全量备份（.orfullsync；FRB full_sync_backup.rs 镜像）
// =============================================================================

/// 备份内单表记录数（Rust 侧 BTreeMap 展开为有序列表）
class BackupTableCount {
  final String table;
  final int count;

  const BackupTableCount({required this.table, required this.count});
}

/// 备份清单（manifest.json；恢复预览与导出结果共用）
class BackupManifest {
  final int formatVersion;
  final String createdAt;
  final int createdAtTs;
  final String appVersion;
  final String deviceId;
  final String? deviceName;
  final int schemaVersion;
  final List<BackupTableCount> tableCounts;

  const BackupManifest({
    required this.formatVersion,
    required this.createdAt,
    required this.createdAtTs,
    required this.appVersion,
    required this.deviceId,
    this.deviceName,
    required this.schemaVersion,
    required this.tableCounts,
  });

  /// 表记录数合计（清单摘要行展示）
  int get totalRecords => tableCounts.fold(0, (sum, e) => sum + e.count);
}

/// 全量备份导出结果（本地文件 + 可选云端副本，两者失败互不阻塞）
class BackupExportResult {
  final String filePath;
  final int fileSize;
  final BackupManifest manifest;
  final String? cloudPath;
  final bool cloudUploaded;
  final String? cloudError;
  final String? localPath;
  final String? localError;

  const BackupExportResult({
    required this.filePath,
    required this.fileSize,
    required this.manifest,
    this.cloudPath,
    required this.cloudUploaded,
    this.cloudError,
    this.localPath,
    this.localError,
  });
}

/// 全量备份导入（恢复）结果
class BackupImportResult {
  final int successCount;
  final int errorCount;
  final List<String> errors;
  final BackupManifest manifest;

  /// 恢复的是更早版本 schema 时提示重启以完成迁移
  final bool needsRestart;

  const BackupImportResult({
    required this.successCount,
    required this.errorCount,
    required this.errors,
    required this.manifest,
    required this.needsRestart,
  });
}

/// 备份内单条任务预览（恢复确认框抽样展示）
class BackupPreviewTask {
  final String title;
  final String status;
  final bool done;
  final int? dueDate;
  final int priority;
  final String? project;
  final bool isDeleted;

  const BackupPreviewTask({
    required this.title,
    required this.status,
    required this.done,
    this.dueDate,
    required this.priority,
    this.project,
    required this.isDeleted,
  });
}

/// 备份内任务统计（存活/已完成/墓碑）
class BackupTaskStats {
  final int total;
  final int alive;
  final int done;
  final int deleted;

  const BackupTaskStats({
    required this.total,
    required this.alive,
    required this.done,
    required this.deleted,
  });
}

/// 恢复预览（只读：清单统计 + 任务抽样 + schema 比对）
class BackupPreview {
  final BackupManifest manifest;
  final List<BackupPreviewTask> sampleTasks;
  final BackupTaskStats taskStats;

  /// 备份 schema 与当前库不一致（恢复需追加一次强制确认）
  final bool schemaMismatch;
  final int currentSchemaVersion;

  const BackupPreview({
    required this.manifest,
    required this.sampleTasks,
    required this.taskStats,
    required this.schemaMismatch,
    required this.currentSchemaVersion,
  });
}

/// 本地备份文件条目
class BackupEntry {
  final String filename;
  final String filePath;
  final int modifiedAt;
  final int sizeBytes;

  const BackupEntry({
    required this.filename,
    required this.filePath,
    required this.modifiedAt,
    required this.sizeBytes,
  });
}

/// 云端备份副本条目（cloudPath 为 peek/restore 回传的完整对象路径）
class CloudBackupEntry {
  final String name;
  final String cloudPath;
  final int sizeBytes;
  final int modifiedAt;

  const CloudBackupEntry({
    required this.name,
    required this.cloudPath,
    required this.sizeBytes,
    required this.modifiedAt,
  });
}

/// 自动备份偏好（镜像 core BackupPrefs；scheduleType 用字符串承载：
/// off / hourly / daily / weekly / monthly / yearly）
class BackupPrefs {
  final String? localPath;
  final bool keepLatest;
  final bool cloudBackupEnabled;
  final bool localBackupEnabled;
  final String scheduleType;

  /// "HH:mm"（daily/weekly/monthly/yearly 使用）
  final String scheduleTime;
  final int scheduleMinute;
  final int scheduleWeekday;
  final int scheduleDayOfMonth;
  final int scheduleMonth;
  final int lastBackupAt;
  final int nextBackupAt;

  const BackupPrefs({
    this.localPath,
    required this.keepLatest,
    required this.cloudBackupEnabled,
    required this.localBackupEnabled,
    required this.scheduleType,
    required this.scheduleTime,
    required this.scheduleMinute,
    required this.scheduleWeekday,
    required this.scheduleDayOfMonth,
    required this.scheduleMonth,
    required this.lastBackupAt,
    required this.nextBackupAt,
  });

  /// 默认值（与 core BackupPrefs::default 同口径：调度关闭、双开关开）
  static const initial = BackupPrefs(
    keepLatest: false,
    cloudBackupEnabled: true,
    localBackupEnabled: true,
    scheduleType: 'off',
    scheduleTime: '03:00',
    scheduleMinute: 0,
    scheduleWeekday: 0,
    scheduleDayOfMonth: 1,
    scheduleMonth: 1,
    lastBackupAt: 0,
    nextBackupAt: 0,
  );

  BackupPrefs copyWith({
    bool? keepLatest,
    bool? cloudBackupEnabled,
    bool? localBackupEnabled,
    String? scheduleType,
    String? scheduleTime,
    int? scheduleMinute,
    int? scheduleWeekday,
    int? scheduleDayOfMonth,
    int? scheduleMonth,
    int? lastBackupAt,
    int? nextBackupAt,
  }) => BackupPrefs(
    localPath: localPath,
    keepLatest: keepLatest ?? this.keepLatest,
    cloudBackupEnabled: cloudBackupEnabled ?? this.cloudBackupEnabled,
    localBackupEnabled: localBackupEnabled ?? this.localBackupEnabled,
    scheduleType: scheduleType ?? this.scheduleType,
    scheduleTime: scheduleTime ?? this.scheduleTime,
    scheduleMinute: scheduleMinute ?? this.scheduleMinute,
    scheduleWeekday: scheduleWeekday ?? this.scheduleWeekday,
    scheduleDayOfMonth: scheduleDayOfMonth ?? this.scheduleDayOfMonth,
    scheduleMonth: scheduleMonth ?? this.scheduleMonth,
    lastBackupAt: lastBackupAt ?? this.lastBackupAt,
    nextBackupAt: nextBackupAt ?? this.nextBackupAt,
  );
}

/// 当前设备信息（导出预览展示）
class BackupDeviceInfo {
  final String deviceId;

  const BackupDeviceInfo({required this.deviceId});
}

// =============================================================================
// 通知历史（notification_log 本地轨迹表；FRB notification_log.rs 镜像）
// =============================================================================

/// 通知历史行（kind = reminder_due / snooze / complete / boot_skip）
class NotificationLogRow {
  final int id;
  final String kind;
  final int? taskId;
  final String taskTitle;
  final int? reminderId;

  /// 附加 JSON：{remind_at, snooze_until, source}
  final String payload;
  final int createdAt;

  const NotificationLogRow({
    required this.id,
    required this.kind,
    this.taskId,
    required this.taskTitle,
    this.reminderId,
    required this.payload,
    required this.createdAt,
  });
}

/// 增量同步历史行（FRB sync.rs SyncHistoryView 镜像；只读聚合）
class SyncHistoryRow {
  final int id;

  /// core 真值：incremental / push_only / pull_only（engine.rs 同名常量，
  /// F77 对齐——旧注释里的 sync_now/pull_then_push 是臆测字符串）
  final String syncType;
  final String status;
  final int startedAt;
  final int? finishedAt;
  final int pulledCount;
  final int pushedCount;
  final int conflictCount;
  final String? errorMessage;

  const SyncHistoryRow({
    required this.id,
    required this.syncType,
    required this.status,
    required this.startedAt,
    this.finishedAt,
    required this.pulledCount,
    required this.pushedCount,
    required this.conflictCount,
    this.errorMessage,
  });

  /// 耗时毫秒（未完成时按 0 处理）
  int get elapsedMs =>
      finishedAt == null ? 0 : (finishedAt! - startedAt).clamp(0, 1 << 40);
}

/// 本地同步账本（core `SyncState` 镜像；`sync_state.json`，只有指纹元数据）
///
/// 桥侧以 JSON 字符串返回（对齐桌面 `cloud_sync_get_state`），此处解析为
/// 强类型；水位线是逻辑时钟毫秒（0 = 从未推进），指纹是桶内容的 sha256。
class SyncStateView {
  /// 最后一次同步完成时间（Unix 毫秒，墙上时钟）
  final int lastSyncedAt;

  /// 最后一次同步完成时的逻辑时钟（pull 侧「真并发」判据基线）
  final int lastSyncedClockMs;

  /// 最后一次 push 成功时的逻辑时钟上界（增量 push 水位线；0 = 首轮全量）
  final int lastPushedClockMs;
  final String deviceId;

  /// 远端清单 epoch（0 = 从未成功同步）
  final int manifestEpoch;

  /// 远端数据桶快照：表 → 桶号 → 指纹
  final Map<String, Map<String, String>> remoteTables;

  /// 远端墓碑桶快照：表 → 桶键（YYYY-MM）→ 指纹
  final Map<String, Map<String, String>> remoteTombstones;

  const SyncStateView({
    required this.lastSyncedAt,
    required this.lastSyncedClockMs,
    required this.lastPushedClockMs,
    required this.deviceId,
    required this.manifestEpoch,
    required this.remoteTables,
    required this.remoteTombstones,
  });

  factory SyncStateView.fromJson(Map<String, dynamic> j) => SyncStateView(
    lastSyncedAt: (j['last_synced_at'] as num?)?.toInt() ?? 0,
    lastSyncedClockMs: (j['last_synced_clock_ms'] as num?)?.toInt() ?? 0,
    lastPushedClockMs: (j['last_pushed_clock_ms'] as num?)?.toInt() ?? 0,
    deviceId: j['device_id'] as String? ?? '',
    manifestEpoch: (j['manifest_epoch'] as num?)?.toInt() ?? 0,
    remoteTables: _stringMapOf(j['remote_tables']),
    remoteTombstones: _stringMapOf(j['remote_tombstones']),
  );

  /// 桶索引快照（嵌套对象，值都是指纹字符串）；缺字段/形状异常回落空表
  static Map<String, Map<String, String>> _stringMapOf(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, Map<String, String>>{};
    raw.forEach((k, v) {
      if (v is! Map) return;
      out['$k'] = {for (final e in v.entries) '${e.key}': '${e.value}'};
    });
    return out;
  }
}

// ---------- 应用内诊断（docs/09 内存专项；只读聚合） ----------

/// 单表活行数（镜像 core `diagnostics_api::TableRowCount`）
class TableRowCount {
  final String table;

  /// `is_deleted = 0` 的行数
  final int rows;

  const TableRowCount({required this.table, required this.rows});

  /// 列表通道 JSON → App 模型（mock 桥用；真桥走 `_mapDiagnostics` 直映 FRB DTO）
  factory TableRowCount.fromJson(Map<String, dynamic> j) => TableRowCount(
    table: j['table'] as String,
    rows: (j['rows'] as num).toInt(),
  );
}

/// 应用内诊断快照（镜像 core `diagnostics_api::DiagnosticsSnapshot`）
///
/// 只读读数，不进同步白名单；单位统一为字节/行数（格式化在 UI 层做）。
class DiagnosticsSnapshot {
  /// 本地库体积（SQLite `page_count × page_size`）
  final int dbSizeBytes;

  /// 各表活行数（顺序 = 同步白名单顺序）
  final List<TableRowCount> tableRows;

  /// 全部可同步表的墓碑行数合计
  final int tombstoneRows;

  /// 附件本地缓存体积（字节）
  final int attachmentCacheBytes;

  /// 附件本地缓存文件数
  final int attachmentCacheFiles;

  const DiagnosticsSnapshot({
    required this.dbSizeBytes,
    required this.tableRows,
    required this.tombstoneRows,
    required this.attachmentCacheBytes,
    required this.attachmentCacheFiles,
  });

  /// 列表通道 JSON → App 模型（mock 桥用）
  factory DiagnosticsSnapshot.fromJson(Map<String, dynamic> j) =>
      DiagnosticsSnapshot(
        dbSizeBytes: (j['db_size_bytes'] as num).toInt(),
        tableRows: [
          for (final row in (j['table_rows'] as List? ?? const []))
            TableRowCount.fromJson(Map<String, dynamic>.from(row as Map)),
        ],
        tombstoneRows: (j['tombstone_rows'] as num).toInt(),
        attachmentCacheBytes: (j['attachment_cache_bytes'] as num).toInt(),
        attachmentCacheFiles: (j['attachment_cache_files'] as num).toInt(),
      );
}

// ---------- 测试数据（仅 debug 构建；镜像 core `dev_seed_api`） ----------

/// 生成规模（镜像 core `dev_seed_api::DevSeedPlan`；只暴露任务条数）
class DevSeedPlan {
  /// 任务条数（含约 2% 回收站墓碑行）
  final int tasks;

  const DevSeedPlan({required this.tasks});
}

/// 各表写入/清除条数（镜像 core `dev_seed_api::DevSeedCounts`）
class DevSeedCounts {
  final int projects;
  final int labels;
  final int tasks;
  final int subtasks;
  final int reminders;
  final int comments;
  final int taskLabels;
  final int taskRelations;

  const DevSeedCounts({
    required this.projects,
    required this.labels,
    required this.tasks,
    required this.subtasks,
    required this.reminders,
    required this.comments,
    required this.taskLabels,
    required this.taskRelations,
  });

  /// 全表合计（结果卡片的「已写入 N 行」口径，与桌面 `totalOf` 一致）
  int get total =>
      projects +
      labels +
      tasks +
      subtasks +
      reminders +
      comments +
      taskLabels +
      taskRelations;
}

/// 生成结果（`cleared` = 生成前清掉的上一批）
class DevSeedResult {
  final DevSeedCounts created;
  final DevSeedCounts cleared;

  /// Rust 侧实测耗时（毫秒）
  final int elapsedMs;

  const DevSeedResult({
    required this.created,
    required this.cleared,
    required this.elapsedMs,
  });
}

/// 清理结果
class DevSeedClearResult {
  final DevSeedCounts removed;

  /// Rust 侧实测耗时（毫秒）
  final int elapsedMs;

  const DevSeedClearResult({required this.removed, required this.elapsedMs});
}
