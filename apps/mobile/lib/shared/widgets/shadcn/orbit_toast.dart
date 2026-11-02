import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_elevation.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';
import 'orbit_button.dart';

/// 轻提示（flutter_miuix `MiuixSnackbar` 承载，四变体语义不变）
///
/// **2026-11-01 换承载**：shadcn `showToast`（挂 `ShadcnLayer` 的 ToastLayer）
/// 换成 miuix 全局 Snackbar 队列——单一宿主 [MiuixSnackbarHostState] 由根部
/// [OrbitToastHost] 挂载（`app.dart` 与测试壳同构），获得入场/退场动画与
/// **横滑关闭**；卡面从 shadcn Card 换成 HyperOS squircle + 高斯毛玻璃
/// （口径对齐 `MiuixSnackbar.blurSigma` 的玻璃路径：squircle 裁剪 +
/// `BackdropFilter` + 半透明表面 + 1px 描边）。
///
/// **公共 API 与旧 `WaitToast` 逐字一致**：仓库内全部调用点零改动——类名、
/// 方法签名、四变体枚举、停留时长常量全部保留；仅实现层从「shadcn ToastLayer」
/// 换成「miuix SnackbarHost 队列」。
///
/// 单条策略不变：重复触发先撤旧条目再插新条目（避免叠影）。变体色/图标/副文
/// 案无法经 `MiuixSnackbarVisuals` 传递（miuix 队列只认 message/actionLabel），
/// 故按 `MiuixSnackbarData` **身份**挂一张 payload 表：退场动画期间旧卡仍
/// 渲染自己的变体，不串色。
///
/// 停留口径（与旧实现一致）：
/// - 无交互的 → [defaultDwell] 自动收（miuix 宿主条目自起 Timer）；
/// - 带 [onTap]（提醒跳详情）或 `actionLabel`（撤销类）→ 默认**不自动收**
///   （`indefinite`，不起 Timer），由用户处置；撤销类调用点显式传
///   `autoDismissAfter: undoDwell`。旧实现的 [holdForever] 常量保留
///   （测试收尾口径引用它，新承载用 indefinite 表达常驻、无真实 Timer）。
enum WaitToastVariant { info, success, warning, destructive }

abstract final class WaitToast {
  /// 默认停留时长（纯提示，无交互的）
  static const Duration defaultDwell = Duration(milliseconds: 2600);

  /// 撤销类浮层停留时长＝撤销窗口（trash 延迟提交 5s、undo_stack 窗口同口径）
  static const Duration undoDwell = Duration(seconds: 5);

  /// 旧承载（shadcn `showToast` 的 `showDuration` 非空）表达「不自动收」的
  /// 替代值；新承载用 `indefinite`（无 Timer）表达常驻，此常量仅为既有调用
  /// 与测试收尾口径保留。
  static const Duration holdForever = Duration(days: 365);

  /// 当前宿主状态（单条策略：任何时刻至多一条可见）
  ///
  /// 由根部 [OrbitToastHost] 在挂载时换新（[_bindHost]）：生产壳整棵树只
  /// 挂载一次，等价于全局单例；测试壳每个用例都会重新挂载，借此隔离上一
  /// 用例残留的条目——miuix 队列的条目只能靠退场动画出队，用例结束时的
  /// 在途条目会留在静态队列里，下一用例挂载后会被重新渲染成卡片（遮挡
  /// 底部按钮的点击、污染 find 断言），故必须按挂载实例隔离。
  static MiuixSnackbarHostState _host = MiuixSnackbarHostState();

  /// 活动条目的扩展视觉（变体色/副文案/整卡点击）——miuix 队列只认
  /// message/actionLabel，其余按 data 身份挂表，条目完成时移除
  static final Map<MiuixSnackbarData, _ToastPayload> _payloads = {};

  /// 宿主挂载时换一份全新队列（见 [_host] 注释）
  static MiuixSnackbarHostState _bindHost() {
    _host = MiuixSnackbarHostState();
    _payloads.clear();
    return _host;
  }

