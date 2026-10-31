import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/miuix_theme.dart';
import '../../../core/theme/orbit_accents.dart';

/// 按钮变体（语义与 Material 三件套一一对应，便于逐点替换）
enum OrbitButtonVariant {
  /// 实心主色（原 `FilledButton`）
  primary,

  /// 实心次级（HyperOS 默认按钮形态：浅灰底深字；原 `FilledButton.tonal`）
  secondary,

  /// 描边（原 `OutlinedButton`）
  outline,

  /// 纯文字（原 `TextButton`）
  text,
}

/// 按钮（原语层：flutter_miuix `MiuixButton` 承载，HyperOS squircle 形态）
///
/// **2026-10-31 新增**：此前 95 处按钮直接用 Material `FilledButton` /
/// `OutlinedButton` / `TextButton`，外观由 `app_theme.dart` 的
/// `filledButtonTheme` / `outlinedButtonTheme` / `textButtonTheme` 统一着色。
/// 本原语把它们换成 [MiuixButton]——**squircle 超椭圆圆角**（与卡片同一套
/// 几何语言）+ `MiuixPressable` 的按压遮罩/弹簧反馈（源端 Compose `Button`
/// 同款手感），颜色仍由 `core/theme` token 派生（不写裸色值）。
///
/// **三种形态的色板口径**（与既有主题同源，避免"换组件顺带换配色"）：
/// - primary：主题强调色底 + 白字（= 原 `filledButtonTheme`）；
/// - outline：透明底 + 强调色描边 + 强调色字（= 原 `outlinedButtonTheme`）；
/// - text：透明底 + 强调色字（= 原 `textButtonTheme`）；
/// - destructive：破坏性色底/描边（删除类），替代各处
///   `OutlinedButton.styleFrom(foregroundColor: colors.destructive)` 的手写样式。
///
/// **尺寸口径**：`MiuixButton` 的 `minHeight` 默认 40，本仓库触控目标是 48
/// （[AppDimens.touchTarget]）。默认取 48 保证热区不下滑；`compact: true`
/// 用于表格/头行里的轻量动作（40，与 Material `visualDensity: compact` 同档）。
///
/// **整行宽按钮**：`MiuixButton` 贴内容尺寸（对应 Compose `defaultMinSize`），
/// 不会自动撑满。旧调用点常用 `SizedBox(width: double.infinity, child: ...)`
/// 包一层——这种写法仍有效（外层撑满、按钮居中），需要**按钮本身**撑满时传
/// [expand]。
class OrbitButton extends StatelessWidget {
  const OrbitButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.variant = OrbitButtonVariant.primary,
    this.destructive = false,
    this.compact = false,
    this.expand = false,
    this.iconGap = AppDimens.space8,
  });

  /// 主色实心按钮
  const OrbitButton.primary({
    super.key,
    required this.onPressed,
    required this.child,
    this.destructive = false,
    this.compact = false,
    this.expand = false,
    this.iconGap = AppDimens.space8,
  }) : variant = OrbitButtonVariant.primary;

  /// 次级实心按钮（HyperOS 默认形态）
  const OrbitButton.secondary({
    super.key,
    required this.onPressed,
    required this.child,
    this.destructive = false,
    this.compact = false,
    this.expand = false,
    this.iconGap = AppDimens.space8,
  }) : variant = OrbitButtonVariant.secondary;

  /// 描边按钮
  const OrbitButton.outline({
    super.key,
    required this.onPressed,
    required this.child,
    this.destructive = false,
    this.compact = false,
    this.expand = false,
    this.iconGap = AppDimens.space8,
  }) : variant = OrbitButtonVariant.outline;

  /// 纯文字按钮
  const OrbitButton.text({
    super.key,
    required this.onPressed,
    required this.child,
    this.destructive = false,
    this.compact = false,
    this.expand = false,
    this.iconGap = AppDimens.space8,
  }) : variant = OrbitButtonVariant.text;

  /// 带前置图标 + 文案的快捷构造（替代 `XButton.icon(icon:, label:)`）
  OrbitButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    required Widget label,
    this.variant = OrbitButtonVariant.primary,
    this.destructive = false,
    this.compact = false,
    this.expand = false,
    this.iconGap = AppDimens.space8,
  }) : child = _IconLabel(icon: icon, label: label, gap: iconGap);

  final VoidCallback? onPressed;

  /// 按钮内容（图标 + 文案由 [OrbitButton.icon] 组装，也可自行传任意 Widget）
  final Widget child;

  final OrbitButtonVariant variant;

  /// 破坏性语义（删除/清空/断开类）：主色与描边换成 [AppColorSet.destructive]
  final bool destructive;

  /// 紧凑档（40 高，用于表格/头行轻量动作）
  final bool compact;

  /// 撑满可用宽度（`MiuixButton` 本身贴内容尺寸）
  final bool expand;

  /// 图标与文案间距（仅 [OrbitButton.icon] 使用）
  final double iconGap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final mColors = buildMiuixColors(Theme.of(context).brightness);
    final accent = destructive ? colors.destructive : OrbitAccents.themeAccent;
    final minHeight = compact ? 40.0 : AppDimens.touchTarget;

    final buttonColors = switch (variant) {
      OrbitButtonVariant.primary => MiuixButtonColors(
          color: accent,
          disabledColor: colors.divider,
          contentColor: mColors.onPrimary,
          disabledContentColor: colors.deactivatedText,
        ),
      OrbitButtonVariant.secondary => MiuixButtonColors(
          color: colors.surfaceSecondary,
          disabledColor: colors.divider,
          contentColor: destructive ? colors.destructive : colors.bodyText,
          disabledContentColor: colors.deactivatedText,
        ),
      // 描边/文字：底透明，靠描边或文字色表达强调
      OrbitButtonVariant.outline => MiuixButtonColors(
          color: Colors.transparent,
          disabledColor: Colors.transparent,
          contentColor: accent,
          disabledContentColor: colors.deactivatedText,
        ),
      OrbitButtonVariant.text => MiuixButtonColors(
          color: Colors.transparent,
          disabledColor: Colors.transparent,
          contentColor: accent,
          disabledContentColor: colors.deactivatedText,
        ),
    };

    Widget button = MiuixButton(
      onPressed: onPressed,
      minHeight: minHeight,
      // 圆角：与卡片同一档（squircle 几何由 MiuixButton 内部构造）
      cornerRadius: AppShapes.radiusMedium,
      insideMargin: EdgeInsets.symmetric(
        horizontal: compact ? AppDimens.space12 : AppDimens.space16,
        vertical: compact ? AppDimens.space8 : AppDimens.space12,
      ),
      colors: buttonColors,
      child: child,
    );

    if (variant == OrbitButtonVariant.outline) {
      button = CustomPaint(
        foregroundPainter: _ButtonOutlinePainter(
          color: onPressed == null ? colors.outline : accent,
          radius: AppShapes.radiusMedium,
        ),
        child: button,
      );
    }

    if (expand) {
      return SizedBox(width: double.infinity, child: button);
    }
    return button;
  }
}

/// 图标 + 文案（[OrbitButton.icon] 的内容组装）
class _IconLabel extends StatelessWidget {
  const _IconLabel({required this.icon, required this.label, required this.gap});

  final Widget icon;
  final Widget label;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          SizedBox(width: gap),
          label,
        ],
      );
}

/// 描边按钮的 1px 描边（与卡面同形的超椭圆路径）
class _ButtonOutlinePainter extends CustomPainter {
  const _ButtonOutlinePainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shape = MiuixSquircleBorder(cornerRadius: radius);
    canvas.drawPath(
      shape.getOuterPath(Offset.zero & size),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ButtonOutlinePainter old) =>
      old.color != color || old.radius != radius;
}


