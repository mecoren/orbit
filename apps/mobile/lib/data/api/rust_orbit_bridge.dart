import 'dart:async';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';

import '../../src/rust/api/dto.dart' as gen;
import '../../src/rust/api/csv_import.dart' as gen_import;
import '../../src/rust/api/asset.dart' as gen_asset;
import '../../src/rust/api/holiday.dart' as gen_holiday;
import '../../src/rust/api/events.dart' as gen_events;
import '../../src/rust/api/plaintext_export.dart' as gen_export;
import '../../src/rust/api/sync.dart' as gen_sync;
import '../../src/rust/api/auth.dart' as gen_auth;
import '../../src/rust/api/todo.dart' as gen_todo;
import '../../src/rust/api/trash.dart' as gen_trash;
import '../../src/rust/api/stats.dart' as gen_stats;
import '../../src/rust/api/search.dart' as gen_search;
import '../../src/rust/frb_generated.dart' show RustLib;
import 'dto.dart';
import 'orbit_bridge.dart';

/// 真实 Rust 桥（FRB codegen 包装）
///
/// 职责：领域 DTO ↔ FRB 生成类型 的边界映射 + base_dir 注入。
/// UI 层不感知本类存在（经 orbitBridgeProvider 注入）。
class RustOrbitBridge implements OrbitBridge {
  RustOrbitBridge();

  String? _baseDir;

  /// 应用数据目录（懒加载；Android = getApplicationSupportDirectory）
  Future<String> _dir() async {
    final cached = _baseDir;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    _baseDir = dir.path;
    return _baseDir!;
  }

  // ── 主密码认证 ──

  @override
  Future<bool> masterAuthHas() async =>
      gen_auth.masterAuthHas(baseDir: await _dir());

  @override
  Future<String> masterAuthInit(String password) async =>
      gen_auth.masterAuthInit(baseDir: await _dir(), password: password);

  @override
  Future<String> masterAuthUnlock(String password) async =>
      gen_auth.masterAuthUnlock(baseDir: await _dir(), password: password);

  @override
  Future<bool> masterAuthVerify(String password) async =>
      gen_auth.masterAuthVerify(baseDir: await _dir(), password: password);

  // ── DB 生命周期 ──

  @override
  Future<void> dbInitPlaintext() async =>
      gen_auth.dbInitPlaintext(baseDir: await _dir());

  @override
  Future<void> dbInitEncrypted(String dbKeyHex) async =>
      gen_auth.dbInitEncrypted(baseDir: await _dir(), dbKeyHex: dbKeyHex);

  @override
  Future<bool> dbIsReady() => gen_auth.dbIsReady();

  @override
  Future<void> dbSetDeviceId(String deviceId) =>
      gen_auth.dbSetDeviceId(deviceId: deviceId);

  // ── todo_projects ──

  @override
  Future<List<TodoProject>> todoProjectList(ListFilter filter) async =>
      (await gen_todo.todoProjectsList(filter: _genFilter(filter)))
          .map(_mapProject)
          .toList();

  @override
  Future<TodoProject> todoProjectGet(int id) async =>
      _mapProject(await gen_todo.todoProjectsGet(id: id));

  @override
  Future<TodoProject> todoProjectCreate(TodoProjectCreateInput input) async =>
      _mapProject(await gen_todo.todoProjectsCreate(
        input: gen.TodoProjectCreateInput(
          title: input.title,
          description: input.description,
          hexColor: input.hexColor,
          sortOrder: input.sortOrder,
        ),
      ));

  @override
  Future<TodoProject> todoProjectUpdate(int id, String patchJson) async =>
      _mapProject(await gen_todo.todoProjectsUpdate(id: id, patchJson: patchJson));

  @override
  Future<void> todoProjectDelete(int id) =>
      gen_todo.todoProjectsDelete(id: id);

  @override
  Future<void> todoProjectUpdateSortOrder(int id, int sortOrder) =>
      gen_todo.todoProjectsUpdateSortOrder(id: id, sortOrder: sortOrder.toDouble());

  // ── todo_tasks ──

