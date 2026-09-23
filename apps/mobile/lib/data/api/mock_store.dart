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
  // 任务活动轨迹行（todo_activity_log 同形：本地轨迹，不随同步；历史区块消费）
  final activityLog = <int, Map<String, dynamic>>{};
  final savedFilters = <TodoSavedFilter>[]; // #35 保存的筛选器
  final templates = <TodoTemplate>[]; // 任务模板（竞品矩阵高价值缺口）
  // 冲突败方副本（03 §八）：JSON Map 形状 = Rust serde 产物，处置状态就地改写
  final conflicts = <Map<String, dynamic>>[];

  // 通知历史（notification_log 同形：本地轨迹，不进同步白名单；通知历史页消费）
  final notificationLog = <Map<String, dynamic>>[];

  // 全量备份域（本地/云端备份清单 + 自动备份偏好 + 增量同步历史）
  final localBackups = <BackupEntry>[];
  final cloudBackups = <CloudBackupEntry>[];
  final syncHistory = <SyncHistoryRow>[];
  BackupPrefs backupPrefs = BackupPrefs.initial;

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

  /// 同步密钥方案版本：'v1' 存量随机密钥 / 'v2' 同密码确定性派生。
  /// 未设置密码时无元数据（`syncCryptoMetaVersion` 返 null）；升级即置 'v2'
  String syncKeyVersion = 'v2';

  /// 节假日每日固定更新时刻（0-23；core 缺省 08:00）
  int holidayFixedHour = 8;

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

    // 活动轨迹造态（历史区块）：覆盖三代 detail 形状（空/changes+fields/target）
    void activity(String action, String detail, int agoMs) {
      final a = {
        ...newEntity('act'),
        'task_id': t1['id'],
        'task_title': t1['title'],
        'action': action,
        'detail': detail,
        'created_at': now() - agoMs,
      };
      activityLog[a['id'] as int] = a;
    }

    activity('create', '{}', 4 * day);
    activity(
      'update',
      jsonEncode({
        'fields': ['priority'],
        'changes': [
          {'field': 'priority', 'from': 0, 'to': 4}
        ],
      }),
      2 * day,
    );
    activity(
        'comment_add', jsonEncode({'target': '评审会定在周四下午两点。'}), 3600000);

    // 冲突败方副本造态（03 §八）：两条覆盖「本地被覆盖 / 远端被丢弃」两条主路径
    conflicts.addAll([
      {
        ...newEntity('cf'),
        'table_name': 'todo_tasks',
        'record_uuid': t1['uuid'],
        'record_title': t1['title'],
        'decision': 'lww',
        'loser_side': 'local',
        'winner_side': 'remote',
        'loser_payload': jsonEncode({'title': t1['title'], 'priority': 1}),
        'winner_payload': jsonEncode({'title': t1['title'], 'priority': 3}),
        'loser_updated_at': now() - 5400000,
        'winner_updated_at': now() - 3600000,
        'resolution': 'unresolved',
        'created_at': now() - 3500000,
        'resolved_at': 0,
      },
      {
        ...newEntity('cf'),
        'table_name': 'todo_projects',
        'record_uuid': work['uuid'],
        'record_title': work['title'],
        'decision': 'tie_version',
        'loser_side': 'remote',
        'winner_side': 'local',
        'loser_payload': jsonEncode({'title': work['title'], 'hex_color': '#EF4444'}),
        'winner_payload': jsonEncode({'title': work['title'], 'hex_color': '#4E8CFF'}),
        'loser_updated_at': now() - 90000000,
        'winner_updated_at': now() - 90000000,
        'resolution': 'unresolved',
        'created_at': now() - 89000000,
        'resolved_at': 0,
      },
    ]);

    // 通知历史造态（通知页）：覆盖 到期 / 推迟 / 完成 三类
    void notify(String kind, String title, int agoMs, String payload) {
      final n = {
        ...newEntity('nl'),
        'kind': kind,
        'task_id': t1['id'],
        'task_title': title,
        'reminder_id': null,
        'payload': payload,
        'created_at': now() - agoMs,
      };
      notificationLog.add(n);
    }

    notify('reminder_due', t1['title'], 3600000, jsonEncode({'remind_at': 0}));
    notify('snooze', t1['title'], 7200000, jsonEncode({'snooze_until': 0}));
    notify('complete', t1['title'], 86400000, '{}');

    // 增量同步历史造态（同步历史卡）
    syncHistory.addAll([
      SyncHistoryRow(
        id: id,
        syncType: 'sync_now',
        status: 'success',
        startedAt: now() - 5400000,
        finishedAt: now() - 5399000,
        pulledCount: 3,
        pushedCount: 5,
        conflictCount: 0,
      ),
      SyncHistoryRow(
        id: id,
        syncType: 'push_only',
        status: 'failed',
        startedAt: now() - 86000000,
        finishedAt: now() - 85998000,
        pulledCount: 0,
        pushedCount: 0,
        conflictCount: 0,
        errorMessage: '[network] 连接超时',
      ),
    ]);
  }

  /// 全量备份清单（mock 导出/预览共用；表计数按当前内存库口径推导）
  BackupManifest buildManifest({String? deviceId}) => BackupManifest(
        formatVersion: 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(now()).toIso8601String(),
        createdAtTs: now(),
        appVersion: '0.1.0',
        deviceId: deviceId ?? 'mock-device',
        deviceName: 'Mock 设备',
        schemaVersion: 1,
        tableCounts: [
          BackupTableCount(table: 'todo_projects', count: projects.length),
          BackupTableCount(table: 'todo_tasks', count: tasks.length),
          BackupTableCount(table: 'todo_subtasks', count: subtasks.length),
          BackupTableCount(table: 'todo_labels', count: labels.length),
        ],
      );
}
