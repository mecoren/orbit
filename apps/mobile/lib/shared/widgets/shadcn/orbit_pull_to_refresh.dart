import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/orbit_accents.dart';

/// 下拉刷新（原语层：flutter_miuix `MiuixPullToRefresh` 承载）
///
/// **2026-11-01 换承载**：主列表 / 清单 / 统计 / 回收站四页的 Material
/// `RefreshIndicator` 换成 miuix HyperOS 下拉刷新——阻尼拖拽 + 细环指示圈 +
/// 阈值「断环」形态 + 四档文案（下拉刷新 / 释放刷新 / 正在刷新… / 刷新成功）
/// + 越过阈值触感反馈。
///
/// **为什么包一层而不是页面直用 `MiuixPullToRefresh`**：
/// miuix 组件的 `isRefreshing` 要求调用方提升刷新状态（Compose 语义），而四页
/// 现有调用走 Material `RefreshIndicator` 的「`onRefresh` 返回 Future →
/// 指示器自持转圈」口径。本包装把 Future 期间的 refreshing 状态收在内部，
/// 调用点只需把 `RefreshIndicator` 逐字换成 [OrbitPullToRefresh]（参数同形），
/// 页面刷新逻辑零改动。
///
/// **指示器避让玻璃页头**：Material 版用 `edgeOffset` 把指示条压到页头之下；
/// miuix 版的刷新头随容器顶部生长，用 `contentPadding.top`（=
/// `edgeOffset + displacement`）把整条下拉带下移，两者的视觉落点一致，
/// 不会被 `OrbitPageHeader` 盖住。
///
/// **短内容提示**：miuix 版与 Material 版同约束——列表内容不满一屏时，滚动
/// 组件需 `AlwaysScrollableScrollPhysics` 才能产生 overscroll 触发刷新。
class OrbitPullToRefresh extends StatefulWidget {
  const OrbitPullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.color,
    this.edgeOffset = 0,
    this.displacement = 0,
  });

  /// 刷新回调（返回 Future；期间指示器保持转圈）
  final Future<void> Function() onRefresh;

  /// 被包滚动视图
  final Widget child;

  /// 指示圈颜色（null = 全局主题强调色）
  final Color? color;

  /// 指示条避让量（原 `RefreshIndicator.edgeOffset`：状态栏 + 页头高）
  final double edgeOffset;

  /// 指示条相对避让位的下移量（原 `RefreshIndicator.displacement`）
  final double displacement;

  @override
  State<OrbitPullToRefresh> createState() => _OrbitPullToRefreshState();
}

class _OrbitPullToRefreshState extends State<OrbitPullToRefresh> {
  bool _refreshing = false;

  Future<void> _handleRefresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MiuixPullToRefresh(
      isRefreshing: _refreshing,
      onRefresh: _handleRefresh,
      // 整条下拉带下移到玻璃页头之下（口径见类文档）
      contentPadding: EdgeInsets.only(
        top: widget.edgeOffset + widget.displacement,
      ),
      color: widget.color ?? OrbitAccents.themeAccent,
      // 库内默认英文文案，按 zh-CN 口径覆盖
      refreshTexts: const ['下拉刷新', '释放刷新', '正在刷新…', '刷新成功'],
      refreshTextStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.ofContext(context).secondaryText,
      ),
      child: widget.child,
    );
  }
}