  @override
  Future<List<TodoTask>> todoTaskList(ListFilter filter) async =>
      (await gen_todo.todoTasksList(filter: _genFilter(filter)))
          .map(_mapTask)
          .toList();

  @override
  Future<TodoTask> todoTaskGet(int id) async =>
      _mapTask(await gen_todo.todoTasksGet(id: id));

  @override
  Future<TodoTask> todoTaskCreate(TodoTaskCreateInput input) async =>
      _mapTask(await gen_todo.todoTasksCreate(
        input: gen.TodoTaskCreateInput(
          title: input.title,
          description: input.description,
          projectId: input.projectId,
          priority: input.priority,
          status: input.status,
          done: input.done,
          doneAt: input.doneAt,
          dueDate: input.dueDate,
          startDate: input.startDate,
          repeatAfter: input.repeatAfter,
          repeatMode: input.repeatMode,
          repeatWeekdays: input.repeatWeekdays,
          repeatEndType: input.repeatEndType,
          repeatEndParam: input.repeatEndParam,
          repeatFromDone: input.repeatFromDone,
          position: input.position?.toDouble(),
          isFavorite: input.isFavorite,
          myDayDate: input.myDayDate,
        ),
      ));

  @override
  Future<TodoTask> todoTaskUpdate(int id, String patchJson) async =>
      _mapTask(await gen_todo.todoTasksUpdate(id: id, patchJson: patchJson));

  @override
  Future<TodoTask> todoTaskComplete(int id) async =>
      _mapTask((await gen_todo.todoTasksComplete(id: id)).task);

  @override
  Future<void> todoTaskDelete(int id) => gen_todo.todoTasksDelete(id: id);

  @override
  Future<void> todoTaskUpdatePosition(int id, int position) =>
      gen_todo.todoTasksUpdatePosition(id: id, position: position.toDouble());

  @override
  Future<TodoTaskDetail> todoTaskGetDetail(int id) async {
    final d = await gen_todo.todoTasksGetDetail(id: id);
    return TodoTaskDetail(
      id: d.id,
      uuid: d.uuid,
      title: d.title,
      description: d.description,
      projectId: d.projectId,
      priority: d.priority,
      status: d.status,
      done: d.done,
      doneAt: d.doneAt,
      dueDate: d.dueDate,
      startDate: d.startDate,
      repeatAfter: d.repeatAfter,
      repeatMode: d.repeatMode,
      repeatWeekdays: d.repeatWeekdays,
      repeatEndType: d.repeatEndType,
      repeatEndParam: d.repeatEndParam,
      repeatFromDone: d.repeatFromDone,
      percentDone: d.percentDone,
      position: d.position,
      isFavorite: d.isFavorite,
      myDayDate: d.myDayDate,
      isDeleted: d.isDeleted,
      createdAt: d.createdAt,
      updatedAt: d.updatedAt,
      deletedAt: d.deletedAt,
      version: d.version,
      subtasks: d.subtasks.map(_mapSubtask).toList(),
      labels: [
        for (final l in d.labels)
          TaskLabelWithId(
            id: l.id,
            uuid: l.uuid,
            title: l.title,
            hexColor: l.hexColor,
            isDeleted: l.isDeleted,
            createdAt: l.createdAt,
            updatedAt: l.updatedAt,
            deletedAt: l.deletedAt,
            version: l.version,
            taskLabelId: l.taskLabelId,
          ),
      ],
      comments: d.comments.map(_mapComment).toList(),
      relations: d.relations.map(_mapRelation).toList(),
      reminders: d.reminders.map(_mapReminder).toList(),
    );
  }

  // ── todo_subtasks ──

  @override
  Future<List<TodoSubtask>> todoSubtaskList(ListFilter filter) async =>
      (await gen_todo.todoSubtasksList(filter: _genFilter(filter)))
          .map(_mapSubtask)
          .toList();

  @override
  Future<TodoSubtask> todoSubtaskCreate(TodoSubtaskCreateInput input) async =>
      _mapSubtask(await gen_todo.todoSubtasksCreate(
        input: gen.TodoSubtaskCreateInput(
          taskId: input.taskId,
          title: input.title,
          position: input.position?.toDouble(),
        ),
      ));

