// 共享弹层族（orbit_sheets.dart）承载口径：
// - 确认 / 更多操作：Material `showModalBottomSheet` + `bottomSheetTopShape`；
// - 单选：2026-11-05 起与「今天」页头 ⋮ 菜单同一套口径（MiuixGlassPopupItem
//   行 + 圆角 24 玻璃卡 + 贴触发行下方弹出），承载换成库内
//   `MiuixGlassDropdownPopup`，不再走底部抽屉、也不再手写测量/落位/形变。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_colors.dart';
import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/core/theme/app_shapes.dart';
import 'package:orbit/core/theme/orbit_accents.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_panel.dart'
    show orbitPanelMaxWidth, orbitPanelMinWidth;
import 'package:orbit/shared/widgets/shadcn/orbit_sheet_scaffold.dart';
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

  testWidgets('单选浮层：miuix 下拉行（未选中正文色 / 选中强调色 + 勾）',
      (tester) async {
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

    // 行渲染走玻璃菜单条目（MiuixGlassPopupItem），承载是库内 dropdown 弹层
    expect(selectPopup(), findsOneWidget);
    expect(find.byType(MiuixGlassDropdownPopup), findsOneWidget);
    expect(find.byType(MiuixGlassPopupItem), findsNWidgets(2));
    expect(find.byType(BottomSheet), findsNothing, reason: '不再从底部升起抽屉');
    expect(find.text('视图模式'), findsNothing, reason: '下拉面板没有标题行');

    expect(selectedPopupLabels(tester), ['列表']);
    expect(
      tester.widget<Text>(find.text('列表')).style?.color,
      OrbitAccents.themeAccent,
      reason: '选中项文字取强调色',
    );
    expect(
      tester.widget<Text>(find.text('网格')).style?.color,
      AppColors.light.titleText,
      reason: '未选中项取库内下拉默认正文色（onSurfaceContainer）',
    );
  });

  testWidgets('单选浮层：卡面与「今天」菜单同一枚玻璃面板（无采样器退实色白卡）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showSelectBottomSheet<String>(
      ctx,
      title: '视图模式',
      items: const [SelectItem(value: 'list', label: '列表')],
      current: 'list',
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    // 2026-11-05 起卡面直接用 ⋮ 菜单同款 `MiuixGlassPanel`：测试裸页没有
    // 壳层 OrbitGlassScope → 库内无快照分支填实色（白卡），不再自绘实时
    // 模糊（那档会把白卡糊成灰白半透明，与菜单观感不一致）。
    // 承载换到库内 dropdown 后，panel 与条目列在 `GlassPopupLayout` 里是
    // **兄弟**（content 不再是 panel 的子孙），故按数量断言。
    expect(find.byType(MiuixGlassPanel), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing,
        reason: '无采样器走库内实色填充，不再叠实时模糊');
  });

  testWidgets('单选浮层：路由内容必须包 Material（黄线下划线回归）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showSelectBottomSheet<String>(
      ctx,
      title: '视图模式',
      items: const [SelectItem(value: 'list', label: '列表')],
      current: 'list',
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    // `showGeneralDialog` 不像 showDialog / 底部抽屉那样自带 Material；缺层
    // 时 DefaultTextStyle 落到 MaterialApp 的警告样式（黄双下划线）。
    final style = DefaultTextStyle.of(tester.element(find.text('列表'))).style;
    expect(style.decoration, isNot(TextDecoration.underline),
        reason: '弹层缺 Material 祖先时选项文字会画黄线下划线');
  });

  testWidgets('单选浮层：贴锚点行下方、右沿对齐（下拉偏好 Overlay 口径）',
      (tester) async {
    final ctx = await pumpHost(tester);
    const anchor = Rect.fromLTWH(320, 120, 300, 48);
    showSelectBottomSheet<String>(
      ctx,
      title: '同步引擎',
      items: const [
        SelectItem(value: 'webdav', label: 'WebDAV'),
        SelectItem(value: 's3', label: 'S3 兼容存储'),
      ],
      current: 'webdav',
      anchor: anchor,
      onSelect: (_) {},
    );
    await tester.pumpAndSettle();

    final screen = tester.getSize(find.byType(Scaffold));
    final popup = tester.getRect(selectPopup());
    expect(
      popup.top,
      greaterThanOrEqualTo(anchor.bottom),
      reason: '落在触发行的下方（不盖住当前值）',
    );
    expect(
      popup.right,
      moreOrLessEquals(anchor.right, epsilon: 1),
      reason: '右沿对齐触发行',
    );
    expect(
      popup.width,
      greaterThanOrEqualTo(orbitPanelMinWidth),
      reason: '全站弹出菜单统一最小宽',
    );
    expect(
      popup.width,
      lessThanOrEqualTo(orbitPanelMaxWidth),
      reason: '全站弹出菜单统一最大宽（条目文案最长也就「排序方式」这一档）',
    );
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
    expect(
      hint.style?.color,
      AppColors.light.secondaryText,
      reason: '副标题取库内下拉默认 summary 色（onSurfaceVariantSummary）',
    );
    expect(find.text('明天'), findsOneWidget);
    // hint 不改变选中态：当前值为空时任何一项都不打勾
    expect(selectedPopupLabels(tester), isEmpty);
  });

  testWidgets('确认弹层：浮起圆角卡 + 居中标题（对齐 miuix 对话框参考）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showConfirmBottomSheet(
      ctx,
      title: '导出明文数据',
      message: '导出内容为未加密明文',
    );
    await tester.pumpAndSettle();

    final card = find.byKey(confirmDialogCardKey);
    expect(card, findsOneWidget);
    // 宽屏上 BottomSheet 自身会限宽居中，故验外观配置而非绝对坐标
    final container = tester.widget<Container>(card);
    expect(
      container.margin,
      const EdgeInsets.only(
        left: AppDimens.space16,
        right: AppDimens.space16,
        bottom: AppDimens.space16,
      ),
      reason: '左/右/下各留白 16，底边不贴屏幕、四角圆角完整可见',
    );
    expect(
      (container.decoration! as BoxDecoration).borderRadius,
      AppShapes.xl,
      reason: '四角大圆角（不是贴边抽屉的顶圆角）',
    );
    expect(
      tester.widget<OrbitSheetScaffold>(find.byType(OrbitSheetScaffold)).showHandle,
      isFalse,
      reason: '对话框没有拖拽手柄',
    );
    expect(
      tester.widget<Text>(find.text('导出明文数据')).textAlign,
      TextAlign.center,
      reason: '标题居中',
    );
    expect(
      tester.widget<Text>(find.text('导出内容为未加密明文')).textAlign,
      TextAlign.center,
      reason: '说明居中',
    );
    for (final label in ['取消', '确定']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(MiuixButton),
      );
      expect(
        tester.widget<MiuixButton>(button.first).cornerRadius,
        AppShapes.radiusMedium,
        reason: '$label 圆角与项目按钮统一档一致（AppShapes.medium = 14）',
      );
    }
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
    // 卡片现在是浮起浮层（底部留白 16），量「按钮到卡片底」而非到承载底
    final cardBottom = tester
        .getRect(
          find
              .descendant(
                of: find.byKey(confirmDialogCardKey),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .bottom;
    expect(
      cardBottom - before.bottom,
      lessThan(40),
      reason: '按钮应钉在卡片底部（间距只剩尾栏内边距）',
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
