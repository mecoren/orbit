import 'dart:convert';

/// 任务模板套用预填（纯函数；桌面 template-apply.ts 同口径）
///
/// 模板 payload 键（与 Rust ALLOWED_PAYLOAD_KEYS 同口径）：
/// title / notes / priority / due_offset_days / subtasks。
/// 套用语义：按存在键预填（缺键 = 不预填）；due_offset_days 以套用当天
/// 为基准偏移（0=今天），本地时区零点。
class TemplatePayload {
  final String? title;
  final String? notes;
  final int? priority;
  final int? dueOffsetDays;
  final List<String> subtasks;

  const TemplatePayload({
    this.title,
    this.notes,
    this.priority,
    this.dueOffsetDays,
    this.subtasks = const [],
  });

  bool get isEmpty =>
      title == null &&
      notes == null &&
      priority == null &&
      dueOffsetDays == null &&
      subtasks.isEmpty;
}

/// 解析模板 payload JSON；非法/类型不符的键静默跳过（宁缺毋错）
TemplatePayload parseTemplatePayload(String payload) {
  final dynamic parsed;
  try {
    parsed = jsonDecode(payload);
  } catch (_) {
    return const TemplatePayload();
  }
  if (parsed is! Map<String, dynamic>) return const TemplatePayload();

  return TemplatePayload(
    title: parsed['title'] is String && (parsed['title'] as String).trim().isNotEmpty
        ? parsed['title'] as String
        : null,
    notes: parsed['notes'] is String ? parsed['notes'] as String : null,
    priority: parsed['priority'] is int ? parsed['priority'] as int : null,
    dueOffsetDays:
        parsed['due_offset_days'] is int ? parsed['due_offset_days'] as int : null,
    subtasks: parsed['subtasks'] is List &&
            (parsed['subtasks'] as List).every((x) => x is String)
        ? List<String>.from(parsed['subtasks'] as List)
        : const [],
  );
}

/// 截止偏移 → 本地零点毫秒（套用当天 + N 天）
int templateDueDateMs(int offsetDays) {
  final d = DateTime.now().add(Duration(days: offsetDays));
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}