  @override
  Future<TodoSubtask> todoSubtaskUpdate(int id, String patchJson) async =>
      _mapSubtask(await gen_todo.todoSubtasksUpdate(id: id, patchJson: patchJson));

  @override
  Future<void> todoSubtaskDelete(int id) => gen_todo.todoSubtasksDelete(id: id);

  @override
  Future<void> todoSubtaskToggleDone(int subtaskId, bool done) =>
      gen_todo.todoSubtasksToggleDone(subtaskId: subtaskId, done: done);

  // ── todo_labels / task_labels ──

  @override
  Future<List<TodoLabel>> todoLabelList(ListFilter filter) async =>
      (await gen_todo.todoLabelsList(filter: _genFilter(filter)))
          .map(_mapLabel)
          .toList();

  @override
  Future<TodoLabel> todoLabelCreate(TodoLabelCreateInput input) async =>
      _mapLabel(await gen_todo.todoLabelsCreate(
        input: gen.TodoLabelCreateInput(title: input.title, hexColor: input.hexColor),
      ));

  @override
  Future<void> todoLabelDelete(int id) => gen_todo.todoLabelsDelete(id: id);

  @override
  Future<TaskLabelWithId> todoTaskLabelCreate(TodoTaskLabelCreateInput input) async {
    final link = await gen_todo.todoTaskLabelsCreate(
      input: gen.TodoTaskLabelCreateInput(
        taskId: input.taskId,
        labelId: input.labelId,
      ),
    );
    // 关联行不含标签字段，回查补全（UI 随后刷新详情聚合）
    final labels = await gen_todo.todoLabelsList(
      filter: _genFilter(const ListFilter()),
    );
    final l = labels.firstWhere((x) => x.id == link.labelId);
    return TaskLabelWithId(
      id: l.id,
      uuid: l.uuid,
      title: l.title,
      hexColor: l.hexColor,
      isDeleted: l.isDeleted,
      createdAt: l.createdAt,
      updatedAt: l.updatedAt,
      deletedAt: l.deletedAt,
      version: l.version,
      taskLabelId: link.id,
    );
  }

  @override
  Future<void> todoTaskLabelDelete(int taskLabelId) =>
      gen_todo.todoTaskLabelsDelete(id: taskLabelId);

  // ── todo_comments ──

  @override
  Future<List<TodoComment>> todoCommentList(ListFilter filter) async =>
      (await gen_todo.todoCommentsList(filter: _genFilter(filter)))
          .map(_mapComment)
          .toList();

  @override
  Future<TodoComment> todoCommentCreate(TodoCommentCreateInput input) async =>
      _mapComment(await gen_todo.todoCommentsCreate(
        input: gen.TodoCommentCreateInput(taskId: input.taskId, content: input.content),
      ));

  @override
  Future<void> todoCommentDelete(int id) => gen_todo.todoCommentsDelete(id: id);

  // ── todo_task_relations ──

  @override
  Future<List<TodoTaskRelation>> todoTaskRelationList(ListFilter filter) async =>
      (await gen_todo.todoTaskRelationsList(filter: _genFilter(filter)))
          .map(_mapRelation)
          .toList();

  @override
  Future<TodoTaskRelation> todoTaskRelationCreate(
      TodoTaskRelationCreateInput input) async {
    final r = await gen_todo.todoTaskRelationsCreate(
      input: gen.TodoTaskRelationCreateInput(
        taskId: input.taskId,
        otherTaskId: input.otherTaskId,
        relationType: input.relationType,
      ),
    );
    return TodoTaskRelation(
      id: r.id,
      uuid: r.uuid,
      taskId: r.taskId,
      otherTaskId: r.otherTaskId,
      relationType: r.relationType,
      isDeleted: r.isDeleted,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
      deletedAt: r.deletedAt,
      version: r.version,
    );
  }

  @override
  Future<void> todoTaskRelationDelete(int id) =>
      gen_todo.todoTaskRelationsDelete(id: id);

  // ── todo_reminders ──

  @override
  Future<List<TodoReminder>> todoReminderList(ListFilter filter) async =>
      (await gen_todo.todoRemindersList(filter: _genFilter(filter)))
          .map(_mapReminder)
          .toList();

