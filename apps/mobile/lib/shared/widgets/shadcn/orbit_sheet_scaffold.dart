/// 底部抽屉统一骨架 + 底部按钮行（设计系统 v3，2026-09-22 收口）
///
/// **为什么收口**：底部抽屉此前各写一套「标题 + 内容 + 按钮行」，由此产生两类
/// 通病——
/// ① 按钮被放进滚动容器（内容一长，确认钮就滚出可视区，用户得先回滚才能提交）；
/// ② 标签在 `Expanded` 拉满宽的按钮里贴左（shadcn 按钮内标签盒子与按钮同宽，
///    默认 `TextAlign.start`），观感"字不在按钮中间"。
/// 本文件是两个通病的唯一口径：
/// - 顶部拖拽手柄（40×4 圆角条，像素与既有各抽屉一致）
/// - 标题：[title] 走标准文本标题，特殊标题行（可点/带副标题/带动作）走 [header]
/// - 内容区：默认包 `SingleChildScrollView`（[contentScrollable]），整屉高度上限
///   [maxHeightFactor]（短内容自适应，长内容在区内滚动）
/// - 底部按钮行（[actions]，通常传 [OrbitSheetActions]）：**固定在抽屉底部**，
///   不随内容滚动
/// - 键盘避让：底部内边距跟随 `viewInsets`
///
/// 承载（`showModalBottomSheet` + `bottomSheetTopShape` + `bottomSheetMotion`）
/// 仍由调用方提供——形状/动效的唯一来源是 `orbit_sheets.dart`。
library;

import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 抽屉骨架：[title]/[header] + 可滚 [content] + 固定 [actions] 尾栏
class OrbitSheetScaffold extends StatelessWidget {
  const OrbitSheetScaffold({
    super.key,
    required this.content,
    this.title,
    this.header,
    this.actions,
    this.maxHeightFactor = 0.85,
    this.contentScrollable = true,
    this.showHandle = true,
    this.contentPadding,
  });

  /// 抽屉内容；[contentScrollable] 为 true 时外包 `SingleChildScrollView`
  final Widget content;

  /// 标准文本标题（16/w600）；与 [header] 二选一，[header] 优先
  final String? title;

  /// 自定义标题区（如"标题可点切换视图 + 副标题 + 清除"这类行）
  final Widget? header;

  /// 底部固定按钮行；null = 无尾栏（即点即关的选择型抽屉）
  final Widget? actions;

  /// 整屉高度上限（屏高比例）。短内容自适应，长内容在内容区滚动
  final double maxHeightFactor;

  /// 内容是否自动包滚动容器（列表类自管滚动的传 false）
  final bool contentScrollable;

  /// 是否显示顶部拖拽手柄
  final bool showHandle;

  /// 内容区自定义内边距（默认由内容自管）
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final headerWidget = header ?? (title == null ? null : _SheetTitle(title!));

    // 键盘避让：底部 padding 跟随 viewInsets（输入型抽屉必有）
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * maxHeightFactor,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showHandle) const _SheetHandle(),
              ?headerWidget,
              Flexible(
                child: contentScrollable
                    ? SingleChildScrollView(
                        padding: contentPadding,
                        child: content,
                      )
                    : Padding(
                        padding: contentPadding ?? EdgeInsets.zero,
                        child: content,
                      ),
              ),
              // 尾栏固定在底部：与内容区之间用 1px 分隔线划界（不随内容滚动）
              if (actions != null) ...[
                Divider(height: 1, color: colors.divider),
                actions!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 抽屉标准文本标题（16/w600）
class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        AppDimens.space16,
        AppDimens.space16,
        AppDimens.space8,
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
    );
  }
}

/// 抽屉顶部拖拽手柄（视觉提示；下滑关闭手势由承载方提供）
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(top: AppDimens.space8),
        decoration: BoxDecoration(
          color: colors.deactivatedText.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 抽屉底部按钮行（**固定**在抽屉底部，标签一律居中）
///
/// - 双按钮：[cancelLabel] + [confirmLabel]，各占一半宽（取消在左、确认在右）
/// - 单按钮：[cancelLabel] 传 null（主行动独占整行）
/// - [confirmChild] 覆盖确认钮内容（如 busy 态 spinner）
/// - 标签居中原因：按钮被 `Expanded` 拉满宽后，shadcn 按钮内标签盒子与按钮同宽，
///   默认 `TextAlign.start` 会把字形顶到左边距（2026-09-22 统一修复）
class OrbitSheetActions extends StatelessWidget {
  const OrbitSheetActions({
    super.key,
    required this.confirmLabel,
    required this.onConfirm,
    this.cancelLabel,
    this.onCancel,
    this.destructive = false,
    this.confirmChild,
  });

  final String confirmLabel;
  final VoidCallback? onConfirm;
  final String? cancelLabel;
  final VoidCallback? onCancel;
  final bool destructive;
  final Widget? confirmChild;

  @override
  Widget build(BuildContext context) {
    final label = confirmChild ??
        Text(confirmLabel, textAlign: TextAlign.center);

    return Padding(
      padding: const EdgeInsets.all(AppDimens.space12),
      child: Row(
        children: [
          if (cancelLabel != null) ...[
            Expanded(
              child: sh.Button.outline(
                onPressed: onCancel,
                child: Text(cancelLabel!, textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: AppDimens.space12),
          ],
          Expanded(
            child: destructive
                ? sh.Button.destructive(
                    onPressed: onConfirm,
                    child: label,
                  )
                : sh.Button.primary(
                    onPressed: onConfirm,
                    child: label,
                  ),
          ),
        ],
      ),
    );
  }
}
