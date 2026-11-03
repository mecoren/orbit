import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/orbit_accents.dart';

/// 底部导航栏（原语层：flutter_miuix `MiuixGlassNavigationBar` 承载 —— OS4 玻璃）
///
/// **2026-10-31 换承载**：实色表面 + 1px 上缘描边的 Material 式底栏，换成
/// HyperOS 4 的**液态玻璃导航栏**——毛玻璃底 + 随选中项滑动的胶囊指示器
/// （跨项切换带弹簧回弹，支持按住拖动换页、松手在栏内才提交选择）。
///
/// **保持既有交互口径（有意不做 HyperOS 的 iconAndText）**：
/// 本仓底栏历来是**纯图标**（对齐竞品形态，页签文字由读屏语义承载），
/// 故 `MiuixGlassNavigationItem` 只传 `contentDescription`、不传 `label`——
/// 栏体不渲染文字，读屏仍能读出「今天 / 清单 / 日历 …」。这既是"减少使用
/// 逻辑改动"，也避免与各页页头标题撞文案（`home_shell_test` 锁定
/// 「今天」只出现在页头）。
///
/// **2026-11-02 悬浮形态**：栏体不贴边通栏（换承载前的通栏胶囊看着像贴在屏底
/// 的一条带子），改为浮在页面内容之上——左右各 12、底边距 12（另加系统手势区）、
/// 上方 8，宽度在平板/横屏封顶 520 居中（对齐 `flutter_miuix` 的
/// `example/lib/showcase/os4.dart` 底栏接线）。
///
/// **OS4 玻璃采样**：`MiuixGlassNavigationBar` 需要 `MiuixLayerBackdrop` 采样
/// 「栏体背后的内容」。宿主（`home_shell.dart`）把页面内容包进
/// [MiuixLayerBackdropCapture] 并把同一个 backdrop 传给本组件——**捕获树与
/// 玻璃消费方必须是兄弟节点**，否则会形成自采样反馈循环（栏体把自己也拍进
/// 背景，越糊越实）。没有 backdrop 时库内自动回退实色，不会黑屏。
///
/// 悬浮的另一半前提是壳层 `Scaffold.extendBody: true`：页面内容铺到屏幕底边，
/// 栏体才「浮」在真实内容（列表行、卡片）之上，玻璃能采样到东西。此时页面
/// 的滚动尾部必须自带 [clearanceOf] 的净空，末行才不会停在栏体背后。
///
/// 公共 API 与旧实现一致（`items` / `currentIndex` / `onTap` /
/// `moreTabIndex` / `onMoreTap` / `badges`），`home_shell.dart` 只多传
/// [backdrop]。**2026-11-03 起「更多」菜单改 OS4 形变弹层**：[onMoreTap] 退回
/// 无参回调（不再算页签矩形），栏体另收 [moreAnchor] 并把该图标包进
/// `MiuixGlassAnchor`——菜单由宿主用 `MiuixGlassTransformPopup` 渲染，
/// 从图标位置连续长出来。
class OrbitBottomNav extends StatefulWidget {
  const OrbitBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.moreTabIndex,
    this.onMoreTap,
    this.moreAnchor,
    this.badges = const <int, int>{},
    this.backdrop,
  });

  /// 栏体内容高度（不含悬浮留白与底部手势区；HyperOS 玻璃栏最小 54）
  static const double barHeight = 54;

  /// 悬浮留白：栏体距屏幕左右各 12、底边 12（另加手势区）、上方 8
  static const double sideGap = AppDimens.space12;
  static const double topGap = AppDimens.space8;
  static const double bottomGap = AppDimens.space12;

  /// 栏体最大宽度（平板/横屏居中，对齐 OS4 showcase 的 520 封顶）
  static const double maxWidth = 520;

  /// 悬浮栏在页面内占用的底部净空（栏体 + 上下留白 + 手势区）
  ///
  /// 壳层 `extendBody: true` 后内容铺到屏幕底边、栏体浮在其上：各页滚动内容的
  /// 尾部 padding 必须加这段净空（再叠页面自己的呼吸留白），末行才不会停在
  /// 玻璃后面——既看不见也点不到。
  static double clearanceOf(BuildContext context) =>
      barHeight +
      topGap +
      bottomGap +
      MediaQuery.viewPaddingOf(context).bottom;

  /// 页签（末位 [moreTabIndex] 为「更多」动作位，不参与路由切换）
  final List<OrbitBottomNavItem> items;

  /// 当前选中下标
  final int currentIndex;

  /// 页签点击（下标；「更多」位不走此回调）
  final ValueChanged<int> onTap;

  /// 「更多」动作位下标（null = 无动作位）
  final int? moreTabIndex;

  /// 「更多」位点击（菜单由宿主渲染，栏体只负责触发）
  final VoidCallback? onMoreTap;

  /// 「更多」图标的形变锚点（宿主传入后，栏体把该图标包进
  /// `MiuixGlassAnchor`，OS4 形变菜单才能从图标位置长出来）
  final MiuixGlassPopupAnchor? moreAnchor;

  /// 页签角标计数（下标 → 数量；<=0 不显示）
  final Map<int, int> badges;

  /// OS4 玻璃的背景采样器（null = 库内回退实色）
  final MiuixLayerBackdrop? backdrop;

  @override
  State<OrbitBottomNav> createState() => _OrbitBottomNavState();
}

