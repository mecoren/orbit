// 持续提醒间隔纯逻辑回归（与桌面 constant-interval.ts 同口径）：
// 归一钳制（默认 5 分钟 / [1 分钟, 24 小时]）、档位补自定义值、展示文案。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/logic/constant_interval.dart';

const int _min = 60 * 1000;

void main() {
  group('normalizeConstantIntervalMs', () {
    test('缺失/非正数回落默认 5 分钟', () {
      expect(normalizeConstantIntervalMs(null), defaultConstantIntervalMs);
      expect(normalizeConstantIntervalMs(0), defaultConstantIntervalMs);
      expect(normalizeConstantIntervalMs(-5), defaultConstantIntervalMs);
      expect(defaultConstantIntervalMs, 5 * _min);
    });

    test('越界钳到 [1 分钟, 24 小时]（与 core 同口径）', () {
      expect(normalizeConstantIntervalMs(1000), minConstantIntervalMs);
      expect(
        normalizeConstantIntervalMs(7 * 24 * 60 * _min),
        maxConstantIntervalMs,
      );
      expect(maxConstantIntervalMs, 24 * 60 * _min);
    });

    test('档位内原样返回', () {
      expect(normalizeConstantIntervalMs(15 * _min), 15 * _min);
    });
  });

  group('constantIntervalOptions', () {
    test('预设值命中时不追加', () {
      expect(constantIntervalOptions(10 * _min), [
        for (final m in constantIntervalPresetsMin) m * _min,
      ]);
    });

    test('自定义值补进档位并保持升序去重（选择器不缺当前项）', () {
      final options = constantIntervalOptions(45 * _min);
      expect(options.contains(45 * _min), isTrue);
      final sorted = [...options]..sort();
      expect(options, sorted);
      expect(options.toSet().length, options.length);
    });
  });

  group('formatConstantInterval', () {
    test('整小时档用小时措辞', () {
      expect(formatConstantInterval(60 * _min), '每 1 小时');
      expect(formatConstantInterval(120 * _min), '每 2 小时');
    });

    test('非整小时用分钟措辞（含自定义值）', () {
      expect(formatConstantInterval(5 * _min), '每 5 分钟');
      expect(formatConstantInterval(90 * _min), '每 90 分钟');
    });

    test('未设置回落默认档文案', () {
      expect(formatConstantInterval(0), '每 5 分钟');
    });
  });
}
