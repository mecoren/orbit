// apps/mobile/lib/modules/todo/logic/parse_quick_input.dart
//
// NLP 快速输入规则解析器 v2 —— 同源移植桌面端
// apps/desktop/src/features/todo/shared/parse-quick-input.ts（07 报告 §五-P1#7
// 日期/优先级/项目/标签；docs/13 §五 F4 补时刻/时长/重复）。
// 双端共享测试向量 parse-quick-input-vectors.json 是行为唯一真相源，
// 改本文件必须同步改 TS 侧并跑同一组向量。
//
// 纯函数、零 UI 依赖，可直接单测。语法（中文优先，大小写敏感仅限拉丁 token）：
//   日期：今天/明天/后天/大后天 | 今晚/明晚（=当天/次日零点，无显式时刻不猜）|
//         周X·星期X·礼拜X（未来最近，含今天）| 下周X·下星期X·下礼拜X |
//         M月d日·M月d号（今年已过则顺延一年）
//   时刻：HH:mm（含全角冒号）| 时段词+X点(半)（凌晨/清晨/早上/上午/中午/下午/
//         傍晚/晚上；中午仅认 11/12/1/2 点的口语窗口）| X点半·X点钟 |
//         今晚/明晚X点（组合词，时段按晚上计）
//   时长：N小时 / N分钟 / Nh / N小时M分钟（组合）/ 半小时
//   重复：每天 | 每周X | 每周 | 每月X号 | 每月 → repeat_* 三列并给出锚点日
//   优先级：!1 ~ !5（!6+ 不识别，原样保留）
//   项目：#名称 —— 项目标题精确匹配优先，其次第一个前缀命中
//   标签：@名称 —— 同上，可出现多个（去重）
//
// 组合规则：显式日期 token 与时刻组合；无日期时取重复锚点，再无则默认今天；
// 纯时刻已过顺延明天（重复为按天档同样顺延；周/月锚点保序列对齐不顺延）。
// 重复不覆盖显式日期 token。
//
// 边界规则：长词优先、命中区间互斥、未匹配 token 原样保留（歧义不猜测）；
// 时刻/时长对前后文做守卫（数字粘连、相对语后缀）。#/@ 名称以空白或中英文
// 常用标点收尾。

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

/// 重复规则解析结果（todo_tasks.repeat_* 三列的子集；
/// 结束条件/月高级语义不参与 NLP，走表单编辑器）
class ParsedRepeat {
  /// 1 按天 2 按周 3 按月（与 repeat_mode 列同口径）
  final int mode;

  /// 间隔数（NLP 恒 1）
  final int after;

  /// 星期几位掩码 bit0=周一…bit6=周日（仅周档；0 = 按 due 的星期）
  final int weekdays;

  const ParsedRepeat({
    required this.mode,
    required this.after,
    required this.weekdays,
  });

  @override
  bool operator ==(Object other) =>
      other is ParsedRepeat &&
      other.mode == mode &&
      other.after == after &&
      other.weekdays == weekdays;

  @override
  int get hashCode => Object.hash(mode, after, weekdays);
}

/// 解析结果
class ParsedQuickInput {
  /// 剥离全部命中 token 并收敛空白后的标题
  final String title;

  /// 截止日期；无显式时刻时为当日零点，组合时刻时携带时刻位
  final DateTime? dueDate;

  /// true = dueDate 时刻位来自显式时刻 token，消费端勿再归一零点/视图 18 点
  final bool dueHasTime;

  /// 1-5；0 = 输入中未指定
  final int priority;

  /// 项目 id（null = 未指定）
  final int? projectId;

  /// 标签 id 列表（去重，按命中顺序）
  final List<int> labelIds;

  /// 预计时长（分钟）；null = 未命中
  final int? durationMinutes;

  /// 命中即非 null；dueDate 同时给出锚点日（无显式日期时）
  final ParsedRepeat? repeat;

  const ParsedQuickInput({
    required this.title,
    required this.dueDate,
    required this.dueHasTime,
    required this.priority,
    required this.projectId,
    required this.labelIds,
    required this.durationMinutes,
    required this.repeat,
  });
}

const _weekdayCn = {
  '一': 1,
  '二': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '日': 0,
  '天': 0,
};
const _relativeDays = {'今天': 0, '明天': 1, '后天': 2, '大后天': 3};

/// 时段词 → 是否午后（午后小时数 <12 时 +12；12 点恒 12 点口径）
const _pmParts = {'下午', '傍晚', '晚上'};

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

