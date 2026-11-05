/// 连体分段筛选（原语层：HyperOS FilterSortView 同款轨道 + 滑动的选中块）
///
/// 与 [OrbitFilterChip] 的分工：
/// - **本组件 = 卡内独占一整行的互斥筛选**（同步历史四档这类 2～5 档、同屏
///   只此一组）：四个独立胶囊读起来是「四个可选项」，分段控件读起来是
///   「一个控件的四个档位」——轨道连成一片、选中块在轨道内滑动，分组归属
///   一目了然，也不再是四个各自描边的盒子堆在卡里；
/// - **列表行筛选**（任务状态/优先级、冲突解决记录，常与其他筛选并排）
///   仍用裸 [OrbitFilterChip] + `Wrap`：多组并排时连体轨道会互相抢视线。
///
/// 为什么不是下拉偏好行（`OrbitDropdownPreference`）：那条原语是给**设置项**
/// 用的（当前档常驻行内、点开才展开）；本行是排障面板的**类型筛选**，四档
/// 常驻可见、一次点击直达，与桌面端同步历史卡那排筛选钮同口径。判据差异在
/// 「切档要不要连带改配置」——改配置走偏好行，只是换个视角看列表走这里。
///
/// 承载是库内 `MiuixTabRowWithContour`（squircle 轨道 + squircle 选中块 +
/// 选中档字重加粗 + 宽度不够时横向滚动），本层只补配色映射：库内默认轨道取
/// `colors.surface`（本仓卡片正是 surface，轨道会与卡片融为一体、只剩选中块
/// 浮着），故轨道显式退一档到 `surfaceSecondary`；选中块亮色取卡片白（灰轨
/// 上的白块），暗色取白 10% 叠在轨道上（暗色下 `surface` 比轨道更深，直接
/// 复用会「选中反而陷下去」）。
///
/// 为什么不用 `MiuixGlassSegmentedTabRow`：玻璃分段要背景采样器，卡内无采样器
/// 时退白卡，在白色卡片上等于「看不见的轨道」；筛选要稳定的实色分层。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/orbit_accents.dart';

/// 连体分段筛选（见文件头）
class OrbitSegmentedFilter extends StatelessWidget {
  const OrbitSegmentedFilter({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelect,
  });

  /// 档位文案（顺序即显示顺序；选中判据是下标）
  final List<String> tabs;

  /// 当前档下标（越界由库内 clamp 兜底）
  final int selectedIndex;

  /// 切档回调
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();
    final colors = AppColors.ofContext(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final track = colors.surfaceSecondary;
    final selectedBg = dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.10), track)
        : colors.surface;
    return MiuixTabRowWithContour(
      tabs: tabs,
      selectedTabIndex: selectedIndex,
      onTabSelected: onSelect,
      colors: MiuixTabRowColors(
        backgroundColor: track,
        contentColor: colors.secondaryText,
        selectedBackgroundColor: selectedBg,
        selectedContentColor: OrbitAccents.themeAccent,
      ),
    );
  }
}
