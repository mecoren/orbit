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

  /// 活动日志 TTL 清理的行数
  final int logRowsPruned;

  /// VACUUM 前空闲页数（碎片页）
  final int freelistBefore;

  /// VACUUM 后空闲页数（应为 0）
  final int freelistAfter;

  /// VACUUM 实际回收的页数
  final int pagesReclaimed;

  const DbMaintenanceResult({
    required this.walBytesAfterCheckpoint,
    required this.attachmentsCleaned,
    required this.logRowsPruned,
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

/// 导入限额（FRB ImportLimitsView 镜像）：选文件后先比对大小，超限即拦，
/// 不把整份内容读进内存再拒绝。上限单一来源在 orbit-core。
class ImportLimits {
  /// 单文件字节上限
  final int maxBytes;

  /// 单文件数据行上限
  final int maxRows;

  const ImportLimits({required this.maxBytes, required this.maxRows});
}

/// 可取消导入任务状态（FRB ImportJobStatusView 镜像；UI 轮询用）
class ImportJobStatus {
  final String jobId;

  /// 已处理行数（含跳过/失败）
  final int processed;

  /// 预计总行数（启动前已数过）
  final int? total;

  final bool finished;
  final bool cancelled;

  /// 结束时的统计（未结束为 null）
  final CsvImportStats? stats;

  /// 结束时的错误说明
  final String? error;

  const ImportJobStatus({
    required this.jobId,
    required this.processed,
    required this.total,
    required this.finished,
    required this.cancelled,
    required this.stats,
    required this.error,
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

  // ── 项目回顾节奏（F1；判定真值在 core，nowMs 由调用方传本地毫秒） ──

  /// 待回顾项目清单（回顾中心/侧栏徽标共用）
  Future<List<ProjectReviewStatus>> todoProjectsDueForReview(int nowMs);

  /// 标记项目已回顾（下次到期 = 今天 + 周期；顺带清空暂缓）
  Future<TodoProject> todoProjectMarkReviewed(int projectId);

  /// 设置项目回顾周期（days null/≤0 = 关闭；开启时从未回顾过则从现在起算）
  Future<TodoProject> todoProjectSetReviewInterval(int projectId, int? days);

  /// 暂缓项目回顾 days 天（不重置周期）
  Future<TodoProject> todoProjectSnoozeReview(int projectId, int days, int nowMs);

  // ── 日排程（F3 阶段一只读预览） ──

  /// 规划今天：只读排程预览（不写库；nowMs 由调用方传本地毫秒）
  Future<DayPlan> dayPlanPreview(DayPlanPrefs prefs, int nowMs);

  /// 应用排程（阶段二）：写 my_day_date + start_date（不改 due_date，单事务）；
  /// 返回 prev 快照供撤销写回
  Future<ApplyResult> dayPlanApply(int dayStartMs, List<ApplySlotInput> slots);

  /// 读取排程偏好（cfg_kv，缺键回落默认；编辑抽屉初值）
  Future<DayPlanPrefs> dayPlanPrefsGet();

  /// 保存排程偏好（校验钳制后落库，返回存后生效值供 UI 回显）
  Future<DayPlanPrefs> dayPlanPrefsSet(DayPlanPrefs prefs);

  // ── todo_tasks ──

  Future<List<TodoTask>> todoTaskList(ListFilter filter);

  /// 任务键集分页（P1 50k 规模档）：列表窗口化的唯一读通道。
  ///
  /// `cursor` 为上一页返回值，首页传 null；`limit` 由 Rust 钳制到 1..=1000。
  /// 换排序档后沿用旧游标返回空页（UI 竞态自愈）。
  Future<TodoTaskPage> todoTaskPage(ListFilter filter, ListCursor? cursor, int limit);

  /// 任务总览：总数（「已加载 X / 共 Y」）+ 按项目未完成计数（侧栏角标）
  Future<TodoTaskOverview> todoTaskOverview(ListFilter filter);

  /// 看板/四象限窗口化（对齐桌面 `todo_tasks_board`）：每列前
  /// [limitPerGroup] 条 + 每列总数（不受上限影响）。
  ///
  /// [dayStart]/[dayEnd] 由 Dart 侧按本地时区算好传入——due 五分桶与
  /// 四象限「今天以内到期 = 紧急」的界不在 Rust 侧重算。
  Future<TodoTaskBoardResult> todoTaskBoard(
    ListFilter filter,
    TodoBoardGroupBy groupBy,
    int limitPerGroup,
    int dayStart,
    int dayEnd,
  );

  Future<TodoTask> todoTaskGet(int id);
  Future<TodoTask> todoTaskCreate(TodoTaskCreateInput input);
  Future<TodoTask> todoTaskUpdate(int id, String patchJson);
  Future<void> todoTaskDelete(int id);
  Future<void> todoTaskUpdatePosition(int id, int position);

  /// 统一完成任务：普通标记 / 重复任务单事务推进下一实例
  /// （引擎下沉 orbit-core，与桌面同一 Rust 入口；返回完成后的任务，
  /// nextInstance 供 UI 弹「已生成下一期」提示）
  Future<CompleteTaskResult> todoTaskComplete(int id);

  /// 一键复制任务（#37：克隆字段+子任务，副本标题后缀）
  Future<TodoTask> todoTaskDuplicate(int id);

  /// 详情聚合：任务 + 子任务 + 标签 + 评论 + 关联 + 提醒
  Future<TodoTaskDetail> todoTaskGetDetail(int id);

  /// 重算任务进度（子任务变更后手动触发，对齐桌面 todo_tasks_recalc_percent）
  Future<void> todoTaskRecalcPercent(int taskId);

  /// 按 uuid 获取项目（同步引擎定位远端记录，对齐桌面 todo_projects_get_by_uuid）
  Future<TodoProject?> todoProjectGetByUuid(String uuid);

  /// 按 uuid 获取任务（对齐桌面 todo_tasks_get_by_uuid）
  Future<TodoTask?> todoTaskGetByUuid(String uuid);

  /// 业务表记录数（首页仪表盘计数角标，只读聚合，对齐桌面 business_count）
  Future<int> businessCount(String table);

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
  Future<TodoLabel> todoLabelGet(int id);
  Future<TodoLabel> todoLabelCreate(TodoLabelCreateInput input);

  /// 更新标签（patchJson：{"title":…,"hex_color":…}；标签管理页改名/改色）
  Future<TodoLabel> todoLabelUpdate(int id, String patchJson);

  Future<void> todoLabelDelete(int id);
  Future<TaskLabelWithId> todoTaskLabelCreate(TodoTaskLabelCreateInput input);
  Future<TaskLabelWithId> todoTaskLabelGet(int id);
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

  /// 任务→「有描述」投影（只出 description 非空串的存活行；行内描述图标消费）
  Future<List<TaskDescriptionFlag>> taskDescriptionFlags();

  /// 任务→「有附件」旗标（#71 筛选器 has_attachment 数据源）
  Future<List<TaskExistenceFlag>> taskAttachmentFlags();

  /// 任务→「有未完成子任务」旗标（#71 筛选器 has_open_subtask 数据源）
  Future<List<TaskExistenceFlag>> taskOpenSubtaskFlags();

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

  /// 强制同步（进入/退出应用专用，对齐桌面 cloud_sync_force；
  /// 不检查自动开关/间隔，忙时最多等待 [waitForIdleMs] 毫秒）
  Future<SyncResultJson> cloudSyncForce(
      {String origin = 'manual', int waitForIdleMs = 3000});

  /// 桥接探活（对齐桌面 ping；验证 Dart → Rust → orbit_core 通路）
  Future<String> ping();

  /// SHA-256 哈希 hex（对齐桌面 crypto_sha256）
  Future<String> cryptoSha256(String input);

  /// 密码学安全随机 hex（对齐桌面 crypto_random_hex；[len] 为字节数）
  Future<String> cryptoRandomHex(int len);

  /// 增量同步历史（scope：all | incremental | push_only | pull_only；
  /// 只读聚合，设置页「同步历史」卡数据源）
  Future<List<SyncHistoryRow>> cloudSyncHistory(
      {String scope = 'all', int limit = 20});

  /// 本地同步账本（`sync_state.json`：桶指纹 + 水位线 + 设备/epoch；
  /// 只读诊断，设置页「同步账本」卡数据源；未配置云同步时不报错，返回空账本）
  Future<SyncStateView> cloudSyncGetState();

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

  /// 导入限额（字节 / 行数）：选文件后先比对大小，超限即拦
  Future<ImportLimits> csvImportLimits();

  /// 预览导入（不写库）：解析 + 映射 + 统计
  Future<CsvImportPreview> csvImportPreview(String content, String preset, int previewLimit);
  /// 执行导入（写库）：项目自动创建、逐行独立成败
  Future<CsvImportStats> csvImportExecute(String content, String preset);

  /// 启动可取消导入：同步预检限额后返回 job_id（后台执行）
  Future<String> csvImportJobStart(String content, String preset);

  /// 轮询导入任务状态（processed / total / finished / cancelled / stats）
  Future<ImportJobStatus> csvImportJobStatus(String jobId);

  /// 请求取消导入（行边界生效；已写入的行保留）
  Future<void> csvImportJobCancel(String jobId);

  /// 释放任务条目（拿到终态后调用，避免任务表滞留）
  Future<void> csvImportJobDrop(String jobId);

  // ── 任务附件（内容寻址：上传/列表/读取/卸下）──

  /// 上传并挂载附件（内存已有字节的来源：拍照/分享；单任务 20 个/单文件 50MB）
  Future<TaskAttachmentView> taskAttachmentAdd(
      int taskId, String fileName, String mimeType, List<int> data);

  /// 从本地文件路径挂载附件（文件选择器主路径）
  ///
  /// 不经 Dart 读整份字节：core 按 256KiB 块流式读盘并算 SHA-256，调用方峰值
  /// 与文件大小无关。`sourcePath` 为 file_picker 返回的临时路径。
  Future<TaskAttachmentView> taskAttachmentAddPath(
      int taskId, String fileName, String mimeType, String sourcePath);

  /// 任务附件列表（含 isLocalCached 状态）
  Future<List<TaskAttachmentView>> taskAttachmentsList(int taskId);

  /// 读取附件本地字节（未缓存时抛 NotFound）
  Future<List<int>> taskAttachmentRead(String hash);

  /// 卸下附件（软删关联，孤儿二进制由 GC 清）
  Future<void> taskAttachmentRemove(int linkId);

  // ── 云端孤儿附件清理（docs/15；需已配置云同步且密钥已解锁）──

  /// 扫描云端孤儿附件（只读）
  ///
  /// 判据 = 云端对象集 − 云端引用集（`todo_task_attachments` 云端分桶
  /// `is_deleted = 0` 的行），只列 30 天前、且服务端提供 mtime 的对象。
  Future<CloudUnusedScanResult> cloudUnusedAttachmentsScan();

  /// 删除云端孤儿附件（整包 + 分片，成功后本地账本按无引用复核收尾）
  ///
  /// [expectedEpoch] 原样回传扫描结果的 epoch：云端刚有他端 push 时
  /// [CloudUnusedDeleteResult.staleManifest] 为 true 且一个对象都不删，
  /// 调用方须提示重新扫描。
  Future<CloudUnusedDeleteResult> cloudUnusedAttachmentsDelete({
    required List<String> hashes,
    required int expectedEpoch,
  });

  // ── 任务活动日志（详情页「历史」区块：只读轨迹）──

  /// 单任务活动历史（时间倒序；limit 缺省 30、上限 100 由 core 收口）
  Future<List<ActivityLogRow>> taskActivityList(int taskId, {int? limit});

  // ── 数据库维护（性能批次：WAL checkpoint / 附件 GC / 查询统计 / VACUUM）──

  /// 一键数据库维护：回收 WAL 日志与磁盘碎片、清理无引用附件、更新查询统计。
  /// 只读维护路径：不触发 db-change、不触碰同步数据。
  ///
  /// 设置页「立即维护」用，含 VACUUM（整库重写）。**不要放进启动路径**——见
  /// [dbMaintenanceRoutine] 的实测口径。
  Future<DbMaintenanceResult> dbMaintenance();

  /// 启动轻维护：WAL checkpoint → 附件 GC → 缓存上限 → 日志 TTL → 统计（仅缺失时）。
  ///
  /// 与 [dbMaintenance] 的唯一差别是不做 VACUUM：前四步都是「不跑就会无界增长」
  /// 且成本与库体积无关；VACUUM 的成本却与库体积成正比、收益只与空闲页成正比
  /// （50k 稳态实测 332～429ms 换回 0 字节），故只归手动入口。
  Future<DbMaintenanceResult> dbMaintenanceRoutine();

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
  ///
  /// 从 `.orfullsync` 字节全量覆盖恢复（整包过桥；小文件或已持有字节时用）。
  Future<BackupImportResult> fullBackupImport(
    List<int> bytes, {
    bool ignoreSchemaMismatch = false,
  });

  /// 从**文件路径**全量覆盖恢复（推荐：不再把整包字节跨 FFI 搬运）
  ///
  /// v2 容器在 core 内逐帧流式读，峰值与备份体积无关；v1 因格式所限仍需
  /// 整份读入（core 内部处理，不过桥）。
  Future<BackupImportResult> fullBackupImportPath(
    String filePath, {
    bool ignoreSchemaMismatch = false,
  });

  /// 从**文件路径**读取恢复预览（推荐；与 [fullBackupPeekLocal] 同语义）
  Future<BackupPreview> fullBackupPeekPath(String filePath);

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

  // ── 应用内诊断（只读读数，不进同步白名单）──

  /// 采集诊断快照（库体积 / 各表活行数 / 墓碑行数 / 附件缓存占用）
  Future<DiagnosticsSnapshot> diagnosticsSnapshot();

  // ── 测试数据（仅 debug 构建；设置页入口由 kDebugMode 门禁，Rust 侧再拒一次）──

  /// 一键生成示例数据（先按 uuid 前缀清上一批，不碰手工数据）
  Future<DevSeedResult> devSeedDemoData(DevSeedPlan plan);

  /// 清除示例数据（按 uuid 前缀物理删除）
  Future<DevSeedClearResult> devSeedClear();

  // ── 节假日数据（日历视图联网更新；cfg_holidays 本地缓存）──

  /// 全部节假日（date 升序；空库回落预置 2026 表，冷启动可用）
  Future<List<HolidayInfo>> holidayList();

  /// 判定某日期：true 放假 / false 调休补班 / null 普通日
  Future<bool?> holidayIsOn(String date);

  /// 手动更新（强制拉取；失败抛错误文案，旧缓存保留）
  Future<HolidayMeta> holidayUpdate();

  /// 按单年补写（年份需在 2013 ~ 明年；整年替换，历史年份不写自动更新记账）
  ///
  /// 返回记账 + 该年实际行数（`rowCount == 0` = 该年线上无数据，UI 据此提示）
  Future<HolidayYearOutcome> holidayFetchYear(int year);

  /// 按年份范围补写（分片并发 + 熔断；进度经 [holidayProgress] 回传）
  Future<HolidayRangeSummary> holidayFetchRange(int start, int end);

  /// 请求取消进行中的范围补写（幂等；无进行中操作时无害）
  Future<void> holidayCancelFetch();

  /// 更新记账（上次成功/尝试、连续失败次数、自动更新总开关）
  Future<HolidayMeta> holidayMeta();

  /// 设置自动更新总开关（关闭后调度器不再联网，仅保留手动与按年补写）
  Future<void> holidaySetAutoEnabled(bool enabled);

  /// 范围补写进度流（每次订阅新建一条；取消订阅后 core 侧自行退出）
  Stream<HolidayProgress> get holidayProgress;

  /// 启动自动更新守护（幂等；DB 就绪后由 BootGate 调一次——
  /// 每月一次更新 + 跨月后下次启动首轮补更 + 总开关关闭时静默跳过）
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

  // ── 每日摘要提醒（G3：每日固定时刻汇总通知，对标 TickTick Daily Reminder）──

  /// 读摘要偏好（开关 + 目标时刻；cfg_kv 本机设置）
  Future<DigestPrefs> digestPrefs();

  /// 设置摘要偏好（hour 0–23 / minute 0–59，越界抛错）
  Future<void> digestSetPrefs({
    required bool enabled,
    required int hour,
    required int minute,
  });

  /// 当前时刻摘要计数（设置页预览；只读）
  Future<DigestSummary> digestSummary();

  /// 摘要通知文案（Rust 侧 summary_body 单一真相源；排程时取一次作正文）
  Future<String> digestBody();

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
