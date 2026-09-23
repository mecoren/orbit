import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import 'orbit_sheet_scaffold.dart';
import 'orbit_sheets.dart';

/// 自定义取色抽屉（清单颜色行的「自定义」入口）
///
/// 取色本体由 shadcn `ColorPicker` 承载（色域 + 滑杆 + HEX 输入三档模式），
/// 外壳沿用底部抽屉族——形状/动效常量取 [bottomSheetTopShape] / [bottomSheetMotion]，
/// 按钮行走 [OrbitSheetActions]，与全项目弹层同口径。
///
/// 默认落在 **HEX 档**：`hex_color` 字段就是 `#RRGGBB` 文本，精确输入比拖滑杆
/// 更贴合「填一个色值」的意图；alpha 关掉（项目色只用 RGB，透明度交给主题层）。
/// 返回 `null` = 取消（点遮罩 / 下滑 / 取消钮）。
Future<Color?> showOrbitColorPickerSheet(
  BuildContext context, {
  required Color initial,
}) async {
  var picked = initial;
  final result = await showModalBottomSheet<Color>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => OrbitSheetScaffold(
        title: '自定义颜色',
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space16,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            sh.ColorPicker(
              value: sh.ColorDerivative.fromColor(picked),
              onChanged: (value) =>
                  setSheetState(() => picked = value.toColor()),
              initialMode: sh.ColorPickerMode.hex,
              showAlpha: false,
              // 历史色板依赖 RecentColorsScope（应用未挂该作用域），关掉
              showHistoryButton: false,
            ),
            const SizedBox(height: AppDimens.space8),
          ],
        ),
        actions: OrbitSheetActions(
          cancelLabel: '取消',
          onCancel: () => Navigator.of(sheetContext).pop(),
          confirmLabel: '确定',
          onConfirm: () => Navigator.of(sheetContext).pop(picked),
        ),
      ),
    ),
  );
  return result;
}