  /// 展示一条 toast；[description] 可选副文案；[onTap] 可选整卡点击回调
  ///（提醒 toast 用于跳任务详情；不传时点击仅收起）；
  /// [actionLabel]/[onAction] 可选右侧动作按钮（撤销删除等场景）。
  static void global(
    String title, {
    WaitToastVariant variant = WaitToastVariant.info,
    String? description,
    VoidCallback? onTap,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? autoDismissAfter,
  }) {
    // fire-and-forget：global 是同步入口（服务层无 context 直接调），
    // 撤旧→插新的微任务链在下一帧渲染前完成，不阻塞调用方
    unawaited(_present(
      title,
      variant: variant,
      description: description,
      onTap: onTap,
      actionLabel: actionLabel,
      onAction: onAction,
      autoDismissAfter: autoDismissAfter,
    ));
  }

  static Future<void> _present(
    String title, {
    required WaitToastVariant variant,
    String? description,
    VoidCallback? onTap,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? autoDismissAfter,
  }) async {
    // 单条策略：撤旧插新，避免叠影（旧条目退场动画期间保留自己的 payload）
    final active = await _host.newestSnackbarData();
    if (active != null) unawaited(active.dismiss());

    final auto = autoDismissAfter ??
        (onTap == null && onAction == null ? defaultDwell : null);
    final payload = _ToastPayload(
      variant: variant,
      description: description,
      onTap: onTap,
    );

    final resultFuture = _host.showSnackbar(
      title,
      actionLabel: actionLabel,
      // null = indefinite 常驻（无 Timer），等用户处置
      duration: auto == null
          ? MiuixSnackbarDuration.indefinite
          : MiuixSnackbarDuration.custom(auto.inMilliseconds),
    );

    // 数据句柄只能异步取（microtask，先于下一帧）：取到后登记 payload，
    // 卡面构建时按身份查表
    final data = await _host.newestSnackbarData();
    if (data != null) _payloads[data] = payload;

    final result = await resultFuture;
    _payloads.remove(data);
    if (result == MiuixSnackbarResult.actionPerformed) {
      onAction?.call();
    }
  }

  /// 测试收尾：把仍可见的条目全部撤下（配合 `drainToastTimers` 的 pump 推进
  /// 让退场动画走完、条目真正出队——静态宿主跨用例存活，不清会把上一用例的
  /// toast 文案带进下一用例的 find 断言）。
  @visibleForTesting
  static Future<void> debugFlushForTest() async {
    while (true) {
      final data = await _host.newestSnackbarData();
      if (data == null) break;
      await data.dismiss();
    }
  }

  /// 四个语义快捷入口（warning 支持 onTap——提醒跳详情场景）
  static void info(String title) =>
      global(title, variant: WaitToastVariant.info);
  static void success(String title) =>
      global(title, variant: WaitToastVariant.success);

  /// [description] 为可选副文案（同 [global] 同名参数）：warning 是唯一开放的
  /// 快捷入口，用于「部分成功」把明细（失败年份）与结论分行，避免标题过长
  static void warning(String title,
          {VoidCallback? onTap, String? description}) =>
      global(title,
          variant: WaitToastVariant.warning,
          onTap: onTap,
          description: description);
  static void destructive(String title) =>
      global(title, variant: WaitToastVariant.destructive);

  /// 条目卡面（[MiuixSnackbarHost.builder] 的回调）：按 data 身份查 payload
  static Widget _buildCard(BuildContext context, MiuixSnackbarData data) {
    final payload = _payloads[data];
    final actionLabel = data.visuals.actionLabel;
    return _ToastCard(
      title: data.visuals.message,
      description: payload?.description,
      variant: payload?.variant ?? WaitToastVariant.info,
      actionLabel: actionLabel,
      onAction: actionLabel == null
          ? null
          : () => unawaited(data.performAction()),
      // 旧口径：不传 onTap 时点击仅收起
      onTap: () {
        unawaited(data.dismiss());
        payload?.onTap?.call();
      },
    );
  }
}

/// 全局 toast 宿主：挂载在根部（路由内容之上），消费 [WaitToast] 的队列
///
/// 必须与消费方同处于 `OrbitMiuixTheme` 子树（卡面/按钮取 miuix 主题与
/// `core/theme` token）。空队列时整层 hit-test 透明（Align/Column 无不透明
/// 命中层），不挡页面手势；条目卡自身吃点击与横滑。
class OrbitToastHost extends StatefulWidget {
  const OrbitToastHost({super.key});

