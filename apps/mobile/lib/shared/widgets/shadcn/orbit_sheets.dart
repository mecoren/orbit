/// 底部弹层族（设计系统 v3：承载与形状统一走 Material）
///
/// 本文件现在只剩**确认 / 更多操作**两个底部抽屉
/// （`showConfirmBottomSheet` 25 处、`showMoreActionsSheet` 3 处），
/// 公共 API 与旧实现逐字一致，保留原名与原参数以免制造无谓 diff。
///
/// **单选已迁出（2026-11-03）**：从一组值里挑一个的交互不再从底部升起抽屉，
/// 改为**复用页头 ⋮ 菜单的面板**（`MiuixGlassPopupItem` 行 + 玻璃卡面，
/// 贴触发行下沿弹出），实现见 `orbit_select_popup.dart`；`showSelectBottomSheet`
/// 保留为兼容名并直接转发，存量调用点零改动即统一。
///
/// **为什么承载回到 Material `showModalBottomSheet`**（2026-09-21 修复）：
/// shadcn 的 `SheetConfiguration` 打开的 sheet 容器（`SheetRawContainer`）把背景
/// 画成 `colorScheme.background` 的不透明**矩形**（`getBorderRadius()` 硬编码
/// `BorderRadius.zero`），而 `SheetConfiguration` 没有背景/圆角入口——于是
/// 自绘的顶部圆角被这层直角背景盖住，观感变成「两边有角」。
/// 页面级抽屉（表单 / 重复规则 / 色板 / 视图切换）本就走 Material
/// `showModalBottomSheet` 且圆角正常，故共享弹层族与其统一到同一承载 +
/// 同一形状常量 [bottomSheetTopShape]（形状与动效的唯一来源仍是本文件）。
///
/// 全项目底部抽屉一律 `useRootNavigator: true`：页签分支各持 Navigator，
/// 默认落在分支路由时抽屉会被壳的悬浮钮/底栏盖住（抽屉在 Scaffold body 内，
/// FAB 与底栏是 Scaffold 兄弟层）；走根路由抽屉才盖住底栏全屏可点。
///
/// 与 `AlertDialog` 的分工终态（2026-09-24）：`AlertDialog` 已清零——确认类
/// 走底部锚定的浮起卡片（承载仍是抽屉路由），普通文本输入（新建项目/标签/
/// 模板/筛选器）走输入型底部抽屉（`OrbitSheetScaffold` + 固定尾栏），密码类
/// 输入走 `orbit_password_sheet.dart` 的共享抽屉；仅剩附件图片预览用透明
/// `Dialog`（非选择/确认/输入，不算违规）。
///
/// **确认弹层形态（2026-11-04 对齐 miuix 对话框参考）**：确认类不再是贴边
/// 全宽、带拖拽手柄/左对齐标题的抽屉，改为**浮起圆角卡片**——左/右/下各
/// 16 留白（四角圆角完整可见，底边不贴屏幕）、四角 28 圆角、标题/说明居中、
/// 无手柄、遮罩 0.32。承载仍取 Material
/// `showModalBottomSheet`（保留下滑关闭手势与 25 处调用点的 `Future<bool>`
/// 语义），但底色必须透明、卡片形状由内容容器自绘。**2026-11-04 起这套浮起
/// 圆角卡片推广到全部底部弹层**（输入型、选择型、玻璃弹层、主表单），
/// 统一由 `OrbitFloatingSheetCard` / `OrbitGlassSheet` 绘制，见
/// `orbit_floating_sheet_card.dart`；本文件的确认弹层不再特殊。
///
/// **结构与按钮口径**（2026-09-22 收口）：三个弹层的骨架统一走 [OrbitSheetScaffold]
/// ——内容可滚、底部按钮行**固定在抽屉底部**、按钮标签一律居中；本文件只保留
/// 承载、形状与对外 API（口径详见 `orbit_sheet_scaffold.dart` 文件头）。
///
/// **注意**：调用方必须持有 `Navigator` 祖先（页面 / Material 抽屉内均可）；
/// shadcn 浮层（挂在 Navigator 之外的根 `DrawerOverlay`）内部不可调用本族——
/// 那里没有 `Navigator`，Material 路由式弹层唤不起来。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import 'package:flutter_miuix/miuix.dart';
import 'orbit_dropdown_panel.dart' show OrbitPanelItem;
import 'orbit_glass_surface.dart';
import 'orbit_select_popup.dart';
import 'orbit_sheet_scaffold.dart';

