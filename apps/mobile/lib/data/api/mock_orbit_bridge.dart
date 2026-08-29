import 'dart:async';

import 'dto.dart';
import 'mock_store.dart';
import 'orbit_bridge.dart';

/// 内存假实现（omnipass MockOmniBridge 同款模式）。
///
/// UI 层在 FRB 绑定接入前可完全独立开发与测试；
/// Phase 5 在 main 中以 Provider override 替换为 RustOrbitBridge。
class MockOrbitBridge implements OrbitBridge {
  final store = MockStore()..seed();

  static const _latency = Duration(milliseconds: 120);

  final _dbChangesCtrl = StreamController<DbChangeEvent>.broadcast();
  final _reminderDueCtrl = StreamController<ReminderDueEvent>.broadcast();

  Future<T> _delay<T>(T Function() body) async {
    await Future<void>.delayed(_latency);
    return body();
  }

  void _emit(String table) {
    _dbChangesCtrl.add(DbChangeEvent(
      table: table,
      op: 'write',
      timestamp: store.now(),
    ));
  }

  Never _notFound(String what) => throw Exception('$what not found');

  // ── 主密码认证 ──

  @override
  Future<bool> masterAuthHas() => _delay(() => store.masterAuthSet);

  @override
  Future<String> masterAuthInit(String password) => _delay(() {
        if (password.isEmpty) throw Exception('[invalid_input] 密码不能为空');
        store.masterAuthSet = true;
        return 'a' * 64;
      });

  @override
  Future<String> masterAuthUnlock(String password) => _delay(() {
        if (!store.masterAuthSet) throw Exception('[not_initialized] 未设置主密码');
        return 'a' * 64;
      });

  @override
  Future<bool> masterAuthVerify(String password) async => true;

  // ── DB 生命周期 ──

  @override
  Future<void> dbInitPlaintext() async => store.dbReady = true;

  @override
  Future<void> dbInitEncrypted(String dbKeyHex) async => store.dbReady = true;

  @override
  Future<bool> dbIsReady() async => store.dbReady;

  @override
  Future<void> dbSetDeviceId(String deviceId) async {}

  // ── todo_projects ──

  @override
  Future<List<TodoProject>> todoProjectList(ListFilter filter) => _delay(() {
        final list = store.projects.values
            .where((p) => p['is_deleted'] == 0)
            .toList()
          ..sort((a, b) =>
              (a['sort_order'] as int).compareTo(b['sort_order'] as int));
        return list.map(TodoProject.fromJson).toList();
      });

  @override
  Future<TodoProject> todoProjectGet(int id) =>
      _delay(() => TodoProject.fromJson(store.projects[id] ?? _notFound('project $id')));

  @override
  Future<TodoProject> todoProjectCreate(TodoProjectCreateInput input) =>
      _delay(() {
        final p = {
          ...store.newEntity('p'),
          'title': input.title,
          'description': input.description,
          'hex_color': input.hexColor ?? '#4E8CFF',
          'sort_order': input.sortOrder ?? store.projects.length,
          'is_deleted': 0,
          'created_at': store.now(),
          'updated_at': store.now(),
          'deleted_at': null,
          'version': 1,
        };
        store.projects[p['id'] as int] = p;
        _emit('todo_projects');
        return TodoProject.fromJson(p);
      });

  @override
  Future<TodoProject> todoProjectUpdate(int id, String patchJson) => _delay(() {
        final p = store.projects[id] ?? _notFound('project $id');
        store.mergePatch(p, patchJson);
        _emit('todo_projects');
        return TodoProject.fromJson(p);
      });

  @override
  Future<void> todoProjectDelete(int id) => _delay(() {
        store.projects.remove(id);
        _emit('todo_projects');
      });

  @override
  Future<void> todoProjectUpdateSortOrder(int id, int sortOrder) =>
      _delay(() {
        final p = store.projects[id];
        if (p != null) p['sort_order'] = sortOrder;
      });

  // ── todo_tasks ──

  @override
  Future<List<TodoTask>> todoTaskList(ListFilter filter) => _delay(() {
        final list = store.tasks.values
            .where((t) => t['is_deleted'] == 0)
            .toList()
          ..sort((a, b) =>
              (a['position'] as int).compareTo(b['position'] as int));
        return list.map(TodoTask.fromJson).toList();
      });

  @override
  Future<TodoTask> todoTaskGet(int id) =>
      _delay(() => TodoTask.fromJson(store.tasks[id] ?? _notFound('task $id')));

