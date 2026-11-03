// 共享弹层族（orbit_sheets.dart）承载口径：
// - 确认 / 更多操作：Material `showModalBottomSheet` + `bottomSheetTopShape`；
// - 单选：2026-11-03 起**复用页头 ⋮ 菜单的面板**（OrbitDropdownPanelView +
//   OS4 玻璃表面，右上角弹出），不再走底部抽屉或自绘白卡。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_glass_surface.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_sheets.dart';
import 'support/orbit_test_app.dart';

/// 标签字形的水平中心（Text 局部坐标）。
///
/// 底部按钮经 `Expanded` 拉满宽后，标签 Text 的盒子与按钮同宽，字形落位由
/// `textAlign` 决定——故只能量字形，量 Text 盒子量不出居中与否。
double glyphCenterX(WidgetTester tester, String label) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: label.length),
  );
  return boxes
      .map((box) => box.toRect())
      .reduce((a, b) => a.expandToInclude(b))
      .center
      .dx;
}

/// 取按钮实际配置的填充色（2026-11-01 换承载：OrbitButton → miuix
/// `MiuixButton`，颜色经构造上的 `colors` 配置，不再有 shadcn 的
/// `OverflowDecoratedBox` decoration 可取）。
Color buttonFillOf(WidgetTester tester, String label) {
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byType(MiuixButton),
  );
  return tester.widget<MiuixButton>(button.first).colors!.color;
}

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(orbitTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    return ctx;
  }

  testWidgets('单选浮层：复用页头 ⋮ 菜单面板（玻璃 + 行勾）', (tester) async {
    final ctx = await pumpHost(tester);
    showSelectBottomSheet<String>(
      ctx,
      title: '视图模式',
      items: const [
        SelectItem(value: 'list', label: '列表'),
        SelectItem(value: 'grid', label: '网格'),
      ],
      current: 'list',
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    // 与页头菜单同一套渲染：OrbitDropdownPanelView 行 + OS4 玻璃表面；
    // 底部抽屉与自绘白卡均已退场
    expect(selectPopup(), findsOneWidget);
    expect(find.byType(OrbitDropdownPanelView), findsOneWidget);
    expect(find.byType(OrbitGlassSurface), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing, reason: '不再从底部升起抽屉');
    expect(find.text('视图模式'), findsNothing, reason: '菜单没有标题行');

    // 选中态在行数据上打勾；行文字保持正文色（与菜单一致，不染蓝）
    expect(selectedPopupLabels(tester), ['列表']);
    expect(
      tester.widget<Text>(find.text('列表')).style?.color,
      AppColors.light.bodyText,
    );
  });

  testWidgets('单选浮层：右上角、页头下沿、240 宽（与页头菜单同坐标）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showSelectBottomSheet<String>(
      ctx,
      title: '同步引擎',
      items: const [
        SelectItem(value: 'webdav', label: 'WebDAV'),
        SelectItem(value: 's3', label: 'S3 兼容存储'),
      ],
      current: 'webdav',
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    final screen = tester.getSize(find.byType(Scaffold));
    final popup = tester.getRect(selectPopup());
    expect(popup.width, 240, reason: 'orbitPanelMaxWidth（与菜单同宽）');
    expect(
      popup.right,
      moreOrLessEquals(screen.width - 8, epsilon: 1),
      reason: '右侧留白 8（菜单同款）',
    );
    expect(popup.top, greaterThan(0), reason: '页头下沿起算');
    expect(popup.height, lessThan(screen.height * 0.5), reason: '短内容自适应收缩');
    expect(
      tester.getRect(find.text('S3 兼容存储')).bottom,
      lessThanOrEqualTo(screen.height),
      reason: '末项不能溢出屏幕',
    );
  });

  testWidgets('单选浮层：点面板外关闭（不铺遮罩色）', (tester) async {
    final ctx = await pumpHost(tester);
    showSelectBottomSheet<String>(
      ctx,
      title: '优先级',
      items: const [
        SelectItem(value: 'p0', label: 'P0'),
        SelectItem(value: 'p1', label: 'P1'),
      ],
      current: 'p0',
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();
    expect(selectPopup(), findsOneWidget);

    await tester.tapAt(const Offset(8, 300));
    await tester.pumpAndSettle();
    expect(selectPopup(), findsNothing);
  });

  testWidgets('单选弹层：icon 项渲染语义图标（快捷视图切换口径）', (tester) async {
    final ctx = await pumpHost(tester);
    const iconColor = Color(0xFFEF4444);
    showSelectBottomSheet<String>(
      ctx,
      title: '快捷视图',
      items: const [
        SelectItem(
          value: 'today',
          label: '今天',
          icon: Icons.calendar_today,
          iconColor: iconColor,
        ),
      ],
      current: 'today',
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    // 行首是语义图标而非色点：图标按传入色染色，尺寸与清单页快捷行同档
    final icon = tester.widget<Icon>(find.byIcon(Icons.calendar_today));
    expect(icon.color, iconColor);
    expect(icon.size, AppDimens.iconSizeMd);
    expect(find.text('今天'), findsOneWidget);
  });

  testWidgets('单选浮层：hint 渲染为副标题（快捷日期档「周四, 09:00」信息位）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showSelectBottomSheet<String>(
      ctx,
      title: '设置截止时间',
      items: const [
        SelectItem(
          value: 'tomorrow',
          label: '明天',
          hint: '周四, 09:00',
          icon: Icons.wb_sunny_outlined,
        ),
        SelectItem(value: 'clear', label: '清除截止'),
      ],
      current: null,
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    final hint = tester.widget<Text>(find.text('周四, 09:00'));
    expect(hint.style?.color, AppColors.light.secondaryText,
        reason: '行尾提示取次要文字色');
    expect(find.text('明天'), findsOneWidget);
    // hint 不改变选中态：当前值为空时任何一项都不打勾
    expect(selectedPopupLabels(tester), isEmpty);
  });

  testWidgets('确认弹层：底部按钮标签水平居中（贴左即 TextAlign.start 回归）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showConfirmBottomSheet(ctx, title: '删除任务', message: '不可恢复');
    await tester.pumpAndSettle();

    for (final label in ['取消', '确定']) {
      expect(
        glyphCenterX(tester, label),
        moreOrLessEquals(tester.getSize(find.text(label)).width / 2,
            epsilon: 1),
        reason: '$label 应居中于按钮内',
      );
    }
  });

  testWidgets('确认弹层：删除按钮实心不透明（不是像禁用的淡粉）', (tester) async {
    final ctx = await pumpHost(tester);
    showConfirmBottomSheet(
      ctx,
      title: '删除任务',
      message: '删除后将移入回收站',
      confirmLabel: '删除',
      destructive: true,
    );
    await tester.pumpAndSettle();

    final fill = buttonFillOf(tester, '删除');
    expect(
      fill.a,
      1,
      reason: '实心填充——shadcn 默认 0.5 alpha 的白字淡粉会被用户读成"不可点"',
    );
    expect(fill, AppColors.light.destructive, reason: '取破坏性 token 实色');
  });

  testWidgets('确认弹层：长内容滚动时底部按钮固定（不被内容顶出）', (tester) async {
    final ctx = await pumpHost(tester);
    showConfirmBottomSheet(
      ctx,
      title: '长内容',
      content: Column(
        children: [for (var i = 0; i < 80; i++) Text('行 $i')],
      ),
    );
    await tester.pumpAndSettle();

    final confirm = find.text('确定');
    final before = tester.getRect(confirm);
    final sheetBottom = tester.getRect(find.byType(BottomSheet)).bottom;
    expect(
      sheetBottom - before.bottom,
      lessThan(40),
      reason: '按钮应钉在抽屉底部（间距只剩尾栏内边距）',
    );

    // 内容在内容区独立滚动（抽屉高度 85% 上限 + 80 行文本必然溢出），
    // 按钮位置不受影响
    await tester.drag(find.text('行 0'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getRect(confirm), before, reason: '内容滚动不应带动按钮');
  });

  testWidgets('确认弹层：点确认返回 true、点取消返回 false', (tester) async {
    final ctx = await pumpHost(tester);

    final confirmed = showConfirmBottomSheet(ctx, title: '删除任务', message: '不可恢复');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(await confirmed, isTrue);

    final cancelled = showConfirmBottomSheet(ctx, title: '删除任务');
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await cancelled, isFalse);
  });

  // 冷静期口径对齐桌面 DangerousConfirmDialog：确认钮先禁用并倒数，
  // 走完才可点；取消不受限（用户随时能退出）。
  testWidgets('确认弹层：holdSeconds 冷静期内确认钮禁用，走完才可点', (tester) async {
    final ctx = await pumpHost(tester);

    final result = showConfirmBottomSheet(
      ctx,
      title: '再次确认生成',
      message: '不可撤销',
      confirmLabel: '确认生成',
      holdSeconds: 3,
    );
    await tester.pumpAndSettle();

    expect(find.text('请阅读后果（3s）'), findsOneWidget);
    // 冷静期内点确认不生效：抽屉仍在
    await tester.tap(find.text('请阅读后果（3s）'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('再次确认生成'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('请阅读后果（2s）'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('请阅读后果（1s）'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('确认生成'), findsOneWidget);

    await tester.tap(find.text('确认生成'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  test('冷静期文案：未走完显示剩余秒数，走完回落确认文案', () {
    expect(formatHoldConfirmLabel(3, '确认生成'), '请阅读后果（3s）');
    expect(formatHoldConfirmLabel(1, '确认清除'), '请阅读后果（1s）');
    expect(formatHoldConfirmLabel(0, '确认清除'), '确认清除');
  });
}
