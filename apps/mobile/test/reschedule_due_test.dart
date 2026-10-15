// 月历改期时间语义（rescheduleDueMs）：与桌面 shared/reschedule-due.test.ts
// 六条用例一一对应（无截止 / 零点 / 带时刻 / 同日两种 / 跨年边界）。
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/modules/todo/logic/reschedule_due.dart';

void main() {
  group('rescheduleDueMs 改期时间语义（桌面 reschedule-due 同口径）', () {
    test('无截止任务落到目标日 18:00', () {
      expect(
        rescheduleDueMs(null, DateTime(2026, 9, 20)),
        DateTime(2026, 9, 20, 18).millisecondsSinceEpoch,
      );
    });

    test('原截止零点（仅日期语义）落到目标日 18:00', () {
      final orig = DateTime(2026, 9, 10).millisecondsSinceEpoch;
      expect(
        rescheduleDueMs(orig, DateTime(2026, 9, 20)),
        DateTime(2026, 9, 20, 18).millisecondsSinceEpoch,
      );
    });

    test('原截止带时刻 → 保留时分只换日期', () {
      final orig = DateTime(2026, 9, 10, 15, 30).millisecondsSinceEpoch;
      // 目标取日期分量，目标自带时刻无关
      expect(
        rescheduleDueMs(orig, DateTime(2026, 9, 20, 3)),
        DateTime(2026, 9, 20, 15, 30).millisecondsSinceEpoch,
      );
    });

    test('同日落回原处返回 null（不写库）', () {
      final orig = DateTime(2026, 9, 10, 15, 30).millisecondsSinceEpoch;
      expect(rescheduleDueMs(orig, DateTime(2026, 9, 10)), isNull);
    });

    test('零点同日同样返回 null（不得升级成 18:00）', () {
      final orig = DateTime(2026, 9, 10).millisecondsSinceEpoch;
      expect(rescheduleDueMs(orig, DateTime(2026, 9, 10)), isNull);
    });

    test('跨月/跨年边界正确换算', () {
      final orig = DateTime(2026, 12, 30, 9).millisecondsSinceEpoch;
      expect(
        rescheduleDueMs(orig, DateTime(2027, 1, 2)),
        DateTime(2027, 1, 2, 9).millisecondsSinceEpoch,
      );
    });

    test('毫秒分量随时刻一并保留（桌面 setHours 含 ms 同口径）', () {
      final orig = DateTime(2026, 9, 10, 15, 30, 0, 250).millisecondsSinceEpoch;
      expect(
        rescheduleDueMs(orig, DateTime(2026, 9, 20)),
        DateTime(2026, 9, 20, 15, 30, 0, 250).millisecondsSinceEpoch,
      );
    });
  });
}