  @override
  Future<TodoTask> todoTaskCreate(TodoTaskCreateInput input) => _delay(() {
        final t = {
          ...store.newEntity('t'),
          'title': input.title,
          'description': input.description,
          'project_id': input.projectId,
          'priority': input.priority ?? 0,
          'status': input.status ?? 'pending',
          'done': input.done ?? 0,
          'done_at': input.doneAt,
          'due_date': input.dueDate,
          'start_date': input.startDate,
          'end_date': input.endDate,
          'repeat_after': input.repeatAfter ?? 1,
          'repeat_mode': input.repeatMode ?? 0,
          'hex_color': input.hexColor ?? '',
          'percent_done': 0,
          'position': input.position ??
              store.tasks.values
                  .where((e) => e['project_id'] == input.projectId)
                  .length,
          'is_favorite': input.isFavorite ?? 0,
          'is_deleted': 0,
          'created_at': store.now(),
          'updated_at': store.now(),
          'deleted_at': null,
          'version': 1,
        };
        store.tasks[t['id'] as int] = t;
        _emit('todo_tasks');
        return TodoTask.fromJson(t);
      });

  @override
  Future<TodoTask> todoTaskUpdate(int id, String patchJson) => _delay(() {
        final t = store.tasks[id] ?? _notFound('task $id');
        store.mergePatch(t, patchJson);
        _emit('todo_tasks');
        return TodoTask.fromJson(t);
      });

  @override
  Future<void> todoTaskDelete(int id) => _delay(() {
        store.tasks.remove(id);
        _emit('todo_tasks');
      });

  @override
  Future<void> todoTaskUpdatePosition(int id, int position) => _delay(() {
        final t = store.tasks[id];
        if (t != null) t['position'] = position;
      });

  @override
  Future<TodoTaskDetail> todoTaskGetDetail(int id) => _delay(() {
        final m = store.tasks[id] ?? _notFound('task $id');
        final base = TodoTask.fromJson(m);
        final labelMap = store.taskLabels[id] ?? const <int, int>{};
        return TodoTaskDetail(
          id: base.id,
          uuid: base.uuid,
          title: base.title,
          description: base.description,
          projectId: base.projectId,
          priority: base.priority,
          status: base.status,
          done: base.done,
          doneAt: base.doneAt,
          dueDate: base.dueDate,
          startDate: base.startDate,
          endDate: base.endDate,
          repeatAfter: base.repeatAfter,
          repeatMode: base.repeatMode,
          hexColor: base.hexColor,
          percentDone: base.percentDone,
          position: base.position,
          isFavorite: base.isFavorite,
          isDeleted: base.isDeleted,
          createdAt: base.createdAt,
          updatedAt: base.updatedAt,
          deletedAt: base.deletedAt,
          version: base.version,
          subtasks:
              store.subtasksOf(id).map(TodoSubtask.fromJson).toList(),
          labels: [
            for (final lid in labelMap.keys)
              _labelWithLink(lid, labelMap[lid]!),
          ],
          comments: [
            for (final c in store.comments.values.where(
                (c) => c['task_id'] == id && c['is_deleted'] == 0))
              TodoComment.fromJson(c),
          ],
          relations: [
            for (final r in store.relations.values.where(
                (r) => r['task_id'] == id && r['is_deleted'] == 0))
              TodoTaskRelation.fromJson(r),
          ],
          reminders: [
            for (final r in store.reminders.values.where(
                (r) => r['task_id'] == id && r['is_deleted'] == 0))
              TodoReminder.fromJson(r),
          ],
        );
      });

  TaskLabelWithId _labelWithLink(int labelId, int linkId) {
    final l = store.labels[labelId]!;
    return TaskLabelWithId(
      id: l['id'] as int,
      uuid: l['uuid'] as String,
      title: l['title'] as String,
      hexColor: l['hex_color'] as String,
      isDeleted: 0,
      createdAt: l['created_at'] as int,
      updatedAt: l['updated_at'] as int,
      deletedAt: null,
      version: 1,
      taskLabelId: linkId,
    );
  }

  // ── todo_subtasks ──

  @override
  Future<List<TodoSubtask>> todoSubtaskList(ListFilter filter) =>
      _delay(() => store.subtasks.values
          .where((s) => s['is_deleted'] == 0)
          .map(TodoSubtask.fromJson)
          .toList());

