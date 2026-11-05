import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import 'orbit_dropdown_panel.dart'
    show OrbitPanelItem, orbitPanelMaxWidth, orbitPanelMinWidth;
import 'orbit_icon_button.dart';

/// OS4 玻璃「按钮 → 菜单」形变弹层（页头右上角 ⋮ 的载体；2026-11-02）
///
/// 对齐 flutter_miuix os4 demo（`example/lib/showcase/os4.dart`）的
/// `MiuixGlassTransformPopup` 形变菜单：点按钮从按钮轮廓**连续形变**展开成
/// 玻璃菜单（材质档库内自动取 `popupViewGlass`——菜单/弹层的标准档），
/// 点面板外/返回手势/Esc 收起，收起播放逆形变回按钮。
///
/// **配置驱动**：复用 [OrbitPanelItem]，与 `OrbitDropdownPanelView`
/// （锚定面板）数据同源，字段映射——
/// - `checked` → `MiuixGlassPopupItem.selected`（行尾勾号 + 主题色）；
/// - `trailingLabel` → `summary`（行尾副文案，如「已启用 2 项」）；
/// - `color` → `contentColor`（破坏性红）；
/// - `children` → 点该条目**堆叠展开二级面板**（`MiuixGlassSecondaryPopup`，
///   首行「返回上级」收回一级；选中档位打勾），与竞品 OS4 二级菜单同款。
///
/// **挂载口径**：弹层经 `OverlayPortal` 渲染到根 Overlay（在
/// `MiuixLayerBackdropCapture` 捕获树之外，不会自采样）；背景采样器经
/// [backdrop] 传入（壳层 `OrbitGlassScope` 暴露的实例），无壳/测试传 null
/// 时库内退实色填充。
///
/// **触发件**：图标按钮直接用本件；页头标题这类任意控件用 [OrbitGlassMenu]
/// （同一套承载，触发控件与形变副本由调用方各给一份）。
class OrbitGlassMenuButton extends StatelessWidget {
  const OrbitGlassMenuButton({
    super.key,
    required this.groupsBuilder,
    required this.icon,
    this.tooltip,
    this.backdrop,
  });

  /// 菜单条目（点开时构建一次，回调闭包取调用方当下状态）
  final List<List<OrbitPanelItem>> Function() groupsBuilder;

  /// 按钮图标（同时作形变动画的图标副本；可含角标）
  final Widget icon;

  /// 读屏/悬浮提示文案（null = 不包 Tooltip）
  final String? tooltip;

  /// OS4 玻璃背景采样器（通常传 `OrbitGlassScope.maybeOf(context)`）
  final MiuixLayerBackdrop? backdrop;

  @override
  Widget build(BuildContext context) {
    return OrbitGlassMenu(
      groupsBuilder: groupsBuilder,
      backdrop: backdrop,
      // 形变期触发钮内容被锚点隐藏，图标副本由 anchorContent 承担
      anchorContent: Center(child: icon),
      triggerBuilder: (onTap) =>
          OrbitIconButton(onPressed: onTap, tooltip: tooltip, icon: icon),
    );
  }
}

/// 任意触发控件版的玻璃形变菜单（2026-11-03，页头标题「今天 ▾」的快捷视图
/// 切换器）：与 [OrbitGlassMenuButton] 同一套承载、材质与二级面板口径，
/// 差别只在触发件由调用方给——非图标按钮（标题文字 + 箭头）也能长出菜单。
class OrbitGlassMenu extends StatefulWidget {
  const OrbitGlassMenu({
    super.key,
    required this.groupsBuilder,
    required this.triggerBuilder,
    required this.anchorContent,
    this.backdrop,
  });

  /// 菜单条目（点开时构建一次，回调闭包取调用方当下状态）
  final List<List<OrbitPanelItem>> Function() groupsBuilder;

  /// 触发控件（收开/收回调；形变期该控件被隐藏，由 [anchorContent] 接管）
  final Widget Function(VoidCallback onTap) triggerBuilder;

