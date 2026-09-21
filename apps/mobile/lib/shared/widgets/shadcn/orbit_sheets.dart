/// 底部弹层族（设计系统 v3：承载与形状统一走 Material）
///
/// 三个共享弹层（确认 / 单选 / 更多操作）的**公共 API 与旧实现逐字一致**：
/// 调用点合计 70+ 处（`showConfirmBottomSheet` 25、`showSelectBottomSheet` 31、
/// `showMoreActionsSheet` 3），保留原名与原参数以免制造无谓 diff。
///
/// **为什么承载回到 Material `showModalBottomSheet`**（2026-09-21 修复）：
/// shadcn 的 `SheetConfiguration` 打开的 sheet 容器（`SheetRawContainer`）把背景
/// 画成 `colorScheme.background` 的不透明**矩形**（`getBorderRadius()` 硬编码
/// `BorderRadius.zero`），而 `SheetConfiguration` 没有背景/圆角入口——于是
/// `_SheetShell` 自绘的顶部圆角被这层直角背景盖住，观感变成"两边有角"。
/// 页面级抽屉（表单 / 重复规则 / 色板 / 视图切换）本就走 Material
/// `showModalBottomSheet` 且圆角正常，故共享弹层族与其统一到同一承载 +
/// 同一形状常量 [bottomSheetTopShape]（形状与动效的唯一来源仍是本文件）。
///
/// 与 `AlertDialog` 的分工不变：确认类一律走底部抽屉（拇指可达）；
/// `AlertDialog` 只保留需要文本输入的场景。
///
/// **注意**：调用方必须持有 `Navigator` 祖先（页面 / Material 抽屉内均可）；
/// shadcn 浮层（挂在 Navigator 之外的根 `DrawerOverlay`）内部不可调用本族——
/// 那里没有 `Navigator`，Material 路由式弹层唤不起来。
library;

import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';

/// 底部抽屉顶圆角描边形状（全项目底部抽屉的唯一形状来源）
const RoundedRectangleBorder bottomSheetTopShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.vertical(
    top: Radius.circular(AppShapes.radiusLarge),
  ),
);

/// 底部抽屉统一动效（时�?曲线取自 AppMotion，视图内不写裸值）
const AnimationStyle bottomSheetMotion = AnimationStyle(
  duration: AppMotion.normal,
  reverseDuration: AppMotion.fast,
  curve: AppMotion.sheetEnter,
);

/// 确认抽屉：返�?`true` = 用户点了确认按钮；点遮罩/下滑关闭/取消都是 `false`
/// （调用方直接 `if (!await showConfirmBottomSheet(...)) return;` 即可，不必判 null）�?
Future<bool> showConfirmBottomSheet(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = '确定',
  String? cancelLabel = '取消',
  bool destructive = false,
}) async {
  // 取值语义：确认 -> true；取消 / 下滑关闭 / 点遮罩 -> false（结果缺失按 false 处理）
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _ConfirmSheet(
      title: title,
      message: message,
      content: content,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
      onCancel: () => Navigator.of(sheetContext).pop(false),
      onConfirm: () => Navigator.of(sheetContext).pop(true),
    ),
  );
  return result ?? false;
}

/// 单选弹层数据项�?2×12 色点 + 文案�?
class SelectItem<T> {
  final T value;
  final String label;
  final Color? colorDot;

  const SelectItem({required this.value, required this.label, this.colorDot});
}

/// 详情/表单底部单选弹层：�?= 可选色�?+ 文案，当前值尾随对勾；
/// 点选即回调并关闭�?
Future<void> showSelectBottomSheet<T>(
  BuildContext context, {
  required String title,
  required List<SelectItem<T>> items,
  T? current,
  required ValueChanged<T> onSelect,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _SelectSheet<T>(
      title: title,
      items: items,
      current: current,
      onPick: (value) {
        Navigator.of(sheetContext).pop();
        onSelect(value);
      },
    ),
  );
}

