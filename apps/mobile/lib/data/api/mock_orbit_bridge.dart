import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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

  // ── 生物识别解锁（mock：密钥链编排在内存，闭环可跑通）──

  /// 内存密钥链（biometricSetup 写入 / biometricUnlock 读出校验）
  BiometricSecretBundle? _bioBundle;

  /// 测试预置口：直接放三件套（绕过 async setup，widget 测试秒装）
  @visibleForTesting
  set bioBundleForTest(BiometricSecretBundle? bundle) => _bioBundle = bundle;

  @override
  Future<BiometricSecretBundle> biometricSetup(String dbKeyHex) => _delay(() {
        if (dbKeyHex.length != 64) {
          throw Exception('[invalid_input] DB Key hex 长度非法');
        }
        return _bioBundle = BiometricSecretBundle(
          encryptedDbKeyBio: 'mock:${dbKeyHex.hashCode}',
          biometricKey: 'mock-biometric-key',
          nonce: 'mock-nonce',
        );
      });

  @override
  Future<String> biometricUnlock(BiometricSecretBundle bundle) => _delay(() {
        if (!store.masterAuthSet) {
          throw Exception('[not_initialized] 未设置主密码');
        }
        final saved = _bioBundle;
        if (saved == null ||
            saved.encryptedDbKeyBio != bundle.encryptedDbKeyBio ||
            saved.biometricKey != bundle.biometricKey ||
            saved.nonce != bundle.nonce) {
          throw Exception('[biometric_failed] 生物识别解锁失败（密钥数据可能已损坏）');
        }
        return 'a' * 64;
      });

  @override
  Future<void> biometricDisable(String password) => _delay(() {
        if (password.isEmpty) {
          throw Exception('[wrong_password] 主密码错误');
        }
        _bioBundle = null;
      });

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
        // 默认排除已归档（对齐 Rust list_todo_projects 的 is_archived=0 谓词）
        final list = store.projects.values
            .where((p) => p['is_deleted'] == 0 && (p['is_archived'] ?? 0) == 0)
            .toList()
          ..sort((a, b) =>
              (a['sort_order'] as int).compareTo(b['sort_order'] as int));
        return list.map(TodoProject.fromJson).toList();
      });

  @override
  Future<List<TodoProject>> todoProjectListArchived() => _delay(() {
        final list = store.projects.values
            .where((p) =>
                p['is_deleted'] == 0 && (p['is_archived'] ?? 0) == 1)
            .toList()
          ..sort((a, b) => (b['updated_at'] as int).compareTo(a['updated_at'] as int));
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
          'is_archived': 0,
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
        // 列裁剪（批2 对齐 Rust generic_repo）：keyword 空时 description
        // 不传输（null 占位）；keyword 非空保留全列（SQL LIKE 依赖）
        final keyword = filter.keyword?.trim();
        final pruneDesc = keyword == null || keyword.isEmpty;
        return list
            .map((t) => pruneDesc ? {...t, 'description': null} : t)
            .map(TodoTask.fromJson)
            .toList();
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
          'repeat_after': input.repeatAfter ?? 1,
          'repeat_mode': input.repeatMode ?? 0,
          'repeat_weekdays': input.repeatWeekdays ?? 0,
          'repeat_end_type': input.repeatEndType ?? 0,
          'repeat_end_param': input.repeatEndParam ?? 0,
          'repeat_from_done': input.repeatFromDone ?? 0,
          'percent_done': 0,
          'position': input.position ??
              store.tasks.values
                  .where((e) => e['project_id'] == input.projectId)
                  .length,
          'is_favorite': input.isFavorite ?? 0,
          'my_day_date': input.myDayDate,
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
  Future<TodoTask> todoTaskComplete(int id) => _delay(() {
        // 对齐 Rust complete_todo_task：普通任务标记完成；重复任务
        // （repeat_mode>0 且有 due_date）克隆下一实例（due 按天/周步进、
        // 子任务复制标题、不复制提醒）再标记本实例；已完成任务幂等跳过
        final t = store.tasks[id] ?? _notFound('task $id');
        if (t['is_deleted'] == 1) _notFound('task $id 已在回收站');
        final now = store.now();
        final repeatMode = (t['repeat_mode'] as int?) ?? 0;
        final due = t['due_date'] as int?;
        final done = (t['done'] as int?) ?? 0;
        // #34 结束条件：次数型 param<=1 → 序列终结，不再克隆（对齐 Rust）
        final endType = (t['repeat_end_type'] as int?) ?? 0;
        final endParam = (t['repeat_end_param'] as int?) ?? 0;
        final endTerminated = endType == 2 && endParam <= 1;
        if (done == 0 && repeatMode > 0 && due != null && !endTerminated) {
          final after = ((t['repeat_after'] as int?) ?? 1).clamp(1, 1000);
          final stepMs = switch (repeatMode) {
            1 => 86400000 * after,
            2 => 7 * 86400000 * after,
            3 => 30 * 86400000 * after, // 月近似（mock 无日历语义）
            4 => 365 * 86400000 * after, // 年近似
            _ => null,
          };
          if (stepMs != null) {
            final fromDone = (t['repeat_from_done'] as int?) ?? 0;
            final int nextDue;
            if (fromDone == 1) {
              // when done：完成日锚定 + 一个完整步长（不吃快进）
              nextDue = now + stepMs;
            } else {
              // 默认：锚定原 due 快进到 now 之后最近的序列点
              var candidate = due + stepMs;
              var guard = 0;
              while (candidate <= now && guard++ < 5000) {
                candidate += stepMs;
              }
              nextDue = candidate;
            }
            final next = {
              ...store.newEntity('t'),
              'title': t['title'],
              'description': t['description'],
              'project_id': t['project_id'],
              'priority': t['priority'],
              'status': 'pending',
              'done': 0,
              'done_at': null,
              'due_date': nextDue,
              'start_date': t['start_date'] != null
                  ? (t['start_date'] as int) + (nextDue - due)
                  : null,
              'repeat_after': t['repeat_after'],
              'repeat_mode': repeatMode,
              'repeat_weekdays': t['repeat_weekdays'],
              'repeat_end_type': t['repeat_end_type'],
              'repeat_end_param': t['repeat_end_type'] == 2
                  ? ((t['repeat_end_param'] as int?) ?? 0) - 1
                  : t['repeat_end_param'],
              'repeat_from_done': t['repeat_from_done'],
              'percent_done': 0,
              'position': 100000,
              'is_favorite': t['is_favorite'],
              'my_day_date': null,
              'is_deleted': 0,
              'created_at': now,
              'updated_at': now,
              'deleted_at': null,
              'version': 1,
            };
            store.tasks[next['id'] as int] = next;
            for (final s in store.subtasksOf(id)) {
              final clone = {
                ...store.newEntity('s'),
                'task_id': next['id'],
                'title': s['title'],
                'done': 0,
                'done_at': null,
                'position': s['position'],
                'is_deleted': 0,
                'created_at': now,
                'updated_at': now,
                'deleted_at': null,
                'version': 1,
              };
              store.subtasks[clone['id'] as int] = clone;
            }
            _emit('todo_subtasks');
          }
        }
        t['done'] = 1;
        t['done_at'] = now;
        t['status'] = 'done';
        t['updated_at'] = now;
        t['version'] = ((t['version'] as int?) ?? 1) + 1;
        _emit('todo_tasks');
        return TodoTask.fromJson(t);
      });

  @override
  Future<TodoTask> todoTaskDuplicate(int id) => _delay(() {
        final t = store.tasks[id] ?? _notFound('task $id');
        final now = store.now();
        final copy = {
          ...store.newEntity('t'),
          'title': '${t['title']}（副本）',
          'description': t['description'],
          'project_id': t['project_id'],
          'priority': t['priority'],
          'status': 'pending',
          'done': 0,
          'done_at': null,
          'due_date': t['due_date'],
          'start_date': t['start_date'],
          'repeat_after': t['repeat_after'],
          'repeat_mode': t['repeat_mode'],
          'repeat_weekdays': t['repeat_weekdays'],
          'repeat_end_type': t['repeat_end_type'],
          'repeat_end_param': t['repeat_end_param'],
          'repeat_from_done': t['repeat_from_done'],
          'percent_done': 0,
          'position': (t['position'] as num) + 1.0,
          'is_favorite': t['is_favorite'],
          'my_day_date': null,
          'is_deleted': 0,
          'created_at': now,
          'updated_at': now,
          'deleted_at': null,
          'version': 1,
        };
        store.tasks[copy['id'] as int] = copy;
        // 子任务复制标题（完成态重置）
        for (final s in store.subtasksOf(id)) {
          store.subtasks[store.id] = {
            ...store.newEntity('s'),
            'task_id': copy['id'],
            'title': s['title'],
            'done': 0,
            'done_at': null,
            'position': s['position'],
            'is_deleted': 0,
            'created_at': now,
            'updated_at': now,
            'deleted_at': null,
            'version': 1,
          };
        }
        _emit('todo_tasks');
        return TodoTask.fromJson(copy);
      });

@override
  Future<void> todoTaskDelete(int id) => _delay(() {
        // 对齐 Rust 软删语义：墓碑行留在库中（回收站可见），不物理删除
        final t = store.tasks[id] ?? _notFound('task $id');
        final now = store.now();
        t['is_deleted'] = 1;
        t['deleted_at'] = now;
        t['updated_at'] = now;
        t['version'] = (t['version'] as int) + 1;
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
          repeatAfter: base.repeatAfter,
          repeatMode: base.repeatMode,
          repeatWeekdays: base.repeatWeekdays,
          repeatEndType: base.repeatEndType,
          repeatEndParam: base.repeatEndParam,
          repeatFromDone: base.repeatFromDone,
          percentDone: base.percentDone,
          position: base.position,
          isFavorite: base.isFavorite,
          myDayDate: base.myDayDate,
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

  @override
  Future<TodoTask> todoSubtaskPromote(int subtaskId) => _delay(() {
        // 对齐 Rust promote_todo_subtask：软删行 + 承接父任务 project/
        // priority/due 建尾位新任务 + percent 重算
        final s = store.subtasks[subtaskId] ?? _notFound('subtask $subtaskId');
        final parent = store.tasks[s['task_id'] as int] ??
            _notFound('task ${s['task_id']}');
        final now = store.now();
        s['is_deleted'] = 1;
        s['deleted_at'] = now;
        s['updated_at'] = now;
        final sibling = store.tasks.values.where((t) =>
            t['is_deleted'] == 0 &&
            (t['project_id'] as int?) == (parent['project_id'] as int?));
        final maxPos = sibling.fold<double>(
            -1.0, (m, t) => (t['position'] as num?) != null
                ? ((t['position'] as num).toDouble() > m
                    ? (t['position'] as num).toDouble()
                    : m)
                : m);
        final t = {
          ...store.newEntity('t'),
          'title': s['title'],
          'description': null,
          'project_id': parent['project_id'],
          'priority': parent['priority'],
          'status': s['done'] == 1 ? 'done' : 'pending',
          'done': s['done'],
          'done_at': s['done_at'],
          'due_date': parent['due_date'],
          'start_date': parent['start_date'],
          'repeat_after': 0,
          'repeat_mode': 0,
          'repeat_weekdays': 0,
          'repeat_end_type': 0,
          'repeat_end_param': 0,
          'repeat_from_done': 0,
          'percent_done': 0,
          'position': maxPos + 1,
          'is_favorite': 0,
          'my_day_date': null,
          'is_deleted': 0,
          'created_at': now,
          'updated_at': now,
          'deleted_at': null,
          'version': 1,
        };
        store.tasks[t['id'] as int] = t;
        store.recalcPercent(parent['id'] as int);
        _emit('todo_subtasks');
        _emit('todo_tasks');
        return TodoTask.fromJson(t);
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

  // ── 任务列表投影聚合（A4，只读：从内存库同口径推导，不 emit 事件）──

  @override
  Future<List<TaskLabelsProjection>> taskLabelsProjection() => _delay(() {
        final groups = <int, List<ProjectedTaskLabel>>{};
        final taskIds = store.taskLabels.keys.toList()..sort();
        for (final taskId in taskIds) {
          final labelIds = store.taskLabels[taskId]!.keys.toList()..sort();
          for (final labelId in labelIds) {
            final l = store.labels[labelId];
            if (l == null || (l['is_deleted'] as int) != 0) continue;
            (groups[taskId] ??= []).add(ProjectedTaskLabel(
              id: l['id'] as int,
              title: l['title'] as String,
              hexColor: l['hex_color'] as String,
            ));
          }
          if (groups[taskId]?.isEmpty ?? false) groups.remove(taskId);
        }
        return groups.entries
            .map((e) => TaskLabelsProjection(taskId: e.key, labels: e.value))
            .toList();
      });

  @override
  Future<List<TaskRemindersProjection>> taskRemindersProjection() => _delay(() {
        final groups = <int, List<ProjectedReminder>>{};
        final rows = store.reminders.values
            .where((r) => (r['is_deleted'] as int) == 0)
            .toList()
          ..sort((a, b) {
            final t = (a['task_id'] as int).compareTo(b['task_id'] as int);
            return t != 0 ? t : (a['remind_at'] as int).compareTo(b['remind_at'] as int);
          });
        for (final r in rows) {
          (groups[r['task_id'] as int] ??= []).add(ProjectedReminder(
            id: r['id'] as int,
            remindAt: r['remind_at'] as int,
          ));
        }
        return groups.entries
            .map((e) => TaskRemindersProjection(taskId: e.key, reminders: e.value))
            .toList();
      });

  @override
  Future<List<TaskDependencyFlags>> taskDependencyFlags() => _delay(() {
        final counts = <int, int>{};
        for (final r in store.relations.values) {
          if ((r['is_deleted'] as int) != 0) continue;
          final taskId = r['task_id'] as int;
          counts[taskId] = (counts[taskId] ?? 0) + 1;
        }
        final ids = counts.keys.toList()..sort();
        return ids
            .map((taskId) =>
                TaskDependencyFlags(taskId: taskId, relationCount: counts[taskId]!))
            .toList();
      });

  // ── 任务附件（内容寻址；与桌面 ipc-mock 同构语义）──

  @override
  Future<TaskAttachmentView> taskAttachmentAdd(
      int taskId, String fileName, String mimeType, List<int> data) {
    return _delay(() {
      if (data.isEmpty) throw Exception('附件内容为空');
      if (data.length > 50 * 1024 * 1024) throw Exception('附件超过单文件上限 50MB');
      final task = store.tasks[taskId];
      if (task == null) throw Exception('task $taskId not found');
      // 简化内容指纹（djb2）保证同内容同键，幂等去重
      var h = 5381;
      for (final b in data) {
        h = ((h << 5) + h + b) & 0x7fffffff;
      }
      final hash = h.toRadixString(16).padLeft(8, '0');
      final dup = store.attachments.values
          .where((a) => a['task_id'] == taskId && a['hash'] == hash)
          .toList();
      if (dup.isNotEmpty) return _mapMockAttachment(dup.first);
      if (store.attachments.values
              .where((a) => a['task_id'] == taskId)
              .length >=
          20) {
        throw Exception('单任务附件数已达上限 20');
      }
      final link = {
        'link_id': store.id,
        'link_uuid': 'att-${DateTime.now().millisecondsSinceEpoch}',
        'task_id': taskId,
        'hash': hash,
        'original_name': fileName,
        'mime_type': mimeType,
        'size_bytes': data.length,
        'is_local_cached': 1,
      };
      store.attachments[link['link_id'] as int] = link;
      return _mapMockAttachment(link);
    });
  }

  @override
  Future<List<TaskAttachmentView>> taskAttachmentsList(int taskId) {
    return _delay(() {
      return store.attachments.values
          .where((a) => a['task_id'] == taskId)
          .map(_mapMockAttachment)
          .toList()
        ..sort((a, b) => a.linkId.compareTo(b.linkId));
    });
  }

  @override
  Future<List<int>> taskAttachmentRead(String hash) {
    return _delay(() {
      final row = store.attachments.values.firstWhere(
        (a) => a['hash'] == hash,
        orElse: () => throw Exception('附件 $hash 不存在'),
      );
      if ((row['is_local_cached'] as int) == 0) {
        throw Exception('附件尚未从云端同步到本机');
      }
      return <int>[];
    });
  }

  @override
  Future<void> taskAttachmentRemove(int linkId) {
    return _delay(() {
      store.attachments.remove(linkId);
    });
  }

  // ── 任务活动日志（历史区块；排序/截断口径同桌面 ipc-mock task_activity_list）──

  @override
  Future<List<ActivityLogRow>> taskActivityList(int taskId, {int? limit}) {
    return _delay(() {
      final rows = store.activityLog.values
          .where((a) => a['task_id'] == taskId)
          .map(ActivityLogRow.fromJson)
          .toList()
        ..sort((a, b) => a.createdAt != b.createdAt
            ? b.createdAt.compareTo(a.createdAt)
            : b.id.compareTo(a.id));
      return rows.take(limit ?? 30).toList();
    });
  }

  // ── 数据库维护（性能批次；内存 mock 库无碎片，各步返回零值）──

  @override
  Future<DbMaintenanceResult> dbMaintenance() {
    return _delay(() => const DbMaintenanceResult(
          walBytesAfterCheckpoint: 0,
          attachmentsCleaned: 0,
          freelistBefore: 0,
          freelistAfter: 0,
          pagesReclaimed: 0,
        ));
  }

  // ── 保存的筛选器（#35；与桌面 ipc-mock 同构语义）──

  @override
  Future<List<TodoSavedFilter>> savedFiltersList() {
    return _delay(() => List<TodoSavedFilter>.from(store.savedFilters));
  }

  @override
  Future<TodoSavedFilter> savedFilterCreate(String name, String conditions) {
    return _delay(() {
      if (name.trim().isEmpty) throw Exception('筛选器名称不能为空');
      final row = TodoSavedFilter(
        id: store.id,
        uuid: 'sf-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        conditions: conditions,
      );
      store.savedFilters.add(row);
      return row;
    });
  }

  @override
  Future<void> savedFilterDelete(int id) {
    return _delay(() {
      store.savedFilters.removeWhere((f) => f.id == id);
    });
  }

  // ── 冲突败方副本（03 §八；与桌面 ipc-mock 同构语义）──

  @override
  Future<List<SyncConflict>> syncConflictList(
      String? resolution, int limit, int offset) {
    return _delay(() {
      final rows = store.conflicts
          .where((c) => resolution == null || c['resolution'] == resolution)
          .toList()
        ..sort((a, b) =>
            (b['created_at'] as int).compareTo(a['created_at'] as int));
      return rows
          .skip(offset)
          .take(limit)
          .map(_toSyncConflict)
          .toList();
    });
  }

  @override
  Future<int> syncConflictCount(String? resolution) {
    return _delay(() => store.conflicts
        .where((c) => resolution == null || c['resolution'] == resolution)
        .length);
  }

  @override
  Future<int> syncConflictRestore(int id) {
    return _delay(() {
      final row = store.conflicts.firstWhere((c) => c['id'] == id,
          orElse: () => throw Exception('冲突记录 $id 不存在'));
      row['resolution'] = 'restored';
      row['resolved_at'] = store.now();
      return row['id'] as int;
    });
  }

  @override
  Future<void> syncConflictDismiss(int id) {
    return _delay(() {
      final row = store.conflicts.firstWhere((c) => c['id'] == id,
          orElse: () => throw Exception('冲突记录 $id 不存在'));
      row['resolution'] = 'dismissed';
      row['resolved_at'] = store.now();
    });
  }

  @override
  Future<int> syncConflictClear(String? resolution) {
    return _delay(() {
      final before = store.conflicts.length;
      if (resolution == null) {
        store.conflicts.clear();
      } else {
        store.conflicts.removeWhere((c) => c['resolution'] == resolution);
      }
      return before - store.conflicts.length;
    });
  }

  SyncConflict _toSyncConflict(Map<String, dynamic> c) => SyncConflict(
        id: c['id'] as int,
        tableName: c['table_name'] as String,
        recordUuid: c['record_uuid'] as String,
        recordTitle: c['record_title'] as String,
        decision: c['decision'] as String,
        loserSide: c['loser_side'] as String,
        winnerSide: c['winner_side'] as String,
        loserPayload: c['loser_payload'] as String,
        winnerPayload: c['winner_payload'] as String,
        loserUpdatedAt: c['loser_updated_at'] as int,
        winnerUpdatedAt: c['winner_updated_at'] as int,
        resolution: c['resolution'] as String,
        createdAt: c['created_at'] as int,
        resolvedAt: c['resolved_at'] as int,
      );

  // ── 任务模板（与 Rust template_api 同构最小语义）──

  static const _templatePayloadKeys = [
    'title',
    'notes',
    'priority',
    'due_offset_days',
    'subtasks',
  ];

  /// payload 白名单校验（与 Rust ALLOWED_PAYLOAD_KEYS 同口径）
  static void _validateTemplatePayload(String payload) {
    final dynamic parsed = jsonDecode(payload);
    if (parsed is! Map<String, dynamic>) {
      throw Exception('模板内容必须是 JSON 对象');
    }
    for (final key in parsed.keys) {
      if (!_templatePayloadKeys.contains(key)) {
        throw Exception('模板内容含未知键 $key');
      }
    }
    final subtasks = parsed['subtasks'];
    if (subtasks != null &&
        (subtasks is! List || subtasks.any((x) => x is! String))) {
      throw Exception('subtasks 必须是字符串数组');
    }
  }

  @override
  Future<List<TodoTemplate>> templatesList() {
    return _delay(() => List<TodoTemplate>.from(store.templates));
  }

  @override
  Future<TodoTemplate> templateCreate(String name, String payload) {
    return _delay(() {
      if (name.trim().isEmpty) throw Exception('模板名称不能为空');
      _validateTemplatePayload(payload);
      final row = TodoTemplate(
        id: store.id,
        uuid: 'tpl-${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        payload: payload,
      );
      store.templates.add(row);
      return row;
    });
  }

  @override
  Future<void> templateDelete(int id) {
    return _delay(() {
      store.templates.removeWhere((t) => t.id == id);
    });
  }

  // ── Android 桌面小组件（#3；与 badge_count 同口径的 mock 实现）──

  @override
  Future<List<WidgetTodoItem>> widgetTodoQuery(int limit) => _delay(() {
        final endOfToday =
            DateTime.now().millisecondsSinceEpoch + 24 * 3600 * 1000;
        final rows = store.tasks.values
            .where((t) =>
                t['is_deleted'] == 0 &&
                t['done'] == 0 &&
                t['due_date'] != null &&
                (t['due_date'] as int) < endOfToday)
            .toList()
          ..sort((a, b) {
            final p = (b['priority'] as int).compareTo(a['priority'] as int);
            return p != 0
                ? p
                : (a['due_date'] as int).compareTo(b['due_date'] as int);
          });
        return rows.take(limit).map((t) {
          final id = t['id'] as int;
          return WidgetTodoItem(
            id: id,
            uuid: (t['uuid'] as String?) ?? 'w-$id',
            title: t['title'] as String,
            priority: t['priority'] as int,
            done: t['done'] as int,
          );
        }).toList();
      });

  @override
  Future<void> widgetTodoToggle(int id, int done) => _delay(() {
        final t = store.tasks[id];
        if (t == null) throw Exception('[not_found] task $id not found');
        t['done'] = done;
        t['done_at'] = done == 1 ? store.now() : null;
        t['status'] = done == 1 ? 'done' : 'pending';
        _emit('todo_tasks');
      });

  // ── ICS 日历导出（#4；与 Rust export_ics 同构最小语义）──

  @override
  Future<IcsExportView> icsExport() => _delay(() {
        final tasks = store.tasks.values
            .where((t) => t['is_deleted'] == 0)
            .toList();
        final content = StringBuffer()
          ..write('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Orbit//TODO ICS Export//CN\r\n');
        for (final t in tasks) {
          content.write('BEGIN:VTODO\r\nUID:${t['uuid']}@orbit\r\nSUMMARY:${t['title']}\r\nEND:VTODO\r\n');
        }
        content.write('END:VCALENDAR\r\n');
        return IcsExportView(
          content: content.toString(),
          tableCounts: [
            IcsTableCount(table: 'todo_tasks', count: tasks.length),
          ],
          suggestedFilename: 'orbit_mock.ics',
        );
      });

  TaskAttachmentView _mapMockAttachment(Map<String, dynamic> a) =>
      TaskAttachmentView(
        linkId: a['link_id'] as int,
        linkUuid: a['link_uuid'] as String,
        hash: a['hash'] as String,
        originalName: a['original_name'] as String,
        mimeType: a['mime_type'] as String,
        sizeBytes: a['size_bytes'] as int,
        isLocalCached: a['is_local_cached'] as int,
      );

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
        // 凭据回填源（syncTestConnection 留空字段时借用，对齐 Rust 侧语义）
        store.lastSyncEngine = (input['engine'] as String?) ?? 'webdav';
        store.lastSyncUsername = (input['username'] as String?) ?? '';
        store.lastSyncPassword = (input['password'] as String?) ?? '';
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

  @override
  Future<int> syncTestConnection(Map<String, Object?> input) => _delay(() {
        // 对齐 Rust [config] 前置校验：引擎 / 服务器地址 / 凭据
        final engine = (input['engine'] as String?) ?? '';
        if (engine != 'webdav' && engine != 's3') {
          throw Exception('[config] 不支持的引擎类型，仅支持 webdav/s3');
        }
        if (((input['endpoint'] as String?) ?? '').trim().isEmpty) {
          throw Exception('[config] 服务器地址不能为空');
        }
        var username = (input['username'] as String?) ?? '';
        var password = (input['password'] as String?) ?? '';
        // 留空字段从已存配置回填（同协议才借用，同 Rust 侧语义）
        if (store.syncConfigured &&
            (username.isEmpty || password.isEmpty) &&
            store.lastSyncEngine == engine) {
          if (username.isEmpty) username = store.lastSyncUsername;
          if (password.isEmpty) password = store.lastSyncPassword;
        }
        if (username.isEmpty || password.isEmpty) {
          throw Exception('[config] 请填写用户名与密码');
        }
        return 3; // 模拟根目录条目数
      });

  @override
  Future<void> syncDisconnect() => _delay(() {
        store.syncConfigured = false;
        store.lastSyncEngine = null;
        store.lastSyncUsername = '';
        store.lastSyncPassword = '';
      });

  // ── 明文数据导出（07 报告 #15）──

  @override
  Future<PlaintextExportResult> plaintextExportJson({bool excludeDeleted = true}) =>
      _delay(() => PlaintextExportResult(
            content: '{"format":"orbit.plaintext-export","version":1,"mock":true}',
            tableCounts: {'todo_tasks': store.tasks.length},
            suggestedFilename: 'orbit-export-mock.json',
          ));

  @override
  Future<PlaintextExportResult> plaintextExportCsv({bool excludeDeleted = true}) =>
      _delay(() => PlaintextExportResult(
            content: '\u{feff}id,title\n1,mock-task',
            tableCounts: {'todo_tasks': store.tasks.length},
            suggestedFilename: 'orbit-export-mock.csv',
          ));

  // ── CSV 导入（lite 解析；与桌面 ipc-mock 同构语义）──

  @override
  Future<CsvImportPreview> csvImportPreview(
      String content, String preset, int previewLimit) {
    return _delay(() {
      final rows = _parseCsvLite(content);
      final mapped = rows
          .skip(1)
          .map((row) => _mapImportRowLite(preset, rows.first, row))
          .toList();
      return CsvImportPreview(
        preset: preset,
        rows: mapped.take(previewLimit).toList(),
        stats: CsvImportStats(
          success: mapped.where((r) => r.skipReason == null).length,
          skipped: mapped.where((r) => r.skipReason != null).length,
          failed: 0,
          notes: const [],
        ),
      );
    });
  }

  @override
  Future<CsvImportStats> csvImportExecute(String content, String preset) {
    return _delay(() {
      final rows = _parseCsvLite(content);
      var success = 0;
      var skipped = 0;
      final notes = <String>[];
      for (final row in rows.skip(1)) {
        final m = _mapImportRowLite(preset, rows.first, row);
        if (m.skipReason != null) {
          skipped++;
          notes.add('第 ${m.sourceLine} 行跳过：${m.skipReason}');
          continue;
        }
        final now = store.now();
        final projectId = m.projectTitle != null
            ? _ensureMockProject(m.projectTitle!)
            : null;
        final t = {
          ...store.newEntity('t'),
          'title': m.title,
          'description': null,
          'project_id': projectId,
          'priority': m.priority ?? 0,
          'status': m.done ? 'done' : 'pending',
          'done': m.done ? 1 : 0,
          'done_at': m.done ? now : null,
          'due_date': null,
          'start_date': null,
          'repeat_after': 0,
          'repeat_mode': 0,
          'percent_done': 0,
          'position': 100000,
          'is_favorite': 0,
          'my_day_date': null,
          'is_deleted': 0,
          'created_at': now,
          'updated_at': now,
          'deleted_at': null,
          'version': 1,
        };
        store.tasks[t['id'] as int] = t;
        success++;
      }
      _emit('todo_tasks');
      return CsvImportStats(
          success: success, skipped: skipped, failed: 0, notes: notes);
    });
  }

  /// 按标题找项目，无则创建（对齐 Rust execute_csv_import 项目复用）
  int _ensureMockProject(String title) {
    final key = title.trim().toLowerCase();
    for (final p in store.projects.values) {
      if ((p['title'] as String).toLowerCase() == key) return p['id'] as int;
    }
    final now = store.now();
    final p = {
      ...store.newEntity('p'),
      'title': title.trim(),
      'description': null,
      'hex_color': '#3B82F6',
      'sort_order': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
      'version': 1,
    };
    store.projects[p['id'] as int] = p;
    return p['id'] as int;
  }

  /// RFC 4180 关键子集解析（引号转义/逗号切分/跳空行）
  static List<List<String>> _parseCsvLite(String content) {
    final rows = <List<String>>[];
    for (final line
        in content.replaceFirst('\u{feff}', '').split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      final fields = <String>[];
      var cur = StringBuffer();
      var inQ = false;
      for (var i = 0; i < line.length; i++) {
        final c = line[i];
        if (c == '"') {
          if (inQ && i + 1 < line.length && line[i + 1] == '"') {
            cur.write('"');
            i++;
          } else {
            inQ = !inQ;
          }
        } else if (c == ',' && !inQ) {
          fields.add(cur.toString());
          cur = StringBuffer();
        } else {
          cur.write(c);
        }
      }
      fields.add(cur.toString());
      rows.add(fields);
    }
    return rows;
  }

  /// 三档预设轻量映射（与桌面 ipc-mock 同构）
  static CsvImportPreviewRow _mapImportRowLite(
      String preset, List<String> header, List<String> row) {
    final lower = header.map((h) => h.trim().toLowerCase()).toList();
    String? cell(String name) {
      final i = lower.indexOf(name);
      if (i < 0 || i >= row.length) return null;
      final v = row[i].trim();
      return v.isEmpty ? null : v;
    }

    final line = 2; // 表头后相对行号由调用方需要时再补（mock 预览足够）
    String? title;
    String? projectTitle;
    int? priority;
    var skip = false;
    if (preset == 'todoist') {
      final type = cell('type');
      if (type != null && type.toLowerCase() != 'task') skip = true;
      title = cell('content');
      projectTitle = cell('list name');
      priority = const {'p1': 4, 'p2': 3, 'p3': 2, 'p4': 1}[cell('priority')?.toLowerCase()];
    } else if (preset == 'ticktick') {
      title = cell('summary');
      projectTitle = cell('list name');
      priority = const {'高': 3, '中': 2, '低': 1, '无': 0}[cell('priority') ?? ''];
    } else {
      title = cell('title');
      projectTitle = cell('project');
      priority = const {'低': 1, '中': 2, '高': 3, '紧急': 4, '立即处理': 5}[cell('priority') ?? ''];
    }
    final done = (cell('completed date') ?? cell('completed time')) != null;
    return CsvImportPreviewRow(
      sourceLine: line,
      projectTitle: projectTitle,
      title: title ?? '',
      priority: priority,
      done: done,
      dueDate: null,
      skipReason: skip ? '非 Task 类型行' : (title == null ? '标题为空' : null),
    );
  }

  // ── 同步加密 ──

  @override
  Future<SyncCryptoStatus> syncCryptoStatus() => _delay(() => SyncCryptoStatus(
      hasPassword: store.syncPasswordSet, isUnlocked: store.syncUnlocked));

  @override
  Future<void> syncCryptoInit(String password, {bool remember = false}) =>
      _delay(() {
        if (password.length < 6) {
          throw Exception('[invalid_input] 同步密码至少 6 位');
        }
        store.syncPasswordSet = true;
        store.syncUnlocked = true;
        store.syncPassword = password;
      });

  @override
  Future<void> syncCryptoLock() => _delay(() {
        store.syncUnlocked = false;
      });

  @override
  Future<void> syncCryptoUnlock(String password, {bool remember = false}) =>
      _delay(() {
        if (!store.syncPasswordSet) {
          throw Exception('[not_initialized] 未设置同步密码');
        }
        if (password != store.syncPassword) {
          throw Exception('[wrong_password] 同步密码错误');
        }
        store.syncUnlocked = true;
      });

  @override
  Future<String> syncCryptoImportBundle(SyncCryptoBundle bundle,
          String password, {bool force = false}) =>
      _delay(() => throw Exception('[not_unlocked] Mock 未实现'));

  @override
  Future<String?> syncCryptoMetaVersion() =>
      _delay(() => store.syncPasswordSet ? 'v2' : null);

  @override
  Future<void> syncCryptoUpgradeV2(String password) =>
      _delay(() => throw Exception('[not_unlocked] Mock 未实现'));

  @override
  Future<String> cloudSyncRekey() =>
      _delay(() => throw Exception('[not_unlocked] Mock 未实现'));

  // ── 节假日（内存假数据；形状对齐 Rust 预置 2026 表节选）──

  static const _mockHolidays = [
    HolidayInfo(date: '2026-01-01', year: 2026, isHoliday: true, name: '元旦'),
    HolidayInfo(date: '2026-01-04', year: 2026, isHoliday: false, name: '元旦后补班'),
    HolidayInfo(date: '2026-02-17', year: 2026, isHoliday: true, name: '初一'),
  ];

  @override
  Future<List<HolidayInfo>> holidayList() async => _mockHolidays;

  @override
  Future<bool?> holidayIsOn(String date) async =>
      _mockHolidays.where((h) => h.date == date).firstOrNull?.isHoliday;

  @override
  Future<HolidayMeta> holidayUpdate() async => const HolidayMeta(
        lastUpdateMs: 1770000000000,
        lastAttemptMs: 1770000000000,
        failureCount: 0,
        fixedHour: 8,
      );

  @override
  Future<HolidayMeta> holidayMeta() async => const HolidayMeta(
        lastUpdateMs: 1770000000000,
        lastAttemptMs: 1770000000000,
        failureCount: 0,
        fixedHour: 8,
      );

  @override
  Future<void> startHolidayScheduler() async {}

  // ── 回收站 ──

  /// Mock 保留档位（内存态；跨端不持久，测试够用）
  int _trashRetentionDays = 30;

  List<Map<String, dynamic>> get _trashed => store.tasks.values
      .where((t) => t['is_deleted'] == 1 && t['deleted_at'] != null)
      .toList()
    ..sort((a, b) => (b['deleted_at'] as int).compareTo(a['deleted_at'] as int));

  @override
  Future<List<TodoTask>> trashTasksList() =>
      _delay(() => _trashed.map(TodoTask.fromJson).toList());

  @override
  Future<TodoTask> trashTaskRestore(int id) => _delay(() {
        final t = store.tasks[id];
        if (t == null || t['is_deleted'] != 1) {
          throw Exception('task $id 不在回收站');
        }
        final now = store.now();
        t['is_deleted'] = 0;
        t['deleted_at'] = null;
        t['updated_at'] = now;
        t['version'] = (t['version'] as int) + 1;
        // 对齐 Rust：原项目已删则落未分组
        final pid = t['project_id'] as int?;
        if (pid != null &&
            !(store.projects[pid]?['is_deleted'] == 0)) {
          t['project_id'] = null;
        }
        _emit('todo_tasks');
        return TodoTask.fromJson(t);
      });

  @override
  Future<void> trashTaskPurge(int id) => _delay(() {
        final t = store.tasks[id];
        if (t == null || t['is_deleted'] != 1) {
          throw Exception('task $id 不在回收站');
        }
        store.tasks.remove(id);
        _emit('todo_tasks');
      });

  @override
  Future<int> trashPurgeAll() => _delay(() {
        final trashed = _trashed;
        for (final t in trashed) {
          store.tasks.remove(t['id'] as int);
        }
        _emit('todo_tasks');
        return trashed.length;
      });

  @override
  Future<TrashMeta> trashMeta() async => TrashMeta(
        retentionDays: _trashRetentionDays,
        lastPurgeMs: 0,
      );

  @override
  Future<void> trashSetRetentionDays(int days) async {
    if (days != 0 && days != 7 && days != 30 && days != 90) {
      throw Exception('非法保留天数 $days');
    }
    _trashRetentionDays = days;
  }

  @override
  Future<void> startTrashScheduler() async {}

  // ── 统计仪表盘（backlog #25；口径对齐 stats_api：done_at 本地日界、仅存活任务；
  //      2026-09-10 热力图改按年——当前年滚动 365 天、历史年完整年）──

  @override
  Future<StatsAggregate> statsAggregate({int? year}) => _delay(() {
        final selectedYear = year ?? DateTime.now().year;
        final live = store.tasks.values
            .where((t) => t['is_deleted'] == 0)
            .toList(growable: false);
        final doneTasks = live
            .where((t) => t['done'] == 1 && t['done_at'] != null)
            .toList(growable: false);

        String dayKey(int ms) {
          final d = DateTime.fromMillisecondsSinceEpoch(ms);
          return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        }

        int idxOf(String key) =>
            DateTime.parse(key).millisecondsSinceEpoch ~/ 86400000;

        final today = DateTime.now();
        final todayKey =
            '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
        final tIdx = idxOf(todayKey);
        // 年份窗口：当前年 = 滚动 365 天（今天往前 364 天到今天）；历史年 = 1/1 ~ 12/31
        final DateTime from;
        final DateTime to;
        if (selectedYear == today.year) {
          final t0 = today.copyWith(
              hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0);
          from = t0.subtract(const Duration(days: 364));
          to = t0;
        } else {
          from = DateTime(selectedYear, 1, 1);
          to = DateTime(selectedYear, 12, 31);
        }
        final startMs = from.millisecondsSinceEpoch;
        final endMs = to.millisecondsSinceEpoch + 86400000 - 1;

        final byDay = <String, int>{};
        for (final t in doneTasks) {
          final doneAt = t['done_at'] as int;
          if (doneAt >= startMs && doneAt <= endMs) {
            final k = dayKey(doneAt);
            byDay[k] = (byDay[k] ?? 0) + 1;
          }
        }
        final cells = <StatsHeatmapCell>[];
        for (var ms = startMs; ms <= endMs; ms += 86400000) {
          final k = dayKey(ms);
          cells.add(StatsHeatmapCell(date: k, count: byDay[k] ?? 0));
        }

        // 可选年份：全部完成记录的年份（不看窗口）；无完成记录回退 [当前年]
        final availableYears = <int>{
          for (final t in doneTasks)
            DateTime.fromMillisecondsSinceEpoch(t['done_at'] as int).year,
          if (doneTasks.isEmpty) today.year,
        }.toList()
          ..sort();

        // streak（断档规则对齐 core compute_streak）
        final doneIdx = byDay.keys.map(idxOf).toSet();
        final doneToday = doneIdx.contains(tIdx);
        var anchor = doneToday ? tIdx : tIdx - 1;
        var current = 0;
        while (doneIdx.contains(anchor)) {
          current++;
          anchor--;
        }
        var best = 0;
        var run = 0;
        int? prev;
        for (final i in doneIdx.toList()..sort()) {
          run = prev == i - 1 ? run + 1 : 1;
          if (run > best) best = run;
          prev = i;
        }

        int inLast(int n) {
          final cutoff = tIdx - (n - 1);
          return doneTasks
              .where((t) => idxOf(dayKey(t['done_at'] as int)) >= cutoff)
              .length;
        }

        final byProjectMap = <Object, StatsProjectRow>{};
        for (final t in live) {
          final key = t['project_id'] ?? 'none';
          final existing = byProjectMap[key];
          final pid = t['project_id'] as int?;
          final project = pid != null ? store.projects[pid] : null;
          final title =
              project != null ? (project['title'] as String? ?? '未知项目') : null;
          final row = existing ??
              StatsProjectRow(
                projectId: pid,
                projectTitle: title,
                projectHexColor: project?['hex_color'] as String?,
                doneCount: 0,
                pendingCount: 0,
              );
          byProjectMap[key] = StatsProjectRow(
            projectId: row.projectId,
            projectTitle: row.projectTitle,
            projectHexColor: row.projectHexColor,
            doneCount: row.doneCount + (t['done'] == 1 ? 1 : 0),
            pendingCount: row.pendingCount + (t['done'] == 1 ? 0 : 1),
          );
        }

        final byPriorityMap = <int, StatsPriorityRow>{};
        for (final t in live) {
          final p = t['priority'] as int;
          final row = byPriorityMap[p] ?? StatsPriorityRow(priority: p, doneCount: 0, pendingCount: 0);
          byPriorityMap[p] = StatsPriorityRow(
            priority: p,
            doneCount: row.doneCount + (t['done'] == 1 ? 1 : 0),
            pendingCount: row.pendingCount + (t['done'] == 1 ? 0 : 1),
          );
        }

        final byWeekday = List.filled(7, 0, growable: false);
        for (final t in doneTasks) {
          // 周一=0 基（对齐 Rust num_days_from_monday）
          byWeekday[(DateTime.fromMillisecondsSinceEpoch(t['done_at'] as int)
                      .weekday -
                  1)]++;
        }

        return StatsAggregate(
          overview: StatsOverview(
            total: live.length,
            pending: live.where((t) => t['done'] == 0).length,
            done: doneTasks.length,
            doneLast7d: inLast(7),
            doneLast30d: inLast(30),
          ),
          heatmap: StatsHeatmap(
            year: selectedYear,
            startDate: cells.first.date,
            endDate: cells.last.date,
            cells: cells,
          ),
          streak: StatsStreak(
            current: current,
            best: best,
            doneToday: doneToday,
          ),
          byProject: byProjectMap.values.toList()
            ..sort((a, b) => b.doneCount.compareTo(a.doneCount)),
          byPriority: byPriorityMap.values.toList()
            ..sort((a, b) => a.priority.compareTo(b.priority)),
          byWeekday: [
            for (var i = 0; i < 7; i++)
              StatsWeekdayRow(weekday: i, doneCount: byWeekday[i]),
          ],
          availableYears: availableYears,
        );
      });

  // ── 全局搜索（backlog #26；口径对齐 business_api::search_all：三路 LIKE、软删过滤）──

  @override
  Future<GlobalSearchResult> globalSearch(String keyword, {int? limit}) =>
      _delay(() {
        final kw = keyword.trim();
        final n = (limit ?? 20) <= 0 ? 20 : (limit ?? 20);
        if (kw.isEmpty) {
          return const GlobalSearchResult(tasks: [], projects: [], comments: []);
        }
        final pattern = kw.toLowerCase();

        bool hit(Map<String, dynamic> row, List<String> fields) => fields
            .any((f) => (row[f] as String?)?.toLowerCase().contains(pattern) ?? false);

        final tasks = store.tasks.values
            .where((t) => t['is_deleted'] == 0 && hit(t, ['title', 'description']))
            .toList()
          ..sort((a, b) => (b['updated_at'] as int).compareTo(a['updated_at'] as int));
        final projects = store.projects.values
            .where((p) => p['is_deleted'] == 0 && hit(p, ['title', 'description']))
            .toList()
          ..sort((a, b) => ((a['sort_order'] as int).compareTo(b['sort_order'] as int)));
        final comments = store.comments.values
            .where((c) =>
                c['is_deleted'] == 0 &&
                (c['content'] as String? ?? '').toLowerCase().contains(pattern))
            .toList()
          ..sort((a, b) => (b['created_at'] as int).compareTo(a['created_at'] as int));

        return GlobalSearchResult(
          tasks: tasks.take(n).map(TodoTask.fromJson).toList(),
          projects: projects.take(n).map(TodoProject.fromJson).toList(),
          comments: comments
              .take(n)
              .map((c) {
                final task = store.tasks[c['task_id'] as int];
                return CommentSearchHit(
                  commentId: c['id'] as int,
                  taskId: c['task_id'] as int,
                  taskTitle: (task?['title'] as String?) ?? '',
                  content: c['content'] as String? ?? '',
                  createdAt: c['created_at'] as int,
                );
              })
              .where((c) => c.taskTitle.isNotEmpty)
              .toList(),
        );
      });

  // ── 事件流 ──

  @override
  Stream<DbChangeEvent> get dbChanges => _dbChangesCtrl.stream;

  @override
  Stream<ReminderDueEvent> get reminderDue => _reminderDueCtrl.stream;
}
