import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/orbit_accents.dart';

/// 筛选标签（原语层：flutter_miuix squircle 表面承载）
///
/// **2026-10-31 新增**：仓库里「一行可选标签」（状态/优先级/解决状态/预设档）
/// 有两套手搓实现——`ChoiceChip`（Material 的 M3 胶囊，`test_data_page` /
/// `settings_screen` 用）与各页自绘的 `GestureDetector + Container`
/// （`sub_list_screen._filterChip` / `sync_conflicts_page._filterChip`）。
/// 视觉上圆角、内边距、选中底色的透明度各不相同。
///
/// 本原语把口径收成一套（与 `OrbitButton.outline` 同源的 squircle 描边语言）：
/// - 选中：强调色 16% 底 + 强调色 1px 描边 + 强调色字；
/// - 未选：透明底 + `divider` 描边 + 正文色字；
/// - 可选色点（[dotColor]，项目/优先级色即语义的场景）；
/// - 禁用态（[onTap] 为 null）整体降透明度。
///
/// 触控：内边距 `space12 / space8`，最小高度 [AppDimens.touchTarget] 的一半以上
/// （标签行不是主操作，36 足够；整行热区由外层 `Wrap` 的 spacing 保证不误触）。
class OrbitFilterChip extends StatelessWidget {
  const OrbitFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dotColor,
    this.compact = false,
  });

  final String label;
  final bool selected;

  /// null = 禁用（Material `ChoiceChip.onSelected: null` 同语义）
  final VoidCallback? onTap;

  /// 可选色点（12×12 圆点，项目/优先级语义色）
  final Color? dotColor;

  /// 紧凑档（垂直 6 内边距，用于冲突页这类密集筛选行）
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final enabled = onTap != null;
    final accent = OrbitAccents.themeAccent;
    final chip = MiuixSurface(
      cornerRadius: AppShapes.radiusSmall,
      color: selected
          ? accent.withValues(alpha: 0.16)
          : Colors.transparent,
      border: Border.all(
        color: selected ? accent : colors.divider,
      ),
      onPressed: enabled ? onTap : null,
      enabled: enabled,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppDimens.space12,
          vertical: compact ? AppDimens.space6 : AppDimens.space8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: AppDimens.colorDotSize - 4,
                height: AppDimens.colorDotSize - 4,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppDimens.space6),
            ],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: selected ? accent : colors.bodyText,
              ),
            ),
          ],
        ),
      ),
    );
    if (!enabled) {
      return Opacity(opacity: 0.45, child: chip);
    }
    return chip;
  }
}