  @override
  Future<TodoReminder> todoReminderCreate(TodoReminderCreateInput input) async =>
      _mapReminder(await gen_todo.todoRemindersCreate(
        input: gen.TodoReminderCreateInput(
          taskId: input.taskId,
          remindAt: input.remindAt,
        ),
      ));

  @override
  Future<void> todoReminderDelete(int id) => gen_todo.todoRemindersDelete(id: id);

  // ── 同步配置与执行 ──

  @override
  Future<SyncConfigView?> syncConfigGet() async {
    final v = await gen_sync.syncConfigGet();
    if (v == null) return null;
    return SyncConfigView(
      id: v.id,
      engine: v.engine,
      endpoint: v.endpoint,
      bucket: v.bucket,
      region: v.region,
      username: v.username,
      passwordSet: v.passwordSet,
      basePath: v.basePath,
      intervalMinutes: v.intervalMinutes,
      autoSyncEnabled: v.autoSyncEnabled,
      syncOnChange: v.syncOnChange,
      skipTlsVerify: v.skipTlsVerify,
      timeoutSeconds: v.timeoutSeconds,
      lastSyncedAt: v.lastSyncedAt,
    );
  }

  @override
  Future<SyncConfigView> syncConfigSave(Map<String, Object?> input) async {
    final saved = await gen_sync.syncConfigSave(input: _toGenConfigInput(input));
    return SyncConfigView(
      id: saved.id,
      engine: saved.engine,
      endpoint: saved.endpoint,
      bucket: saved.bucket,
      region: saved.region,
      username: saved.username,
      passwordSet: saved.passwordSet,
      basePath: saved.basePath,
      intervalMinutes: saved.intervalMinutes,
      autoSyncEnabled: saved.autoSyncEnabled,
      syncOnChange: saved.syncOnChange,
      skipTlsVerify: saved.skipTlsVerify,
      timeoutSeconds: saved.timeoutSeconds,
      lastSyncedAt: saved.lastSyncedAt,
    );
  }

  @override
  Future<SyncResultJson> cloudSyncNow({String origin = 'manual'}) async =>
      SyncResultJson.fromJson(
        jsonDecode(await gen_sync.cloudSyncNow(origin: origin))
            as Map<String, dynamic>,
      );

  @override
  Future<bool> cloudSyncIsRunning() => gen_sync.cloudSyncIsRunning();

  @override
  Future<int> syncTestConnection(Map<String, Object?> input) async =>
      gen_sync.syncTestConnection(input: _toGenConfigInput(input));

  @override
  Future<void> syncDisconnect() => gen_sync.syncDisconnect();

  // ── 明文数据导出（07 报告 #15）──

  @override
  Future<PlaintextExportResult> plaintextExportJson({bool excludeDeleted = true}) async {
    final r = await gen_export.plaintextExportJson(excludeDeleted: excludeDeleted);
    return PlaintextExportResult(
      content: r.content,
      tableCounts: {
        for (final e in r.tableCounts) e.table: e.count.toInt(),
      },
      suggestedFilename: r.suggestedFilename,
    );
  }

  @override
  Future<PlaintextExportResult> plaintextExportCsv({bool excludeDeleted = true}) async {
    final r = await gen_export.plaintextExportCsv(excludeDeleted: excludeDeleted);
    return PlaintextExportResult(
      content: r.content,
      tableCounts: {
        for (final e in r.tableCounts) e.table: e.count.toInt(),
      },
      suggestedFilename: r.suggestedFilename,
    );
  }

  // ── CSV 导入（迁移路径）──

  @override
  Future<CsvImportPreview> csvImportPreview(
    String content,
    String preset,
    int previewLimit,
  ) async {
    final r = await gen_import.csvImportPreview(
      content: content,
      preset: preset,
      previewLimit: BigInt.from(previewLimit),
    );
    return CsvImportPreview(
      preset: r.preset,
      rows: r.rows
          .map(
            (row) => CsvImportPreviewRow(
              sourceLine: row.sourceLine.toInt(),
              projectTitle: row.projectTitle,
              title: row.input.title,
              priority: row.input.priority?.toInt(),
              done: (row.input.done ?? 0) == 1,
              dueDate: row.input.dueDate?.toInt(),
              skipReason: row.skipReason,
            ),
          )
          .toList(),
      stats: _mapStats(r.stats),
    );
  }

