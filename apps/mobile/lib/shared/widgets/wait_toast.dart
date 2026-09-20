import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_elevation.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/routing/router_keys.dart';

/// 轻量浮层 Toast（Overlay 实现，左竖条四变体）
///
/// 对齐原 React 版 wait-toast 语义并按移动端任务书扩展为四变体：
/// info（accent）/ success / warning / destructive。
///
/// 使用 [WaitToast.global]（经全局 Navigator Overlay 插入），
/// 供任意屏面与事件流回调（reminderDue 等）调用，无需逐层传 context。
/// 同一时刻仅保留最新一条：重复触发先撤旧条目再插入新条目。
enum WaitToastVariant { info, success, warning, destructive }

class WaitToast {
  WaitToast._();

  static OverlayEntry? _active;
  static Timer? _dismissTimer;

  /// 默认停留时长（纯提示，无交互）
  static const Duration defaultDwell = Duration(milliseconds: 2600);

  /// 撤销类浮层停留时长＝撤销窗口（trash 延迟提交 5s、undo_stack 窗口同口径）。
  /// 到期即自动收起：撤销浮层不能长驻（会一直挡住内容，且窗口过后点了也无效）
  static const Duration undoDwell = Duration(seconds: 5);

  /// 展示一条 toast；[description] 可选副文案；[onTap] 可选整卡点击回调
  ///（提醒 toast 用于跳任务详情；不传时点击仅收起）；
  /// [actionLabel]/[onAction] 可选右侧动作按钮（撤销删除等场景）。
  ///
  /// 停留口径：无交互 → [defaultDwell] 自动收；带 onTap 的提醒条不收
  /// （等用户点）；带动作按钮默认不收（错误引导类需要用户处置），
  /// 撤销类调用点显式传 [autoDismissAfter] = [undoDwell] 到期自动收。
  static void global(
    String title, {
    WaitToastVariant variant = WaitToastVariant.info,
    String? description,
    VoidCallback? onTap,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? autoDismissAfter,
  }) {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;

    // 单条策略：撤旧插新，避免叠影
    _remove();

    final entry = OverlayEntry(
      builder: (_) => _ToastView(
        title: title,
        description: description,
        variant: variant,
        onTap: onTap,
        actionLabel: actionLabel,
        onAction: onAction,
        onDismiss: _remove,
      ),
    );
    _active = entry;
    overlay.insert(entry);

    // 自动收起（动画由 _ToastView 内部退出态承担）：无交互 → defaultDwell；
    // 带 onTap/action → 仅当调用点显式给了 autoDismissAfter 才计时
    final auto = autoDismissAfter ??
        (onTap == null && onAction == null ? defaultDwell : null);
    if (auto != null) {
      _dismissTimer = Timer(auto, _remove);
    }
  }

  /// 四个语义快捷入口（warning 支持 onTap——提醒跳详情场景）
  static void info(String title) =>
      global(title, variant: WaitToastVariant.info);
  static void success(String title) =>
      global(title, variant: WaitToastVariant.success);
  static void warning(String title, {VoidCallback? onTap}) =>
      global(title, variant: WaitToastVariant.warning, onTap: onTap);
  static void destructive(String title) =>
      global(title, variant: WaitToastVariant.destructive);

  static void _remove() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _active?.remove();
    _active = null;
  }
}

/// 变体 → 左竖条颜色（AppColors 状态色板）
Color _variantColor(WaitToastVariant variant, AppColorSet colors) =>
    switch (variant) {
      WaitToastVariant.info => colors.accent,
      WaitToastVariant.success => colors.success,
      WaitToastVariant.warning => colors.warning,
      WaitToastVariant.destructive => colors.destructive,
    };

class _ToastView extends StatefulWidget {
  const _ToastView({
    required this.title,
    required this.description,
    required this.variant,
    required this.onDismiss,
    this.onTap,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? description;
  final WaitToastVariant variant;
  final VoidCallback onDismiss;

  /// 整卡点击回调；null 时点击仅收起（原行为）
  final VoidCallback? onTap;

  /// 右侧动作按钮文案与回调（撤销等；两者须成对提供）
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: AppMotion.fast)..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _exit() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  /// 点击：有 onTap 先执行再退出（提醒 toast 跳详情）；
  /// 无 onTap 与原行为一致仅收起
  Future<void> _tap() async {
    final action = widget.onTap;
    await _exit();
    action?.call();
  }

  /// 动作按钮：先收条再执行回调（撤销删除后 toast 无须停留）
  Future<void> _runAction() async {
    final action = widget.onAction;
    await _exit();
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = View.of(context).platformDispatcher.platformBrightness;
    final colors = AppColors.of(brightness);
    final barColor = _variantColor(widget.variant, colors);

    return Positioned(
      top: MediaQuery.of(context).padding.top + AppDimens.space16,
      left: AppDimens.space16,
      right: AppDimens.space16,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.4),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _controller, curve: AppMotion.standard)),
        child: FadeTransition(
          opacity: _controller,
          child: GestureDetector(
            onTap: _tap,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.popup,
                  borderRadius: AppShapes.medium,
                  border: Border.all(color: colors.outline),
                  boxShadow: AppElevation.e2(brightness),
                ),
                // IntrinsicHeight：给 Row(crossAxisAlignment.stretch) 提供
                // 有界高度——Container 在 Overlay 的 Positioned 下无固有高度，
                // 裸 stretch 会把无界约束传给子级导致布局断言崩溃
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 左竖条（四变体色）
                      Container(width: 4, color: barColor),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.space12,
                            vertical: AppDimens.space12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color:
                                      widget.variant ==
                                              WaitToastVariant.destructive
                                          ? colors.destructive
                                          : colors.titleText,
                                ),
                              ),
                              if (widget.description != null) ...[
                                const SizedBox(height: AppDimens.space4),
                                Text(
                                  widget.description!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.secondaryText,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      // 右侧动作按钮（撤销等；点击收条并执行回调）
                      if (widget.actionLabel != null && widget.onAction != null)
                        Padding(
                          padding:
                              const EdgeInsets.only(right: AppDimens.space8),
                          child: TextButton(
                            onPressed: _runAction,
                            style: TextButton.styleFrom(
                              foregroundColor: colors.accent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppDimens.space8,
                              ),
                              minimumSize: const Size(0, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              widget.actionLabel!,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
