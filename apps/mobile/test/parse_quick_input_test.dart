// parseQuickInput 规则表驱动测试 —— 桌面端
// apps/desktop/src/features/todo/shared/parse-quick-input.test.ts 17 用例同源随迁
// 基准时刻 2026-08-26 为周三；日期 token 一律落到当日零点（本地时区）。
//
// F4（时刻/时长/重复）用例来自双端共享向量
// apps/desktop/src/features/todo/shared/parse-quick-input-vectors.json
// ——与 TS 侧跑同一组输入/期望，防两套解析器漂移。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/modules/todo/logic/parse_quick_input.dart';

/// 定位共享向量 JSON：flutter test 的工作目录是包根（apps/mobile），
/// 兼容从仓库根/其它目录发起的运行（向上找 apps/desktop 下该文件）。
File _findVectorsFile() {
  const rel =
      'apps/desktop/src/features/todo/shared/parse-quick-input-vectors.json';
  final cwd = Directory.current;
  final candidates = <String>[
    // cwd=apps/mobile：兄弟目录直连
    '${cwd.parent.path}/desktop/src/features/todo/shared/parse-quick-input-vectors.json',
    '${cwd.path}/$rel',
    for (var d = cwd; d.parent.path != d.path; d = d.parent) '${d.path}/$rel',
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  fail(
    '找不到共享向量 JSON（apps/desktop/src/features/todo/shared/），'
    '当前工作目录：${cwd.path}',
  );
}

/// "2026-08-27T15:00" → 本地时区 DateTime（不写绝对时间戳，任意时区机器可复算）
DateTime _localDate(String s) {
  final parts = s.split('T');
  final d = parts[0].split('-').map(int.parse).toList();
  final t = parts.length > 1
      ? parts[1].split(':').map(int.parse).toList()
      : const [0, 0];
  return DateTime(d[0], d[1], d[2], t[0], t[1]);
}

void main() {
  final now = DateTime(2026, 8, 26, 15, 30); // 周三
  DateTime day(int month1based, int d) => DateTime(2026, month1based, d);

  final ctx = QuickInputContext(
    projects: const [
      QuickInputRef(id: 1, title: '工作'),
      QuickInputRef(id: 2, title: '工作汇报'),
      QuickInputRef(id: 7, title: '生活'),
    ],
    labels: const [
      QuickInputRef(id: 10, title: '家人'),
      QuickInputRef(id: 11, title: '紧急跟进'),
    ],
    now: now,
  );

  group('parseQuickInput · 日期', () {
    test('明天 → 次日零点，正文剥离', () {
      final r = parseQuickInput('明天开会', ctx);
      expect(r.title, '开会');
      expect(r.dueDate, day(8, 27));
    });

    test('大后天 → +3 天', () {
      final r = parseQuickInput('交周报 大后天', ctx);
      expect(r.dueDate, day(8, 29));
      expect(r.title, '交周报');
    });

    test('周X → 未来最近（含今天）：周五聚餐', () {
      final r = parseQuickInput('周五聚餐', ctx); // 周三→周五 = +2
      expect(r.dueDate, day(8, 28));
    });

    test('今天恰逢周X → 取今天', () {
      final r = parseQuickInput('周三站会', ctx);
      expect(r.dueDate, day(8, 26));
    });

    test('下周X → 下周一为首日的下周对应日', () {
      final r = parseQuickInput('下周三复查', ctx); // 下周一=08-31，+2 → 09-02
      expect(r.dueDate, day(9, 2));
    });

    test('M月d日 今年未过 → 今年；已过 → 顺延一年', () {
      expect(parseQuickInput('9月10日体检', ctx).dueDate, day(9, 10));
      expect(parseQuickInput('1月5日续费', ctx).dueDate, DateTime(2027, 1, 5));
    });

    test('多个日期 token：靠后者覆盖；下周X 不被内层 周X 二次命中', () {
      final r = parseQuickInput('下周三复查 改明天', ctx);
      expect(r.dueDate, day(8, 27));
      expect(r.title, '复查 改');
    });
  });

  group('parseQuickInput · 优先级/项目/标签', () {
    test('!1-!5 提取优先级', () {
      expect(parseQuickInput('买菜 !3', ctx).priority, 3);
      expect(parseQuickInput('买菜', ctx).priority, 0);
    });

    test('#项目 精确优先于前缀；前缀唯一命中可用', () {
      expect(parseQuickInput('#工作 计划', ctx).projectId, 1);
      expect(parseQuickInput('#工作汇 计划', ctx).projectId, 2);
    });

    test('@标签 可多个且去重', () {
      final r = parseQuickInput('买礼物 @家人 @家人 @紧急跟进', ctx);
      expect(r.labelIds, [10, 11]);
    });

    test('项目名以标点收尾也能截断（中文无空格场景）', () {
      final r = parseQuickInput('#生活，明天交电费', ctx);
      expect(r.projectId, 7);
      expect(r.title, '，交电费');
      expect(r.dueDate, day(8, 27));
    });
  });

  group('parseQuickInput · 兜底语义', () {
    test('未匹配的 #token 原样保留在标题', () {
      final r = parseQuickInput('事项 #不存在', ctx);
      expect(r.projectId, isNull);
      expect(r.title, '事项 #不存在');
    });

    test('无 token 时原样返回', () {
      final r = parseQuickInput('纯文本任务', ctx);
      expect(r.title, '纯文本任务');
      expect(r.dueDate, isNull);
      expect(r.priority, 0);
      expect(r.labelIds, isEmpty);
    });

    test('剥离后收敛多余空白', () {
      expect(parseQuickInput('买 牛奶  明天', ctx).title, '买 牛奶');
    });

    test('!10 以上不识别且不损坏标题（评审修复：负向先行）', () {
      final r = parseQuickInput('买菜 !12', ctx);
      expect(r.title, '买菜 !12');
      expect(r.priority, 0);
    });

    test('无效日期（平年 2月29日）不静默滚动，保留原文', () {
      final r = parseQuickInput('2月29日聚会', ctx);
      expect(r.dueDate, isNull);
      expect(r.title, '2月29日聚会');
    });

    test('词形变体：今天/后天/星期X/礼拜X/M月d号', () {
      expect(parseQuickInput('今天交', ctx).dueDate, day(8, 26));
      expect(parseQuickInput('后天搬', ctx).dueDate, day(8, 28));
      expect(parseQuickInput('星期四复诊', ctx).dueDate, day(8, 27));
      expect(parseQuickInput('礼拜六加班', ctx).dueDate, day(8, 29));
      expect(parseQuickInput('9月10号体检', ctx).dueDate, day(9, 10));
    });
  });

  // ---- F4 共享向量（docs/13 §五；JSON 为双端唯一真相源）----
  group('parseQuickInput · F4 共享向量（时刻/时长/重复）', () {
    final spec =
        jsonDecode(_findVectorsFile().readAsStringSync())
            as Map<String, dynamic>;
    final vectorCtx = QuickInputContext(
      projects: [
        for (final p in (spec['projects'] as List))
          QuickInputRef(id: p['id'] as int, title: p['title'] as String),
      ],
      labels: [
        for (final l in (spec['labels'] as List))
          QuickInputRef(id: l['id'] as int, title: l['title'] as String),
      ],
      now: _localDate(spec['now'] as String),
    );

    for (final v in (spec['vectors'] as List)) {
      final name = v['name'] as String;
      final input = v['input'] as String;
      final e = (v['expect'] as Map<String, dynamic>).cast<String, dynamic>();
      test(name, () {
        final r = parseQuickInput(input, vectorCtx);
        expect(r.title, e['title']);
        final String? due = e['due'];
        if (due != null) {
          expect(r.dueDate, isNotNull);
          expect(
            r.dueDate!.millisecondsSinceEpoch,
            _localDate(due).millisecondsSinceEpoch,
          );
        } else {
          expect(r.dueDate, isNull);
        }
        expect(r.dueHasTime, e['dueHasTime'] as bool? ?? false);
        expect(r.priority, e['priority'] as int? ?? 0);
        expect(r.projectId, e['projectId'] as int?);
        expect(r.labelIds, e['labelIds'] as List? ?? isEmpty);
        expect(r.durationMinutes, e['durationMinutes'] as int?);
        final rep = e['repeat'] as Map<String, dynamic>?;
        if (rep == null) {
          expect(r.repeat, isNull);
        } else {
          expect(
            r.repeat,
            ParsedRepeat(
              mode: rep['mode'] as int,
              after: rep['after'] as int,
              weekdays: rep['weekdays'] as int,
            ),
          );
        }
      });
    }
  });
}
