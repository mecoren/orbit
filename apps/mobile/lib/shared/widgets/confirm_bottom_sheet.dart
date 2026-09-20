import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import 'more_actions_sheet.dart' show bottomSheetMotion, bottomSheetTopShape;

/// 底部确认抽屉（删除/清空/恢复/断开/关闭等确认类交互的统一形态）
///
/// 与 `AlertDialog` 的分工（AGENTS.md「确认类交互统一用底部抽屉」）：
/// 确认类一律走本抽屉——拇指天然可达、破坏性按钮有整行触控面积、
/// 下滑/点遮罩即取消（等同「取消」而非「确认」）；`AlertDialog` 只保留
/// 文本输入表单（新建项目、改密码等需要 TextField 的场景）。
///
/// 形态：顶部拖拽手柄 + 标题/说明（长文案整块可滚，上限 70% 屏高）+
/// 底部「取消 / 确认」按钮行；[destructive] 时确认钮取 `destructive` 红底。
///
/// 返回 `true` = 用户点了确认按钮；点遮罩/下滑关闭/取消 都是 `false`
/// （调用方直接 `if (!await showConfirmBottomSheet(...)) return;` 即可，
/// 不必再判 null）。
Future<bool> showConfirmBottomSheet(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = '确定',
  String? cancelLabel = '取消',
  bool destructive = false,
}) async {
  final colors = AppColors.ofContext(context);
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _ConfirmSheet(
      title: title,
      message: message,
      content: content,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
    ),
  );
  return confirmed ?? false;
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    this.message,
    this.content,
  });

  final String title;
  final String? message;
  final Widget? content;
  final String confirmLabel;
  final String? cancelLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.ofContext(context);
    final accent = destructive ? colors.destructive : colors.accent;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 拖拽手柄：暗示可下滑关闭（下滑 = 取消，不误触发确认）
            Padding(
              padding: const EdgeInsets.only(top: AppDimens.space8),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            // 标题/说明/自定义内容：长文案（如备份预览）滚动而非撑破面板
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.space20,
                  AppDimens.space16,
                  AppDimens.space20,
                  0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.titleText,
                      ),
                    ),
                    if (message != null) ...[
                      const SizedBox(height: AppDimens.space8),
                      Text(
                        message!,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: colors.secondaryText,
                        ),
                      ),
                    ],
                    if (content != null) ...[
                      const SizedBox(height: AppDimens.space12),
                      content!,
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppDimens.space20,
                AppDimens.space20,
                AppDimens.space20,
                AppDimens.space12,
              ),
              child: Row(
                children: [
                  if (cancelLabel != null) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colors.bodyText,
                          side: BorderSide(color: colors.divider),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(
                              vertical: AppDimens.space12),
                        ),
                        child: Text(cancelLabel!),
                      ),
                    ),
                    const SizedBox(width: AppDimens.space12),
                  ],
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(
                            vertical: AppDimens.space12),
                      ),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: AppDimens.gestureInsetFallback / 2),
          ],
        ),
      ),
    );
  }
}
