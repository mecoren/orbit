import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:go_router/go_router.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_bottom_nav.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_panel.dart';
import '../../shared/widgets/shadcn/orbit_fab.dart';
import '../../shared/widgets/shadcn/orbit_glass_surface.dart';
import '../../shared/widgets/shadcn/orbit_divider.dart';
import '../todo/form_bottom_sheet.dart';
import '../todo/logic/quick_add_context.dart';
import '../todo/logic/task_logic.dart';
import '../todo/providers/task_window_provider.dart';
import '../todo/quick_add_sheet.dart' show showQuickAddSheet;
import '../todo/sidebar_screen.dart';
import 'nav_modules.dart';

/// 主导航壳（OS4 玻璃底栏 + 右下悬浮新建钮 + 「更多」面板）
///
/// 对齐竞品主导航形态：模块页签经 StatefulShellRoute 各自持有导航栈，切页签
/// 互不丢栈，页签内入栈（任务列表、项目编辑等）时底栏常驻；任务详情等根级
/// 路由覆盖全屏，底栏随之隐藏。**底栏页签可配置**（对齐竞品「功能模块」）：
/// 启用序前 [NavModulesState.bottomTabLimit] 个模块进底栏，其余启用模块收进
/// 「更多」面板；末位「更多」动作页签不切页——就地弹出锚在页签上方的次级
/// 目的地面板（标题行带「编辑」入口进功能模块配置页），点面板外关闭，面板
/// 条目点击 = 切到对应模块分支。「新建」上收右下悬浮钮（[OrbitFab]）：落点
/// 跟随当前列表页（[QuickAddContext] 登记的筛选入参），长按直达模板新建；
/// 「今天」页签挂今日未完成计数角标（不在底栏时不挂）。
///
/// **OS4 玻璃接线（2026-10-31）**：底栏换成 `MiuixGlassNavigationBar` 后需要
/// 「栏体背后的内容」采样快照。按库内约束，**捕获树与玻璃消费方必须是兄弟
/// 节点**——这里用 `Stack` 把页面内容包进 [MiuixLayerBackdropCapture]，
/// 底栏与悬浮钮作为 `Scaffold` 的兄弟层挂在捕获树之外，两者共享同一个
/// [MiuixLayerBackdrop]。反之（捕获树包住玻璃组件）会自采样：栏体把自己
/// 也拍进背景，越糊越实。
///
/// 页头（各页 `OrbitPageHeader`）本身不在本壳的捕获树内（各页自持 Stack），
/// 故默认仍走实时 `BackdropFilter` 路径；需要 OS4 采样的页头可显式传
/// `backdrop`——本壳把同一实例经 [OrbitGlassScope] 向下暴露。
///
/// **2026-11-02 悬浮底栏**：壳层 Scaffold 改 `extendBody: true`，配合
/// [OrbitBottomNav] 的悬浮留白，底栏才真正浮在页面内容之上（玻璃采样有东西）。
/// 代价是页面内容会铺到屏幕底边：各页滚动尾部必须补
/// `OrbitBottomNav.clearanceOf(context)`，否则末行停在栏体背后。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// go_router 的页签容器（IndexedStack 语义，切换保留各页签状态）
  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// OS4 玻璃背景采样器（随 State 生命周期持有，dispose 释放快照图像）
  final MiuixLayerBackdrop _backdrop = MiuixLayerBackdrop();

  /// 「更多」菜单的形变锚点（由 [OrbitBottomNav] 绑到「更多」图标上，
  /// 菜单从该图标位置连续长出来）
  final MiuixGlassPopupAnchor _moreAnchor = MiuixGlassPopupAnchor();

  /// 「更多」菜单开合（`MiuixGlassTransformPopup.show` 驱动进出场动画）
  bool _moreOpen = false;

  @override
  void initState() {
    super.initState();
    // 预热 OS4 shader：首帧就绪可避免"第一下看到实色带、再变玻璃"的跳变
    MiuixGlassRendering.load();
  }

  @override
  void dispose() {
    _moreAnchor.dispose();
    _backdrop.dispose();
    super.dispose();
  }

  /// 关闭「更多」菜单（点条目/点外部/返回手势都走这里）
  void _closeMoreMenu() => setState(() => _moreOpen = false);

  @override
  Widget build(BuildContext context) {
    final nav = ref.watch(navModulesProvider);
    final tabs = nav.bottomTabs;
    // 「今天」角标 = 今天截止视图的未完成数（0 不显示，见 [OrbitBottomNav]）；
    // 今天模块不在底栏时无角标位。P1 窗口化后改读 SQL 聚合：底栏常驻，
    // 不能再为一个小角标在内存里留一份万行任务数组。
    final counts =
        ref.watch(sidebarCountsProvider).value ??
        const SidebarCounts(quickView: {}, undoneByProject: {});
    final todayPos = tabs.indexOf(OrbitNavModule.today);
    // 当前分支对应模块不在底栏（经「更多」面板/侧栏内跳进入）时，选中态落
    // 「更多」动作位（竞品同款：面板进入的模块页高亮「更多」）
    final currentModule = OrbitNavModule.values[widget.navigationShell.currentIndex];
    final currentTabPos = tabs.indexOf(currentModule);

    // 配置变化后当前模块被停用：回落到启用序第一个模块（配置页在全屏路由
    // 之上操作，返回壳前兜底，避免停在「无页签指向」的分支上）
    ref.listen(navModulesProvider, (prev, next) {
      if (!next.enabled.contains(currentModule)) {
        widget.navigationShell.goBranch(next.enabled.first.branchIndex);
      }
    });

    // 平板/横屏（#107）：清单页本身即 SidebarScreen，其它模块左侧常驻一份
    // 清单导航，避免在宽屏上来回「汉堡 → 清单 → 回来」。
    // 判据是**模块**而非路由：`/todo` 的 `sidebar` 分支根页就是侧栏整页，
    // 在它旁边再嵌一份会重复渲染（两份快捷视图 + 双页头，2026-10-27 评审发现）。
    final showEmbeddedSidebar =
        OrbitBreakpoints.isExpanded(context) &&
        currentModule != OrbitNavModule.sidebar;

    // 页面内容统一包进捕获树：底栏/页头消费同一 backdrop 的玻璃材质
    final content = MiuixLayerBackdropCapture(
      backdrop: _backdrop,
      child: showEmbeddedSidebar
          ? Row(
              children: [
                const SizedBox(
                  width: OrbitBreakpoints.sidebarWidth,
                  child: SidebarScreen(embedded: true),
                ),
                const OrbitVerticalDivider(width: 1),
                Expanded(child: widget.navigationShell),
              ],
            )
          : widget.navigationShell,
    );

    final colors = AppColors.ofContext(context);
    // 当前模块不在底栏（经「更多」进入）时「更多」位高亮
    final moreSelected = currentTabPos < 0;

    return OrbitGlassScope(
      backdrop: _backdrop,
      child: Stack(
        children: [
          Scaffold(
            // 详情见 [OrbitBottomNav]：底栏是悬浮胶囊，内容必须铺到屏幕底边，玻璃才
            // 采样得到背后的列表/卡片；各页滚动尾部按 `OrbitBottomNav.clearanceOf`
            // 自带净空，末行不会被栏体扣住。
            extendBody: true,
            body: content,
            // 玻璃作用域之下的 context：本 build 的 context 在 [OrbitGlassScope]
            // **之上**，直接用它取采样器永远为 null（快速添加面板会退实时模糊）
            floatingActionButton: Builder(
              builder: (fabContext) => OrbitFab(
                accentColor: OrbitAccents.themeAccent,
                // 新建落点跟随当前列表（无页面语境时面板内自选）
                onPressed: () {
                  final target = QuickAddContext.current;
                  showQuickAddSheet(
                    fabContext,
                    defaultProjectId: target?.projectId,
                    quickView: target?.quickView,
                  );
                },
                // 长按 = 从模板新建（与列表页长按加号同源；无模板静默返回）
                onLongPress: () => showTemplateCreateFlow(
                  fabContext,
                  ref.read(orbitBridgeProvider),
                ),
              ),
            ),
            bottomNavigationBar: OrbitBottomNav(
              backdrop: _backdrop,
              currentIndex: currentTabPos >= 0 ? currentTabPos : tabs.length,
              moreTabIndex: tabs.length,
              // 形变锚点绑在「更多」图标上；点按只负责开菜单（内容见下方弹层）
              moreAnchor: _moreAnchor,
              onMoreTap: () => setState(() => _moreOpen = true),
              // 重复点击当前页签回退到该页签根（go_router 惯例：保留栈内其余状态）
              onTap: (index) {
                final module = tabs[index];
                widget.navigationShell.goBranch(
                  module.branchIndex,
                  initialLocation:
                      module.branchIndex == widget.navigationShell.currentIndex,
                );
              },
              badges: todayPos >= 0
                  ? {todayPos: counts.quickView[QuickViewKey.today] ?? 0}
                  : const <int, int>{},
              items: [
                for (final m in tabs)
                  OrbitBottomNavItem(icon: m.icon, label: m.label),
                const OrbitBottomNavItem(icon: OrbitIcons.more, label: '更多'),
              ],
            ),
          ),
          // 「更多」的 OS4 玻璃形变菜单：从底栏图标连续长出来（与页头 ⋮ 同款）。
          // 弹层挂在本壳 Stack 顶层，`OverlayPortal` 自己再上浮到根 Overlay。
          MiuixGlassTransformPopup(
            show: _moreOpen,
            anchor: _moreAnchor,
            anchorContent: Icon(
              OrbitIcons.more,
              size: AppDimens.iconSizeLg,
              color: moreSelected
                  ? OrbitAccents.themeAccent
                  : colors.secondaryText,
            ),
            backdrop: _backdrop,
            // 材质与 `OrbitGlassMenu` 同档：puredThinGlass + blurRadius 32
            // （库默认 popupViewGlass 的 60 档在形变期 origin/size 逐帧变、
            // 纹理缓存逐帧失效，每帧重算 sigma≈27 的离屏模糊会掉帧）
            visuals: MiuixGlassPopupVisuals(
              material: MiuixGlassMaterials.puredThinGlass(
                Theme.of(context).brightness == Brightness.dark,
              ).copyWith(blurRadius: 32),
            ),
            // 默认「底边贴锚点底边」会压在底栏上：往上让一个栏体高度
            gap: -(OrbitBottomNav.barHeight + OrbitBottomNav.bottomGap),
            onDismissRequest: _closeMoreMenu,
            child: OrbitDropdownPanelView(
              title: '更多',
              actionLabel: '编辑',
              onAction: () => context.push('/settings/nav-modules'),
              onClose: _closeMoreMenu,
              // 形变弹层外层已带纵向滚动，这里不能再套一层
              scrollable: false,
              groups: [
                [
                  for (final m in nav.morePanelItems)
                    OrbitPanelItem(
                      icon: m.icon,
                      label: m.label,
                      onTap: () =>
                          widget.navigationShell.goBranch(m.branchIndex),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}



