import 'dto.dart';

/// 事件载荷（对齐桌面端 lib/events.ts 与 notification_scheduler 载荷）

/// "db-change"：本地写操作事件（Rust EVENT_BUS 转发）
class DbChangeEvent {
  final String table;
  final String op;
  final int? recordId;
  final String? recordUuid;
  final String? deviceId;
  final int timestamp;

  const DbChangeEvent({
    required this.table,
    required this.op,
    this.recordId,
    this.recordUuid,
    this.deviceId,
    required this.timestamp,
  });
}

/// "sync-finished" 事件已移除（ADR 0003）：云同步结果经 cloudSyncNow
/// 返回值直达，不存在可订阅的事件流。

/// "todo_reminder:due"：提醒到期事件
class ReminderDueEvent {
  final int id;
  final int taskId;
  final String title;
  final int remindAt;

  const ReminderDueEvent({
    required this.id,
    required this.taskId,
    required this.title,
    required this.remindAt,
  });
}

/// 明文导出结果（07 报告 #15；FRB plaintext_export.rs 镜像）
class PlaintextExportResult {
  /// 文件内容（JSON 文本或 CSV 文本，UTF-8；CSV 带 BOM）
  final String content;

  /// 各表行数（表名 → 行数）
  final Map<String, int> tableCounts;

  /// 建议文件名（含时间戳）
  final String suggestedFilename;

  const PlaintextExportResult({
    required this.content,
    required this.tableCounts,
    required this.suggestedFilename,
  });
}

/// CSV 导入统计（预览口径 success=待导入条数；执行口径=实际成功条数；
/// FRB csv_import.rs 的 CsvImportStatsView 镜像）
class CsvImportStats {
  final int success;
  final int skipped;
  final int failed;

  /// 逐行错误/跳过说明（行号 + 原因）
  final List<String> notes;

  const CsvImportStats({
    required this.success,
    required this.skipped,
    required this.failed,
    required this.notes,
  });
}

/// CSV 导入预览结果（FRB csv_import.rs 的 CsvImportPreviewView 镜像；
/// rows 已映射为待创建任务字段）
class CsvImportPreview {
  final String preset;

  /// 预览行（最多 previewLimit 条，含跳过标记与原因）
  final List<CsvImportPreviewRow> rows;

  final CsvImportStats stats;

  const CsvImportPreview({
    required this.preset,
    required this.rows,
    required this.stats,
  });
}

/// 一条待导入行预览载荷
class CsvImportPreviewRow {
  final int sourceLine;
  final String? projectTitle;
  final String title;
  final int? priority;
  final bool done;
  final int? dueDate;
  final String? skipReason;

  const CsvImportPreviewRow({
    required this.sourceLine,
    required this.projectTitle,
    required this.title,
    required this.priority,
    required this.done,
    required this.dueDate,
    required this.skipReason,
  });
}

/// Orbit 数据桥抽象（omnipass `OmniBridge` 同款模式）
///
/// 移动端唯一数据入口。UI 层只依赖本抽象：
/// - Phase 4-6：`MockOrbitBridge` 内存实现，UI 可独立开发测试；
/// - Phase 5 起：`RustOrbitBridge`（FRB codegen 包装）在 main 中
///   经 Provider override 注入替换，UI 零改动。
///
/// 方法面 = 原 React 移动端消费的命令子集（桌面端保留全量）。
/// 更新路径采用 JSON patch 载荷（[encodePatch]），与 Tauri invoke 走
/// 同一 serde 反序列化路径，"缺省键=跳过、null=清空"语义无损。
abstract class OrbitBridge {
  // ── 主密码认证 ──

  /// 是否已设置主密码（启动门控第一步）
  Future<bool> masterAuthHas();

  /// 初始化主密码，返回 db_key_hex
  Future<String> masterAuthInit(String password);

  /// 解锁主密码，返回 db_key_hex；密码错误抛异常
  Future<String> masterAuthUnlock(String password);

  /// 仅验证主密码（敏感操作二次确认）
  Future<bool> masterAuthVerify(String password);

  // ── DB 生命周期 ──

  Future<void> dbInitPlaintext();
  Future<void> dbInitEncrypted(String dbKeyHex);
  Future<bool> dbIsReady();
  Future<void> dbSetDeviceId(String deviceId);

  // ── todo_projects ──

