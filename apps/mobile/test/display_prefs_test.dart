// 显示偏好（竞品「显示详细/显示设置」）：控制器开关/落盘/行渲染门控。
//
// 控制器纯 Dart 驱动（LocalPrefs 承载）；行渲染用 TodoTaskTile 直 pump
// （showDetail/showProject/showTags 三参缺省全开，搜索等复用面不接入口）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/data/api/dto.dart';
import 'package:orbit/modules/todo/logic/display_prefs.dart';
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/services/local_prefs.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_list_card.dart';

import 'support/orbit_test_app.dart';

Widget _tile({
  bool showDetail = true,
  bool showProject = true,
  bool showTags = true,
}) =>
    orbitTestApp(
      home: Scaffold(
        body: TodoTaskTile(
          task: _task(),
          projectTitle: '工作',
          projectColorHex: '#4E8CFF',
          labels: const [
            ProjectedTaskLabel(id: 1, title: '紧急', hexColor: '#F44336'),
          ],
          showDetail: showDetail,
          showProject: showProject,
          showTags: showTags,
          onToggleDone: () {},
          onOpen: () {},
        ),
      ),
    );

TodoTask _task() => TodoTask.fromJson(const {
      'id': 1,
      'uuid': 'u1',
      'title': '带元信息任务',
      'description': null,
      'project_id': 7,
      'priority': 0,
      'status': 'pending',
      'done': 0,
      'done_at': null,
      'due_date': 1758758400000,
      'start_date': null,
      'repeat_after': 1,
      'repeat_mode': 0,
      'percent_done': 0,
      'position': 1,
      'is_favorite': 0,
      'my_day_date': null,
      'is_deleted': 0,
      'created_at': 1758758400000,
      'updated_at': 1758758400000,
      'deleted_at': null,
      'version': 1,
    });

void main() {
  setUp(() => LocalPrefs.resetForTest());

  group('控制器', () {
    test('默认全开（未配置回落口径）', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(displayPrefsProvider),
          const DisplayPrefsState(detail: true, project: true, tags: true));
    });

    test('开关写即改状态并落盘，新容器读到同一状态', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(displayPrefsProvider.notifier);
      await controller.setDetail(false);
      await controller.setTags(false);

      expect(container.read(displayPrefsProvider).detail, false);
      expect(container.read(displayPrefsProvider).tags, false);
      expect(container.read(displayPrefsProvider).project, true);

      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final persisted = container2.read(displayPrefsProvider);
      expect(persisted.detail, false);
      expect(persisted.tags, false);
      expect(persisted.project, true);
    });
  });

  group('行渲染门控', () {
    testWidgets('全开：副标题含标签与所属清单', (tester) async {
      await tester.pumpWidget(_tile());
      expect(find.text('紧急'), findsOneWidget);
      expect(find.text('工作'), findsOneWidget);
    });

    testWidgets('detail 关：副标题整行消失（单行紧凑形态）', (tester) async {
      await tester.pumpWidget(_tile(showDetail: false));
      expect(find.text('紧急'), findsNothing);
      expect(find.text('工作'), findsNothing);
    });

    testWidgets('project 关：清单名消失、标签保留', (tester) async {
      await tester.pumpWidget(_tile(showProject: false));
      expect(find.text('工作'), findsNothing);
      expect(find.text('紧急'), findsOneWidget);
    });

    testWidgets('tags 关：标签消失、清单名保留', (tester) async {
      await tester.pumpWidget(_tile(showTags: false));
      expect(find.text('紧急'), findsNothing);
      expect(find.text('工作'), findsOneWidget);
    });
  });

  testWidgets('卡片段位（OrbitCardSegment）仍包裹行内容', (tester) async {
    await tester.pumpWidget(_tile(showDetail: false));
    expect(find.byType(OrbitCardSegment), findsOneWidget);
  });
}