  @override
  Future<CsvImportStats> csvImportExecute(String content, String preset) async {
    final r = await gen_import.csvImportExecute(content: content, preset: preset);
    return _mapStats(r);
  }

  CsvImportStats _mapStats(gen.CsvImportStatsView s) => CsvImportStats(
        success: s.success.toInt(),
        skipped: s.skipped.toInt(),
        failed: s.failed.toInt(),
        notes: s.notes,
      );

  // ── 任务附件（内容寻址）──

  @override
  Future<TaskAttachmentView> taskAttachmentAdd(
      int taskId, String fileName, String mimeType, List<int> data) async {
    final r = await gen_asset.taskAttachmentAdd(
      taskId: taskId,
      fileName: fileName,
      mimeType: mimeType,
      data: data,
    );
    return _mapAttachment(r);
  }

  @override
  Future<List<TaskAttachmentView>> taskAttachmentsList(int taskId) async {
    final rows = await gen_asset.taskAttachmentsList(taskId: taskId);
    return rows.map(_mapAttachment).toList();
  }

  @override
  Future<List<int>> taskAttachmentRead(String hash) async {
    final bytes = await gen_asset.taskAttachmentRead(hash: hash);
    return bytes.toList();
  }

  @override
  Future<void> taskAttachmentRemove(int linkId) =>
      gen_asset.taskAttachmentRemove(linkId: linkId);

  TaskAttachmentView _mapAttachment(gen.TaskAttachmentView r) => TaskAttachmentView(
        linkId: r.linkId.toInt(),
        linkUuid: r.linkUuid,
        hash: r.hash,
        originalName: r.originalName,
        mimeType: r.mimeType,
        sizeBytes: r.sizeBytes.toInt(),
        isLocalCached: r.isLocalCached.toInt(),
      );

  // ── 同步加密 ──

  @override
  Future<SyncCryptoStatus> syncCryptoStatus() async {
    final s = await gen_sync.syncCryptoStatus();
    return SyncCryptoStatus(hasPassword: s.hasPassword, isUnlocked: s.isUnlocked);
  }

  @override
  Future<void> syncCryptoInit(String password, {bool remember = false}) =>
      gen_sync.syncCryptoInit(password: password, remember: remember);

  @override
  Future<void> syncCryptoUnlock(String password, {bool remember = false}) =>
      gen_sync.syncCryptoUnlock(password: password, remember: remember);

  @override
  Future<void> syncCryptoLock() => gen_sync.syncCryptoLock();

  @override
  Future<String> syncCryptoImportBundle(SyncCryptoBundle bundle,
      String password, {bool force = false}) {
    // 桌面契约：bundle JSON + 密码；Rust 侧自行解析（见 sync.rs 注释）
    return gen_sync.syncCryptoImportBundle(
      bundleJson: jsonEncode(bundle.toJson()),
      password: password,
      force: force,
    );
  }

  // ── 节假日 ──

  @override
  Future<List<HolidayInfo>> holidayList() async {
    final rows = await gen_holiday.holidayList();
    return rows
        .map((h) => HolidayInfo(
              date: h.date,
              year: h.year,
              isHoliday: h.isHoliday,
              name: h.name,
            ))
        .toList();
  }

  @override
  Future<bool?> holidayIsOn(String date) => gen_holiday.holidayIsOn(date: date);

  @override
  Future<HolidayMeta> holidayUpdate() async {
    final m = await gen_holiday.holidayUpdate();
    return HolidayMeta(
      lastUpdateMs: m.lastUpdateMs,
      lastAttemptMs: m.lastAttemptMs,
      failureCount: m.failureCount,
      fixedHour: m.fixedHour,
    );
  }

  @override
  Future<HolidayMeta> holidayMeta() async {
    final m = await gen_holiday.holidayMeta();
    return HolidayMeta(
      lastUpdateMs: m.lastUpdateMs,
      lastAttemptMs: m.lastAttemptMs,
      failureCount: m.failureCount,
      fixedHour: m.fixedHour,
    );
  }