class _OrbitBottomNavState extends State<OrbitBottomNav> {
  void _handleTap(int index) {
    if (index == widget.moreTabIndex) {
      HapticFeedback.selectionClick();
      widget.onMoreTap?.call();
      return;
    }
    if (index != widget.currentIndex) HapticFeedback.selectionClick();
    widget.onTap(index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 悬浮留白 + 手势区让位：OS4 玻璃栏自身不吃 `viewPadding.bottom`（库内只画
    // 54 高的玻璃条），系统手势条/三键导航会与图标叠在一起，故底边距取
    // 「12 + 手势区」；左右 12 让它离屏边、浮起来。
    return Padding(
      padding: EdgeInsets.fromLTRB(
        OrbitBottomNav.sideGap,
        OrbitBottomNav.topGap,
        OrbitBottomNav.sideGap,
        OrbitBottomNav.bottomGap + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Center(
        // heightFactor 只保留横向居中：底栏槽给的是松高度约束，不钉住高度的
        // Center 会撑满整条槽（栏体被拉成两倍高）
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: OrbitBottomNav.maxWidth),
          child: MiuixGlassNavigationBar(
            backdrop: widget.backdrop,
            selectedIndex: widget.currentIndex,
            // 「更多」动作位：OS4 的 isAction 项只触发回调、不移动指示器
            onSelect: _handleTap,
            height: OrbitBottomNav.barHeight,
            // 选中项图标走主题强调色，未选中走次要文字色
            selectedColor: OrbitAccents.themeAccent,
            unselectedColor: colors.secondaryText,
            items: [
              for (var i = 0; i < widget.items.length; i++)
                MiuixGlassNavigationItem(
                  icon: _buildIcon(colors, i),
                  // label 不传 → 栏体纯图标（本仓既有形态）；语义文案走 contentDescription
                  contentDescription: widget.items[i].label,
                  isAction: i == widget.moreTabIndex,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 页签图标（选中态强调色 + 可选计数角标）
  Widget _buildIcon(AppColorSet colors, int index) {
    final selected = index == widget.currentIndex;
    final badge = widget.badges[index] ?? 0;
    final icon = Icon(
      widget.items[index].icon,
      size: AppDimens.iconSizeLg,
      color: selected ? OrbitAccents.themeAccent : colors.secondaryText,
    );
    final content = badge <= 0
        ? icon
        // 角标贴图标右上角：`Stack` + `clipBehavior: none` 允许溢出图标盒绘制
        : Stack(
            clipBehavior: Clip.none,
            children: [
              icon,
              Positioned(top: -5, right: -12, child: _buildBadge(badge)),
            ],
          );
    // 「更多」动作位挂形变锚点：OS4 菜单从该图标位置连续长出来
    final anchor = widget.moreAnchor;
    if (index == widget.moreTabIndex && anchor != null) {
      return MiuixGlassAnchor(anchor: anchor, child: content);
    }
    return content;
  }

  /// 计数角标：红色胶囊（>99 折叠为 99+），白字加粗保对比度
  Widget _buildBadge(int n) {
    return Container(
      constraints: const BoxConstraints(minHeight: 14),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: OrbitAccents.overdueRed,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        n > 99 ? '99+' : '$n',
        style: const TextStyle(
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
          color: Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}

/// 底部导航页签描述（图标独立展示 + 读屏语义文案）
class OrbitBottomNavItem {
  const OrbitBottomNavItem({required this.icon, required this.label});

  final IconData icon;

  /// 读屏文案（栏体不渲染文字，见 [_OrbitBottomNavState.build]）
  final String label;
}
