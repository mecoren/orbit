import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/routing/router_keys.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_elevation.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';

/// 轻提示（设计系统 v3：shadcn toast 承载，四变体语义不变�?
///
/// **公共 API 与旧 `WaitToast` 逐字一�?*：`WaitToast` 在仓库内�?155 处调�?
/// （lib 18 个文件），改名只会制造噪�?diff、不带来任何结构收益，故保留原类名与
/// 原方法签名，仅把实现从「自�?OverlayEntry」换�?shadcn �?`showToast`—�?
/// 获得 shadcn 的入�?退场动画与堆叠管理，视觉（左竖�?+ 圆角卡）与服务语义不变�?
///
/// 单条策略不变：重复触发先撤旧条目再插新条目（避免叠影）�?
///
/// 停留口径（与旧实现一致）�?
/// - 无交�?�?[defaultDwell] 自动收；
/// - �?[onTap]（提醒跳详情）或 `actionLabel`（撤销类）�?默认**不自动收**�?
///   由用户处置；撤销类调用点显式�?`autoDismissAfter: undoDwell`�?
///   shadcn �?`showDuration` 非空，故「不自动收」用 [_holdForever] 表达�?
enum WaitToastVariant { info, success, warning, destructive }

abstract final class WaitToast {
  /// 默认停留时长（纯提示，无交互�?
  static const Duration defaultDwell = Duration(milliseconds: 2600);

  /// 撤销类浮层停留时长＝撤销窗口（trash 延迟提交 5s、undo_stack 窗口同口径）
  static const Duration undoDwell = Duration(seconds: 5);

  /// 「不自动收起」的替代值：shadcn `showDuration` 不接�?null�?
  /// 用一个远超会话时长的常量表达常驻，由用户点击或下一�?toast 撤下�?
  static const Duration _holdForever = Duration(days: 365);

  static sh.ToastOverlay? _active;

  /// 展示一�?toast；[description] 可选副文案；[onTap] 可选整卡点击回�?
  ///（提�?toast 用于跳任务详情；不传时点击仅收起）；
  /// [actionLabel]/[onAction] 可选右侧动作按钮（撤销删除等场景）�?
  static void global(
    String title, {
    WaitToastVariant variant = WaitToastVariant.info,
    String? description,
    VoidCallback? onTap,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? autoDismissAfter,
  }) {
    // shadcn �?toast 挂在 ShadcnLayer �?ToastLayer 上，锚点取全局 Navigator
    // context（位�?ShadcnLayer 之下，能向上找到 ToastLayer�?
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;

    // 单条策略：撤旧插新，避免叠影
    _active?.close();
    _active = null;

    final auto = autoDismissAfter ??
        (onTap == null && onAction == null ? defaultDwell : null);

    _active = sh.showToast(
      context: context,
      location: sh.ToastLocation.bottomCenter,
      showDuration: auto ?? _holdForever,
      builder: (context, overlay) => _ToastCard(
        title: title,
        description: description,
        variant: variant,
        onTap: onTap == null
            ? null
            : () {
                overlay.close();
                onTap();
              },
        actionLabel: actionLabel,
        onAction: onAction == null
            ? null
            : () {
                overlay.close();
                onAction();
              },
        onDismiss: overlay.close,
      ),
    );
  }

  /// 四个语义快捷入口（warning 支持 onTap——提醒跳详情场景�?
  static void info(String title) =>
      global(title, variant: WaitToastVariant.info);
  static void success(String title) =>
      global(title, variant: WaitToastVariant.success);
  static void warning(String title, {VoidCallback? onTap}) =>
      global(title, variant: WaitToastVariant.warning, onTap: onTap);
  static void destructive(String title) =>
      global(title, variant: WaitToastVariant.destructive);
}

/// 变体 �?左竖条颜色（AppColors 状态色板）
Color _variantColor(WaitToastVariant variant, AppColorSet colors) =>
    switch (variant) {
      WaitToastVariant.info => colors.accent,
      WaitToastVariant.success => colors.success,
      WaitToastVariant.warning => colors.warning,
      WaitToastVariant.destructive => colors.destructive,
    };

/// 变体 �?前置图标（线性图标集，语义与状态色一致）
IconData _variantIcon(WaitToastVariant variant) => switch (variant) {
      WaitToastVariant.info => OrbitIcons.info,
      WaitToastVariant.success => OrbitIcons.success,
      WaitToastVariant.warning => OrbitIcons.warning,
      WaitToastVariant.destructive => OrbitIcons.error,
    };

/// toast 卡面：左竖条 + 图标 + 标题/副文�?+ 可选动作按�?
class _ToastCard extends StatelessWidget {
  const _ToastCard({
    required this.title,
    required this.variant,
    required this.onDismiss,
    this.description,
    this.onTap,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final WaitToastVariant variant;
  final String? description;
  final VoidCallback? onTap;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final color = _variantColor(variant, colors);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.pageInline),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: sh.Card(
          padding: EdgeInsets.zero,
          filled: true,
          fillColor: colors.surfaceElevated,
          borderColor: colors.outline,
          borderWidth: 1,
          borderRadius: AppShapes.large,
          boxShadow: AppElevation.ofContext(context, level: 2),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap ?? onDismiss,
              borderRadius: AppShapes.large,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 左竖条：变体语义色（旧实现同款识别手段）
                    Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(AppShapes.radiusLarge),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppDimens.cardPadding),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_variantIcon(variant),
                              size: AppDimens.iconSizeSm, color: color),
                          const SizedBox(width: AppDimens.space12),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500,
                                    color: colors.titleText,
                                  ),
                                ),
                                if (description != null) ...[
                                  const SizedBox(height: AppDimens.space4),
                                  Text(
                                    description!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colors.secondaryText,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (actionLabel != null && onAction != null) ...[
                            const SizedBox(width: AppDimens.space12),
                            sh.Button.ghost(
                              onPressed: onAction,
                              child: Text(actionLabel!),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