  @override
  Future<TodoSubtask> todoSubtaskCreate(TodoSubtaskCreateInput input) =>
      _delay(() {
        final s = {
          ...store.newEntity('s'),
          'task_id': input.taskId,
          'title': input.title,
          'done': 0,
          'done_at': null,
          'position':
              store.subtasks.values.where((e) => e['task_id'] == input.taskId).length,
          'is_deleted': 0,
          'created_at': store.now(),
          'updated_at': store.now(),
          'deleted_at': null,
          'version': 1,
        };
        store.subtasks[s['id'] as int] = s;
        store.recalcPercent(input.taskId);
        _emit('todo_subtasks');
        return TodoSubtask.fromJson(s);
      });

  @override
  Future<TodoSubtask> todoSubtaskUpdate(int id, String patchJson) => _delay(() {
        final s = store.subtasks[id] ?? _notFound('subtask $id');
        store.mergePatch(s, patchJson);
        store.recalcPercent(s['task_id'] as int);
        _emit('todo_subtasks');
        return TodoSubtask.fromJson(s);
      });

  @override
  Future<void> todoSubtaskDelete(int id) => _delay(() {
        final s = store.subtasks.remove(id);
        if (s != null) store.recalcPercent(s['task_id'] as int);
        _emit('todo_subtasks');
      });

  @override
  Future<void> todoSubtaskToggleDone(int subtaskId, bool done) => _delay(() {
        final s = store.subtasks[subtaskId] ?? _notFound('subtask $subtaskId');
        s['done'] = done ? 1 : 0;
        s['done_at'] = done ? store.now() : null;
        store.recalcPercent(s['task_id'] as int);
        _emit('todo_subtasks');
      });

  // ── todo_labels / task_labels ──

  @override
  Future<List<TodoLabel>> todoLabelList(ListFilter filter) => _delay(
      () => store.labels.values.map(TodoLabel.fromJson).toList());

  @override
  Future<TodoLabel> todoLabelCreate(TodoLabelCreateInput input) => _delay(() {
        final l = {
          ...store.newEntity('l'),
          'title': input.title,
          'hex_color': input.hexColor ?? '#4E8CFF',
          'is_deleted': 0,
          'created_at': store.now(),
          'updated_at': store.now(),
          'deleted_at': null,
          'version': 1,
        };
        store.labels[l['id'] as int] = l;
        _emit('todo_labels');
        return TodoLabel.fromJson(l);
      });

  @override
  Future<void> todoLabelDelete(int id) => _delay(() {
        store.labels.remove(id);
        _emit('todo_labels');
      });

  @override
  Future<TaskLabelWithId> todoTaskLabelCreate(
          TodoTaskLabelCreateInput input) =>
      _delay(() {
        if (!store.labels.containsKey(input.labelId)) {
          _notFound('label ${input.labelId}');
        }
        final linkId = store.id;
        (store.taskLabels[input.taskId] ??= {})[input.labelId] = linkId;
        _emit('todo_task_labels');
        return _labelWithLink(input.labelId, linkId);
      });

  @override
  Future<void> todoTaskLabelDelete(int taskLabelId) => _delay(() {
        for (final links in store.taskLabels.values) {
          links.removeWhere((_, v) => v == taskLabelId);
        }
        _emit('todo_task_labels');
      });

  // ── comments ──

  @override
  Future<List<TodoComment>> todoCommentList(ListFilter filter) =>
      _delay(() => store.comments.values.map(TodoComment.fromJson).toList());

  @override
  Future<TodoComment> todoCommentCreate(TodoCommentCreateInput input) =>
      _delay(() {
        final now = store.now();
        final c = {
          ...store.newEntity('c'),
          'task_id': input.taskId,
          'content': input.content,
          'is_deleted': 0,
          'created_at': now,
          'updated_at': now,
          'deleted_at': null,
          'version': 1,
        };
        store.comments[c['id'] as int] = c;
        _emit('todo_comments');
        return TodoComment.fromJson(c);
      });

  @override
  Future<void> todoCommentDelete(int id) => _delay(() {
        store.comments.remove(id);
        _emit('todo_comments');
      });

  // ── relations ──

  @override
  Future<List<TodoTaskRelation>> todoTaskRelationList(ListFilter filter) =>
      _delay(() =>
          store.relations.values.map(TodoTaskRelation.fromJson).toList());

