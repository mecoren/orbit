// 今日上下文条（G2 今日已达成 + G4 容量规划；镜像桌面 today-strip）：
// 两项渲染、容量文案、预算编辑回调、三空自隐藏。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/today_strip.dart';
import 'support/orbit_test_app.dart' show orbitTestApp;

TodoTask _task({
  int? dueDate,
  int? doneAt,
  int? durationMinutes,
  bool done = false,
}) =>
    TodoTask(
      id: 1,
      uuid: 'u1',
      title: 't1',
      description: null,
      projectId: null,
      priority: 0,
      status: done ? 'done' : 'pending',
      done: done ? 1 : 0,
      doneAt: doneAt,
      dueDate: dueDate,
      startDate: null,
      repeatAfter: 0,
      repeatMode: 0,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      repeatMonthMode: 0,
      repeatNthWeek: 0,
      percentDone: 0,
      position: 0,
      isFavorite: 0,
      myDayDate: null,
      durationMinutes: durationMinutes,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: 0,
      deletedAt: null,
      version: 0,
    );

void main() {
  Future<void> pump(WidgetTester tester, TodayStrip strip) async {
    await tester.pumpWidget(orbitTestApp(home: Scaffold(body: strip)));
    await tester.pump();
  }

  testWidgets('今日已达成与容量文案都渲染', (tester) async {
    final now = DateTime.now();
    final todayDue = DateTime(now.year, now.month, now.day, 18).millisecondsSinceEpoch;
    final doneAt = now.millisecondsSinceEpoch;
    await pump(
      tester,
      TodayStrip(
        tasks: [
          _task(dueDate: todayDue, durationMinutes: 60),
          _task(done: true, doneAt: doneAt),
        ],
        budgetMinutes: 480,
        onTapBudget: () {},
      ),
    );
    expect(find.textContaining('今日已达成'), findsOneWidget);
    expect(find.textContaining('已排'), findsOneWidget);
    expect(find.textContaining('预算'), findsOneWidget);
  });

  testWidgets('点预算编辑入口触发回调', (tester) async {
    var tapped = false;
    await pump(
      tester,
      TodayStrip(
        tasks: const [],
        budgetMinutes: 480,
        onTapBudget: () => tapped = true,
      ),
    );
    await tester.tap(find.text('每日容量'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('三空（无达成/无排程/无预算）自隐藏不占位', (tester) async {
    await pump(
      tester,
      TodayStrip(
        tasks: [_task(dueDate: null)],
        budgetMinutes: null,
        onTapBudget: () {},
      ),
    );
    expect(find.textContaining('今日已达成'), findsNothing);
    // 自隐藏 = SizedBox.shrink（零尺寸）：条目内容与点击目标都不渲染
    expect(find.text('每日容量'), findsNothing);
  });

  testWidgets('超载时文案报「超出」', (tester) async {
    final now = DateTime.now();
    final todayDue = DateTime(now.year, now.month, now.day, 18).millisecondsSinceEpoch;
    await pump(
      tester,
      TodayStrip(
        tasks: [_task(dueDate: todayDue, durationMinutes: 600)],
        budgetMinutes: 480,
        onTapBudget: () {},
      ),
    );
    expect(find.textContaining('超出'), findsOneWidget);
  });
}
