import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/modules/todo/logic/template_apply.dart';

/// 模板套用预填纯函数单测（与桌面 template-apply.test.ts 同口径）
void main() {
  group('parseTemplatePayload', () {
    test('全字段解析', () {
      final p = parseTemplatePayload(
          '{"title":"周报","notes":"格式说明","priority":3,"due_offset_days":2,"subtasks":["a","b"]}');
      expect(p.title, '周报');
      expect(p.notes, '格式说明');
      expect(p.priority, 3);
      expect(p.dueOffsetDays, 2);
      expect(p.subtasks, ['a', 'b']);
    });

    test('空对象返回空预填（isEmpty）', () {
      final p = parseTemplatePayload('{}');
      expect(p.isEmpty, isTrue);
    });

    test('非法 JSON / 非对象返回空（不抛）', () {
      expect(parseTemplatePayload('not-json').isEmpty, isTrue);
      expect(parseTemplatePayload('[1,2]').isEmpty, isTrue);
      expect(parseTemplatePayload('"str"').isEmpty, isTrue);
    });

    test('类型不符键静默跳过', () {
      final p = parseTemplatePayload('{"title":123,"priority":"高"}');
      expect(p.title, isNull);
      expect(p.priority, isNull);
    });

    test('subtasks 混入非字符串时整组丢弃', () {
      final p = parseTemplatePayload('{"subtasks":["a",1]}');
      expect(p.subtasks, isEmpty);
    });
  });

  group('templateDueDateMs', () {
    test('offset 0 = 今天本地零点', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      expect(templateDueDateMs(0), today.millisecondsSinceEpoch);
    });

    test('offset 1 = 明天零点（跨月末由 DateTime 自进位）', () {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final expected =
          DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
      expect(templateDueDateMs(1), expected.millisecondsSinceEpoch);
    });
  });
}
