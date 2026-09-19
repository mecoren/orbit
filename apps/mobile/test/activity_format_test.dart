// describeActivity 纯函数测试：镜像桌面 activity-format.test.ts 口径
// （三代 detail 形状回退 + 字段值格式化 + 非法 JSON 兜底）
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/logic/activity_format.dart';

void main() {
  group('describeActivity', () {
    test('新行 changes：枚举走标签口径、字符串原样、长文本 30 字截断', () {
      final long = '题' * 34;
      final detail = jsonEncode({
        'fields': ['priority', 'status', 'title'],
        'changes': [
          {'field': 'priority', 'from': 0, 'to': 4},
          {'field': 'status', 'from': 'pending', 'to': 'doing'},
          {'field': 'title', 'from': '短标题', 'to': long},
        ],
      });
      expect(
        describeActivity('update', detail),
        '更新（优先级：无 → 紧急、状态：待办 → 进行中、标题：短标题 → ${'题' * 30}…）',
      );
    });

    test('旧行 fields：无 changes 回退字段名列表', () {
      expect(
        describeActivity('update', jsonEncode({
          'fields': ['due_date', 'priority']
        })),
        '更新（截止日期、优先级）',
      );
    });

    test('done/is_favorite/percent_done/position 值口径', () {
      String one(String f, Object? from, Object? to) =>
          describeActivity('update', jsonEncode({
            'changes': [
              {'field': f, 'from': from, 'to': to}
            ]
          }));
      expect(one('done', 0, 1), '更新（完成标记：未完成 → 已完成）');
      expect(one('is_favorite', 1, 0), '更新（收藏：是 → 否）');
      expect(one('percent_done', 0, 45), '更新（进度：0% → 45%）');
      expect(one('position', 1.2, 3.4), '更新（顺序：已调整 → 已调整）');
    });

    test('repeat_rule 伪字段：整规则快照走 repeatLabelExt', () {
      final snap = {
        'mode': 2,
        'after': 1,
        'weekdays': 0,
        'end_type': 0,
        'end_param': 0,
        'from_done': 0,
      };
      final weeklyMask = {...snap, 'weekdays': 0x11}; // bit0+bit4 = 周一+周五
      final weeklyFromDone = {...snap, 'from_done': 1};
      final detail = jsonEncode({
        'changes': [
          {'field': 'repeat_rule', 'from': {'mode': 0, 'after': 1, 'weekdays': 0, 'end_type': 0, 'end_param': 0, 'from_done': 0}, 'to': snap},
          {'field': 'repeat_rule', 'from': snap, 'to': weeklyMask},
          {'field': 'repeat_rule', 'from': snap, 'to': weeklyFromDone},
        ]
      });
      expect(
        describeActivity('update', detail),
        '更新（重复规则：不重复 → 每周、重复规则：每周 → 每周一五、'
        '重复规则：每周 → 每周（按完成日））',
      );
    });

    test('标签动作拼标签名', () {
      expect(
        describeActivity('label_add', jsonEncode({'label': '工作'})),
        '添加标签「工作」',
      );
      expect(
        describeActivity('label_remove', jsonEncode({'label': '工作'})),
        '移除标签「工作」',
      );
    });

    test('从属对象动作拼 target（子任务/评论/提醒/滚周期）', () {
      expect(
        describeActivity('subtask_add', jsonEncode({'target': '整理清单'})),
        '添加子任务「整理清单」',
      );
      expect(
        describeActivity('comment_add', jsonEncode({'target': '评审会周四开'})),
        '添加评论「评审会周四开」',
      );
      expect(
        describeActivity('repeat_rollover', jsonEncode({'target': '2026-09-26 09:00'})),
        '已滚动下一周期「2026-09-26 09:00」',
      );
    });

    test('create（含滚周期来源 detail）只报动作文案', () {
      expect(describeActivity('create', '{}'), '创建了任务');
      expect(
        describeActivity('create', jsonEncode({'from': 'repeat', 'parent_id': 7})),
        '创建了任务',
      );
    });

    test('detail 非法 JSON / 非对象 / 未映射 action 均回退', () {
      expect(describeActivity('update', 'not-json'), '更新');
      expect(describeActivity('update', '[1,2]'), '更新');
      expect(describeActivity('pinned', '{}'), 'pinned');
    });
  });
}
