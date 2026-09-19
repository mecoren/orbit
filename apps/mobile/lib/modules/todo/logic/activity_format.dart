/// 任务活动历史行文案格式化（纯函数，镜像桌面 shared/activity-format.ts）
///
/// detail JSON 三代并存，渲染按优先级回退：
/// - {"changes":[{field,from,to},…]}  新行：写入端已快照前后值
///   （枚举/数值按本文件口径格式化，日期串已由写入端转好本地格式）
/// - {"fields":["priority",…]}        旧行：只有字段名
/// - {"label":"工作"} + action label_add/label_remove：标签挂/摘
/// - {"target":"子任务甲"} + 从属对象前缀动作：提醒/子任务/评论等
/// 与桌面端不同源但同口径——改一侧必须同步另一侧，否则双端历史文案漂移。
library;

import 'dart:convert';

import 'repeat_logic.dart';
import 'task_logic.dart';

/// action → 中文动作文案
const activityActionLabels = {
  'create': '创建了任务',
  'update': '更新',
  'complete': '标记为完成',
  'uncomplete': '恢复为未完成',
  'delete': '移入回收站',
  'restore': '从回收站恢复',
  'label_add': '添加标签',
  'label_remove': '移除标签',
  'subtask_add': '添加子任务',
  'subtask_delete': '删除子任务',
  'subtask_done': '完成子任务',
  'subtask_undone': '取消完成子任务',
  'subtask_rename': '子任务改名',
  'subtask_promote': '子任务转为独立任务',
  'comment_add': '添加评论',
  'comment_delete': '删除评论',
  'link_add': '添加关联任务',
  'link_remove': '移除关联任务',
  'reminder_add': '添加提醒',
  'reminder_delete': '移除提醒',
  'attachment_add': '添加附件',
  'attachment_delete': '移除附件',
  'repeat_rollover': '已滚动下一周期',
};

/// detail 带 {"target"} 的从属对象动作：文案统一拼「target」
const _targetActions = {
  'subtask_add',
  'subtask_delete',
  'subtask_done',
  'subtask_undone',
  'subtask_rename',
  'subtask_promote',
  'comment_add',
  'comment_delete',
  'link_add',
  'link_remove',
  'reminder_add',
  'reminder_delete',
  'attachment_add',
  'attachment_delete',
  'repeat_rollover',
};

/// update detail 里的字段名 → 中文（与属性行文案对齐；未映射字段原样展示）
const activityFieldLabels = {
  'title': '标题',
  'description': '描述',
  'project_id': '所属项目',
  'priority': '优先级',
  'status': '状态',
  'done': '完成标记',
  'done_at': '完成时间',
  'due_date': '截止日期',
  'start_date': '开始日期',
  'repeat_rule': '重复规则',
  'percent_done': '进度',
  'position': '顺序',
  'is_favorite': '收藏',
  'my_day_date': '我的一天',
};

/// 字段值 → 可读文案（null=无；枚举走同目录标签函数；position 浮点无意义只报"已调整"）
String _fmtValue(String field, Object? v) {
  if (v == null) return '无';
  switch (field) {
    case 'priority':
      return priorityLabel((v as num).toInt());
    case 'status':
      return statusLabel(v as String);
    case 'done':
      return v == 1 ? '已完成' : '未完成';
    case 'is_favorite':
      return v == 1 ? '是' : '否';
    case 'repeat_rule':
      final r = v as Map<String, dynamic>;
      return repeatLabelExt(
        (r['mode'] as num?)?.toInt() ?? 0,
        (r['after'] as num?)?.toInt() ?? 0,
        weekdays: (r['weekdays'] as num?)?.toInt() ?? 0,
        endType: (r['end_type'] as num?)?.toInt() ?? 0,
        endParam: (r['end_param'] as num?)?.toInt() ?? 0,
        fromDone: (r['from_done'] as num?)?.toInt() ?? 0,
      );
    case 'percent_done':
      return '$v%';
    case 'position':
      return '已调整';
    default:
      final s = '$v';
      return s.length > 30 ? '${s.substring(0, 30)}…' : s;
  }
}

/// 历史行动作文案：update 优先渲染前后值（changes），旧行回退字段名（fields）；
/// 标签动作拼标签名；detail 非法 JSON 回退动作文案
String describeActivity(String action, String detail) {
  final base = activityActionLabels[action] ?? action;
  Map<String, dynamic> d;
  try {
    final parsed = jsonDecode(detail);
    if (parsed is! Map<String, dynamic>) return base;
    d = parsed;
  } catch (_) {
    return base;
  }
  if (action == 'label_add' || action == 'label_remove') {
    final label = d['label'];
    return label is String && label.isNotEmpty ? '$base「$label」' : base;
  }
  if (_targetActions.contains(action)) {
    final target = d['target'];
    return target is String && target.isNotEmpty ? '$base「$target」' : base;
  }
  if (action != 'update') return base;
  final changes = d['changes'];
  if (changes is List && changes.isNotEmpty) {
    final parts = changes.map((c) {
      final m = c as Map<String, dynamic>;
      final field = m['field'] as String;
      final name = activityFieldLabels[field] ?? field;
      return '$name：${_fmtValue(field, m['from'])} → ${_fmtValue(field, m['to'])}';
    }).join('、');
    return '$base（$parts）';
  }
  final fields = d['fields'];
  if (fields is! List || fields.isEmpty) return base;
  final names = fields
      .map((f) => f as String)
      .map((f) => activityFieldLabels[f] ?? f)
      .join('、');
  return '$base（$names）';
}