export 'orbit_select_popup.dart'
    show SelectItem, showOrbitSelectPopup, orbitSelectPopupKey;

/// 底部弹层承载形状（全项目唯一形状来源；兼容名保留）
///
/// 2026-11-04 起所有底部弹层一律浮起圆角卡片：真正的卡片由
/// `OrbitFloatingSheetCard` / `OrbitGlassSheet` 自绘（左右下各 16 留白 +
/// 四角 `AppShapes.xl`），承载底色透明。本形状只作 Material 兜底，四角与卡片
/// 同档，避免顶圆角 shape 把卡片顶角裁成贴边抽屉的样子。
const RoundedRectangleBorder bottomSheetTopShape = RoundedRectangleBorder(
  borderRadius: AppShapes.xl,
);

/// 底部抽屉统一动效（时长/曲线取自 AppMotion，视图内不写裸值）
const AnimationStyle bottomSheetMotion = AnimationStyle(
  duration: AppMotion.normal,
  reverseDuration: AppMotion.fast,
  curve: AppMotion.sheetEnter,
);

/// 确认钮文案：冷静期未走完显示剩余秒数，走完显示正常确认文案。
///
/// 与桌面 `DangerousConfirmDialog.formatHoldLabel` 同口径（纯函数便于单测）。
String formatHoldConfirmLabel(int remaining, String confirmLabel) =>
    remaining > 0 ? '请阅读后果（${remaining}s）' : confirmLabel;

/// 确认弹层卡片 finder（形态回归测试用；同 `orbitSelectPopupKey` 口径）
const ValueKey<String> confirmDialogCardKey = ValueKey<String>(
  'orbit-confirm-dialog-card',
);

/// 确认弹层（兼容名 `showConfirmBottomSheet`）：返回 `true` = 用户点了确认按钮；
/// 点遮罩/下滑关闭/取消都是 `false`
/// （调用方直接 `if (!await showConfirmBottomSheet(...)) return;` 即可，不必判 null）。
///
/// [holdSeconds] > 0 时开层即进入强制冷静期：确认钮禁用并显示剩余秒数，
/// 倒计时归零后才可点（对应桌面 `DangerousConfirmDialog` 的 `holdSeconds`）。
/// 默认 0 = 立即确认，存量调用行为不变。
Future<bool> showConfirmBottomSheet(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = '确定',
  String? cancelLabel = '取消',
  bool destructive = false,
  int holdSeconds = 0,
}) async {
  // 取值语义：确认 -> true；取消 / 下滑关闭 / 点遮罩 -> false（结果缺失按 false 处理）
  final colors = AppColors.ofContext(context);
  final result = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    // 卡片自绘四角圆角与左/右/下留白：承载底色必须透明，否则 BottomSheet 自带的
    // 顶圆角/直角背景会从卡片外圈露出来（2026-09-21 同款踩坑）
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    elevation: 0,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => Container(
      key: confirmDialogCardKey,
      margin: const EdgeInsets.only(
        left: AppDimens.space16,
        right: AppDimens.space16,
        bottom: AppDimens.space16,
      ),
      decoration: BoxDecoration(
        color: colors.popup,
        borderRadius: AppShapes.xl,
      ),
      clipBehavior: Clip.antiAlias,
      // 卡片底色是 DecoratedBox，会隔断 BottomSheet 的 Material：内容里的
      // ListTile / InkWell 需要就近的 Material 才能画水波纹（库内对话框同款兜底）
      child: Material(
        type: MaterialType.transparency,
        child: _ConfirmSheet(
          title: title,
          message: message,
          content: content,
          confirmLabel: confirmLabel,
          cancelLabel: cancelLabel,
          destructive: destructive,
          holdSeconds: holdSeconds,
          onCancel: () => Navigator.of(sheetContext).pop(false),
          onConfirm: () => Navigator.of(sheetContext).pop(true),
        ),
      ),
    ),
  );
  return result ?? false;
}

/// 详情/表单单选弹层（**兼容名**）
///
/// 2026-11-03 起实现换成 miuix 口径的锚定浮层
/// （[showOrbitSelectPopup]：复用页头菜单面板，右上角弹出 + 行尾对勾），
/// 不再从底部升起玻璃抽屉。保留原名与参数，存量调用点零改动即统一。
///
/// [title] 仍必填，但浮层里不画标题行（miuix 下拉面板无标题；当前值靠对勾），
/// 仅作无障碍语义。行式入口可传 [anchor]（触发行矩形）让弹层贴行弹出。
Future<void> showSelectBottomSheet<T>(
  BuildContext context, {
  required String title,
  required List<SelectItem<T>> items,
  T? current,
  required ValueChanged<T> onSelect,
  Rect? anchor,
}) => showOrbitSelectPopup<T>(
  context,
  title: title,
  items: items,
  current: current,
  onSelect: onSelect,
  anchor: anchor,
);

