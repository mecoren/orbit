// 双端对齐第三批交叉验证（docs/07 #87 / docs/12 §4.3）：
// 1. 详情/表单把状态切到「已完成」必须走 todoTaskComplete（重复任务推进下一实例），
//    不得用普通 update 绕过引擎；新建即完成同理（不能只写 status=done 而 done=0）。
// 2. 保存筛选器构建器状态含「进行中」，项目/标签按名称多选（不再裸 id 文本框）。
// 3. 预计时长在常用档之外支持自定义分钟数（对齐桌面数字输入）。
// 4. 明文导出带「排除已删除条目」开关，JSON / CSV 同口径透传 excludeDeleted。
// 5. 详情提醒区的「持续」chip 未激活时恒显可点（开启/关闭双向）。
// 6. 关闭加密先验主密码：密码错误必须中止且不迁移库。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/data/api/orbit_bridge.dart' show PlaintextExportResult;
import 'package:orbit/modules/settings/settings_screen.dart';
import 'package:orbit/modules/todo/detail_screen.dart';
import 'package:orbit/modules/todo/form_bottom_sheet.dart';
import 'package:orbit/modules/todo/saved_filters_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_info_row.dart';

import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 表单/详情主滚动容器（避免 EditableText 内层 Scrollable 顶替树序末位）
final Finder _formScrollable = find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20 && finder.evaluate().isEmpty; i++) {
    await tester.drag(_formScrollable, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  // 双向收敛：仅判下沿会把目标顶到页头浮层之下，点击会被页头吃掉
  for (var i = 0; i < 12; i++) {
    final rect = tester.getRect(finder);
    if (rect.top >= 80 && rect.bottom <= 580) break;
    await tester.drag(_formScrollable, Offset(0, rect.top < 80 ? 100 : -100));
    await tester.pumpAndSettle();
  }
}

/// 信息区某行的值文本（限定在包含 [label] 的 InfoTile 内）
Finder _tileValue(String label, String value) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(InfoTile)),
      matching: find.text(value),
    );

/// 把重复规则写进种子任务 5（详情/表单用例共用）
void _seedRepeatingTask(MockOrbitBridge bridge) {
  bridge.store.tasks[5]!['repeat_mode'] = 1;
  bridge.store.tasks[5]!['repeat_after'] = 1;
  bridge.store.tasks[5]!['due_date'] =
      DateTime.now().millisecondsSinceEpoch + 86400000;
}

List<Map<String, dynamic>> _spawnedOf(
  MockOrbitBridge bridge,
  String title,
  int originId,
) =>
    [
      for (final t in bridge.store.tasks.values)
        if (t['title'] == title &&
            t['id'] != originId &&
            t['is_deleted'] == 0)
          t,
    ];

/// 设置页目标滚进「页头之下、视口下沿之上」的可点区（页头浮层会吃掉贴顶点击）
Future<void> _scrollSettingsTo(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(ListView).first;
  for (var i = 0; i < 24 && finder.evaluate().isEmpty; i++) {
    await tester.drag(scrollable, const Offset(0, -220));
    await tester.pumpAndSettle();
  }
  for (var i = 0; i < 12; i++) {
    final rect = tester.getRect(finder);
    if (rect.top >= 80 && rect.bottom <= 580) break;
    await tester.drag(scrollable, Offset(0, rect.top < 80 ? 120 : -100));
    await tester.pumpAndSettle();
  }
}

