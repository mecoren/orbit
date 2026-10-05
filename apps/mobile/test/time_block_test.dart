// 时间轴时段块布局纯函数（镜像桌面 shared/time-block.ts）单测
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/time_block.dart';

TodoTask _task({
  required int id,
  int? startDate,
  int? dueDate,
  int? durationMinutes,
  bool done = false,
  String title = 't',
}) =>
    TodoTask(
      id: id,
      uuid: 'u$id',
      title: title,
      description: null,
      projectId: null,
      priority: 0,
      status: done ? 'done' : 'pending',
      done: done ? 1 : 0,
      doneAt: null,
      dueDate: dueDate,
      startDate: startDate,
      repeatAfter: 1,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      repeatMonthMode: 0,
      repeatNthWeek: 0,
      percentDone: 0,
      position: id.toDouble(),
      isFavorite: 0,
      myDayDate: null,
      durationMinutes: durationMinutes,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      version: 1,
    );

void main() {
  // 2026-10-05 周一
  final day0 = DateTime(2026, 10, 5).millisecondsSinceEpoch;
  const day = 86400000;

  /// 当日 HH:mm 的时间戳（固定日期，断言不随真实时间漂移）
  int at(int h, [int m = 0]) =>
      DateTime(2026, 10, 5, h, m).millisecondsSinceEpoch;

  group('hasTimePart（本地字段判时刻）', () {
    test('零点为 false，带时刻为 true', () {
      expect(hasTimePart(day0), isFalse);
      expect(hasTimePart(null), isFalse);
      expect(hasTimePart(at(9, 30)), isTrue);
      // 00:00 加 1 毫秒也算带时刻
      expect(hasTimePart(day0 + 1), isTrue);
    });
  });

  group('taskTimeBlock 起算口径', () {
    test('start 带时刻 → 直接用（显式排程最强）', () {
      final b = taskTimeBlock(_task(id: 1, startDate: at(9), dueDate: at(18)));
      expect(b!.startMs, at(9));
      // 未设时长 → 默认 30（显式 start 优先于 due，故不倒推）
      expect(b.durationMin, 30);
    });

    test('仅 due 带时刻 → 按截止倒推 due − 时长', () {
      final b = taskTimeBlock(_task(id: 2, dueDate: at(18), durationMinutes: 90));
      expect(b!.startMs, at(16, 30));
      expect(b.durationMin, 90);
    });

    test('未设时长 → 默认 30 分钟最小可视块', () {
      expect(defaultBlockMinutes, 30);
      final b = taskTimeBlock(_task(id: 3, dueDate: at(18)));
      expect(b!.durationMin, 30);
      expect(b.startMs, at(17, 30));
      // 非法时长（0/负）同样回落默认
      final b0 = taskTimeBlock(_task(id: 4, dueDate: at(18), durationMinutes: 0));
      expect(b0!.durationMin, 30);
      final bNeg =
          taskTimeBlock(_task(id: 5, dueDate: at(18), durationMinutes: -60));
      expect(bNeg!.durationMin, 30);
    });

    test('两处都无时刻 → 不出块（纯日期任务属日格不属时段）', () {
      expect(taskTimeBlock(_task(id: 6, startDate: day0, dueDate: day0)), isNull);
      expect(taskTimeBlock(_task(id: 7)), isNull);
      // start 是零点但 due 带时刻 → 仍走倒推
      final b = taskTimeBlock(_task(id: 8, startDate: day0, dueDate: at(18)));
      expect(b!.startMs, at(17, 30));
    });

    test('完成任务照常出块（渲染层弱化）', () {
      final b = taskTimeBlock(
          _task(id: 9, dueDate: at(18), durationMinutes: 60, done: true));
      expect(b!.done, isTrue);
    });
  });

  group('layoutTimeBlock 渲染比例', () {
    test('日内块：top/height 与时刻成正比', () {
      final b = taskTimeBlock(_task(id: 1, dueDate: at(18), durationMinutes: 60))!;
      final l = layoutTimeBlock(b, day0);
      expect(l.topRatio, closeTo(17 / 24, 1e-9));
      expect(l.heightRatio, closeTo(1 / 24, 1e-9));
    });

    test('跨午夜：底部截到 24:00，跨零点倒推贴顶', () {
      // 23:00 起 120 分钟 → 贴到 24:00（高 1/24）
      final late = taskTimeBlock(
          _task(id: 2, startDate: at(23), durationMinutes: 120))!;
      final l1 = layoutTimeBlock(late, day0);
      expect(l1.topRatio, closeTo(23 / 24, 1e-9));
      expect(l1.heightRatio, closeTo(1 / 24, 1e-9));
      // 跨零点：起点早于当日零点 → 贴顶（高 = 起点到结束）
      final early = taskTimeBlock(_task(
        id: 3,
        dueDate: day0 + 30 * 60000,
        durationMinutes: 120,
      ))!;
      expect(early.startMs, day0 - 90 * 60000);
      final l2 = layoutTimeBlock(early, day0);
      expect(l2.topRatio, 0.0);
      expect(l2.heightRatio, closeTo(0.5 / 24, 1e-9));
    });

    test('整日块：占满当日', () {
      final all = taskTimeBlock(
          _task(id: 4, startDate: day0 + 60000, durationMinutes: 24 * 60))!;
      final l = layoutTimeBlock(all, day0);
      expect(l.heightRatio, closeTo(1 - 1 / 1440, 1e-9));
    });
  });

  group('assignLanes 分车道', () {
    test('不重叠 → 全落车道 0', () {
      final ls = [
        layoutTimeBlock(
            taskTimeBlock(_task(id: 1, dueDate: at(10), durationMinutes: 60))!,
            day0),
        layoutTimeBlock(
            taskTimeBlock(_task(id: 2, dueDate: at(14), durationMinutes: 60))!,
            day0),
      ];
      expect(assignLanes(ls), [0, 0]);
    });

    test('重叠 → 贪心复用最早空闲车道', () {
      final ls = [
        // 9:00–11:00
        layoutTimeBlock(
            taskTimeBlock(_task(id: 1, startDate: at(9), durationMinutes: 120))!,
            day0),
        // 10:00–11:00（与上重叠）
        layoutTimeBlock(
            taskTimeBlock(_task(id: 2, startDate: at(10), durationMinutes: 60))!,
            day0),
        // 11:00–12:00（车道 0 的尾恰为 11:00，贪心取最早空闲 → 回车道 0）
        layoutTimeBlock(
            taskTimeBlock(_task(id: 3, startDate: at(11), durationMinutes: 60))!,
            day0),
      ];
      expect(assignLanes(ls), [0, 1, 0]);
    });

    test('空输入 → 空车道表', () {
      expect(assignLanes(const []), isEmpty);
    });
  });

  group('blocksForDay 日内分桶', () {
    test('只留起点在当日的块，跨日块归起点日', () {
      final blocks = [
        // 当日 9:00
        taskTimeBlock(_task(id: 1, startDate: at(9), durationMinutes: 60))!,
        // 次日 9:00（在当日分桶外）
        taskTimeBlock(_task(
            id: 2, startDate: day0 + day + 9 * 3600000, durationMinutes: 60))!,
      ];
      final out = blocksForDay(blocks, day0);
      expect(out.length, 1);
      expect(out.first.block.taskId, 1);
      expect(out.first.lane, 0);
      expect(out.first.laneCount, 1);
    });

    test('同日重叠 → laneCount = 最大车道 + 1', () {
      final blocks = [
        taskTimeBlock(_task(id: 1, startDate: at(9), durationMinutes: 120))!,
        taskTimeBlock(_task(id: 2, startDate: at(10), durationMinutes: 60))!,
        taskTimeBlock(_task(id: 3, startDate: at(10, 30), durationMinutes: 30))!,
      ];
      final out = blocksForDay(blocks, day0);
      expect(out.length, 3);
      // 三块互相重叠 → 3 车道
      expect(out.every((e) => e.laneCount == 3), isTrue);
      expect(out.map((e) => e.lane).toSet().length, 3);
    });

    test('空输入 → 空列表', () {
      expect(blocksForDay(const [], day0), isEmpty);
    });
  });

  // ---------- #75 拖拽（移动端子集：长按拾起 + 纵向改时刻）----------

  group('snapMinutesDelta（15 分钟吸附）', () {
    test('就近吸附到 15 分钟整数倍（48px = 1 小时，1px = 1.25 分钟）', () {
      expect(snapMinutes, 15);
      expect(snapMinutesDelta(48, 48), 60);
      expect(snapMinutesDelta(24, 48), 30);
      expect(snapMinutesDelta(12, 48), 15); // 恰好 15 分钟
      // 半格内（<7.5 分钟）吸回原格：5px = 6.25 分钟 → 0
      expect(snapMinutesDelta(5, 48), 0);
      // 过半格：11px = 13.75 分钟 → 15；13px = 16.25 → 15
      expect(snapMinutesDelta(11, 48), 15);
      expect(snapMinutesDelta(13, 48), 15);
      // 反向同理（负位移向下取整到格）
      expect(snapMinutesDelta(-11, 48), -15);
      expect(snapMinutesDelta(48 * 24, 48), 24 * 60);
    });

    test('非法网格高 / 非有限位移 → 0（防 NaN 传播到写库）', () {
      expect(snapMinutesDelta(48, 0), 0);
      expect(snapMinutesDelta(48, -1), 0);
      expect(snapMinutesDelta(48, double.nan), 0);
      expect(snapMinutesDelta(double.nan, 48), 0);
      expect(snapMinutesDelta(double.infinity, 48), 0);
    });
  });

  group('resolveTimeslotMove（纵向落点）', () {
    test('下拖 2 小时 → 起点 +2 小时，时长不变', () {
      final b = taskTimeBlock(_task(id: 1, startDate: at(9), durationMinutes: 60))!;
      final r = resolveTimeslotMove(b, day0, deltaPx: 96, hourPx: 48);
      expect(r.startMs, at(11));
      expect(r.durationMin, 60);
    });

    test('15 分钟吸附：半格内吸回原格，过半格进一格', () {
      final b = taskTimeBlock(_task(id: 2, startDate: at(9)))!;
      // 5px = 6.25 分钟（< 半格 7.5）→ 起点不动
      expect(resolveTimeslotMove(b, day0, deltaPx: 5, hourPx: 48).startMs, at(9));
      // 11px = 13.75 分钟（> 半格）→ +15
      expect(resolveTimeslotMove(b, day0, deltaPx: 11, hourPx: 48).startMs, at(9, 15));
      // 24px = 30 分钟 → +30
      expect(resolveTimeslotMove(b, day0, deltaPx: 24, hourPx: 48).startMs, at(9, 30));
    });

    test('上下夹取：起点 ≥ 00:00 且 起点+时长 ≤ 24:00', () {
      final b = taskTimeBlock(_task(id: 3, startDate: at(9), durationMinutes: 60))!;
      // 上拖 24h → 夹到当日 00:00
      expect(resolveTimeslotMove(b, day0, deltaPx: -48 * 24, hourPx: 48).startMs, day0);
      // 下拖 24h + 时长 60 分 → 起点夹到 23:00（块完整落在列内）
      expect(resolveTimeslotMove(b, day0, deltaPx: 48 * 24, hourPx: 48).startMs,
          at(23));
    });

    test('零位移 → 原起点（无变化由 timeslotDropPatch 判空）', () {
      final b = taskTimeBlock(_task(id: 4, startDate: at(9)))!;
      expect(resolveTimeslotMove(b, day0, deltaPx: 0, hourPx: 48).startMs, at(9));
    });
  });

  group('timeslotDropPatch（落库口径按块来源三分）', () {
    test('显式排程块 → 改 start_date', () {
      final t = _task(id: 1, startDate: at(9), dueDate: at(20), durationMinutes: 60);
      expect(timeslotDropPatch(t, at(11)), {'start_date': at(11)});
    });

    test('截止倒推块 → 只改 due_date（起点+时长），绝不种 start', () {
      final t = _task(id: 2, dueDate: at(18), durationMinutes: 60);
      final patch = timeslotDropPatch(t, at(19));
      expect(patch, {'due_date': at(20)});
      expect(patch!.containsKey('start_date'), isFalse);
    });

    test('无变化 → null（不写库）', () {
      final t = _task(id: 3, startDate: at(9), durationMinutes: 60);
      expect(timeslotDropPatch(t, at(9)), isNull);
    });

    test('纯日期任务（无带时刻字段）→ null（防御不臆造时刻）', () {
      final t = _task(id: 4, startDate: day0, dueDate: day0, durationMinutes: 60);
      expect(timeslotDropPatch(t, day0 + 3600000), isNull);
    });
  });

  group('localDayStartMs', () {
    test('任意时刻归一到当日零点', () {
      expect(localDayStartMs(DateTime(2026, 10, 5, 17, 30)), day0);
      expect(localDayStartMs(DateTime(2026, 10, 5)), day0);
    });
  });
}
