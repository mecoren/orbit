import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import 'more_actions_sheet.dart';

/// 底部选择弹层数据项（12×12 色点 + 文案）
class SelectItem<T> {
  final T value;
  final String label;
  final Color? colorDot;

  const SelectItem({required this.value, required this.label, this.colorDot});
}

/// 详情/表单底部单选弹层（docs/05 §4.3 基本信息编辑器形态）
///
/// 头部标题 16/w600 padding16；行 = 12×12 圆点 + 15px 文案，
/// 当前值尾随 check_rounded（todoAccent）；点选即回调并关闭。
Future<void> showSelectBottomSheet<T>(
  BuildContext context, {
  required String title,
  required List<SelectItem<T>> items,
  T? current,
  required ValueChanged<T> onSelect,
}) {
  final colors = AppColors.ofContext(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.55,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppDimens.space16),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final item in items)
                    InkWell(
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onSelect(item.value);
                      },
                      child: SizedBox(
                        height: AppDimens.touchTarget,
                        child: Row(
                          children: [
                            const SizedBox(width: AppDimens.space16),
                            if (item.colorDot != null) ...[
                              Container(
                                width: AppDimens.colorDotSize,
                                height: AppDimens.colorDotSize,
                                decoration: BoxDecoration(
                                  color: item.colorDot,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: AppDimens.space12),
                            ] else
                              const SizedBox(width: AppDimens.space4),
                            Expanded(
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: colors.bodyText,
                                ),
                              ),
                            ),
                            if (item.value == current)
                              Icon(
                                Icons.check_rounded,
                                size: AppDimens.iconSizeMd,
                                color: colors.accent,
                              ),
                            const SizedBox(width: AppDimens.space16),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: AppDimens.gestureInsetFallback / 2),
          ],
        ),
      ),
    ),
  );
}