  Future<List<TodoProject>> todoProjectList(ListFilter filter);
  Future<TodoProject> todoProjectGet(int id);
  Future<TodoProject> todoProjectCreate(TodoProjectCreateInput input);
  Future<TodoProject> todoProjectUpdate(int id, String patchJson);
  Future<void> todoProjectDelete(int id);
  Future<void> todoProjectUpdateSortOrder(int id, int sortOrder);

  // ── todo_tasks ──

  Future<List<TodoTask>> todoTaskList(ListFilter filter);
  Future<TodoTask> todoTaskGet(int id);
  Future<TodoTask> todoTaskCreate(TodoTaskCreateInput input);
  Future<TodoTask> todoTaskUpdate(int id, String patchJson);
  Future<void> todoTaskDelete(int id);
  Future<void> todoTaskUpdatePosition(int id, int position);

  /// 统一完成任务：普通标记 / 重复任务单事务推进下一实例
  /// （引擎下沉 orbit-core，与桌面同一 Rust 入口；返回完成后的任务）
  Future<TodoTask> todoTaskComplete(int id);

  /// 一键复制任务（#37：克隆字段+子任务，副本标题后缀）
  Future<TodoTask> todoTaskDuplicate(int id);

  /// 详情聚合：任务 + 子任务 + 标签 + 评论 + 关联 + 提醒
  Future<TodoTaskDetail> todoTaskGetDetail(int id);

  // ── todo_subtasks ──

  Future<List<TodoSubtask>> todoSubtaskList(ListFilter filter);
  Future<TodoSubtask> todoSubtaskCreate(TodoSubtaskCreateInput input);
  Future<TodoSubtask> todoSubtaskUpdate(int id, String patchJson);
  Future<void> todoSubtaskDelete(int id);
  Future<void> todoSubtaskToggleDone(int subtaskId, bool done);

  // ── todo_labels / todo_task_labels ──

  Future<List<TodoLabel>> todoLabelList(ListFilter filter);
  Future<TodoLabel> todoLabelCreate(TodoLabelCreateInput input);
  Future<void> todoLabelDelete(int id);
  Future<TaskLabelWithId> todoTaskLabelCreate(TodoTaskLabelCreateInput input);
  Future<void> todoTaskLabelDelete(int taskLabelId);

  // ── todo_comments ──

  Future<List<TodoComment>> todoCommentList(ListFilter filter);
  Future<TodoComment> todoCommentCreate(TodoCommentCreateInput input);
  Future<void> todoCommentDelete(int id);

  // ── todo_task_relations ──

  Future<List<TodoTaskRelation>> todoTaskRelationList(ListFilter filter);
  Future<TodoTaskRelation> todoTaskRelationCreate(
      TodoTaskRelationCreateInput input);
  Future<void> todoTaskRelationDelete(int id);

  // ── todo_reminders ──

  Future<List<TodoReminder>> todoReminderList(ListFilter filter);
  Future<TodoReminder> todoReminderCreate(TodoReminderCreateInput input);
  Future<void> todoReminderDelete(int id);

  // ── 同步配置与执行 ──

  /// 当前同步配置；未配置时返回 null
  Future<SyncConfigView?> syncConfigGet();
  Future<SyncConfigView> syncConfigSave(Map<String, Object?> input);

  /// 立即同步（pull_then_push），返回结果摘要
  Future<SyncResultJson> cloudSyncNow({String origin = 'manual'});
  Future<bool> cloudSyncIsRunning();

  /// 测试连接（不落盘）：返回云端根目录条目数；用户名/密码留空时
  /// 从已存激活配置回填（同协议）。错误文案带 [config]/[network] tag。
  Future<int> syncTestConnection(Map<String, Object?> input);

  /// 断开云同步：仅清除本机连接配置与凭据，不动本地数据与云端文件
  Future<void> syncDisconnect();

  // ── 明文数据导出（07 报告 #15；PRIVACY.md §七口径）──

  /// 导出全部待办数据为结构化 JSON（默认排除墓碑行）
  Future<PlaintextExportResult> plaintextExportJson({bool excludeDeleted = true});

  /// 导出任务主视图 CSV（UTF-8 with BOM；默认排除墓碑行）
  Future<PlaintextExportResult> plaintextExportCsv({bool excludeDeleted = true});

  // ── CSV 导入（迁移路径：orbit / todoist / ticktick）──

  /// 预览导入（不写库）：解析 + 映射 + 统计
  Future<CsvImportPreview> csvImportPreview(String content, String preset, int previewLimit);

