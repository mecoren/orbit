// 输入型底部弹层的间距回归（2026-11-04 收口）：
// 字段纵向节奏统一 AppDimens.space12，色板几何统一走 OrbitColorSwatches，
// 承载统一走 OrbitSheetScaffold（形状/动效常量同共享弹层族）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/core/theme/app_dimens.dart';
import 'package:orbit/core/theme/app_shapes.dart';
import 'package:orbit/data/api/mock_orbit_bridge.dart';
import 'package:orbit/data/providers/bridge_provider.dart';
import 'package:orbit/modules/settings/label_manager_page.dart';
import 'package:orbit/modules/settings/template_manager_page.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_color_swatches.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_dropdown_preference.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_floating_sheet_card.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_password_sheet.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import 'package:orbit/shared/widgets/shadcn/orbit_sheets.dart';
import 'support/orbit_test_app.dart';

Widget _page(Widget child, MockOrbitBridge bridge) => ProviderScope(
  overrides: [orbitBridgeProvider.overrideWithValue(bridge)],
  child: orbitTestApp(home: child),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 是否属于项目间距刻度档（页面写得出字段间距的合法取值）
bool _isSpacingScale(double h) =>
    h == AppDimens.space8 ||
    h == AppDimens.space12 ||
    h == AppDimens.space16 ||
    h == AppDimens.space20 ||
    h == AppDimens.space24;

/// 页面显式写出的字段间距。按钮行的横向 SizedBox 的 height 为 null、miuix
/// 输入框内部的 0/22 留白不属于页面节奏，一并排除；下拉偏好原语
/// （`OrbitDropdownPreference`）内部的呼吸位也由原语自持，不算页面节奏。
List<double> _sheetGaps(WidgetTester tester) {
  final gaps = <double>[];
  for (final element in find
      .descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(SizedBox),
      )
      .evaluate()) {
    final widget = element.widget;
    if (widget is! SizedBox) continue;
    final height = widget.height;
    if (height == null || !_isSpacingScale(height)) continue;
    if (_insideDropdownPreference(element)) continue;
    gaps.add(height);
  }
  return gaps;
}

/// 元素是否落在 [OrbitDropdownPreference] 子树内（原语自持的箭头/呼吸位盒）
///
/// 不用 `findAncestorWidgetOfExactType`：它按 `runtimeType` 精确比对，
/// 泛型实参不同（`<int?>` vs `<Object?>`）匹配不上；这里用协变 `is` 判断。
bool _insideDropdownPreference(Element element) {
  var inside = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is OrbitDropdownPreference<Object?>) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

void _expectUnifiedGaps(WidgetTester tester) {
  final gaps = _sheetGaps(tester);
  expect(gaps, isNotEmpty, reason: '弹层里应有显式字段间距');
  expect(
    gaps.every((h) => h == AppDimens.space12),
    isTrue,
    reason: '字段间距统一 12，实际取值 $gaps',
  );
}

/// 所有底部弹层都必须是脱离屏幕边缘的浮起圆角卡片（与确认弹层同形态）
void _expectFloatingCard(WidgetTester tester) {
  final card = find.byType(OrbitFloatingSheetCard);
  expect(card, findsOneWidget, reason: '底部弹层应由浮起卡片原语绘制');
  final container = tester.widget<Container>(
    find.descendant(of: card, matching: find.byType(Container)).first,
  );
  expect(
    container.margin,
    const EdgeInsets.only(
      left: AppDimens.space16,
      right: AppDimens.space16,
      bottom: AppDimens.space16,
    ),
    reason: '左/右/下各留白 16，与周围有间隔、底边不贴屏幕',
  );
  expect(
    (container.decoration! as BoxDecoration).borderRadius,
    AppShapes.xl,
    reason: '四角 28，不是贴边抽屉的顶圆角',
  );
}

