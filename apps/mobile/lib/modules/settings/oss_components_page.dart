import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_preference.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_group_card.dart';
import '../../shared/widgets/shadcn/orbit_list_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_settings_group.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import 'oss_components_filter.dart';

/// 开源组件列表页 /about/oss-components
///
/// 数据源在 orbit-core（`oss_components`），与桌面同一份；壳层只做来源筛选、
/// 排序与展示。筛选/排序用设置页同款 [OrbitDropdownPreference]：当前档常驻
/// 行内，点行就地展开玻璃菜单，不走底部抽屉。
class OssComponentsPage extends ConsumerStatefulWidget {
  const OssComponentsPage({super.key});

  @override
  ConsumerState<OssComponentsPage> createState() => _OssComponentsPageState();
}

class _OssComponentsPageState extends ConsumerState<OssComponentsPage> {
  /// null = 加载中
  List<OssComponentInfo>? _components;
  bool _failed = false;
  OssSourceFilter _filter = OssSourceFilter.all;
  OssSort _sort = OssSort.defaultOrder;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final components = await ref.read(orbitBridgeProvider).ossComponents();
      if (!mounted) return;
      setState(() {
        _components = components;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  EdgeInsets get _listPadding => EdgeInsets.only(
    top:
        MediaQuery.of(context).padding.top +
        OrbitPageHeader.rowHeight +
        AppDimens.space16,
    left: AppDimens.space12,
    right: AppDimens.space12,
    bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: OrbitBreakpoints.contentMaxWidth,
                ),
                child: _buildBody(),
              ),
            ),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(title: '开源组件'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_failed) {
      return ListView(
        padding: _listPadding,
        children: [
          SizedBox(
            height: 240,
            child: EmptyState(
              icon: OrbitIcons.code,
              message: '开源组件加载失败，请稍后重试。',
              actionLabel: '重试',
              onAction: _load,
            ),
          ),
        ],
      );
    }
    final components = _components;
    if (components == null) {
      return ListView(
        padding: _listPadding,
        children: const [
          OrbitSkeleton.block(height: 96),
          SizedBox(height: AppDimens.space12),
          OrbitSkeleton.block(height: 64),
          SizedBox(height: AppDimens.space12),
          OrbitSkeleton.block(height: 64),
        ],
      );
    }

    // 移动壳只引用自己的直接依赖：前端（桌面壳）条目在本端隐藏
    final rows = sortOssComponents(
      filterOssComponents(mobileVisibleOssComponents(components), _filter),
      _sort,
    );
    return ListView.builder(
      padding: _listPadding,
      itemCount: rows.isEmpty ? 2 : rows.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppDimens.space12),
            child: _buildFilters(),
          );
        }
        if (rows.isEmpty) {
          return const SizedBox(
            height: 220,
            child: EmptyState(icon: OrbitIcons.code, message: '没有符合当前来源的组件'),
          );
        }
        final component = rows[index - 1];
        return _ComponentTile(
          component: component,
          edge: OrbitCardEdge.of(index - 1, rows.length),
          onTap: () => context.push(
            '/about/oss-components/detail?name=${Uri.encodeQueryComponent(component.name)}',
          ),
        );
      },
    );
  }

  Widget _buildFilters() {
    return OrbitSettingsGroup.rows(
      title: '筛选与排序',
      // 列表页自身已按 12 留边：卡片外边距归零，避免叠成 24 比列表窄一圈
      outerPadding: EdgeInsets.zero,
      children: [
        OrbitDropdownPreference<OssSourceFilter>(
          title: '来源',
          current: _filter,
          items: const [
            SelectItem(value: OssSourceFilter.all, label: '全部来源'),
            SelectItem(value: OssSourceFilter.rust, label: 'Rust'),
            SelectItem(value: OssSourceFilter.flutter, label: 'Flutter'),
          ],
          onSelect: (value) => setState(() => _filter = value),
        ),
        // 本组两行都没有行首图标槽：分隔线按行标题 16 缩进（不是设置页的 56）
        const OrbitGroupDivider(),
        OrbitDropdownPreference<OssSort>(
          title: '排序',
          current: _sort,
          items: const [
            SelectItem(value: OssSort.defaultOrder, label: '默认排序'),
            SelectItem(value: OssSort.nameAsc, label: '名称 A→Z'),
            SelectItem(value: OssSort.nameDesc, label: '名称 Z→A'),
            SelectItem(value: OssSort.source, label: '按来源'),
          ],
          onSelect: (value) => setState(() => _sort = value),
        ),
      ],
    );
  }
}

class _ComponentTile extends StatelessWidget {
  const _ComponentTile({
    required this.component,
    required this.edge,
    required this.onTap,
  });

  final OssComponentInfo component;
  final OrbitCardEdge edge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return InkWell(
      onTap: onTap,
      child: OrbitCardSegment(
        edge: edge,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.space16,
            vertical: AppDimens.space12,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      component.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: colors.titleText,
                      ),
                    ),
                    if (component.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        component.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: colors.secondaryText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppDimens.space12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ossSourceLabel(component.source),
                    style: TextStyle(
                      fontSize: 12,
                      color: OrbitAccents.themeAccent,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'v${component.version}',
                    style: TextStyle(fontSize: 11, color: colors.secondaryText),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
