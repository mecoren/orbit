/// 底部弹层族（设计系统 v3：shadcn `SheetConfiguration` 承载浮层机制�?
///
/// 三个共享弹层（确�?/ 单�?/ 更多操作）的**公共 API 与旧实现逐字一�?*�?
/// 调用点合�?70+ 处（`showConfirmBottomSheet` 25、`showSelectBottomSheet` 31�?
/// `showMoreActionsSheet` 3），保留原名与原参数以免制造无�?diff�?
///
/// 变化点只在内部：浮层�?shadcn �?overlay 体系承载（`showOverlay` +
/// `SheetConfiguration`），内容�?shadcn 原语（`Button`）与设计 token 构成�?
/// 不再�?Material �?`showModalBottomSheet`�?
///
/// �?`AlertDialog` 的分工不变：确认类一律走底部抽屉（拇指可达）�?
/// `AlertDialog` 只保留需要文本输入的场景�?
library;

import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';

/// 底部抽屉顶圆角描边形�?
///
/// 保留给仍�?Material `showModalBottomSheet` 弹出的页面级弹层
/// （表�?重复规则/详情内的二级面板）——这些容器不属于共享弹层族，
/// 但形状与动效口径要与此处统一，故常量的唯一来源仍是本文件�?
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
  //
  // 关闭一律从**弹层内容内部**发起（`closeOverlay(sheetContext, …)`）：`showOverlay`
  // 返回的 `DrawerOverlayCompleter` 没有覆写 `closeWithResult`，会落到基类实现
  // `async => remove()`——值被静默丢弃、弹层以 null 关闭（shadcn_flutter 0.0.53
  // 行为，实测「点确认拿不到 true」）；`closeOverlay` 走内容侧注入的 completer
  // 适配器（`closeDrawer(ctx, value)`），结果才能带到 `completer.future`。
  late final sh.OverlayCompleter<bool?> completer;
  completer = sh.showOverlay<bool>(
    context,
    sh.SheetConfiguration<bool>(
      builder: (sheetContext) => _ConfirmSheet(
        title: title,
        message: message,
        content: content,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
        onCancel: () => sh.closeOverlay(sheetContext, false),
        onConfirm: () => sh.closeOverlay(sheetContext, true),
      ),
    ),
  );
  return await completer.future ?? false;
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
  late final sh.OverlayCompleter<void> completer;
  completer = sh.showOverlay<void>(
    context,
    sh.SheetConfiguration<void>(
      builder: (sheetContext) => _SelectSheet<T>(
        title: title,
        items: items,
        current: current,
        onPick: (value) {
          sh.closeOverlay(sheetContext);
          onSelect(value);
        },
      ),
    ),
  );
  await completer.future;
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
  late final sh.OverlayCompleter<void> completer;
  completer = sh.showOverlay<void>(
    context,
    sh.SheetConfiguration<void>(
      builder: (sheetContext) => _ActionsSheet(
        title: title,
        actions: actions,
        onPick: (action) {
          sh.closeOverlay(sheetContext);
          action.onTap();
        },
      ),
    ),
  );
  await completer.future;
}

/// 弹层通用外壳：顶部拖拽手�?+ 圆角�?+ 弹层表面�?+ 向上投影
class _SheetShell extends StatelessWidget {
  const _SheetShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colors.popup,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppShapes.radiusXl),
          ),
        ),
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
