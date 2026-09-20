import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';

/// MoreActions 风格底部操作菜单（长按弹层）
///
/// 对齐原 React 版 BottomSheet 操作弹层形态：大圆角 20 顶部 + 标题行
/// （16/w600 padding16）+ 全宽 h48 ListTile（图标 22 + 文案 15），
/// 底部预留手势条兜底。destructive 项由调用方传入红色即可。
class MoreActionItem {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const MoreActionItem({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });
}

/// 弹出操作菜单；选项点击后自动关闭再回调 [MoreActionItem.onTap]
Future<void> showMoreActionsSheet(
  BuildContext context, {
  required String title,
  required List<MoreActionItem> actions,
}) {
  final colors = AppColors.ofContext(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space16,
              AppDimens.space16,
              AppDimens.space4,
            ),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.titleText,
              ),
            ),
          ),
          for (final action in actions)
            InkWell(
              onTap: () {
                Navigator.of(sheetContext).pop();
                action.onTap();
              },
              child: SizedBox(
                height: AppDimens.touchTarget,
                child: Row(
                  children: [
                    const SizedBox(width: AppDimens.space16),
                    Icon(
                      action.icon,
                      size: AppDimens.iconSizeMd,
                      color: action.color ?? colors.secondaryText,
                    ),
                    const SizedBox(width: AppDimens.space12),
                    Expanded(
                      child: Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 15,
                          color: action.color ?? colors.bodyText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SizedBox(height: AppDimens.gestureInsetFallback / 2),
        ],
      ),
    ),
  );
}

/// 圆角形状常量复用：底部抽屉顶部圆角统一 20（AppShapes.large 的顶边版本）
const RoundedRectangleBorder bottomSheetTopShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
);

/// 底部抽屉统一入场动画（`showModalBottomSheet` 的 `sheetAnimationStyle`）：
/// 入场 250ms 滑入、退场 150ms 更快收起（对齐微软 To-Do 的轻快手感）。
/// 选择类 / 操作菜单 / 表单三类抽屉同口径，避免逐处手调时长。
const AnimationStyle bottomSheetMotion = AnimationStyle(
  duration: AppMotion.normal,
  reverseDuration: AppMotion.fast,
  curve: AppMotion.sheetEnter,
);

