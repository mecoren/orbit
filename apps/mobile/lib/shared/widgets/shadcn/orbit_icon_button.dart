import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 图标按钮（原语层：flutter_miuix `MiuixIconButton` 承载，HyperOS 圆形按压）
///
/// **2026-10-31 新增**：此前 44 处直接用 Material `IconButton`，视觉靠
/// `ThemeData.iconTheme` + 默认水波；换成 [MiuixIconButton] 后获得
/// **squircle 圆形底 + 弹簧按压遮罩**（源端 Compose `IconButton` 同款手感），
/// 颜色仍取 `core/theme` token。
///
/// **为什么保留 Material `Tooltip` 而不是 `MiuixTooltip`**：
/// `IconButton.tooltip` 在仓库里有 55 处、测试里 64 处 `find.byTooltip` 依赖它；
/// Miuix 的 tooltip 是独立组件（`MiuixTooltipBox`），换掉会同时改掉 55 处调用
/// 写法和 64 条断言。这里保持 `tooltip:` 参数语义不变（内部包 Material
/// `Tooltip`，其外观由 `app_theme.dart` 的 `tooltipTheme` 统一成「主题色底白字」，
/// 与 AGENTS.md 的悬浮提示口径一致）。
///
/// **尺寸/热区**：Miuix 图标钮最小 40×40，本仓库触控目标是 48——默认取
/// [AppDimens.touchTarget]；页头/行内紧凑位传 [compact]（40，与旧
/// `IconButton` 的 `visualDensity: compact` 同档）。
class OrbitIconButton extends StatelessWidget {
  const OrbitIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.color,
    this.compact = false,
    this.circular = true,
    this.visualDensity,
    this.padding,
    this.constraints,
    this.iconSize,
  });

  final VoidCallback? onPressed;

  /// 图标（直接给 `Icon`，尺寸/颜色由调用方决定；不传色时由 [color] 覆盖）
  final Widget icon;

  /// 读屏/悬浮提示文案（null = 不包 Tooltip）
  final String? tooltip;

  /// 图标色覆盖（null = 沿用调用方在 `Icon` 上设的色）
  final Color? color;

  /// 紧凑档（40 高，用于表格/头行/列表行内动作）
  final bool compact;

  /// 圆形（默认；行内方形热区可传 false → 中等圆角）
  final bool circular;

  /// 兼容参数：Material `IconButton` 的 `visualDensity`
  ///
  /// 迁移期保留这个入参是为了**调用点零改动**：仓库 44 处 `IconButton` 里有
  /// 一批带 `VisualDensity.compact`（行内轻量动作）。传 compact 密度即等价于
  /// 本组件的 [compact] 档，其余密度值按标准档处理（Miuix 只有两档）。
  final VisualDensity? visualDensity;

  /// 兼容参数：Material `IconButton` 的内边距（Miuix 版本不吃 padding，
  /// 热区由 [constraints]/[compact] 决定；传 `EdgeInsets.zero` 表示"贴内容"）
  final EdgeInsetsGeometry? padding;

  /// 兼容参数：热区约束（取 `minWidth`/`minHeight` 作为方形边长）
  final BoxConstraints? constraints;

  /// 兼容参数：图标尺寸（包一层 `IconTheme`，覆盖 `Icon` 自身尺寸）
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    // 边长优先级：显式 constraints 的紧约束 > compact 档 > 触控标准档
    final extent = _resolveExtent();
    final iconWidget = _resolveIcon();

    Widget button = SizedBox.square(
      dimension: extent,
      child: MiuixIconButton(
        onPressed: onPressed,
        cornerRadius: circular ? extent : 12,
        minWidth: extent,
        minHeight: extent,
        child: iconWidget,
      ),
    );

    final tip = tooltip;
    if (tip != null) {
      button = Tooltip(
        message: tip,
        child: Semantics(button: true, label: tip, child: button),
      );
    }

    // 禁用态整体降透明度（MiuixIconButton 只按 onPressed 判可用，无禁用色）
    if (onPressed == null) {
      return Opacity(
        opacity: 0.45,
        child: button,
      );
    }
    return button;
  }

  /// 热区边长：`constraints` 的 min 边长 → [compact] → [AppDimens.touchTarget]
  double _resolveExtent() {
    final box = constraints;
    if (box != null) {
      final w = box.minWidth;
      final h = box.minHeight;
      final side = (w.isFinite && h.isFinite) ? (w < h ? w : h) : null;
      if (side != null && side > 0 && side <= 56) return side;
    }
    if (compact || visualDensity == VisualDensity.compact) return 40.0;
    return AppDimens.touchTarget;
  }

  /// 图标（可选叠加尺寸/颜色覆盖）
  Widget _resolveIcon() {
    final size = iconSize;
    if (size == null && color == null) return icon;
    return IconTheme.merge(
      data: IconThemeData(size: size, color: color),
      child: icon,
    );
  }
}

/// 语义色图标钮快捷构造（删除/危险操作用破坏色，其余走次要文字色）
class OrbitDangerIconButton extends StatelessWidget {
  const OrbitDangerIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.compact = true,
  });

  final VoidCallback? onPressed;
  final Widget icon;
  final String? tooltip;
  final bool compact;

  @override
  Widget build(BuildContext context) => OrbitIconButton(
        onPressed: onPressed,
        icon: icon,
        tooltip: tooltip,
        color: AppColors.ofContext(context).destructive,
        compact: compact,
      );
}

