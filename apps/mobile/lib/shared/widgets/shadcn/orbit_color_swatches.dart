/// 离散色板原语（标签改色 / 新建编辑标签等输入型弹层共用）
///
/// 此前标签管理页两处色板各写一套几何（36/6/12 与 40/4/16），同一页面的
/// 两个弹层点起来大小不一。此处收为唯一口径：
/// - 色点视觉 36 = `touchTarget - space12`，外层 `space6` 补到 48 触控热区
/// - 色点纵横向间距 `space12`，与表单字段的纵向节奏同档
/// - 选中态 = 2px 描边 + 白色对勾，描边取语义色 `titleText`
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/icon_map.dart';
import '../../utils/hex_color.dart';

/// 从 [hexes] 里挑一个颜色；[selectedHex] 大小写不敏感
class OrbitColorSwatches extends StatelessWidget {
  const OrbitColorSwatches({
    super.key,
    required this.hexes,
    required this.selectedHex,
    required this.onSelected,
  });

  final List<String> hexes;
  final String selectedHex;
  final ValueChanged<String> onSelected;

  bool _isSelected(String hex) =>
      hex.toUpperCase() == selectedHex.toUpperCase();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Wrap(
      spacing: AppDimens.space12,
      runSpacing: AppDimens.space12,
      children: [
        for (final hex in hexes)
          GestureDetector(
            onTap: () => onSelected(hex),
            child: Padding(
              padding: const EdgeInsets.all(AppDimens.space6),
              child: Container(
                width: AppDimens.touchTarget - AppDimens.space12,
                height: AppDimens.touchTarget - AppDimens.space12,
                decoration: BoxDecoration(
                  color: hexToColor(hex),
                  shape: BoxShape.circle,
                  border: _isSelected(hex)
                      ? Border.all(color: colors.titleText, width: 2)
                      : null,
                ),
                child: _isSelected(hex)
                    ? const Icon(
                        OrbitIcons.check,
                        size: AppDimens.iconSizeSm,
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
