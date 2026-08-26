import 'dart:convert';

/// 数据传输对象（DTO）
///
/// 与 crates/orbit_core serde 模型字段一一对应，snake_case 直传；
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
  final int? endDate;
  final int repeatAfter;
  final int repeatMode;
  final String hexColor;
  final double percentDone;
  final double position;
  final int isFavorite;
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
    required this.endDate,
    required this.repeatAfter,
    required this.repeatMode,
    required this.hexColor,
    required this.percentDone,
    required this.position,
    required this.isFavorite,
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
        endDate: j['end_date'] as int?,
        repeatAfter: j['repeat_after'] as int,
        repeatMode: j['repeat_mode'] as int,
        hexColor: j['hex_color'] as String,
        percentDone: (j['percent_done'] as num).toDouble(),
        position: (j['position'] as num).toDouble(),
        isFavorite: j['is_favorite'] as int,
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
  final int? endDate;
  final int? repeatAfter;
  final int? repeatMode;
  final String? hexColor;
  final double? position;
  final int? isFavorite;

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
    this.endDate,
    this.repeatAfter,
    this.repeatMode,
    this.hexColor,
    this.position,
    this.isFavorite,
  });
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
      );
}

class TodoReminderCreateInput {
  final int taskId;
  final int remindAt;

  const TodoReminderCreateInput({required this.taskId, required this.remindAt});
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
    required super.endDate,
    required super.repeatAfter,
    required super.repeatMode,
    required super.hexColor,
    required super.percentDone,
    required super.position,
    required super.isFavorite,
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
        endDate: j['end_date'] as int?,
        repeatAfter: j['repeat_after'] as int,
        repeatMode: j['repeat_mode'] as int,
        hexColor: j['hex_color'] as String,
        percentDone: (j['percent_done'] as num).toDouble(),
        position: (j['position'] as num).toDouble(),
        isFavorite: j['is_favorite'] as int,
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

  const SyncResultJson({
    required this.pushedModules,
    required this.pulledModules,
    required this.uploadedAttachments,
    required this.downloadedAttachments,
    required this.durationMs,
    required this.skipped,
    required this.errors,
  });

  factory SyncResultJson.fromJson(Map<String, dynamic> j) => SyncResultJson(
        pushedModules: j['pushed_modules'] as int,
        pulledModules: j['pulled_modules'] as int,
        uploadedAttachments: j['uploaded_attachments'] as int,
        downloadedAttachments: j['downloaded_attachments'] as int,
        durationMs: j['duration_ms'] as int,
        skipped: j['skipped'] as bool,
        errors: (j['errors'] as List).cast<String>(),
      );
}