  @override
  Future<TodoTaskRelation> todoTaskRelationCreate(
          TodoTaskRelationCreateInput input) =>
      _delay(() {
        final r = {
          ...store.newEntity('r'),
          'task_id': input.taskId,
          'other_task_id': input.otherTaskId,
          'relation_type': input.relationType,
          'is_deleted': 0,
          'created_at': store.now(),
          'updated_at': store.now(),
          'deleted_at': null,
          'version': 1,
        };
        store.relations[r['id'] as int] = r;
        _emit('todo_task_relations');
        return TodoTaskRelation.fromJson(r);
      });

  @override
  Future<void> todoTaskRelationDelete(int id) => _delay(() {
        store.relations.remove(id);
        _emit('todo_task_relations');
      });

  // ── reminders ──

  @override
  Future<List<TodoReminder>> todoReminderList(ListFilter filter) => _delay(
      () => store.reminders.values.map(TodoReminder.fromJson).toList());

  @override
  Future<TodoReminder> todoReminderCreate(TodoReminderCreateInput input) =>
      _delay(() {
        final r = {
          ...store.newEntity('r'),
          'task_id': input.taskId,
          'remind_at': input.remindAt,
          'is_deleted': 0,
          'created_at': store.now(),
          'updated_at': store.now(),
          'deleted_at': null,
          'version': 1,
        };
        store.reminders[r['id'] as int] = r;
        _emit('todo_reminders');
        return TodoReminder.fromJson(r);
      });

  @override
  Future<void> todoReminderDelete(int id) => _delay(() {
        store.reminders.remove(id);
        _emit('todo_reminders');
      });

  // ── 同步配置与执行 ──

  @override
  Future<SyncConfigView?> syncConfigGet() => _delay(() {
        if (!store.syncConfigured) return null;
        return SyncConfigView(
          id: 1,
          engine: 'webdav',
          endpoint: 'https://dav.example.com',
          bucket: '',
          region: '',
          username: 'demo',
          passwordSet: true,
          basePath: '/orbit/',
          intervalMinutes: 30,
          autoSyncEnabled: false,
          syncOnChange: false,
          skipTlsVerify: false,
          timeoutSeconds: 30,
          lastSyncedAt: store.now() - 3600000,
        );
      });

  @override
  Future<SyncConfigView> syncConfigSave(Map<String, Object?> input) =>
      _delay(() {
        store.syncConfigured = true;
        return SyncConfigView(
          id: 1,
          engine: (input['engine'] as String?) ?? 'webdav',
          endpoint: (input['endpoint'] as String?) ?? '',
          bucket: (input['bucket'] as String?) ?? '',
          region: (input['region'] as String?) ?? '',
          username: (input['username'] as String?) ?? '',
          passwordSet: true,
          basePath: (input['base_path'] as String?) ?? '',
          intervalMinutes: (input['interval_minutes'] as int?) ?? 0,
          autoSyncEnabled: (input['auto_sync_enabled'] as bool?) ?? false,
          syncOnChange: (input['sync_on_change'] as bool?) ?? false,
          skipTlsVerify: (input['skip_tls_verify'] as bool?) ?? false,
          timeoutSeconds: (input['timeout_seconds'] as int?) ?? 30,
          lastSyncedAt: null,
        );
      });

  @override
  Future<SyncResultJson> cloudSyncNow({String origin = 'manual'}) =>
      _delay(() {
        final result = SyncResultJson(
          pushedModules: 2,
          pulledModules: 1,
          uploadedAttachments: 0,
          downloadedAttachments: 0,
          durationMs: 850,
          skipped: false,
          errors: [],
        );
        return result;
      });

  @override
  Future<bool> cloudSyncIsRunning() async => false;

  // ── 同步加密 ──

  @override
  Future<SyncCryptoStatus> syncCryptoStatus() =>
      _delay(() => const SyncCryptoStatus(hasPassword: false, isUnlocked: false));

  @override
  Future<void> syncCryptoUnlock(String password, {bool remember = false}) =>
      _delay(() {
        throw Exception('[wrong_password] Mock 未配置同步密码');
      });

  @override
  Future<String> syncCryptoImportBundle(SyncCryptoBundle bundle,
          String password, {bool force = false}) =>
      _delay(() => throw Exception('[not_unlocked] Mock 未实现'));

  // ── 事件流 ──

  @override
  Stream<DbChangeEvent> get dbChanges => _dbChangesCtrl.stream;

  @override
  Stream<ReminderDueEvent> get reminderDue => _reminderDueCtrl.stream;
}