  @override
  Future<void> startHolidayScheduler() =>
      gen_holiday.startHolidayScheduler();

  // ── 回收站 ──

  @override
  Future<List<TodoTask>> trashTasksList() async =>
      (await gen_trash.trashTasksList()).map(_mapTask).toList();

  @override
  Future<TodoTask> trashTaskRestore(int id) async =>
      _mapTask(await gen_trash.trashTaskRestore(id: id));

  @override
  Future<void> trashTaskPurge(int id) =>
      gen_trash.trashTaskPurge(id: id);

  @override
  Future<int> trashPurgeAll() async =>
      (await gen_trash.trashPurgeAll()).toInt();

  @override
  Future<TrashMeta> trashMeta() async {
    final m = await gen_trash.trashMeta();
    return TrashMeta(
      retentionDays: m.retentionDays,
      lastPurgeMs: m.lastPurgeMs,
    );
  }

  @override
  Future<void> trashSetRetentionDays(int days) =>
      gen_trash.trashSetRetentionDays(days: days);

  @override
  Future<void> startTrashScheduler() =>
      gen_trash.startTrashScheduler();

  // ── 统计仪表盘（backlog #25）──

  @override
  Future<StatsAggregate> statsAggregate({int? days}) async {
    final a = await gen_stats.statsAggregate(days: days);
    return StatsAggregate(
      overview: StatsOverview(
        total: a.overview.total,
        pending: a.overview.pending,
        done: a.overview.done,
        doneLast7d: a.overview.doneLast7D,
        doneLast30d: a.overview.doneLast30D,
      ),
      heatmap: StatsHeatmap(
        startDate: a.heatmap.startDate,
        endDate: a.heatmap.endDate,
        cells: a.heatmap.cells
            .map((c) => StatsHeatmapCell(date: c.date, count: c.count))
            .toList(),
      ),
      streak: StatsStreak(
        current: a.streak.current,
        best: a.streak.best,
        doneToday: a.streak.doneToday,
      ),
      byProject: a.byProject
          .map((r) => StatsProjectRow(
                projectId: r.projectId,
                projectTitle: r.projectTitle,
                projectHexColor: r.projectHexColor,
                doneCount: r.doneCount,
                pendingCount: r.pendingCount,
              ))
          .toList(),
      byPriority: a.byPriority
          .map((r) => StatsPriorityRow(
                priority: r.priority,
                doneCount: r.doneCount,
                pendingCount: r.pendingCount,
              ))
          .toList(),
      byWeekday: a.byWeekday
          .map((r) => StatsWeekdayRow(weekday: r.weekday, doneCount: r.doneCount))
          .toList(),
    );
  }

  // ── 全局搜索（backlog #26）──

  @override
  Future<GlobalSearchResult> globalSearch(String keyword, {int? limit}) async {
    final r = await gen_search.globalSearch(keyword: keyword, limit: limit);
    return GlobalSearchResult(
      tasks: r.tasks.map(_mapTask).toList(),
      projects: r.projects.map(_mapProject).toList(),
      comments: r.comments
          .map((c) => CommentSearchHit(
                commentId: c.commentId,
                taskId: c.taskId,
                taskTitle: c.taskTitle,
                content: c.content,
                createdAt: c.createdAt,
              ))
          .toList(),
    );
  }

  // ── 事件流 ──

  @override
  Stream<DbChangeEvent> get dbChanges =>
      gen_events.subscribeDbChanges().map((e) => DbChangeEvent(
            table: e.table,
            op: e.op,
            recordId: e.recordId,
            recordUuid: e.recordUuid,
            deviceId: e.deviceId,
            timestamp: e.timestamp,
          ));

  @override
  Stream<ReminderDueEvent> get reminderDue =>
      gen_events.startReminderPoller().map((r) => ReminderDueEvent(
            id: r.id,
            taskId: r.taskId,
            title: r.title,
            remindAt: r.remindAt,
          ));

  // ── 映射助手 ──

