import 'dart:convert';

import 'dto.dart';

/// Mock 内存存储：实体以 JSON Map 形式保存（形状 = Rust serde 序列化产物），
/// 更新按"缺省键=跳过、null=清空"合并——与真实桥走同一语义。
class MockStore {
  final projects = <int, Map<String, dynamic>>{};
  final tasks = <int, Map<String, dynamic>>{};
  final subtasks = <int, Map<String, dynamic>>{};
  final labels = <int, Map<String, dynamic>>{};
  final taskLabels = <int, Map<int, int>>{}; // taskId -> labelId -> linkId（`Map<int,int>`）
  final comments = <int, Map<String, dynamic>>{};
  final relations = <int, Map<String, dynamic>>{};
  final reminders = <int, Map<String, dynamic>>{};
  final attachments = <int, Map<String, dynamic>>{}; // linkId -> 附件关联行
  final savedFilters = <TodoSavedFilter>[]; // #35 保存的筛选器
  final templates = <TodoTemplate>[]; // 任务模板（竞品矩阵高价值缺口）

  var nextId = 1;
  bool masterAuthSet = false;
  bool dbReady = false;
  bool syncConfigured = false;

  // 同步域扩展（云同步设置页用）：已存配置的凭据回填源 + 同步密码状态
  String? lastSyncEngine;
  String lastSyncUsername = '';
  String lastSyncPassword = '';
  bool syncPasswordSet = false;
  bool syncUnlocked = false;
  String syncPassword = '';

  int get id => nextId++;

  /// 合并 patch：键存在即生效，值为 null 表示清空（对齐 `Option<Option<T>>`）
  void mergePatch(Map<String, dynamic> target, String patchJson) {
    target.addAll(jsonDecode(patchJson) as Map<String, dynamic>);
    target['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    target['version'] = ((target['version'] as int?) ?? 1) + 1;
  }

  void recalcPercent(int taskId) {
    final subs = subtasks.values
        .where((s) => s['task_id'] == taskId && s['is_deleted'] == 0);
    final t = tasks[taskId];
    if (t == null || subs.isEmpty) return;
    final doneCount = subs.where((s) => s['done'] == 1).length;
    t['percent_done'] = (doneCount * 100 / subs.length).round();
  }

  List<Map<String, dynamic>> subtasksOf(int taskId) {
    final list = subtasks.values
        .where((s) => s['task_id'] == taskId && s['is_deleted'] == 0)
        .toList()
      ..sort((a, b) =>
          (a['position'] as int).compareTo(b['position'] as int));
    return list;
  }

  Map<String, dynamic> newEntity(String prefix, {String? uuid}) =>
      {'id': id, 'uuid': uuid ?? 'uuid-$prefix$nextId'};

  int now() => DateTime.now().millisecondsSinceEpoch;

  void seed() {
    const day = 86400000;
    Map<String, dynamic> project(String title, String color, int order) {
      final p = {
        ...newEntity('p'),
        'title': title,
        'description': null,
        'hex_color': color,
        'sort_order': order,
        'is_deleted': 0,
        'created_at': now(),
        'updated_at': now(),
        'deleted_at': null,
        'version': 1,
      };
      projects[p['id'] as int] = p;
      return p;
    }

    final work = project('工作', '#4E8CFF', 0);
    final life = project('生活', '#2DB87A', 1);

    Map<String, dynamic> label(String title, String color) {
      final l = {
        ...newEntity('l'),
        'title': title,
        'hex_color': color,
        'is_deleted': 0,
        'created_at': now(),
        'updated_at': now(),
        'deleted_at': null,
        'version': 1,
      };
      labels[l['id'] as int] = l;
      return l;
    }

    final urgent = label('紧急', '#F44336');
    label('阅读', '#8B5CF6');

    Map<String, dynamic> task({
      required String title,
      int? projectId,
      int priority = 0,
      String status = 'pending',
      int done = 0,
      int? dueDate,
      int isFavorite = 0,
      int? myDayDate,
      String? description,
    }) {
      final t = {
        ...newEntity('t'),
        'title': title,
        'description': description,
        'project_id': projectId,
        'priority': priority,
        'status': status,
        'done': done,
        'done_at': done == 1 ? now() : null,
        'due_date': dueDate,
        'start_date': null,
        'repeat_after': 1,
        'repeat_mode': 0,
        'hex_color': '',
        'percent_done': 0,
        'position':
            tasks.values.where((e) => e['project_id'] == projectId).length,
        'is_favorite': isFavorite,
        'my_day_date': myDayDate,
        'is_deleted': 0,
        'created_at': now(),
        'updated_at': now(),
        'deleted_at': null,
        'version': 1,
      };
      tasks[t['id'] as int] = t;
      return t;
    }

    final t1 = task(
      title: '完成移动端重构方案评审',
      projectId: work['id'] as int,
      priority: 3,
      description: '对照 docs/05 像素规格逐屏核对。',
      dueDate: now() + day,
      isFavorite: 1,
    );
    task(
      title: '已完成的周报提交',
      projectId: work['id'] as int,
      status: 'done',
      done: 1,
      dueDate: now() - day,
    );
    task(
      title: '回复合作方邮件（逾期）',
      projectId: work['id'] as int,
      priority: 2,
      dueDate: now() - day * 2,
    );
    final t4 = task(
      title: '采购周末露营物资',
      projectId: life['id'] as int,
      priority: 1,
      dueDate: now() + day * 3,
    );
    task(title: '未分组想法：写一篇关于 GTD 的短文');
    task(title: '阅读《Flutter 状态管理实践》', priority: 1, dueDate: now() + day * 7);

    void subtask(int taskId, String title, {bool done = false}) {
      final s = {
        ...newEntity('s'),
        'task_id': taskId,
        'title': title,
        'done': done ? 1 : 0,
        'done_at': done ? now() : null,
        'position':
            subtasks.values.where((e) => e['task_id'] == taskId).length,
        'is_deleted': 0,
        'created_at': now(),
        'updated_at': now(),
        'deleted_at': null,
        'version': 1,
      };
      subtasks[s['id'] as int] = s;
    }

    subtask(t1['id'] as int, '整理 FRB 桥接清单', done: true);
    subtask(t1['id'] as int, '准备演示环境');
    subtask(t4['id'] as int, '列装备清单');

    final c = {
      ...newEntity('c'),
      'task_id': t1['id'],
      'content': '评审会定在周四下午两点。',
      'is_deleted': 0,
      'created_at': now() - 3600000,
      'updated_at': now() - 3600000,
      'deleted_at': null,
      'version': 1,
    };
    comments[c['id'] as int] = c;

    taskLabels[t1['id'] as int] = {urgent['id'] as int: id};

    final r = {
      ...newEntity('r'),
      'task_id': t1['id'],
      'remind_at': now() + day ~/ 2,
      'is_deleted': 0,
      'created_at': now(),
      'updated_at': now(),
      'deleted_at': null,
      'version': 1,
    };
    reminders[r['id'] as int] = r;
  }
}
