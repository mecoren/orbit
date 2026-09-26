// 已完成行整行置灰回归：标题 / 日期 / 元信息 / 勾选框统一弱化灰，
// 不再保留主题蓝、逾期红、星标黄、优先级色环。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_checkbox.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_strikethrough.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;
import 'support/orbit_test_app.dart';

TodoTask _doneTask() => TodoTask(
      id: 7,
      uuid: 'uuid-done-gray',
      title: '已完成置灰',
      description: null,
      projectId: 1,
      priority: 4,
      status: 'done',
      done: 1,
      doneAt: 1700000000000,
      dueDate: DateTime.now().millisecondsSinceEpoch,
      startDate: null,
      repeatAfter: 0,
      repeatMode: 1,
      repeatWeekdays: 0,
      repeatEndType: 0,
      repeatEndParam: 0,
      repeatFromDone: 0,
      percentDone: 50.0,
      position: 0,
      isFavorite: 1,
      myDayDate: null,
      isDeleted: 0,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
      deletedAt: null,
      version: 1,
    );

void main() {
  testWidgets('已完成行：标题/日期/星标/勾选框统一弱化灰', (tester) async {
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: ListView(
          children: [
            TodoTaskTile(
              task: _doneTask(),
              projectTitle: '项目名',
              projectColorHex: '#FF0000',
              labels: const [
                ProjectedTaskLabel(id: 1, title: '工作', hexColor: '#EF4444'),
              ],
              reminder: (id: 1, clock: '09:30', fired: true),
              relationCount: 1,
              onToggleDone: () {},
              onOpen: () {},
              onDelete: () {},
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final muted = AppColors.light.deactivatedText;

    // 标题完成色走弱化灰
    final strike = tester.widget<AnimatedStrikethrough>(
        find.byType(AnimatedStrikethrough));
    expect(strike.doneColor, muted);

    // 勾选框填充走弱化灰，且不保留优先级色环
    final box = tester.widget<sh.Checkbox>(find.descendant(
      of: find.byType(OrbitCheckbox),
      matching: find.byType(sh.Checkbox),
    ));
    expect(box.activeColor, muted);
    expect(box.borderColor, isNot(const Color(0xFFF59E0B)));

    // 星标不再是黄色
    final star = tester.widget<Icon>(find.byIcon(OrbitIcons.star));
    expect(star.color, muted);

    // 重复 / 提醒 / 进度 / 关联图标统一弱化灰
    for (final icon in [
      OrbitIcons.repeat,
      OrbitIcons.notification,
      OrbitIcons.listChecks,
      OrbitIcons.link,
    ]) {
      final w = tester.widget<Icon>(find.byIcon(icon));
      expect(w.color, muted, reason: '$icon 应置灰');
    }
  });
}
