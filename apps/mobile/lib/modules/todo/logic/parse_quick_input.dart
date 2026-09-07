// apps/mobile/lib/modules/todo/logic/parse_quick_input.dart
//
// NLP 快速输入规则解析器 v1 —— 同源移植桌面端
// apps/desktop/src/features/todo/shared/parse-quick-input.ts（07 报告 §五-P1#7）。
//
// 纯函数、零 UI 依赖，可直接单测。语法（中文优先，大小写敏感仅限拉丁 token）：
//   日期：今天/明天/后天/大后天 | 周X·星期X·礼拜X（未来最近，含今天）|
//         下周X·下星期X·下礼拜X（下周一为首周的对应日）|
//         M月d日·M月d号（今年已过则顺延一年）
//   优先级：!1 ~ !5（!6+ 不识别，原样保留）
//   项目：#名称 —— 项目标题精确匹配优先，其次第一个前缀命中
//   标签：@名称 —— 同上，可出现多个（去重）
//
// 边界规则：日期/优先级为封闭词形，文本任意位置可命中；
// #/@ 名称以空白或中英文常用标点收尾。所有命中区间互斥——先命中的
// 长词保护内部短词不被二次解析（如下周三 中的 周三）。
// 未匹配的 #/@ token 原样保留在标题中，避免误删用户文字。

/// 项目/标签名条目（id + 标题）
class QuickInputRef {
  final int id;
  final String title;

  const QuickInputRef({required this.id, required this.title});
}

/// 解析上下文：可选项目/标签 + 基准时刻（测试注入；生产传 DateTime.now()）
class QuickInputContext {
  final List<QuickInputRef> projects;
  final List<QuickInputRef> labels;
  final DateTime now;

  const QuickInputContext({
    this.projects = const [],
    this.labels = const [],
    required this.now,
  });
}

/// 解析结果
class ParsedQuickInput {
  /// 剥离全部命中 token 并收敛空白后的标题
  final String title;

  /// 截止日期（当日零点；null = 未指定）
  final DateTime? dueDate;

  /// 1-5；0 = 输入中未指定
  final int priority;

  /// 项目 id（null = 未指定）
  final int? projectId;

  /// 标签 id 列表（去重，按命中顺序）
  final List<int> labelIds;

  const ParsedQuickInput({
    required this.title,
    required this.dueDate,
    required this.priority,
    required this.projectId,
    required this.labelIds,
  });
}

const _weekdayCn = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 0, '天': 0};
const _relativeDays = {'今天': 0, '明天': 1, '后天': 2, '大后天': 3};

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _addDays(DateTime d, int n) => _startOfDay(d).add(Duration(days: n));

/// 距下一个周一的天数（今天为周一也取下周一），与桌面 nextMondayDelta 同口径
int _nextMondayDelta(DateTime now) {
  // DateTime.weekday：周一=1 … 周日=7（与 JS getDay 0=周日不同）；
  // JS `((8 - day) % 7) || 7` 的 || 兜底在 Dart 写成显式判断
  final delta = (8 - now.weekday) % 7;
  return delta == 0 ? 7 : delta;
}

/// 下周的周 X（周一为首日；wd 口径 0=周日，同桌面 WEEKDAY_CN）
DateTime _nextWeekWeekday(DateTime now, int wd) {
  final posFromMonday = (wd + 6) % 7; // 周一=0 … 周日=6
  return _addDays(now, _nextMondayDelta(now) + posFromMonday);
}

class _Strip {
  final int start;
  final int end;
  const _Strip(this.start, this.end);
}

