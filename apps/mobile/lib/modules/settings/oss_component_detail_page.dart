import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_arrow_tile.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_group_card.dart';
import '../../shared/widgets/shadcn/orbit_info_row.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'oss_components_filter.dart';

/// 开源组件详情页 /about/oss-components/detail?name=…
///
/// 详情页只带组件名路由、自己回查静态清单（支持直接打开/深链）；未知组件
/// 给统一空态。版式对齐更新日志明细页：卡外 MiuixSmallTitle + 零内边距卡片 +
/// 行间左缩进分隔线。
class OssComponentDetailPage extends ConsumerStatefulWidget {
  const OssComponentDetailPage({super.key, required this.name});

  final String name;

  @override
  ConsumerState<OssComponentDetailPage> createState() =>
      _OssComponentDetailPageState();
}

class _OssComponentDetailPageState
    extends ConsumerState<OssComponentDetailPage> {
  /// null = 加载中
  List<OssComponentInfo>? _components;
  bool _failed = false;

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

  OssComponentInfo? _find() {
    for (final component in _components ?? const <OssComponentInfo>[]) {
      if (component.name == widget.name) return component;
    }
    return null;
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
            child: OrbitPageHeader(title: '组件详情'),
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
              message: '组件记录加载失败，请稍后重试。',
              actionLabel: '重试',
              onAction: _load,
            ),
          ),
        ],
      );
    }
    if (_components == null) {
      return ListView(
        padding: _listPadding,
        children: const [
          OrbitSkeleton.block(height: 96),
          SizedBox(height: AppDimens.space12),
          OrbitSkeleton.block(height: 160),
        ],
      );
    }
    final component = _find();
    if (component == null) {
      return ListView(
        padding: _listPadding,
        children: const [
          SizedBox(
            height: 240,
            child: EmptyState(icon: OrbitIcons.code, message: '组件记录不存在或加载失败'),
          ),
        ],
      );
    }
    return _buildDetail(component);
  }

  Widget _buildDetail(OssComponentInfo component) {
    final colors = AppColors.ofContext(context);
    final repository = component.repository;
    final homepage = component.homepage;
    return ListView(
      padding: _listPadding,
      children: [
        OrbitGroupCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppDimens.cardPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    component.name,
                    style: TextStyle(
                      fontSize: 22,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                      color: colors.titleText,
                    ),
                  ),
                  const SizedBox(height: AppDimens.space12),
                  Wrap(
                    spacing: AppDimens.space8,
                    runSpacing: AppDimens.space8,
                    children: [
                      _Tag(text: ossSourceLabel(component.source)),
                      _Tag(text: 'v${component.version}'),
                      _Tag(text: component.license),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.space12),
        const MiuixSmallTitle('基础信息'),
        OrbitGroupCard(
          children: [
            _InfoRow(label: '来源', value: ossSourceLabel(component.source)),
            const OrbitGroupDivider(),
            _InfoRow(label: '版本', value: component.version),
            const OrbitGroupDivider(),
            _InfoRow(label: '许可证', value: component.license),
          ],
        ),
        if (component.description.isNotEmpty) ...[
          const SizedBox(height: AppDimens.space12),
          const MiuixSmallTitle('说明'),
          OrbitGroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.space16,
                  AppDimens.space12,
                  AppDimens.space16,
                  AppDimens.space16,
                ),
                child: Text(
                  component.description,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.6,
                    color: colors.bodyText,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (repository != null || homepage != null) ...[
          const SizedBox(height: AppDimens.space12),
          const MiuixSmallTitle('链接'),
          OrbitGroupCard(
            children: [
              if (repository != null)
                OrbitArrowTile(
                  title: '仓库',
                  summary: repository,
                  onClick: () => _open(repository),
                ),
              if (repository != null && homepage != null)
                const OrbitGroupDivider(),
              if (homepage != null)
                OrbitArrowTile(
                  title: '主页',
                  summary: homepage,
                  onClick: () => _open(homepage),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _open(String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) WaitToast.info('无法打开链接');
    } catch (_) {
      if (mounted) WaitToast.info('无法打开链接');
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
    child: InfoTile(label: label, value: value),
  );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space8,
        vertical: AppDimens.space4,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppShapes.radiusSmall),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: colors.secondaryText),
      ),
    );
  }
}