  /// 形变期按钮副本（按触发控件矩形缩放，版式尽量与触发控件同构）
  final Widget anchorContent;

  /// OS4 玻璃背景采样器（通常传 `OrbitGlassScope.maybeOf(context)`）
  final MiuixLayerBackdrop? backdrop;

  @override
  State<OrbitGlassMenu> createState() => _OrbitGlassMenuState();
}

class _OrbitGlassMenuState extends State<OrbitGlassMenu> {
  /// 触发钮锚点（形变起点；按库内约束调用方创建并 dispose）
  final _anchor = MiuixGlassPopupAnchor();

  /// 二级面板锚行锚点（每个带 children 的条目一个，按 (组, 行) 惰性建）
  final _rowAnchors = <(int, int), MiuixGlassPopupAnchor>{};

  /// 点开时快照的条目配置（关闭后保留到下次打开，二级退出动画期间仍要渲染）
  List<List<OrbitPanelItem>>? _groups;

  bool _open = false;

  /// 当前堆叠展开的二级面板（组下标, 条目下标）；null = 无
  (int, int)? _secondary;

  /// 二级面板锚行矩形（展开时快照；null = 从未展开过，二级组件不挂载。
  /// 收起后**不清**——退出动画还要按它定位）
  Rect? _secondaryBounds;

  /// 弹层材质：puredThin + blurRadius 32（按亮暗各缓存一份，值相等是
  /// 库内纹理缓存的性能要件，见 `MiuixGlassMaterial.==` 注释）
  static final _popupMaterialLight = MiuixGlassMaterials.puredThinGlassLight
      .copyWith(blurRadius: 32);
  static final _popupMaterialDark = MiuixGlassMaterials.puredThinGlassDark
      .copyWith(blurRadius: 32);

  /// 弹层材质档（性能口径，2026-11-02）：
  ///
  /// 库默认菜单档 `popupViewGlass`（blurRadius 60）在 Flutter 端跑不动——
  /// `_RenderGlass.paint` 每次重绘都是「离屏模糊 + 两趟混色 + toImageSync」，
  /// 而纹理缓存键含面板 `origin/size`（`miuix_glass.dart` prepare），形变
  /// 动画期间二者逐帧变化 → 缓存逐帧全盘失效 → **每帧**重跑 sigma≈27 的
  /// 高斯离屏模糊，真机上掉帧明显。降为 blurRadius 32（sigma≈14）：观感
  /// 仍是同一套磨砂玻璃，每帧模糊成本约降 3 倍；动画落定后 origin/size
  /// 静止，缓存命中，静止期间不再重跑模糊。
  static MiuixGlassMaterial _popupMaterial(bool isDark) =>
      isDark ? _popupMaterialDark : _popupMaterialLight;

  @override
  void dispose() {
    _anchor.dispose();
    for (final a in _rowAnchors.values) {
      a.dispose();
    }
    super.dispose();
  }

  void _toggle() {
    if (_open) {
      _close();
      return;
    }
    _groups = widget.groupsBuilder();
    setState(() => _open = true);
  }

  /// 收起整层（一级 + 二级一起；回调在弹层关闭后落回页面执行）
  void _close() {
    setState(() {
      _open = false;
      _secondary = null;
    });
  }

  MiuixGlassPopupAnchor _rowAnchor(int g, int i) =>
      _rowAnchors.putIfAbsent((g, i), MiuixGlassPopupAnchor.new);