  @override
  State<OrbitToastHost> createState() => _OrbitToastHostState();
}

class _OrbitToastHostState extends State<OrbitToastHost> {
  late final MiuixSnackbarHostState _state;

  @override
  void initState() {
    super.initState();
    // 挂载即换新队列：生产壳只挂载一次（等价全局单例），测试壳每用例
    // 重新挂载（隔离上一个用例的在途条目，见 WaitToast._host 注释）
    _state = WaitToast._bindHost();
  }

  @override
  Widget build(BuildContext context) {
    return MiuixSnackbarHost(
      state: _state,
      canSwipeToDismiss: true,
      builder: WaitToast._buildCard,
    );
  }
}

/// 单条 toast 的扩展视觉（miuix 队列载荷装不下的部分，按 data 身份挂表）
class _ToastPayload {
  const _ToastPayload({
    required this.variant,
    this.description,
    this.onTap,
  });

  final WaitToastVariant variant;
  final String? description;
  final VoidCallback? onTap;
}

/// 变体 → 左竖条颜色（AppColors 状态色板）
Color _variantColor(WaitToastVariant variant, AppColorSet colors) =>
    switch (variant) {
      WaitToastVariant.info => colors.accent,
      WaitToastVariant.success => colors.success,
      WaitToastVariant.warning => colors.warning,
      WaitToastVariant.destructive => colors.destructive,
    };

/// 变体 → 前置图标（线性图标集，语义与状态色一致）
IconData _variantIcon(WaitToastVariant variant) => switch (variant) {
      WaitToastVariant.info => OrbitIcons.info,
      WaitToastVariant.success => OrbitIcons.success,
      WaitToastVariant.warning => OrbitIcons.warning,
      WaitToastVariant.destructive => OrbitIcons.error,
    };

/// toast 卡面：HyperOS squircle 毛玻璃底 + 左竖条 + 图标 + 标题/副文案 +
/// 可选动作按钮
///
/// 玻璃路径与 `MiuixSnackbar` 的 `blurSigma > 0` 分支同构：外层 `DecoratedBox`
/// 画阴影（裁剪之外）→ squircle `ClipPath` + `BackdropFilter` 高斯模糊 →
/// 半透明表面 + 1px 描边 → 内容。无 backdrop 内容可透时退化为半透明实色，
/// 观感不劣化。
class _ToastCard extends StatelessWidget {
  const _ToastCard({
    required this.title,
    required this.variant,
    required this.onTap,
    this.description,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final WaitToastVariant variant;
  final String? description;
  final VoidCallback? onAction;
  final VoidCallback onTap;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final color = _variantColor(variant, colors);
    final radius = AppShapes.radiusLarge;
    final shape = MiuixSquircleBorder(cornerRadius: radius);

    Widget content = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
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
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppDimens.cardPadding),
                  child: Row(
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
                        OrbitButton.text(
                          onPressed: onAction,
                          compact: true,
                          child: Text(actionLabel!),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // HyperOS 毛玻璃：squircle 裁剪内做背景模糊，表面降半透明透出磨砂内容
    content = ClipPath(
      clipper: _SquircleClipper(shape),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: colors.surfaceElevated.withValues(alpha: 0.82),
            shape: MiuixSquircleBorder(
              cornerRadius: radius,
              side: BorderSide(color: colors.outline, width: 1),
            ),
          ),
          child: content,
        ),
      ),
    );

    // 阴影画在裁剪之外（否则被 ClipPath 裁掉），口径同 MiuixSnackbar
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.pageInline),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: const Color(0x00000000),
            shape: shape,
            shadows: AppElevation.ofContext(context, level: 2),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// 用 [ShapeBorder.getOuterPath] 包装的 squircle 裁剪器（口径同 MiuixSnackbar）
class _SquircleClipper extends CustomClipper<ui.Path> {
  const _SquircleClipper(this.shape);

  final ShapeBorder shape;

  @override
  ui.Path getClip(ui.Size size) =>
      shape.getOuterPath(Offset.zero & size);

  @override
  bool shouldReclip(_SquircleClipper old) => shape != old.shape;
}
