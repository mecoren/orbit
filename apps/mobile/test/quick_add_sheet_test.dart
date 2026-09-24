// 底部快速添加面板 + 快捷操作档配置：档位读写、面板交互、提交落库口径
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_motion.dart';
import 'package:orbit/core/theme/icon_map.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/quick_actions_page.dart';
import 'package:orbit/modules/todo/logic/quick_actions.dart';
import 'package:orbit/modules/todo/logic/task_logic.dart'
    show TaskFilterInput, dateToMidnightMs, formatYmd;
import 'package:orbit/modules/todo/quick_add_sheet.dart' show showQuickAddSheet;
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_fab.dart';
import 'package:orbit/services/local_prefs.dart';
import 'support/orbit_test_app.dart';

Widget _wrap(Widget child, MockOrbitBridge bridge) => ProviderScope(
      overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
      child: orbitTestApp(home: child),
    );

/// 推进假时钟越过 MockOrbitBridge 的 120ms 人为延迟，再收敛帧
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// 打开任务列表页并点 FAB 唤出快速添加面板
Future<MockOrbitBridge> _openPanel(WidgetTester tester) async {
  final bridge = MockOrbitBridge();
  await tester.pumpWidget(
    _wrap(const SubListScreen(query: TaskFilterInput()), bridge),
  );
  await _settle(tester);
  await tester.tap(find.byType(OrbitFab));
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  // LocalPrefs 是静态内存表，用例间必须复位（否则档位配置串场）
  setUp(() async {
    await LocalPrefs.setString(QuickActions.key, '');
  });

  group('快捷操作档配置', () {
    test('默认档：工具栏四档 + 更多三档', () {
      final (enabled, hidden) = QuickActions.read();
      expect(enabled, QuickActions.defaultEnabled);
      expect(hidden, QuickActions.defaultHidden);
    });

    test('启用/停用：两段间移动且各自相对顺序不变', () async {
      await QuickActions.setEnabled(QuickActionId.image, true);
      final (enabled, hidden) = QuickActions.read();
      expect(enabled.last, QuickActionId.image);
      expect(hidden.contains(QuickActionId.image), isFalse);

      await QuickActions.setEnabled(QuickActionId.due, false);
      final (enabled2, hidden2) = QuickActions.read();
      expect(enabled2.contains(QuickActionId.due), isFalse);
      expect(hidden2.last, QuickActionId.due);
    });

    test('脏数据忽略、重复名去重、缺档补进「更多」', () async {
      await LocalPrefs.setString(
        QuickActions.key,
        'due,due,不存在,|project',
      );
      final (enabled, hidden) = QuickActions.read();
      expect(enabled, [QuickActionId.due]);
      // project 在启用段缺失 → 作为「缺档」补进更多；hidden 原值保留在前
      expect(hidden.first, QuickActionId.project);
      expect(hidden.length, QuickActionId.values.length - 1);
    });
  });

  group('跨段拖拽（纯逻辑：越过「更多」标题即换段）', () {
    test('未启用档拖到标题上方 → 提到工具栏', () {
      final (on, off) = reorderQuickActions(
        enabled: QuickActions.defaultEnabled,
        hidden: QuickActions.defaultHidden,
        oldIndex: 5, // image（标题行之后）
        newIndex: 1,
      );
      expect(on, [
        QuickActionId.due,
        QuickActionId.image,
        QuickActionId.priority,
        QuickActionId.label,
        QuickActionId.project,
      ]);
      expect(off, [QuickActionId.template, QuickActionId.fullscreen]);
    });

    test('启用档拖到标题之下 → 收进「更多」', () {
      final (on, off) = reorderQuickActions(
        enabled: QuickActions.defaultEnabled,
        hidden: QuickActions.defaultHidden,
        oldIndex: 0, // due
        newIndex: 6, // 落到标题行之后的末段
      );
      expect(on, [
        QuickActionId.priority,
        QuickActionId.label,
        QuickActionId.project,
      ]);
      expect(off, [
        QuickActionId.image,
        QuickActionId.template,
        QuickActionId.due,
        QuickActionId.fullscreen,
      ]);
    });

    test('段内拖拽只调顺序、归属不变', () {
      final (on, off) = reorderQuickActions(
        enabled: QuickActions.defaultEnabled,
        hidden: QuickActions.defaultHidden,
        oldIndex: 2, // label
        newIndex: 0,
      );
      expect(on, [
        QuickActionId.label,
        QuickActionId.due,
        QuickActionId.priority,
        QuickActionId.project,
      ]);
      expect(off, QuickActions.defaultHidden);
    });

    test('标题行索引不参与重排（防御：原样返回）', () {
      final (on, off) = reorderQuickActions(
        enabled: QuickActions.defaultEnabled,
        hidden: QuickActions.defaultHidden,
        oldIndex: 4, // 哨兵标题行
        newIndex: 0,
      );
      expect(on, QuickActions.defaultEnabled);
      expect(off, QuickActions.defaultHidden);
    });
  });

  group('段内重排（双卡片各持一段，只调顺序不换段）', () {
    test('启用段内下移', () {
      expect(
        reorderWithinSection(QuickActions.defaultEnabled, 0, 2),
        [
          QuickActionId.priority,
          QuickActionId.label,
          QuickActionId.due,
          QuickActionId.project,
        ],
      );
    });

    test('更多段内上移', () {
      expect(
        reorderWithinSection(QuickActions.defaultHidden, 2, 0),
        [
          QuickActionId.fullscreen,
          QuickActionId.image,
          QuickActionId.template,
        ],
      );
    });

    test('越界旧位原样返回', () {
      expect(
        reorderWithinSection(QuickActions.defaultEnabled, 9, 0),
        QuickActions.defaultEnabled,
      );
    });
  });

  group('快速添加面板', () {
    testWidgets('默认档位：工具栏四枚 + 更多入口', (tester) async {
      await _openPanel(tester);

      expect(find.text('准备做什么？'), findsOneWidget);
      for (final id in QuickActions.defaultEnabled) {
        expect(find.byTooltip(id.label), findsOneWidget);
      }
      expect(find.byTooltip('更多'), findsOneWidget);
      // 未启用档不出现在工具栏
      expect(find.byTooltip('图片'), findsNothing);
    });

    testWidgets('提交：标题落库并关闭面板', (tester) async {
      final bridge = await _openPanel(tester);

      await tester.enterText(find.byType(TextField), '买牛奶');
      await tester.pump();
      await tester.tap(find.byIcon(OrbitIcons.send));
      await _settle(tester);

      final titles = bridge.store.tasks.values.map((t) => t['title']).toList();
      expect(titles, contains('买牛奶'));
      // 面板已关闭
      expect(find.text('准备做什么？'), findsNothing);
    });

    testWidgets('NLP：标题命中日期被剥离并写入截止', (tester) async {
      final bridge = await _openPanel(tester);

      await tester.enterText(find.byType(TextField), '明天 买牛奶');
      await tester.pump();
      await tester.tap(find.byIcon(OrbitIcons.send));
      await _settle(tester);

      final created = bridge.store.tasks.values
          .firstWhere((t) => t['title'] == '买牛奶');
      expect(created['due_date'], isNotNull);
    });

    testWidgets('优先级档：选择后 chip 回显', (tester) async {
      await _openPanel(tester);

      await tester.tap(find.byTooltip('优先级'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高'));
      await tester.pumpAndSettle();

      expect(find.text('P3 高'), findsOneWidget);
    });

    testWidgets('更多菜单：未启用三档 + 固定「设置」入口', (tester) async {
      await _openPanel(tester);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      expect(find.text('图片'), findsOneWidget);
      expect(find.text('模板'), findsOneWidget);
      expect(find.text('全屏'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
    });

    testWidgets('initialDueDate 预填截止并回显 chip（日历长按口径）', (tester) async {
      final due = dateToMidnightMs(
        DateTime.now().add(const Duration(days: 3)),
      );
      await tester.pumpWidget(_wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showQuickAddSheet(context, initialDueDate: due),
              child: const Text('开面板'),
            ),
          ),
        ),
        MockOrbitBridge(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('开面板'));
      await tester.pumpAndSettle();

      expect(find.text('准备做什么？'), findsOneWidget);
      expect(find.text(formatYmd(due)), findsOneWidget);
    });
  });

  group('编辑操作设置页', () {
    testWidgets('预览与两段列表：默认四档在工具栏、三档在更多', (tester) async {
      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();

      expect(find.text('编辑操作'), findsWidgets);
      expect(find.text('更多'), findsWidgets);
      expect(find.text('准备做什么？'), findsOneWidget);
      // 每档一枚加减按钮（四档减 + 三档加）
      expect(
        find.byIcon(OrbitIcons.remove),
        findsNWidgets(QuickActions.defaultEnabled.length),
      );
      expect(
        find.byIcon(OrbitIcons.add),
        findsNWidgets(QuickActions.defaultHidden.length),
      );
    });

    testWidgets('减号把档位收回「更多」并立即反映到预览', (tester) async {
      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();

      // 「标签」行（默认在工具栏段）的减号
      final row = find.ancestor(
        of: find.text('标签'),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(of: row.first, matching: find.byIcon(OrbitIcons.remove)),
      );
      await tester.pumpAndSettle();

      final (enabled, _) = QuickActions.read();
      expect(enabled.contains(QuickActionId.label), isFalse);
      expect(
        find.byIcon(OrbitIcons.remove),
        findsNWidgets(QuickActions.defaultEnabled.length - 1),
      );
    });

    testWidgets('左滑把工具栏档位收进「更多」', (tester) async {
      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();

      await tester.drag(find.text('标签'), const Offset(-400, 0));
      await tester.pumpAndSettle();

      final (enabled, hidden) = QuickActions.read();
      expect(enabled.contains(QuickActionId.label), isFalse);
      expect(hidden.last, QuickActionId.label);
    });

    testWidgets('右滑把「更多」档位提到工具栏', (tester) async {
      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();

      await tester.drag(find.text('图片'), const Offset(400, 0));
      await tester.pumpAndSettle();

      final (enabled, hidden) = QuickActions.read();
      expect(enabled.last, QuickActionId.image);
      expect(hidden.contains(QuickActionId.image), isFalse);
    });

    testWidgets('横滑过程中预览图标跟手让位，松手回弹跟回', (tester) async {
      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();

      AnimatedPositioned previewMore() => tester.widget<AnimatedPositioned>(
            find.byKey(const ValueKey('preview-more')),
          );
      final before = previewMore().left!;

      // 按住「标签」行向左拖 120px（未过阈值不松手）：「...」应同步左移让位
      // （本行在首屏内，直接按住；勿 ensureVisible——滚动会把顶部预览滑出
      // sliver 缓存区，finder 即不可见）
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('标签')));
      // 分两次 move：第一次越过 touch slop 启动拖拽，第二次产生有效位移
      //（与真手指连续滑动一致；单次 move 只够启动 recognizer）
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();

      expect(previewMore().left!, lessThan(before));
      // 跟手期间零延迟直跟（无平滑拖尾）
      expect(previewMore().duration, AppMotion.instant);

      // 未过阈值松手 → 回弹，预览回到原位；档位归属不变
      await gesture.up();
      await tester.pumpAndSettle();
      expect(previewMore().left!, before);
      expect(previewMore().duration, AppMotion.normal);
      final (enabled, hidden) = QuickActions.read();
      expect(enabled.contains(QuickActionId.label), isTrue);
      expect(hidden.contains(QuickActionId.label), isFalse);
    });

    testWidgets('从「更多」横滑时预览尾部出现幽灵占位', (tester) async {
      // 拉高测试面：整页无需滚动即全可见（滚动会把顶部预览滑出缓存区）
      tester.view.physicalSize = const Size(2400, 4200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();

      final gesture =
          await tester.startGesture(tester.getCenter(find.text('图片')));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();

      expect(find.byKey(const ValueKey('preview-ghost')), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('preview-ghost')), findsNothing);
    });
  });
}
