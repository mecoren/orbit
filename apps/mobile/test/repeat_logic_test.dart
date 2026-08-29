// 重复规则常量与标签（镜像桌面端 repeat.ts）单测
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/logic/repeat_logic.dart';

void main() {
  group('repeatLabel', () {
    test('mode=0 不重复', () {
      expect(repeatLabel(RepeatMode.none, 0), '不重复');
    });

    test('预设档位：间隔 1 时省略数字', () {
      expect(repeatLabel(RepeatMode.daily, 1), '每天');
      expect(repeatLabel(RepeatMode.weekly, 1), '每周');
      expect(repeatLabel(RepeatMode.monthly, 1), '每月');
      expect(repeatLabel(RepeatMode.yearly, 1), '每年');
    });

    test('自定义间隔：每 N 单位', () {
      expect(repeatLabel(RepeatMode.daily, 3), '每 3 天');
      expect(repeatLabel(RepeatMode.weekly, 2), '每 2 周');
      expect(repeatLabel(RepeatMode.monthly, 6), '每 6 个月');
      expect(repeatLabel(RepeatMode.yearly, 2), '每 2 年');
    });

    test('after<=0 按间隔 1 兜底（防脏数据）', () {
      expect(repeatLabel(RepeatMode.daily, 0), '每天');
    });
  });

  group('自定义单位 ↔ mode 映射', () {
    test('四单位映射正确', () {
      expect(modeForUnit(RepeatUnit.day), RepeatMode.daily);
      expect(modeForUnit(RepeatUnit.week), RepeatMode.weekly);
      expect(modeForUnit(RepeatUnit.month), RepeatMode.monthly);
      expect(modeForUnit(RepeatUnit.year), RepeatMode.yearly);
    });

    test('单位中文标签', () {
      expect(RepeatUnit.day.label, '天');
      expect(RepeatUnit.year.label, '年');
    });
  });

  test('预设列表：不重复 + 四预设', () {
    expect(repeatPresets.length, 5);
    expect(repeatPresets.first.label, '不重复');
  });
}