  gen.ListFilter _genFilter(ListFilter f) => gen.ListFilter(
        keyword: f.keyword,
        page: f.page,
        pageSize: f.pageSize,
      );

  static TodoProject _mapProject(gen.TodoProject p) => TodoProject(
        id: p.id,
        uuid: p.uuid,
        title: p.title,
        description: p.description,
        hexColor: p.hexColor,
        sortOrder: p.sortOrder,
        isDeleted: p.isDeleted,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
        deletedAt: p.deletedAt,
        version: p.version,
      );

  static TodoTask _mapTask(gen.TodoTask t) => TodoTask(
        id: t.id,
        uuid: t.uuid,
        title: t.title,
        description: t.description,
        projectId: t.projectId,
        priority: t.priority,
        status: t.status,
        done: t.done,
        doneAt: t.doneAt,
        dueDate: t.dueDate,
        startDate: t.startDate,
        repeatAfter: t.repeatAfter,
        repeatMode: t.repeatMode,
        repeatWeekdays: t.repeatWeekdays,
        repeatEndType: t.repeatEndType,
        repeatEndParam: t.repeatEndParam,
        repeatFromDone: t.repeatFromDone,
        percentDone: t.percentDone,
        position: t.position,
        isFavorite: t.isFavorite,
        myDayDate: t.myDayDate,
        isDeleted: t.isDeleted,
        createdAt: t.createdAt,
        updatedAt: t.updatedAt,
        deletedAt: t.deletedAt,
        version: t.version,
      );

  static TodoSubtask _mapSubtask(gen.TodoSubtask s) => TodoSubtask(
        id: s.id,
        uuid: s.uuid,
        taskId: s.taskId,
        title: s.title,
        done: s.done,
        doneAt: s.doneAt,
        position: s.position,
        isDeleted: s.isDeleted,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
        deletedAt: s.deletedAt,
        version: s.version,
      );

  static TodoLabel _mapLabel(gen.TodoLabel l) => TodoLabel(
        id: l.id,
        uuid: l.uuid,
        title: l.title,
        hexColor: l.hexColor,
        isDeleted: l.isDeleted,
        createdAt: l.createdAt,
        updatedAt: l.updatedAt,
        deletedAt: l.deletedAt,
        version: l.version,
      );

  static TodoComment _mapComment(gen.TodoComment c) => TodoComment(
        id: c.id,
        uuid: c.uuid,
        taskId: c.taskId,
        content: c.content,
        isDeleted: c.isDeleted,
        createdAt: c.createdAt,
        updatedAt: c.updatedAt,
        deletedAt: c.deletedAt,
        version: c.version,
      );

  static TodoTaskRelation _mapRelation(gen.TodoTaskRelation r) =>
      TodoTaskRelation(
        id: r.id,
        uuid: r.uuid,
        taskId: r.taskId,
        otherTaskId: r.otherTaskId,
        relationType: r.relationType,
        isDeleted: r.isDeleted,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        deletedAt: r.deletedAt,
        version: r.version,
      );

  static TodoReminder _mapReminder(gen.TodoReminder r) => TodoReminder(
        id: r.id,
        uuid: r.uuid,
        taskId: r.taskId,
        remindAt: r.remindAt,
        isDeleted: r.isDeleted,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        deletedAt: r.deletedAt,
        version: r.version,
      );

  gen_sync.SyncConfigInput _toGenConfigInput(Map<String, Object?> m) =>
      gen_sync.SyncConfigInput(
        engine: m['engine'] as String,
        endpoint: m['endpoint'] as String,
        bucket: m['bucket'] as String?,
        region: m['region'] as String?,
        username: m['username'] as String?,
        password: m['password'] as String?,
        basePath: m['base_path'] as String?,
        intervalMinutes: m['interval_minutes'] as int?,
        autoSyncEnabled: m['auto_sync_enabled'] as bool?,
        syncOnChange: m['sync_on_change'] as bool?,
        skipTlsVerify: m['skip_tls_verify'] as bool?,
        timeoutSeconds: m['timeout_seconds'] as int?,
      );
}

/// 启动 FRB 运行时（main 中在 runApp 前调用）
Future<void> initRustBridge() => RustLib.init();
