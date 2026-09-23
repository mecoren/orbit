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

  const ListFilter({this.keyword, this.page = 1, this.pageSize = 500});

  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'page': page,
        'page_size': pageSize,
      };
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
        isArchived: (j['is_archived'] as int?) ?? 0,
        isDeleted: j['is_deleted'] as int,
        createdAt: j['created_at'] as int,
        updatedAt: j['updated_at'] as int,
        deletedAt: j['deleted_at'] as int?,
        version: j['version'] as int,
      );
}

class TodoProjectCreateInput {
  final String title;
  final String? description;
  final String? hexColor;
  final double? sortOrder;

  const TodoProjectCreateInput({
    required this.title,
    this.description,
    this.hexColor,
    this.sortOrder,
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
  final double percentDone;
  final double position;
  final int isFavorite;
  /// 我的一天：加入当天本地零点 ms；null = 不在任何一天的 My Day
  final int? myDayDate;
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
    required this.percentDone,
    required this.position,
    required this.isFavorite,
    required this.myDayDate,
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
  });

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
        percentDone: (j['percent_done'] as num).toDouble(),
        position: (j['position'] as num).toDouble(),
        isFavorite: j['is_favorite'] as int,
        myDayDate: j['my_day_date'] as int?,
        isDeleted: j['is_deleted'] as int,
        createdAt: j['created_at'] as int,
        updatedAt: j['updated_at'] as int,
        deletedAt: j['deleted_at'] as int?,
        version: j['version'] as int,
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
    final zero = DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;
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
  final double? position;
  final int? isFavorite;
  final int? myDayDate;

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
    this.position,
    this.isFavorite,
    this.myDayDate,
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

  const TodoSubtaskCreateInput({
    required this.taskId,
    required this.title,
    this.position,
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

  factory TaskLabelWithId.fromJson(Map<String, dynamic> j) =>
      TaskLabelWithId(
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

  factory TodoTaskRelation.fromJson(Map<String, dynamic> j) =>
      TodoTaskRelation(
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
    required this.isDeleted,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.version,
    this.reminderTitle,
  });

  factory TodoReminder.fromJson(Map<String, dynamic> j) => TodoReminder(
        id: j['id'] as int,
        uuid: j['uuid'] as String,
        taskId: j['task_id'] as int,
        remindAt: j['remind_at'] as int,
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

  const TodoReminderCreateInput({required this.taskId, required this.remindAt});
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

  factory ProjectedReminder.fromJson(Map<String, dynamic> j) => ProjectedReminder(
        id: j['id'] as int,
        remindAt: j['remind_at'] as int,
      );
}

/// 单任务的提醒分组（组内按 remind_at 升序）
class TaskRemindersProjection {
  final int taskId;
  final List<ProjectedReminder> reminders;

  const TaskRemindersProjection({required this.taskId, required this.reminders});

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

  const TaskDependencyFlags({required this.taskId, required this.relationCount});

  factory TaskDependencyFlags.fromJson(Map<String, dynamic> j) =>
      TaskDependencyFlags(
        taskId: j['task_id'] as int,
        relationCount: j['relation_count'] as int,
      );
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
    required super.percentDone,
    required super.position,
    required super.isFavorite,
    required super.myDayDate,
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
        percentDone: (j['percent_done'] as num).toDouble(),
        position: (j['position'] as num).toDouble(),
        isFavorite: j['is_favorite'] as int,
        myDayDate: j['my_day_date'] as int?,
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

  factory SyncCryptoStatus.fromJson(Map<String, dynamic> j) =>
      SyncCryptoStatus(
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

  factory SyncCryptoBundle.fromJson(Map<String, dynamic> j) =>
      SyncCryptoBundle(
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
        changedTables:
            (j['changed_tables'] as List?)?.cast<String>() ?? const [],
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

/// 节假日更新记账（上次更新时间/失败次数/固定时刻；日历工具栏展示用）
class HolidayMeta {
  /// 上次成功更新（ms；0 = 从未成功）
  final int lastUpdateMs;

  /// 上次尝试（ms；0 = 从未尝试）
  final int lastAttemptMs;

  /// 连续失败次数（成功后清零）
  final int failureCount;

  /// 每日固定更新时刻（本地时区小时 0-23；默认 8）
  final int fixedHour;

  const HolidayMeta({
    required this.lastUpdateMs,
    required this.lastAttemptMs,
    required this.failureCount,
    required this.fixedHour,
  });
}

/// 回收站元数据（回收站页 + 设置页保留档位；FRB trash.rs 镜像）
class TrashMeta {
  /// 保留天数（0 = 永久；默认 30，档位 7/30/90/0）
  final int retentionDays;

  /// 上次 TTL 自动清理时间（ms；0 = 从未执行）
  final int lastPurgeMs;

  const TrashMeta({
    required this.retentionDays,
    required this.lastPurgeMs,
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
  int get totalRecords =>
      tableCounts.fold(0, (sum, e) => sum + e.count);
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
  }) =>
      BackupPrefs(
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

  /// sync_now / push_only / pull_then_push
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
      out['$k'] = {
        for (final e in v.entries) '${e.key}': '${e.value}',
      };
    });
    return out;
  }
}
