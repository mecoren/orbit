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

/// 数据库维护结果（性能批次；FRB maintenance.rs 镜像）
class DbMaintenanceResult {
  /// WAL checkpoint 后 -wal 文件剩余大小（字节）
  final int walBytesAfterCheckpoint;

  /// 附件 GC 清理的孤立文件数
  final int attachmentsCleaned;

  /// VACUUM 前空闲页数（碎片页）
  final int freelistBefore;

  /// VACUUM 后空闲页数（应为 0）
  final int freelistAfter;

  /// VACUUM 实际回收的页数
  final int pagesReclaimed;

  const DbMaintenanceResult({
    required this.walBytesAfterCheckpoint,
    required this.attachmentsCleaned,
    required this.freelistBefore,
    required this.freelistAfter,
    required this.pagesReclaimed,
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

/// biometric 密钥链三件套（Base64 standard；FRB biometric.rs 镜像，
/// 存储于 flutter_secure_storage，加解密编排下沉 Rust）
class BiometricSecretBundle {
  /// AES-256-GCM(Biometric Key, DB Key, nonce) 密文
  final String encryptedDbKeyBio;

  /// 32 字节随机 Biometric Key
  final String biometricKey;

  /// 12 字节随机 nonce
  final String nonce;

  const BiometricSecretBundle({
    required this.encryptedDbKeyBio,
    required this.biometricKey,
    required this.nonce,
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

  /// 修改主密码（校验旧密码后重写 master_auth.json；数据库 Key 不变，
  /// 无需重开连接池）
  Future<void> masterAuthChangePassword(String oldPassword, String newPassword);

  /// 清除主密码（删除 master_auth.json，此后以明文模式打开）
  ///
  /// **调用前必须已完成 [dbMigrateToPlaintext]**，否则加密库无法再打开。
  Future<void> masterAuthClear();

  // ── 加密 ↔ 明文库迁移（设置页安全卡）──

  /// 加密库 → 明文库迁移
  ///
  /// 返回后桥状态被清空，**调用方须重新 [dbInitPlaintext] + 重新订阅事件**
  /// 才能继续操作。
  Future<void> dbMigrateToPlaintext();

  /// 明文库 → 加密库迁移（先 masterAuthInit 持久化 meta，再调用本方法，
  /// 之后 dbInitEncrypted(dbKeyHex) 重开）
  Future<void> dbMigrateToEncrypted(String dbKeyHex);

  // ── 生物识别解锁（密钥链在 Secure Storage，加解密在 Rust）──

  /// 生成 biometric 密钥链三件套（Base64），供写入 Secure Storage
  ///
  /// 调用前提：当前会话已解锁（持有 db_key_hex）且刚通过指纹认证。
  Future<BiometricSecretBundle> biometricSetup(String dbKeyHex);

  /// 指纹认证通过后的解密：三件套 → db_key_hex（与 masterAuthUnlock
  /// 同契约；DB 初始化仍走 dbInitEncrypted 单一路径，BootGate 汇合）
  ///
  /// 密钥链损坏抛 `[biometric_failed]`（UI 引导回密码路径或关闭重开开关）。
  Future<String> biometricUnlock(BiometricSecretBundle bundle);

  /// 关闭前密码确认（防误触）；Rust 仅验证，删除三件套由 Secure Storage 层完成
  Future<void> biometricDisable(String password);

  // ── DB 生命周期 ──

  Future<void> dbInitPlaintext();
  Future<void> dbInitEncrypted(String dbKeyHex);
  Future<bool> dbIsReady();
  Future<void> dbSetDeviceId(String deviceId);

  // ── todo_projects ──

  Future<List<TodoProject>> todoProjectList(ListFilter filter);

  /// 归档项目列表（侧栏归档区；归档切换走 todoProjectUpdate 的
  /// patchJson {"is_archived":0|1}，与桌面同口径无独立命令）
  Future<List<TodoProject>> todoProjectListArchived();
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

  /// 子任务转独立任务（承接父任务 project/priority/due 上下文；返回新任务）
  Future<TodoTask> todoSubtaskPromote(int subtaskId);

  // ── todo_labels / todo_task_labels ──

  Future<List<TodoLabel>> todoLabelList(ListFilter filter);
  Future<TodoLabel> todoLabelCreate(TodoLabelCreateInput input);

  /// 更新标签（patchJson：{"title":…,"hex_color":…}；标签管理页改名/改色）
  Future<TodoLabel> todoLabelUpdate(int id, String patchJson);

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

  // ── 任务列表投影聚合（A4，只读：一次往返替代万行整表 + 前端 join）──

  /// 任务→标签投影（组内按 label id 升序）
  Future<List<TaskLabelsProjection>> taskLabelsProjection();

  /// 任务→提醒投影（组内按 remind_at 升序）
  Future<List<TaskRemindersProjection>> taskRemindersProjection();

  /// 任务→关联计数旗标（仅出边存活行；Wave 5 的 C7 消费）
  Future<List<TaskDependencyFlags>> taskDependencyFlags();

  // ── 同步配置与执行 ──

  /// 当前同步配置；未配置时返回 null
  Future<SyncConfigView?> syncConfigGet();
  Future<SyncConfigView> syncConfigSave(Map<String, Object?> input);

  /// 立即同步（pull_then_push），返回结果摘要
  Future<SyncResultJson> cloudSyncNow({String origin = 'manual'});

  /// 仅推送（修改后立即同步场景）
  Future<SyncResultJson> cloudSyncPushOnly({String origin = 'manual'});

  /// 先拉后推（启动/生命周期场景）
  Future<SyncResultJson> cloudSyncPullThenPush({String origin = 'manual'});

  Future<bool> cloudSyncIsRunning();

  /// 增量同步历史（scope：all | incremental | push_only | pull_only；
  /// 只读聚合，设置页「同步历史」卡数据源）
  Future<List<SyncHistoryRow>> cloudSyncHistory(
      {String scope = 'all', int limit = 20});

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

  // ── 任务活动日志（详情页「历史」区块：只读轨迹）──

  /// 单任务活动历史（时间倒序；limit 缺省 30、上限 100 由 core 收口）
  Future<List<ActivityLogRow>> taskActivityList(int taskId, {int? limit});

  // ── 数据库维护（性能批次：WAL checkpoint / 附件 GC / 查询统计 / VACUUM）──

  /// 一键数据库维护：回收 WAL 日志与磁盘碎片、清理无引用附件、更新查询统计。
  /// 只读维护路径：不触发 db-change、不触碰同步数据。
  Future<DbMaintenanceResult> dbMaintenance();

  // ── 保存的筛选器（#35：Apple Smart List 同款）──

  /// 列出全部保存的筛选器
  Future<List<TodoSavedFilter>> savedFiltersList();

  /// 创建保存的筛选器（条件 JSON 白名单键校验在后端）
  Future<TodoSavedFilter> savedFilterCreate(
      String name, String conditions);

  /// 更新保存的筛选器（可视化构建抽屉的「保存修改」路径）
  Future<TodoSavedFilter> savedFilterUpdate(
      int id, String name, String conditions);

  /// 删除保存的筛选器（软删）
  Future<void> savedFilterDelete(int id);

  // ── 冲突败方副本（03 文档 §八 遗留项：查看 / 恢复 / 忽略 / 清空）──

  /// 列出冲突记录（[resolution] 为 null 时返回全部；按时间倒序分页）
  Future<List<SyncConflict>> syncConflictList(
      String? resolution, int limit, int offset);

  /// 统计冲突记录数（传 'unresolved' 只要待处理）
  Future<int> syncConflictCount(String? resolution);

  /// 恢复某条冲突的败方内容（发起一次新的本地写入，返回被写回的原行 id）
  Future<int> syncConflictRestore(int id);

  /// 忽略某条冲突（不改业务数据）
  Future<void> syncConflictDismiss(int id);

  /// 清空冲突记录（[resolution] 为 null 时清全部），返回删除条数
  Future<int> syncConflictClear(String? resolution);

  // ── 任务模板（竞品矩阵高价值缺口：Vikunja Templates 同款）──

  /// 列出全部任务模板
  Future<List<TodoTemplate>> templatesList();

  /// 创建任务模板（payload JSON 白名单键校验在后端）
  Future<TodoTemplate> templateCreate(String name, String payload);

  /// 更新任务模板（模板管理页编辑）
  Future<TodoTemplate> templateUpdate(int id, String name, String payload);

  /// 删除任务模板（软删）
  Future<void> templateDelete(int id);

  // ── Android 桌面小组件（#3：快照查询 + 勾选落库）──

  /// 拉小组件快照：今天截止或已逾期的未完成任务（优先级降序）
  Future<List<WidgetTodoItem>> widgetTodoQuery(int limit);

  /// 小组件勾选切换（done=1 完成 / 0 取消；完成复用 complete 全语义）
  Future<void> widgetTodoToggle(int id, int done);

  // ── ICS 日历导出（#4：VTODO 日历，日历软件导入/订阅）──

  /// 导出全部任务为 ICS；返回内容与统计
  Future<IcsExportView> icsExport();

  // ── 同步加密（恢复流程用）──

  Future<SyncCryptoStatus> syncCryptoStatus();

  /// 首次设置同步密码（v2：同密码跨设备派生同一 Key；移动端 remember 仅进程内缓存）
  Future<void> syncCryptoInit(String password, {bool remember = false});
  Future<void> syncCryptoUnlock(String password, {bool remember = false});

  /// 锁定：清除内存中的 Data Key（下次同步前需解锁）
  Future<void> syncCryptoLock();
  Future<String> syncCryptoImportBundle(
    SyncCryptoBundle bundle,
    String password, {
    bool force = false,
  });

  /// 本机密钥方案版本（"v1" | "v2"；未设置密码为 null）
  Future<String?> syncCryptoMetaVersion();

  /// v1→v2 迁移：同密码确定性派生 + 云端全量重传（危险操作，UI 二次确认）
  Future<void> syncCryptoUpgradeV2(String password);

  /// 以本机为准重置云端：当前 Data Key 全量重加密覆盖（危险操作，UI 二次确认）
  Future<String> cloudSyncRekey();

  /// 修改同步密码（v2 下即换 Key，内部编排云端全量重传；失败回滚本机密码）
  Future<void> syncCryptoChangePassword(String oldPassword, String newPassword);

  /// 导出密钥包（JSON 字符串；跨设备分发 Data Key 的本地侧载体）
  Future<String> syncCryptoExportBundle();

  /// 启动静默恢复会话（尝试用缓存同步密码解锁）
  ///
  /// 移动端无持久凭据库（会话密码随 lock 清除），除「本就已解锁」外恒为 false，
  /// Dart 侧应引导用户手动输入。
  Future<bool> syncCryptoRestoreSession();

  /// 忘记本机同步密码（清除会话缓存与引擎挂载，云数据与 crypto meta 不动）
  Future<void> syncCryptoForgetSession();

  // ── 全量备份与恢复（.orfullsync；数据安全兜底）──

  /// 导出全量加密备份到本机备份目录；[uploadCloud] 时额外上传云端副本
  ///
  /// 手动导出不受自动备份偏好开关约束。密码复用已解锁的同步加密会话，
  /// 未解锁时抛 `[unlocked]` 类错误——UI 应先引导解锁同步密码。
  Future<BackupExportResult> fullBackupExport({bool uploadCloud = false});

  /// 从备份字节全量覆盖恢复（bytes 由 file_picker 读得）
  ///
  /// 警示：会清空当前业务表再写入备份内容（事务内原子）。成功后广播
  /// db-change（table="*"）触发全量刷新。[ignoreSchemaMismatch] 用于
  /// schema 不一致时的强制二次确认。
  Future<BackupImportResult> fullBackupImport(
    List<int> bytes, {
    bool ignoreSchemaMismatch = false,
  });

  /// 从云端备份副本恢复（先下载字节，再走与本地一致的导入路径）
  Future<BackupImportResult> fullBackupRestoreCloud(
    String cloudPath, {
    bool ignoreSchemaMismatch = false,
  });

  /// 本地备份文件列表（最新在前）
  Future<List<BackupEntry>> fullBackupListLocal();

  /// 删除单个本地备份文件
  Future<void> fullBackupDeleteLocal(String filePath);

  /// 云端备份副本列表（最新在前；未配置云同步时抛 [config]）
  Future<List<CloudBackupEntry>> fullBackupListCloud();

  /// 本地备份恢复预览（解密 + 前 10 条任务抽样 + 统计，不写库）
  Future<BackupPreview> fullBackupPeekLocal(List<int> bytes);

  /// 云端备份恢复预览（先下载字节，再走与本地一致的预览路径，不写库）
  Future<BackupPreview> fullBackupPeekCloud(String cloudPath);

  /// 当前设备 ID（导出预览展示）
  Future<BackupDeviceInfo> fullBackupDeviceInfo();

  /// 读取自动备份偏好（无记录时返回默认值：调度关闭、本地/云端开关开）
  Future<BackupPrefs> backupPrefsGet();

  /// 保存自动备份偏好（校验调度配置；返回回填 nextBackupAt 后的完整偏好）
  Future<BackupPrefs> backupPrefsSave(BackupPrefs prefs);

  /// 启动自动备份调度守护（幂等；DB 就绪后由 BootGate 调一次——
  /// 每日按档位触发 + 错过时刻下次启动首轮补备 + 未解锁同步密码时静默跳过）
  Future<void> startBackupScheduler();

  // ── 通知历史（本地呈现轨迹，不进同步白名单）──

  /// 通知历史列表（时间倒序；[kind] 为 null 时返回全部，limit 默认 50 上限 200）
  Future<List<NotificationLogRow>> notificationLogList({
    String? kind,
    int? limit,
  });

  /// 清空通知历史，返回删除行数
  Future<int> notificationLogClear();

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

  /// 一次性统计聚合（year 为热力图年份；null = 当前年滚动 365 天窗口，
  /// 2026-09-10 对齐 wait-home——当前年滚动 365 天、历史年完整年）
  Future<StatsAggregate> statsAggregate({int? year});

  // ── 全局搜索（backlog #26：任务/项目/评论三路聚合）──

  /// 全局搜索（空关键词返回空结果；limit 默认 20）
  Future<GlobalSearchResult> globalSearch(String keyword, {int? limit});

  // ── 事件流（下行通道，替代 Tauri event listen）──

  /// 本地写操作事件 → 全量失效业务缓存
  Stream<DbChangeEvent> get dbChanges;

  /// 提醒到期事件 → 本地通知 + 重复提醒排程
  Stream<ReminderDueEvent> get reminderDue;
}