void main() {
  testWidgets('密码输入抽屉：字段间距统一 12', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showPasswordSheet(
      ctx,
      title: '设置同步密码',
      message: '设置后所有上传数据以该密码端到端加密。',
      labels: const ['同步密码', '确认密码'],
      confirmLabel: '设置并解锁',
    );
    await tester.pumpAndSettle();

    _expectUnifiedGaps(tester);
    _expectFloatingCard(tester);
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('新建/编辑标签弹层：字段间距与色板几何统一', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_page(const LabelManagerPage(), bridge));
    await _settle(tester);

    await tester.tap(find.text('新建标签'));
    await tester.pumpAndSettle();

    final wrap = tester.widget<Wrap>(
      find.descendant(
        of: find.byType(OrbitColorSwatches),
        matching: find.byType(Wrap),
      ),
    );
    expect(wrap.spacing, AppDimens.space12);
    expect(wrap.runSpacing, AppDimens.space12);
    _expectUnifiedGaps(tester);
    _expectFloatingCard(tester);
  });

  testWidgets('标签改色抽屉：与新建标签共用同一色板几何', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_page(const LabelManagerPage(), bridge));
    await _settle(tester);

    // 行内色点是改色入口；用行标题定位同行的圆形 Container
    final rowDot = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle,
    );
    expect(rowDot, findsWidgets);
    await tester.tap(rowDot.first);
    await tester.pumpAndSettle();

    expect(find.text('标签颜色'), findsOneWidget);
    expect(find.byType(OrbitColorSwatches), findsOneWidget);
    _expectFloatingCard(tester);
    final wrap = tester.widget<Wrap>(
      find.descendant(
        of: find.byType(OrbitColorSwatches),
        matching: find.byType(Wrap),
      ),
    );
    expect(wrap.spacing, AppDimens.space12);
    expect(wrap.runSpacing, AppDimens.space12);
  });

  testWidgets('新建模板弹层：字段间距统一 12', (tester) async {
    final bridge = MockOrbitBridge();
    await tester.pumpWidget(_page(const TemplateManagerPage(), bridge));
    await _settle(tester);

    await tester.tap(find.text('新建模板'));
    await tester.pumpAndSettle();

    _expectUnifiedGaps(tester);
    _expectFloatingCard(tester);
  });

  testWidgets('骨架几何：标题 / 内容 / 按钮行内边距锁死统一口径', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    showModalBottomSheet<void>(
      context: ctx,
      useRootNavigator: true,
      isScrollControlled: true,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (_) => OrbitSheetScaffold(
        title: '口径校验',
        contentPadding: const EdgeInsets.fromLTRB(
          AppDimens.space16,
          0,
          AppDimens.space16,
          AppDimens.space16,
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [SizedBox(height: AppDimens.space12)],
        ),
        actions: OrbitSheetActions(
          cancelLabel: '取消',
          onCancel: () {},
          confirmLabel: '确定',
          onConfirm: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    Padding withPadding(EdgeInsetsGeometry p) => tester.widget<Padding>(
      find.byWidgetPredicate((w) => w is Padding && w.padding == p).first,
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.padding ==
                const EdgeInsets.fromLTRB(
                  AppDimens.space16,
                  AppDimens.space16,
                  AppDimens.space16,
                  AppDimens.space8,
                ),
      ),
      findsOneWidget,
      reason: '标题 16/16/16/8',
    );
    expect(
      withPadding(
        const EdgeInsets.fromLTRB(
          AppDimens.space16,
          0,
          AppDimens.space16,
          AppDimens.space16,
        ),
      ).padding,
      const EdgeInsets.fromLTRB(16, 0, 16, 16),
      reason: '内容 16/0/16/16',
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.padding ==
                const EdgeInsets.fromLTRB(
                  AppDimens.space16,
                  AppDimens.space16,
                  AppDimens.space16,
                  AppDimens.space20,
                ),
      ),
      findsOneWidget,
      reason: '按钮行 16/16/16/20',
    );
    _expectUnifiedGaps(tester);
    _expectFloatingCard(tester);

    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('OrbitColorSwatches：36 色点 / 6 补白 / 12 间距 / 48 热区', (
    tester,
  ) async {
    await tester.pumpWidget(
      orbitTestApp(
        home: Scaffold(
          body: Center(
            child: OrbitColorSwatches(
              hexes: const ['#111111', '#222222'],
              selectedHex: '#111111',
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final wrap = tester.widget<Wrap>(find.byType(Wrap));
    expect(wrap.spacing, AppDimens.space12);
    expect(wrap.runSpacing, AppDimens.space12);

    final dots = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle,
    );
    expect(dots, findsNWidgets(2));
    expect(tester.getSize(dots.first), const Size(36, 36));

    final heat = find.byWidgetPredicate(
      (w) =>
          w is Padding && w.padding == const EdgeInsets.all(AppDimens.space6),
    );
    expect(heat, findsNWidgets(2));
    expect(tester.getSize(heat.first).width, AppDimens.touchTarget);
  });
}
