// 周回顾向导弹层（G5；镜像桌面 weekly-review-dialog）：三步流、一键顺延、
// 排期/唤醒回调、跳过收缩清单、完成关闭返回处置集。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/weekly_review_sheet.dart';
import 'support/orbit_test_app.dart' show orbitTestApp, drainToastTimers;

TodoTask _task({
  int id = 1,
  String title = 'task',
  int? dueDate,
  int? updatedAt,
  bool done = false,
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
      position: id * 100,
      isFavorite: 0,
      myDayDate: null,
      durationMinutes: null,
      isDeleted: 0,
      createdAt: 0,
      updatedAt: updatedAt ?? 0,
      deletedAt: null,
      version: 0,
    );

void main() {
  final day = const Duration(days: 1).inMilliseconds;

  Future<Set<int>?> open(
    WidgetTester tester,
    List<TodoTask> tasks, {
    List<(int, int)>? setDueLog,
    List<int>? wakeLog,
  }) async {
    Set<int>? result;
    await tester.pumpWidget(orbitTestApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showWeeklyReviewSheet(
                context,
                tasks: tasks,
                onSetDue: (id, dueMs) async => setDueLog?.add((id, dueMs)),
                onWake: (id) async => wakeLog?.add(id),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('第 1 步列逾期任务，标题与步进正确', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await open(tester, [
      _task(id: 1, title: '逾期任务A', dueDate: now - 2 * day),
    ]);
    expect(find.textContaining('周回顾 · 逾期任务'), findsOneWidget);
    expect(find.textContaining('第 1 / 3 步'), findsOneWidget);
    expect(find.text('逾期任务A'), findsOneWidget);
  });

  testWidgets('全部顺延到明天：改期回调 + 清单收缩', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final log = <(int, int)>[];
    await open(tester, [
      _task(id: 1, title: '逾期任务A', dueDate: now - 2 * day),
    ], setDueLog: log);
    await tester.tap(find.text('全部顺延到明天'));
    await tester.pumpAndSettle();
    // 顺延后本步清单空 → 显示「已处理完」
    expect(find.textContaining('已处理完'), findsOneWidget);
    expect(log, hasLength(1));
    await drainToastTimers(tester);
  });

  testWidgets('下一步进入第 2 步无日期任务', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await open(tester, [
      _task(id: 1, title: '逾期任务A', dueDate: now - 2 * day),
      _task(id: 2, title: '无日期任务B'),
    ]);
    // 先清空第 1 步（跳过），再下一步
    await tester.ensureVisible(find.text('跳过'));
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    // 跳过触发 toast 浮层会遮住底部按钮，先排空再点下一步
    await drainToastTimers(tester);
    await tester.ensureVisible(find.text('下一步'));
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 2 / 3 步'), findsOneWidget);
    expect(find.text('无日期任务B'), findsOneWidget);
    await drainToastTimers(tester);
  });

  testWidgets('第 3 步停滞任务可唤醒；完成回顾关闭并返回处置集', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final wakeLog = <int>[];
    Set<int>? result;
    await tester.pumpWidget(orbitTestApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await showWeeklyReviewSheet(
                context,
                tasks: [
                  _task(id: 3, title: '停滞任务C', updatedAt: now - 15 * day),
                ],
                onSetDue: (id, dueMs) async {},
                onWake: (id) async => wakeLog.add(id),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 停滞任务无逾期/无日期 → 第 1、2 步皆空，逐步下一步到第 3 步
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 3 / 3 步'), findsOneWidget);
    expect(find.text('停滞任务C'), findsOneWidget);
    await tester.ensureVisible(find.text('动一动'));
    await tester.tap(find.text('动一动'));
    await tester.pumpAndSettle();
    expect(wakeLog, [3]);
    // 唤醒触发 toast 浮层会遮住底部按钮，先排空再点完成
    await drainToastTimers(tester);
    await tester.ensureVisible(find.text('完成回顾'));
    await tester.tap(find.text('完成回顾'));
    await tester.pumpAndSettle();
    // Dialog 已关闭（返回非空处置集）
    expect(result, contains(3));
    await drainToastTimers(tester);
  });
}