  /// 执行导入（写库）：项目自动创建、逐行独立成败
  Future<CsvImportStats> csvImportExecute(String content, String preset);

  // ── 任务附件（内容寻址：上传/列表/读取/卸下）──

  /// 上传并挂载附件（bytes 由 file_picker 读得；单任务 20 个/单文件 50MB）
  Future<TaskAttachmentView> taskAttachmentAdd(
      int taskId, String fileName, String mimeType, List<int> data);

  /// 任务附件列表（含 isLocalCached 状态）
  Future<List<TaskAttachmentView>> taskAttachmentsList(int taskId);

  /// 读取附件本地字节（未缓存时抛 NotFound）
  Future<List<int>> taskAttachmentRead(String hash);

  /// 卸下附件（软删关联，孤儿二进制由 GC 清）
  Future<void> taskAttachmentRemove(int linkId);

  // ── 保存的筛选器（#35：Apple Smart List 同款）──

  /// 列出全部保存的筛选器
  Future<List<TodoSavedFilter>> savedFiltersList();

  /// 创建保存的筛选器（条件 JSON 白名单键校验在后端）
  Future<TodoSavedFilter> savedFilterCreate(
      String name, String conditions);

  /// 删除保存的筛选器（软删）
  Future<void> savedFilterDelete(int id);

  // ── 同步加密（恢复流程用）──

  Future<SyncCryptoStatus> syncCryptoStatus();

  /// 首次设置同步密码（生成 Data Key；移动端 remember 仅进程内缓存）
  Future<void> syncCryptoInit(String password, {bool remember = false});
  Future<void> syncCryptoUnlock(String password, {bool remember = false});

  /// 锁定：清除内存中的 Data Key（下次同步前需解锁）
  Future<void> syncCryptoLock();
  Future<String> syncCryptoImportBundle(
    SyncCryptoBundle bundle,
    String password, {
    bool force = false,
  });

  // ── 节假日数据（日历视图联网更新；cfg_holidays 本地缓存）──

  /// 全部节假日（date 升序；空库回落预置 2026 表，冷启动可用）
  Future<List<HolidayInfo>> holidayList();

  /// 判定某日期：true 放假 / false 调休补班 / null 普通日
  Future<bool?> holidayIsOn(String date);

  /// 手动更新（强制拉取；失败抛错误文案，旧缓存保留）
  Future<HolidayMeta> holidayUpdate();

  /// 更新记账（上次成功/尝试、连续失败次数、固定时刻）
  Future<HolidayMeta> holidayMeta();

  /// 启动自动更新守护（幂等；DB 就绪后由 BootGate 调一次——
  /// 每日固定时刻更新 + 错过时刻下次启动首轮补更）
  Future<void> startHolidayScheduler();

  // ── 回收站（删除的任务可恢复；保留时间可配）──

  /// 回收站任务列表（最近删除排最前）
  Future<List<TodoTask>> trashTasksList();

  /// 恢复任务（原项目已删则落未分组）
  Future<TodoTask> trashTaskRestore(int id);

  /// 彻底删除单个回收站任务（不可恢复）
  Future<void> trashTaskPurge(int id);

  /// 清空回收站，返回删除的任务数
  Future<int> trashPurgeAll();

  /// 回收站元数据（保留档位 + 上次自动清理时间）
  Future<TrashMeta> trashMeta();

  /// 设置保留天数（档位 7/30/90/0=永久；默认 30）
  Future<void> trashSetRetentionDays(int days);

  /// 启动 TTL 自动清理守护（幂等；DB 就绪后由 BootGate 调一次——
  /// 每日最多清理一次 + 多日未开时启动首轮补清）
  Future<void> startTrashScheduler();

  // ── 统计仪表盘（backlog #25：只读聚合）──

  /// 一次性统计聚合（days 为热力图窗口天数，35-371；null = 182 半年）
  Future<StatsAggregate> statsAggregate({int? days});

  // ── 全局搜索（backlog #26：任务/项目/评论三路聚合）──

  /// 全局搜索（空关键词返回空结果；limit 默认 20）
  Future<GlobalSearchResult> globalSearch(String keyword, {int? limit});

  // ── 事件流（下行通道，替代 Tauri event listen）──

  /// 本地写操作事件 → 全量失效业务缓存
  Stream<DbChangeEvent> get dbChanges;

  /// 提醒到期事件 → 本地通知 + 重复提醒排程
  Stream<ReminderDueEvent> get reminderDue;
}