ParsedQuickInput parseQuickInput(String raw, QuickInputContext ctx) {
  final strips = <_Strip>[];
  DateTime? dueDate;
  var priority = 0;
  int? projectId;
  final labelIds = <int>[];

  var dueDateStart = -1;

  // 多个日期 token 时靠文本位置后者覆盖（如「下周三复查 改明天」以 明天 为准）
  void setDueDate(int start, DateTime d) {
    if (start >= dueDateStart) {
      dueDate = d;
      dueDateStart = start;
    }
  }

  bool overlaps(int start, int end) =>
      strips.any((s) => start < s.end && s.start < end);

  // 依次消费每个匹配：consume 返回 true 才剥离该区间
  // （Dart RegExp 无 lastIndex 状态机，用 allMatches + 逐个判断）
  void take(Pattern re, bool Function(Match m) consume) {
    for (final m in re.allMatches(raw)) {
      final end = m.end;
      if (overlaps(m.start, end)) continue;
      if (!consume(m)) continue;
      strips.add(_Strip(m.start, end));
    }
  }

  // ---- 相对日词（大后天 必须列在 后天 前，保证长词优先）----
  take(RegExp('(?:大后天|后天|明天|今天)'), (m) {
    final token = m[0]!;
    setDueDate(m.start, _addDays(ctx.now, _relativeDays[token]!));
    return true;
  });
  // ---- 下周X ----
  take(RegExp('(?:下周|下星期|下礼拜)([一二三四五六日天])'), (m) {
    setDueDate(m.start, _nextWeekWeekday(ctx.now, _weekdayCn[m[1]!]!));
    return true;
  });
  // ---- 周X（未来最近，含今天）----
  take(RegExp('(?:周|星期|礼拜)([一二三四五六日天])'), (m) {
    // JS getDay 0=周日 ↔ Dart weekday 1=周一…7=周日，换算后同式
    final jsDay = ctx.now.weekday % 7; // 周日 7→0，其余同号
    final delta = (_weekdayCn[m[1]!]! - jsDay + 7) % 7;
    setDueDate(m.start, _addDays(ctx.now, delta));
    return true;
  });
  // ---- M月d日 / M月d号 ----
  take(RegExp(r'(\d{1,2})月(\d{1,2})[日号]'), (m) {
    final month = int.parse(m[1]!) - 1;
    final dayOfMonth = int.parse(m[2]!);
    if (month < 0 || month > 11 || dayOfMonth < 1 || dayOfMonth > 31) {
      return false;
    }
    var cand = DateTime(ctx.now.year, month + 1, dayOfMonth);
    // DateTime 构造会静默滚动非法日期（2026-02-29 → 03-01）—— 视为无效保留原文
    if (cand.month != month + 1 || cand.day != dayOfMonth) return false;
    if (cand.isBefore(_startOfDay(ctx.now))) {
      cand = DateTime(ctx.now.year + 1, month + 1, dayOfMonth);
    }
    setDueDate(m.start, cand);
    return true;
  });
  // ---- 优先级 !1-!5（负向先行排除 !12 这类多位数的前缀误命中）----
  take(RegExp(r'!([1-5])(?!\d)'), (m) {
    priority = int.parse(m[1]!);
    return true;
  });
  // ---- 项目 #名称（名称不含空白、#@! 与常用标点）----
  take(RegExp(r'#([^\s#!@，。；、！？,.;;!?()（）\[\]【】""''""]+)'), (m) {
    final name = m[1]!;
    QuickInputRef? hit;
    for (final p in ctx.projects) {
      if (p.title == name) {
        hit = p;
        break;
      }
    }
    hit ??= ctx.projects.where((p) => p.title.startsWith(name)).firstOrNull;
    if (hit == null) return false; // 未匹配：保留原文
    projectId = hit.id;
    return true;
  });
  // ---- 标签 @名称（可多个）----
  take(RegExp(r'@([^\s#!@，。；、！？,.;;!?()（）\[\]【】""''""]+)'), (m) {
    final name = m[1]!;
    QuickInputRef? hit;
    for (final l in ctx.labels) {
      if (l.title == name) {
        hit = l;
        break;
      }
    }
    hit ??= ctx.labels.where((l) => l.title.startsWith(name)).firstOrNull;
    if (hit == null) return false;
    if (!labelIds.contains(hit.id)) labelIds.add(hit.id);
    return true;
  });

  // ---- 剥离命中区间并收敛空白 ----
  final buf = StringBuffer();
  var cursor = 0;
  for (final s in strips..sort((a, b) => a.start.compareTo(b.start))) {
    buf.write(raw.substring(cursor, s.start));
    cursor = s.end;
  }
  buf.write(raw.substring(cursor));

  return ParsedQuickInput(
    title: buf.toString().replaceAll(RegExp(r'\s{2,}'), ' ').trim(),
    dueDate: dueDate,
    priority: priority,
    projectId: projectId,
    labelIds: List.unmodifiable(labelIds),
  );
}