/// 未来最近的 X 号（含今天；目标月无该日号则顺延，如 31 号跳过小月）；无效返回 null
DateTime? _nextMonthlyAnchor(DateTime now, int dayOfMonth) {
  for (var add = 0; add < 12; add++) {
    final cand = DateTime(now.year, now.month + add, dayOfMonth);
    // DateTime 构造会静默滚动非法日号（8月32日 → 9月1日）—— day 不符即该月无此日号
    if (cand.day != dayOfMonth) continue;
    if (!cand.isBefore(_startOfDay(now))) return cand;
  }
  return null;
}

class _Strip {
  final int start;
  final int end;
  const _Strip(this.start, this.end);
}

class _TimeToken {
  final int h;
  final int m;
  const _TimeToken(this.h, this.m);
}

ParsedQuickInput parseQuickInput(String raw, QuickInputContext ctx) {
  final strips = <_Strip>[];
  DateTime? dueDate;
  var priority = 0;
  int? projectId;
  final labelIds = <int>[];
  int? durationMinutes;
  ParsedRepeat? repeat;
  // 重复 token 给出的锚点日（无显式日期 token 时的 due 起点）
  DateTime? repeatAnchor;
  // 显式时刻 token（位置后者覆盖，与日期 token 同口径）
  _TimeToken? timeToken;

  var dueDateStart = -1;
  var timeStart = -1;

  // 多个日期 token 时靠文本位置后者覆盖（如「下周三复查 改明天」以 明天 为准）
  void setDueDate(int start, DateTime d) {
    if (start >= dueDateStart) {
      dueDate = d;
      dueDateStart = start;
    }
  }

  void setTime(int start, int h, int m) {
    if (start >= timeStart) {
      timeToken = _TimeToken(h, m);
      timeStart = start;
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

  final jsDay = ctx.now.weekday % 7; // 周日 7→0，其余同号（JS getDay 口径）

  // ---- 重复（先于 周X/M月d日：每周X 内含 周X，先到先得防拆词）----
  take(RegExp(r'每月(\d{1,2})[日号]'), (m) {
    final anchor = _nextMonthlyAnchor(ctx.now, int.parse(m[1]!));
    if (anchor == null) return false; // 每月0号/32号 —— 无效保留原文
    repeat = ParsedRepeat(mode: 3, after: 1, weekdays: 0);
    repeatAnchor = anchor;
    return true;
  });
  take(RegExp(r'每周([一二三四五六日天])'), (m) {
    final wd = _weekdayCn[m[1]!]!;
    repeat = ParsedRepeat(mode: 2, after: 1, weekdays: 1 << ((wd + 6) % 7));
    repeatAnchor = _addDays(ctx.now, (wd - jsDay + 7) % 7); // 未来最近，含今天
    return true;
  });
  take(RegExp('(每天|每周|每月)'), (m) {
    // 「每月32号」整词已被上方 X号 形态拒绝时，裸词不得再吃掉 每月 前缀
    if (m[1] == '每月' &&
        RegExp(r'^\s*\d{1,2}\s*[日号]').hasMatch(raw.substring(m.end))) {
      return false;
    }
    repeat = ParsedRepeat(
      mode: m[1] == '每天'
          ? 1
          : m[1] == '每周'
          ? 2
          : 3,
      after: 1,
      weekdays: 0,
    );
    repeatAnchor = _addDays(ctx.now, 0);
    return true;
  });

  // ---- 今晚/明晚X点（组合词：日期 + 晚间 12 小时制时刻），先于裸 今晚/明晚 ----
  take(RegExp('(今晚|明晚)\\s*(\\d{1,2})\\s*点(?:钟)?(半)?'), (m) {
    final h = int.parse(m[2]!);
    if (h < 1 || h > 12) return false;
    setDueDate(m.start, _addDays(ctx.now, m[1] == '明晚' ? 1 : 0));
    setTime(m.start, h < 12 ? h + 12 : 12, m[3] != null ? 30 : 0);
    return true;
  });
  take(RegExp('(今晚|明晚)'), (m) {
    setDueDate(m.start, _addDays(ctx.now, m[1] == '明晚' ? 1 : 0));
    return true;
  });

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

  // ---- 时刻：时段词 + X点(半)（上午13点 / 中午3点 这类越界词不识别保原文）----
  take(RegExp('(凌晨|清晨|早上|上午|中午|下午|傍晚|晚上)\\s*(\\d{1,2})\\s*点(?:钟)?(半)?'), (m) {
    final part = m[1]!;
    final h = int.parse(m[2]!);
    final halfMin = m[3] != null ? 30 : 0;
    if (part == '中午') {
      // 口语窗口约 11:00–14:00：11 点按上午、12 点恒正午、1/2 点按午后
      if (h == 12) {
        setTime(m.start, 12, halfMin);
      } else if (h == 1 || h == 2) {
        setTime(m.start, h + 12, halfMin);
      } else if (h == 11) {
        setTime(m.start, 11, halfMin);
      } else {
        return false;
      }
      return true;
    }
    if (h > 12) return false;
    if (_pmParts.contains(part)) {
      setTime(m.start, h < 12 ? h + 12 : 12, halfMin);
    } else {
      setTime(m.start, h, halfMin);
    }
    return true;
  });
  // ---- 时刻：X点半 / X点钟（裸数字必须带 半/钟 后缀，防「三点原因」枚举误伤）----
  take(RegExp(r'(\d{1,2})\s*点(?:钟|半)'), (m) {
    final h = int.parse(m[1]!);
    if (h > 23) return false;
    setTime(m.start, h, m[0]!.endsWith('半') ? 30 : 0);
    return true;
  });
  // ---- 时刻：HH:mm（前后不得粘连数字，防「比分2:10」「13:45:22」误伤）----
  take(RegExp(r'(\d{1,2})[:：](\d{2})'), (m) {
    final s = m.start;
    final e = m.end;
    if (s > 0 && RegExp('[0-9]').hasMatch(raw[s - 1])) return false;
    if (e < raw.length && RegExp('[0-9:：]').hasMatch(raw[e])) return false;
    final h = int.parse(m[1]!);
    final min = int.parse(m[2]!);
    if (h > 23 || min > 59) return false;
    setTime(s, h, min);
    return true;
  });

  // ---- 优先级 !1-!5（负向先行排除 !12 这类多位数的前缀误命中）----
  take(RegExp(r'!([1-5])(?!\d)'), (m) {
    priority = int.parse(m[1]!);
    return true;
  });
  // ---- 项目 #名称（名称不含空白、#@! 与常用标点）----
  take(
    RegExp(
      r'#([^\s#!@，。；、！？,.;;!?()（）\[\]【】""'
      '""]+)',
    ),
    (m) {
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
    },
  );
  // ---- 标签 @名称（可多个）----
  take(
    RegExp(
      r'@([^\s#!@，。；、！？,.;;!?()（）\[\]【】""'
      '""]+)',
    ),
    (m) {
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
    },
  );

  // ---- 时长（多 token 后者覆盖，与日期同口径）----
  take(RegExp(r'(\d+)\s*个?小时\s*(\d{1,2})\s*分钟'), (m) {
    durationMinutes = int.parse(m[1]!) * 60 + int.parse(m[2]!);
    return true;
  });
  take(RegExp(r'半\s*个?小时'), (m) {
    if (m.start > 0 && RegExp('[0-9一两几个]').hasMatch(raw[m.start - 1])) {
      return false; // 一个半小时
    }
    if (m.end < raw.length && RegExp('[后之以内]').hasMatch(raw[m.end])) {
      return false; // 半小时后（相对语）
    }
    durationMinutes = 30;
    return true;
  });
  take(RegExp(r'(\d+(?:\.\d+)?)\s*(?:个?小时|分钟|[hH])'), (m) {
    if (m.end < raw.length && RegExp('[0-9a-zA-Z]').hasMatch(raw[m.end])) {
      return false; // 2https 这类粘连
    }
    if (m.end < raw.length && RegExp('[后之以内]').hasMatch(raw[m.end])) {
      return false; // 30分钟后 / 2小时内
    }
    final n = double.parse(m[1]!);
    final isHours = RegExp('[hH]|小时').hasMatch(m[0]!);
    durationMinutes = isHours ? (n * 60).round() : n.round();
    return true;
  });

  // ---- 时刻与日期/重复锚点组合 ----
  var finalDue = dueDate; // 显式日期 token（含 今晚/明晚）
  if (finalDue == null && repeatAnchor != null) finalDue = repeatAnchor;
  var dueHasTime = false;
  final t = timeToken;
  if (t != null) {
    finalDue ??= _startOfDay(ctx.now); // 纯时刻：默认今天
    var combined = DateTime(
      finalDue.year,
      finalDue.month,
      finalDue.day,
      t.h,
      t.m,
    );
    // 已过顺延明天：仅无显式日期时；重复为按天档同样顺延，周/月锚点保
    // 序列对齐不顺延（当天实例落为逾期，完成引擎仍正确推进）
    if (dueDate == null &&
        combined.isBefore(ctx.now) &&
        (repeat == null || repeat!.mode == 1)) {
      combined = DateTime(
        finalDue.year,
        finalDue.month,
        finalDue.day + 1,
        t.h,
        t.m,
      );
    }
    finalDue = combined;
    dueHasTime = true;
  }

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
    dueDate: finalDue,
    dueHasTime: dueHasTime,
    priority: priority,
    projectId: projectId,
    labelIds: List.unmodifiable(labelIds),
    durationMinutes: durationMinutes,
    repeat: repeat,
  );
}
