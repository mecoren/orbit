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

  // ── 事件流（下行通道，替代 Tauri event listen）──

  /// 本地写操作事件 → 全量失效业务缓存
  Stream<DbChangeEvent> get dbChanges;

  /// 提醒到期事件 → 本地通知 + 重复提醒排程
  Stream<ReminderDueEvent> get reminderDue;
}
