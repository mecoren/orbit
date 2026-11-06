// 侧滑手势测试（07 #18）：任务行右滑露「完成/恢复」面板、左滑露「删除」面板。
// 直接手造 TodoTask（不经 mock bridge 的延迟 Future——testWidgets 假时钟下
// 顶层 await 会死锁），聚焦手势面板本身。
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'support/orbit_test_app.dart';

Widget _harness(TodoTask task) => orbitTestApp(
  home: Scaffold(
    body: ListView(
      children: [
        TodoTaskTile(
          task: task,
          onToggleDone: () {},
          onLongPress: () {},
          onOpen: () {},
          onDelete: () {},
        ),
      ],
    ),
  ),
);

/// 可滚动长列表：验证竖滑时手势被交还给列表（单行列表滚不动）
Widget _scrollHarness(int count) => orbitTestApp(
  home: Scaffold(
    body: ListView.builder(
      itemCount: count,
      itemBuilder: (context, index) => TodoTaskTile(
        task: _task(done: 0, id: index + 1),
        onToggleDone: () {},
        onLongPress: () {},
        onOpen: () {},
        onDelete: () {},
      ),
    ),
  ),
);

TodoTask _task({required int done, int id = 1}) => TodoTask(
  id: id,
  uuid: 'uuid-$id',
  title: '侧滑测试任务',
  description: null,
  projectId: null,
  priority: 2,
  status: done == 1 ? 'done' : 'pending',
  done: done,
  doneAt: done == 1 ? 1700000000000 : null,
  dueDate: null,
  startDate: null,
  repeatAfter: 0,
  repeatMode: 0,
  repeatWeekdays: 0,
  repeatEndType: 0,
  repeatEndParam: 0,
  repeatFromDone: 0,
  repeatMonthMode: 0,
  repeatNthWeek: 0,
  percentDone: 0.0,
  position: 0,
  isFavorite: 0,
  myDayDate: null,
  durationMinutes: null,
  isDeleted: 0,
  createdAt: 1700000000000,
  updatedAt: 1700000000000,
  deletedAt: null,
  version: 1,
);

Future<void> _openPane(WidgetTester tester, Offset delta) async {
  await tester.drag(find.byType(Slidable), delta);
  // BehindMotion 收敛动画：固定时长推进（pumpAndSettle 对无限动画会死等）
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('侧滑：右滑（startActionPane）露「完成」动作', (tester) async {
    await tester.pumpWidget(_harness(_task(done: 0)));

    // 未滑动时不渲染动作面板
    expect(find.text('完成'), findsNothing);

    await _openPane(tester, const Offset(80, 0));
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('侧滑：左滑（endActionPane）露「删除」动作', (tester) async {
    await tester.pumpWidget(_harness(_task(done: 0)));

    await _openPane(tester, const Offset(-80, 0));
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('侧滑：已完成任务右滑动作变「恢复」', (tester) async {
    await tester.pumpWidget(_harness(_task(done: 1)));

    await _openPane(tester, const Offset(80, 0));
    expect(find.text('恢复'), findsOneWidget);
  });

  // 方向锁（2026-11-06）：上下滚动时手指的横向抖动不得夺走手势
  testWidgets('方向锁：纵向起手后的横向抖动不夺走手势', (tester) async {
    await tester.pumpWidget(_scrollHarness(20));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TodoTaskTile).at(5)),
    );
    // 起手纵向占优（都还没到 kTouchSlop）：guard 判为纵向，摘掉本行侧滑
    await gesture.moveBy(const Offset(4, 10));
    await tester.pump();
    // 随后手指横向大幅偏移：旧行为下内层横向识别器此时先过 slop 夺权、
    // 露出面板；方向锁生效后这段位移归外层滚动
    await gesture.moveBy(const Offset(100, 24));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('完成'), findsNothing);
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('方向锁：竖滑手势交还列表滚动', (tester) async {
    await tester.pumpWidget(_scrollHarness(20));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TodoTaskTile).at(5)),
    );
    // 首帧就纵向占优：本行侧滑被摘掉，后续位移全部归外层滚动（向上滑）
    await gesture.moveBy(const Offset(3, -12));
    await tester.pump();
    await gesture.moveBy(const Offset(4, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(2, -40));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('完成'), findsNothing);
    expect(find.text('删除'), findsNothing);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, greaterThan(0));
  });

  // 2026-11-06 真机反馈：快速斜滑会「卡一截」——斜向落在 45° 歧义区时方向锁
  // 还没判定，横向识别器却已 accept 跟手；随后纵向占优触发打断，识别器被
  // dispose、onDragEnd 永不到来，controller 就停在半开。修复后打断同步回弹。
  testWidgets('方向锁：截断跟手中的横滑不卡在半开', (tester) async {
    await tester.pumpWidget(_scrollHarness(20));
    final tile = find.byType(TodoTaskTile).at(5);
    // 以行内标题的左边缘作为位移标尺（动作面板里的 InkWell 不随行移动）
    final label = find.descendant(of: tile, matching: find.text('侧滑测试任务'));
    final restX = tester.getTopLeft(label).dx;

    final gesture = await tester.startGesture(tester.getCenter(tile));
    // 45° 附近：guard 判不出主轴，但 dx=20 已过 accept 阈值，行开始跟手
    await gesture.moveBy(const Offset(20, 18));
    await tester.pump();
    expect(
      tester.getTopLeft(label).dx,
      greaterThan(restX),
      reason: '横向识别器应已跟手',
    );

    // 转成明显纵向：方向锁在此摘掉横向识别器（旧行为：行停在半开）
    await gesture.moveBy(const Offset(2, 20));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.getTopLeft(label).dx, restX, reason: '被打断的跟手必须回弹收起，不能停在中间');
  });

  testWidgets('方向锁：横向为主（轻微纵向抖动）仍能侧滑', (tester) async {
    await tester.pumpWidget(_harness(_task(done: 0)));

    await _openPane(tester, const Offset(80, 8));
    expect(find.text('完成'), findsOneWidget);
  });
}