/// 更多操作底部弹层；选项点击后自动关闭再回调
///
/// 条目模型复用下拉面板的 [OrbitPanelItem]（图标 + 文案 + 可选着色 + 回调）：
/// 底部动作菜单与锚定面板/页头菜单同一份数据口径，调用方不再需要两套菜单项
/// 类型（原 `MoreActionItem` 已并入，2026-11-05）。
Future<void> showMoreActionsSheet(
  BuildContext context, {
  required String title,
  required List<OrbitPanelItem> actions,
}) async {
  final backdrop = OrbitGlassScope.maybeOf(context);
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => OrbitGlassSheet(
      backdrop: backdrop,
      child: _ActionsSheet(
        title: title,
        actions: actions,
        onPick: (action) {
          Navigator.of(sheetContext).pop();
          action.onTap?.call();
        },
      ),
    ),
  );
}

class _ConfirmSheet extends StatefulWidget {
  const _ConfirmSheet({
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    required this.holdSeconds,
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

  /// 强制冷静期（秒）；0 = 立即确认
  final int holdSeconds;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  /// 冷静期剩余秒数（0 = 确认钮已可点；负值按 0 处理）
  late int _remaining = widget.holdSeconds > 0 ? widget.holdSeconds : 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.holdSeconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _remaining -= 1;
        if (_remaining <= 0) {
          _remaining = 0;
          timer.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 正文可滚、按钮固定在骨架尾栏（内容再长也不会把确认钮顶出可视区）
    return OrbitSheetScaffold(
      showHandle: false,
      // 卡片由 showConfirmBottomSheet 外层 Container 画，骨架不再画第二层
      floatingCard: false,
      header: _ConfirmDialogTitle(widget.title),
      // 卡片内边距 24（miuix 对话框 insideMargin 口径）；底部留白由按钮行上边距提供
      contentPadding: const EdgeInsets.symmetric(horizontal: AppDimens.space24),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.message != null)
            Text(
              widget.message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: colors.secondaryText,
              ),
            ),
          if (widget.content != null) ...[
            if (widget.message != null)
              const SizedBox(height: AppDimens.space12),
            widget.content!,
          ],
        ],
      ),
      actions: OrbitSheetActions(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.space24,
          AppDimens.space16,
          AppDimens.space24,
          AppDimens.space20,
        ),
        cancelLabel: widget.cancelLabel,
        onCancel: widget.onCancel,
        // 冷静期内确认钮禁用、文案走剩余秒数（取消始终可点）
        confirmLabel: formatHoldConfirmLabel(_remaining, widget.confirmLabel),
        onConfirm: _remaining > 0 ? null : widget.onConfirm,
        destructive: widget.destructive,
      ),
    );
  }
}

/// 确认弹层标题（居中；miuix 对话框口径，卡片内边距 24）
class _ConfirmDialogTitle extends StatelessWidget {
  const _ConfirmDialogTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space24,
        AppDimens.space24,
        AppDimens.space24,
        AppDimens.space12,
      ),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colors.titleText,
        ),
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
  final List<OrbitPanelItem> actions;
  final ValueChanged<OrbitPanelItem> onPick;

  @override
  Widget build(BuildContext context) {
    // 无尾栏（点选即关）；选项行数量有限，内容区按需滚动
    return OrbitSheetScaffold(
      title: title,
      // 玻璃卡面由 OrbitGlassSheet 画，骨架不再画第二层不透明卡片
      floatingCard: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 行口径与「今天」页头 ⋮ 菜单同源（MiuixGlassPopupItem：44 行高、
          // 24 图标位、破坏性红走 contentColor）；卡面仍按底部抽屉规则
          for (final action in actions)
            MiuixGlassPopupItem(
              text: action.label,
              icon: action.icon == null
                  ? null
                  : Icon(action.icon, color: action.color),
              contentColor: action.color,
              onPressed: action.onTap == null
                  ? null
                  : () => onPick(action),
            ),
          const SizedBox(height: AppDimens.space8),
        ],
      ),
    );
  }
}