/// 更多操作菜单项（图标 + 文案；destructive 项由调用方传红色 [color]�?
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

/// 更多操作底部弹层；选项点击后自动关闭再回调
Future<void> showMoreActionsSheet(
  BuildContext context, {
  required String title,
  required List<MoreActionItem> actions,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => _ActionsSheet(
      title: title,
      actions: actions,
      onPick: (action) {
        Navigator.of(sheetContext).pop();
        action.onTap();
      },
    ),
  );
}

/// 弹层通用外壳：顶部拖拽手�?+ 圆角�?+ 弹层表面�?+ 向上投影
/// 表面色与顶部圆角由承载方（Material `showModalBottomSheet` 的
/// `backgroundColor` + [bottomSheetTopShape]）提供，保持形状单一来源；
/// 此处不再自绘——两层圆角半径不一致时会从 shape 圆角之外溢出白色小三角
class _SheetShell extends StatelessWidget {
  const _SheetShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        width: double.infinity,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 拖拽手柄（视觉提示；shadcn 弹层自带下滑关闭手势�?
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: AppDimens.space8),
                  decoration: BoxDecoration(
                    color: colors.deactivatedText.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹层标题行（16/w600 + 统一内边距）
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

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    required this.onCancel,
    required this.onConfirm,
    this.message,
    this.content,
  });

  final String title;
  final String? message;
  final Widget? content;
  final String confirmLabel;
  final String? cancelLabel;
  final bool destructive;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetTitle(title),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppDimens.space16,
                0,
                AppDimens.space16,
                AppDimens.space16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message != null)
                    Text(
                      message!,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: colors.secondaryText,
                      ),
                    ),
                  if (content != null) ...[
                    if (message != null) const SizedBox(height: AppDimens.space12),
                    content!,
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(AppDimens.space12),
            child: Row(
              children: [
                if (cancelLabel != null) ...[
                  Expanded(
                    child: sh.Button.outline(
                      onPressed: onCancel,
                      child: Text(cancelLabel!),
                    ),
                  ),
                  const SizedBox(width: AppDimens.space12),
                ],
                Expanded(
                  child: destructive
                      ? sh.Button.destructive(
                          onPressed: onConfirm,
                          child: Text(confirmLabel),
                        )
                      : sh.Button.primary(
                          onPressed: onConfirm,
                          child: Text(confirmLabel),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectSheet<T> extends StatelessWidget {
  const _SelectSheet({
    required this.title,
    required this.items,
    required this.onPick,
    this.current,
  });

  final String title;
  final List<SelectItem<T>> items;
  final T? current;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.55;
    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetTitle(title),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: AppDimens.space8),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final selected = item.value == current;
                  return InkWell(
                    onTap: () => onPick(item.value),
                    child: SizedBox(
                      height: AppDimens.touchTarget,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppDimens.space16,
                        ),
                        child: Row(
                          children: [
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
                            ],
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
                            if (selected)
                              Icon(
                                OrbitIcons.check,
                                size: AppDimens.iconSizeMd,
                                color: colors.accent,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: AppDimens.space8),
        ],
      ),
    );
  }
}

class _ActionsSheet extends StatelessWidget {
  const _ActionsSheet({
    required this.title,
    required this.actions,
    required this.onPick,
  });

  final String title;
  final List<MoreActionItem> actions;
  final ValueChanged<MoreActionItem> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetTitle(title),
          for (final action in actions)
            InkWell(
              onTap: () => onPick(action),
              child: SizedBox(
                height: AppDimens.touchTarget,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space16,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        action.icon,
                        size: AppDimens.iconSizeMd,
                        color: action.color ?? colors.iconText,
                      ),
                      const SizedBox(width: AppDimens.space12),
                      Expanded(
                        child: Text(
                          action.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
            ),
          const SizedBox(height: AppDimens.space8),
        ],
      ),
    );
  }
}