/// 打开导出确认抽屉 → 关闭「排除已删除条目」→ 确认（JSON/CSV 共用）
Future<void> _exportWithoutDeleted(WidgetTester tester, String entry) async {
  await _scrollSettingsTo(tester, find.text(entry));
  await tester.tap(find.text(entry));
  await tester.pumpAndSettle();

  expect(find.text('排除已删除条目'), findsOneWidget);
  await tester.tap(find.text('排除已删除条目'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('继续'));
  await _settle(tester);
}

class _SpyExportBridge extends MockOrbitBridge {
  bool? jsonExcludeDeleted;
  bool? csvExcludeDeleted;

  // 只验参数透传：落盘走真实 dart:io，在 widget 测试假时钟下不会完成，
  // 记录参数后即中断（页面会走失败 toast，不影响断言）
  @override
  Future<PlaintextExportResult> plaintextExportJson({
    bool excludeDeleted = true,
  }) async {
    jsonExcludeDeleted = excludeDeleted;
    throw Exception('spy-stop-before-file-io');
  }

  @override
  Future<PlaintextExportResult> plaintextExportCsv({
    bool excludeDeleted = true,
  }) async {
    csvExcludeDeleted = excludeDeleted;
    throw Exception('spy-stop-before-file-io');
  }
}

/// 主密码恒错的桥：验证「关闭加密」在校验失败时中止（不触发库迁移）
class _WrongPasswordBridge extends MockOrbitBridge {
  bool verifyCalled = false;
  bool migrated = false;

  @override
  Future<bool> masterAuthVerify(String password) async {
    verifyCalled = true;
    return false;
  }

  @override
  Future<void> dbMigrateToPlaintext() async {
    migrated = true;
  }
}

void main() {
  group('完成引擎接入（状态切到已完成）', () {
    testWidgets('详情信息区状态选「已完成」→ 重复任务生成下一期', (tester) async {
      final bridge = MockOrbitBridge();
      _seedRepeatingTask(bridge);
      final title = bridge.store.tasks[5]!['title'] as String;
      final before = bridge.store.tasks.length;

      await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
      await _settle(tester);

      await tester.tap(_tileValue('状态', '待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成'));
      await _settle(tester);

      expect(bridge.store.tasks.length, before + 1,
          reason: '完成走 todoTaskComplete，重复规则必须推进下一实例');
      expect(bridge.store.tasks[5]!['done'], 1);
      expect(bridge.store.tasks[5]!['status'], 'done');
      final spawned = _spawnedOf(bridge, title, 5);
      expect(spawned, hasLength(1));
      expect(spawned.single['status'], 'pending');
      expect(spawned.single['done'], 0);
      await drainToastTimers(tester);
    });

    testWidgets('详情已完成 → 状态改「进行中」落 doing（不回落 pending）',
        (tester) async {
      final bridge = MockOrbitBridge();
      bridge.store.tasks[5]!['status'] = 'done';
      bridge.store.tasks[5]!['done'] = 1;
      bridge.store.tasks[5]!['done_at'] =
          DateTime.now().millisecondsSinceEpoch;

      await tester.pumpWidget(_wrap(const DetailScreen(taskId: 5), bridge));
      await _settle(tester);

      await tester.tap(_tileValue('状态', '已完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进行中'));
      await _settle(tester);

      expect(bridge.store.tasks[5]!['status'], 'doing',
          reason: 'done → 进行中必须落目标状态，不能回落 pending');
      expect(bridge.store.tasks[5]!['done'], 0);
      expect(bridge.store.tasks[5]!['done_at'], isNull);
      await drainToastTimers(tester);
    });

    testWidgets('编辑表单状态改「已完成」→ 保存后同样推进重复实例', (tester) async {
      final bridge = MockOrbitBridge();
      _seedRepeatingTask(bridge);
      final title = bridge.store.tasks[5]!['title'] as String;
      final before = bridge.store.tasks.length;

      await tester.pumpWidget(_wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showTodoFormSheet(context, editingTaskId: 5),
              child: const Text('编辑任务'),
            ),
          ),
        ),
        bridge,
      ));
      await _settle(tester);
      await tester.tap(find.text('编辑任务'));
      await tester.pumpAndSettle();

      await _scrollTo(tester, _tileValue('状态', '待办'));
      await tester.tap(_tileValue('状态', '待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('保存'));
      await _settle(tester);

      expect(bridge.store.tasks.length, before + 1,
          reason: '编辑表单跨 done 边界必须走完成引擎');
      expect(bridge.store.tasks[5]!['done'], 1);
      expect(_spawnedOf(bridge, title, 5), hasLength(1));
      await drainToastTimers(tester);
    });

    testWidgets('新建表单选「已完成」→ 落 done=1/done_at（不再 status=done 而 done=0）',
        (tester) async {
      final bridge = MockOrbitBridge();
      await tester.pumpWidget(_wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTodoFormSheet(context),
              child: const Text('新建任务'),
            ),
          ),
        ),
        bridge,
      ));
      await _settle(tester);
      await tester.tap(find.text('新建任务'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, '新建即完成');
      await tester.pumpAndSettle();
      await _scrollTo(tester, _tileValue('状态', '待办'));
      await tester.tap(_tileValue('状态', '待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已完成'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('保存'));
      await _settle(tester);

      final created = bridge.store.tasks.values
          .firstWhere((t) => t['title'] == '新建即完成');
      expect(created['status'], 'done');
      expect(created['done'], 1,
          reason: '新建即完成必须走完成引擎，不能只写 status');
      expect(created['done_at'], isNotNull);
      await drainToastTimers(tester);
    });
  });
  testWidgets('保存筛选器：状态含进行中，项目/标签按名称多选落白名单',
      (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(const SavedFiltersScreen(), bridge));
    await _settle(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // 状态：全部 → 进行中（中文回显）
    await tester.tap(find.text('状态：全部'));
    await tester.pumpAndSettle();
    expect(find.text('进行中'), findsWidgets);
    await tester.tap(find.text('进行中').last);
    await tester.pumpAndSettle();
    expect(find.text('状态：进行中'), findsOneWidget);

    // 项目行：按名称多选（不再要求用户输入数据库 id）
    final sheetScroll = find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    await tester.dragUntilVisible(
      find.text('项目：不限'),
      sheetScroll,
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目：不限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('项目：工作'), findsOneWidget);

    // 标签行：同样按名称多选（种子标签「紧急」）
    await tester.dragUntilVisible(
      find.text('标签：不限'),
      sheetScroll,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签：不限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('紧急'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.textContaining('标签：紧急'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '进行中工作视图');
    await tester.tap(find.text('创建'));
    await _settle(tester);

    final saved = bridge.store.savedFilters.single;
    expect(saved.name, '进行中工作视图');
    final cond = jsonDecode(saved.conditions) as Map<String, dynamic>;
    final labelId = bridge.store.labels.values
        .firstWhere((l) => l['title'] == '紧急')['id'] as int;
    expect(cond['status'], 'doing');
    expect(cond['project_ids'], [1]);
    expect(cond['label_ids'], [labelId]);
    await drainToastTimers(tester);
  });
  testWidgets('预计时长支持自定义分钟数', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_wrap(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTodoFormSheet(context),
            child: const Text('开表单'),
          ),
        ),
      ),
      bridge,
    ));
    await _settle(tester);
    await tester.tap(find.text('开表单'));
    await tester.pumpAndSettle();

    final durationTile = find.text('预计时长');
    await _scrollTo(tester, durationTile);
    await tester.tap(durationTile);
    await tester.pumpAndSettle();
    // 选择抽屉列表懒构建：自定义档在列表尾部，先滚到可见
    await tester.drag(find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义分钟数…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '25');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('25m'), findsOneWidget);
  });
  testWidgets('明文导出 JSON：关闭「排除已删除条目」→ 桥参数为 false', (tester) async {
    final bridge = _SpyExportBridge();
    await tester.pumpWidget(_wrap(const SettingsScreen(), bridge));
    await _settle(tester);

    await _exportWithoutDeleted(tester, '导出 JSON');

    expect(bridge.jsonExcludeDeleted, false,
        reason: '开关关闭后应导出墓碑记录');
    await drainToastTimers(tester);
  });

  testWidgets('明文导出 CSV：开关同样透传 excludeDeleted=false', (tester) async {
    final bridge = _SpyExportBridge();
    await tester.pumpWidget(_wrap(const SettingsScreen(), bridge));
    await _settle(tester);

    await _exportWithoutDeleted(tester, '导出 CSV');

    expect(bridge.csvExcludeDeleted, false,
        reason: 'CSV 导出与 JSON 同口径');
    await drainToastTimers(tester);
  });
  testWidgets('详情持续提醒：未激活 chip 恒显，点击可开/可关', (tester) async {
    final bridge = MockOrbitBridge();
    final now = DateTime.now().millisecondsSinceEpoch;
    // 任务 7 无种子提醒：chip 初始必须是「未激活但恒显」形态
    bridge.store.reminders[900] = {
      'id': 900,
      'uuid': 'uuid-reminder-900',
      'task_id': 7,
      'remind_at': now + 3600000,
      'is_constant': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
      'deleted_at': null,
      'version': 1,
    };

    await tester.pumpWidget(_wrap(const DetailScreen(taskId: 7), bridge));
    await _settle(tester);

    await _scrollTo(tester, find.text('持续'));
    expect(find.text('持续'), findsOneWidget, reason: '未激活也必须恒显可点');
    await tester.tap(find.text('持续'));
    await _settle(tester);
    expect(
      bridge.store.reminders.values
          .where((r) => r['task_id'] == 7 && r['is_constant'] == 1),
      hasLength(1),
      reason: '点击未激活 chip 应开启持续提醒',
    );

    await _scrollTo(tester, find.text('持续'));
    await tester.tap(find.text('持续'));
    await _settle(tester);
    expect(
      bridge.store.reminders.values
          .where((r) => r['task_id'] == 7 && r['is_constant'] == 1),
      isEmpty,
      reason: '再次点击应关闭持续提醒',
    );
    await drainToastTimers(tester);
  });
  testWidgets('关闭加密：主密码错误 → 中止且不迁移库', (tester) async {
    final bridge = _WrongPasswordBridge()..store.masterAuthSet = true;
    await tester.pumpWidget(_wrap(const SettingsScreen(), bridge));
    await _settle(tester);

    const entry = '关闭加密（转为明文库）';
    await _scrollSettingsTo(tester, find.text(entry));
    await tester.tap(find.text(entry));
    await tester.pumpAndSettle();

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认关闭加密'));
    await tester.pumpAndSettle();

    expect(find.text('验证主密码'), findsOneWidget, reason: '必须先校验主密码');
    await tester.enterText(find.byType(TextField), 'wrong-password');
    await tester.tap(find.text('确认'));
    await _settle(tester);

    expect(bridge.verifyCalled, isTrue);
    expect(bridge.migrated, isFalse, reason: '密码错误时不得迁移库');
    await drainToastTimers(tester);
  });
}
