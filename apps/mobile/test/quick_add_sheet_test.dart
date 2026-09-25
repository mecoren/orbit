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
    show
        TaskFilterInput,
        dateToMidnightMs,
        formatDueLabel,
        formatYmd,
        priorityColorHex;
import 'package:orbit/modules/todo/quick_add_sheet.dart' show showQuickAddSheet;
import 'package:orbit/modules/todo/sub_list_screen.dart';
import 'package:orbit/shared/utils/hex_color.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart';
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

/// 打开任务列表页并唤出快速添加面板
///
/// 一级新建入口已上收到底部导航中央添加钮（页面内无 FAB），测试直接在
/// 列表页语境下调 [showQuickAddSheet]（与中央钮同链路，含落点预填读取）。
Future<MockOrbitBridge> _openPanel(WidgetTester tester) async {
  final bridge = MockOrbitBridge();
  await tester.pumpWidget(
    _wrap(const SubListScreen(query: TaskFilterInput()), bridge),
  );
  await _settle(tester);
  showQuickAddSheet(tester.element(find.byType(SubListScreen)));
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

    testWidgets('优先级档：旗子变色无文字胶囊，不加 chips 行', (tester) async {
      await _openPanel(tester);

      await tester.tap(find.byTooltip('优先级'));
      await tester.pumpAndSettle();
      // 锚点卡片形态：除面板自身外不再有第二个 BottomSheet
      expect(find.byType(BottomSheet), findsOneWidget);
      // 卡片完整落屏内（左置按钮右对齐曾把 240 宽卡片推出左屏，只剩窄条）
      final cardRect = tester.getRect(find.byType(OrbitFloatCard));
      final screenSize = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(cardRect.left, greaterThanOrEqualTo(0));
      expect(cardRect.right, lessThanOrEqualTo(screenSize.width));
      await tester.tap(find.text('高'));
      await tester.pumpAndSettle();

      // 只旗子变该档色：无文字胶囊，tooltip 仍带已选值，顶部无 chips 行
      expect(find.byTooltip('优先级：P3 高'), findsOneWidget);
      expect(find.text('P3 高'), findsNothing);
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('优先级：P3 高'),
          matching: find.byType(IconButton),
        ),
      );
      expect((button.icon as Icon).color,
          hexToColor(priorityColorHex(3), fallback: Colors.black));
    });

    testWidgets('标签档：锚点多选卡片点行即选中，无确认尾栏', (tester) async {
      await _openPanel(tester);
      // 等标签 provider 落定（mock 120ms 延迟），否则卡片直接报“还没有标签”
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('标签'));
      await tester.pumpAndSettle();
      // 卡片内列表（mock 种子：紧急/阅读），无确认/取消尾栏
      Finder cardText(String label) => find.descendant(
            of: find.byKey(const ValueKey('quick-add-label-card-list')),
            matching: find.text(label),
          );
      expect(cardText('紧急'), findsOneWidget);
      expect(cardText('阅读'), findsOneWidget);
      expect(find.text('确定'), findsNothing);
      expect(find.text('取消'), findsNothing);

      // 点行即选中，底部胶囊实时显示
      await tester.tap(cardText('紧急'));
      await tester.pump();
      expect(find.byTooltip('标签：已选1个'), findsOneWidget);
      // 再点即取消，胶囊回到未选态
      await tester.tap(cardText('紧急'));
      await tester.pump();
      expect(find.byTooltip('标签'), findsOneWidget);
    });

    testWidgets('项目档：锚点单选卡片，未分组可清除', (tester) async {
      await _openPanel(tester);

      await tester.tap(find.byTooltip('项目'));
      await tester.pumpAndSettle();
      // 卡片形态：除面板自身外不再有第二个 BottomSheet
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('未分组'), findsOneWidget);
    });

    testWidgets('日期档：快捷抽屉选明天→图标带值，可清除', (tester) async {
      await _openPanel(tester);

      await tester.tap(find.byTooltip('日期'));
      await tester.pumpAndSettle();
      // 顶层抽屉（快捷日期单）内的行：背景列表页另有一处「明天」文本，
      // 故点选限定在最后（最顶）一个 BottomSheet 内
      Finder sheetRow(String label) => find.descendant(
            of: find.byType(BottomSheet).last,
            matching: find.text(label),
          );
      expect(sheetRow('今天'), findsOneWidget);
      expect(sheetRow('明天'), findsOneWidget);
      expect(sheetRow('选择日期…'), findsOneWidget);
      // 未设时无清除入口
      expect(find.text('清除日期'), findsNothing);

      await tester.tap(sheetRow('明天'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('截止：明天'), findsOneWidget);
      // 底部胶囊直接显示具体值（背景列表页另有一处「明天」，限定到面板内）
      final panel = find.byType(BottomSheet);
      expect(
        find.descendant(of: panel, matching: find.text('明天')),
        findsOneWidget,
      );

      // 再点开已有清除入口，清除后回到未选态
      await tester.tap(find.byTooltip('截止：明天'));
      await tester.pumpAndSettle();
      expect(sheetRow('清除日期'), findsOneWidget);
      await tester.tap(sheetRow('清除日期'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('日期'), findsOneWidget);
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

    testWidgets('initialDueDate 预填截止落图标态、无 chips 行（日历长按口径）', (tester) async {
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
      expect(find.byTooltip('截止：${formatDueLabel(due)}'), findsOneWidget);
      // 底部胶囊直接显示具体值；顶部不加 chips 行
      expect(find.text(formatDueLabel(due)), findsOneWidget);
      expect(find.text(formatYmd(due)), findsNothing);
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
      // 收进「更多」的行挂过入场过渡
      expect(
        find.ancestor(
          of: find.text('标签'),
          matching: find.byWidgetPredicate((w) => w is TweenAnimationBuilder),
        ),
        findsOneWidget,
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

      // 落位前行外无入场过渡（初建不播）
      expect(
        find.ancestor(
          of: find.text('图片'),
          matching: find.byWidgetPredicate((w) => w is TweenAnimationBuilder),
        ),
        findsNothing,
      );

      await tester.drag(find.text('图片'), const Offset(400, 0));
      await tester.pumpAndSettle();

      final (enabled, hidden) = QuickActions.read();
      expect(enabled.last, QuickActionId.image);
      expect(hidden.contains(QuickActionId.image), isFalse);
      // 落位行挂过入场过渡（淡入 + 滑入播完后仍在树上）
      expect(
        find.ancestor(
          of: find.text('图片'),
          matching: find.byWidgetPredicate((w) => w is TweenAnimationBuilder),
        ),
        findsOneWidget,
      );
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

    testWidgets('纵拖排序时预览实时重排，落位提交', (tester) async {
      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();

      AnimatedPositioned previewIcon(QuickActionId id) =>
          tester.widget<AnimatedPositioned>(
            find.byWidgetPredicate(
              (w) => w is AnimatedPositioned && w.key == ValueKey(id),
            ),
          );
      expect(previewIcon(QuickActionId.due).left, 0);

      // 按住首行「日期」的手柄往下拖：首段 move 启动拖拽，次段产生位移
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(OrbitIcons.drag).first),
      );
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 90));
      await tester.pump();

      // 抬起未落位时预览已重排（日期图标离开首槽）
      expect(previewIcon(QuickActionId.due).left!, greaterThan(0));

      await gesture.up();
      await tester.pumpAndSettle();
      final (enabled, _) = QuickActions.read();
      expect(enabled.first, isNot(QuickActionId.due));
    });

    Finder previewIconOf(QuickActionId id) => find.byWidgetPredicate(
          (w) => w is AnimatedPositioned && w.key == ValueKey(id),
        );

    Finder handleOf(String label) => find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(Dismissible),
          ),
          matching: find.byIcon(OrbitIcons.drag),
        );

    testWidgets('更多直拖到工具栏：预览实时插入，落位提交', (tester) async {
      // 拉高测试面：整页无需滚动（拖拽中滚动会干扰悬停定位）
      tester.view.physicalSize = const Size(2400, 4200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();
      expect(previewIconOf(QuickActionId.image), findsNothing);

      // 按住「图片」手柄向上拖：分段 move，拖进工具栏段即停
      final gesture =
          await tester.startGesture(tester.getCenter(handleOf('图片')));
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, -50));
        await tester.pump();
        if (previewIconOf(QuickActionId.image).evaluate().isNotEmpty) break;
      }

      // 未松手时工具栏预览已按悬停槽位插入图片图标
      expect(previewIconOf(QuickActionId.image), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      final (enabled, hidden) = QuickActions.read();
      expect(enabled.contains(QuickActionId.image), isTrue);
      expect(hidden.contains(QuickActionId.image), isFalse);
      expect(
        find.ancestor(
          of: find.text('图片'),
          matching: find.byWidgetPredicate((w) => w is TweenAnimationBuilder),
        ),
        findsOneWidget,
      );
    });

    testWidgets('工具栏直拖到更多：预览实时闭合，落位提交', (tester) async {
      tester.view.physicalSize = const Size(2400, 4200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(const QuickActionsPage(), MockOrbitBridge()));
      await tester.pumpAndSettle();
      expect(previewIconOf(QuickActionId.label), findsOneWidget);

      // 按住「标签」手柄向下拖：拖进「更多」段即停
      final gesture =
          await tester.startGesture(tester.getCenter(handleOf('标签')));
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 50));
        await tester.pump();
        if (previewIconOf(QuickActionId.label).evaluate().isEmpty) break;
      }

      // 未松手时工具栏预览已闭合缺口（标签图标暂离）
      expect(previewIconOf(QuickActionId.label), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      final (enabled, hidden) = QuickActions.read();
      expect(enabled.contains(QuickActionId.label), isFalse);
      expect(hidden.contains(QuickActionId.label), isTrue);
    });
  });
}