  /// 点叶子条目：先收层再执行（导航类回调落到下层页面，与旧面板同语义）
  void _runItem(OrbitPanelItem item) {
    _close();
    item.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups ?? const <List<OrbitPanelItem>>[];
    final secondary = _secondary;
    // 材质档按亮暗取（与页头/底栏同判据）；visuals 覆写库默认的
    // popupViewGlass(60) 档，见 [_popupMaterial] 的性能口径注释
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final visuals = MiuixGlassPopupVisuals(material: _popupMaterial(isDark));
    return Column(
      mainAxisSize: MainAxisSize.min,
      // 触发件可能是页头标题（外层给满宽约束）：按起始边对齐，别把标题居中
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 触发控件：包进 MiuixGlassAnchor（弹层展开时其内容被隐藏，
        // 副本由 anchorContent 承担形变）
        MiuixGlassAnchor(
          anchor: _anchor,
          child: widget.triggerBuilder(_toggle),
        ),
        // 一级菜单：触发件 → 菜单连续形变（simplified = 展开期不叠副本）
        MiuixGlassTransformPopup(
          show: _open,
          anchor: _anchor,
          anchorContent: widget.anchorContent,
          simplified: true,
          stacked: secondary != null,
          backdrop: widget.backdrop,
          // 宽度与全站弹出菜单同档（180–240），库内默认 200–288 偏宽
          sizing: const MiuixGlassPopupSizing(
            minWidth: orbitPanelMinWidth,
            maxWidth: orbitPanelMaxWidth,
          ),
          visuals: visuals,
          onDismissRequest: _close,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var g = 0; g < groups.length; g++) ...[
                if (g > 0) _groupDivider(context),
                for (var i = 0; i < groups[g].length; i++)
                  _menuRow(g, i, groups[g][i]),
              ],
            ],
          ),
        ),
        // 二级面板：从锚行堆叠展开（首次展开前不挂载——bounds 尚不存在）
        if (_secondaryBounds != null)
          MiuixGlassSecondaryPopup(
            show: secondary != null,
            anchorBounds: _secondaryBounds,
            materialAnchor: _anchor,
            backdrop: widget.backdrop,
            sizing: const MiuixGlassPopupSizing(
              minWidth: orbitPanelMinWidth,
              maxWidth: orbitPanelMaxWidth,
            ),
            visuals: visuals,
            onDismissRequest: () => setState(() => _secondary = null),
            child: secondary == null
                ? const SizedBox.shrink()
                : _secondaryPanel(secondary),
          ),
      ],
    );
  }

  /// 组间分隔（对齐库内 `MiuixGlassPopupDefaults` 的分隔线规格）
  Widget _groupDivider(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Divider(
        height: 1,
        thickness: 0.5,
        indent: 20,
        endIndent: 20,
        color: colors.divider,
      ),
    );
  }

  /// 一级条目行：带 children 的包进锚行（点开二级、箭头随状态转向）
  Widget _menuRow(int g, int i, OrbitPanelItem item) {
    if (item.children.isNotEmpty) {
      final anchor = _rowAnchor(g, i);
      final open = _secondary == (g, i);
      return MiuixGlassAnchor(
        anchor: anchor,
        child: MiuixGlassPopupItem(
          text: item.label,
          icon: Icon(item.icon, color: item.iconColor),
          summary: item.trailingLabel,
          contentColor: item.color,
          showArrow: true,
          arrowRotation: open ? -90 : 0,
          onPressed: () {
            _secondaryBounds = anchor.bounds ?? _secondaryBounds;
            setState(() => _secondary = (g, i));
          },
        ),
      );
    }
    return MiuixGlassPopupItem(
      text: item.label,
      icon: Icon(item.icon, color: item.iconColor),
      summary: item.trailingLabel,
      selected: item.checked,
      contentColor: item.color,
      onPressed: item.onTap == null ? null : () => _runItem(item),
    );
  }

  /// 二级面板：首行「返回上级」收回一级，其后各档位选中打勾
  Widget _secondaryPanel((int, int) index) {
    final item = _groups![index.$1][index.$2];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MiuixGlassPopupItem(
          text: '返回上级',
          showArrow: true,
          arrowRotation: -90,
          onPressed: () => setState(() => _secondary = null),
        ),
        for (final child in item.children)
          MiuixGlassPopupItem(
            text: child.label,
            icon: Icon(child.icon, color: child.iconColor),
            selected: child.checked,
            contentColor: child.color,
            onPressed: child.onTap == null ? null : () => _runItem(child),
          ),
      ],
    );
  }
}
