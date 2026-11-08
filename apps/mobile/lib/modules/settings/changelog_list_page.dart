import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_list_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';

/// 更新日志列表页 /about/changelog
///
/// 版式对齐待办列表（[OrbitCardSegment] 分段卡）：每行 = 版本号标题 +
/// 摘要副标 + 右侧发布日期/条目数，行间 1px 分隔线，首末段各自圆角。
/// 点击进入 `/about/changelog/:version` 看逐条明细（明细页版式对齐
/// 任务详情页）。
///
/// 数据源在 orbit-core（`changelog_versions`），与桌面同一份；壳层只渲染。
class ChangelogListPage extends ConsumerStatefulWidget {
  const ChangelogListPage({super.key});

  @override
  ConsumerState<ChangelogListPage> createState() => _ChangelogListPageState();
}

class _ChangelogListPageState extends ConsumerState<ChangelogListPage> {
  /// null = 加载中
  List<ChangelogVersionInfo>? _versions;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final versions = await ref.read(orbitBridgeProvider).changelogVersions();
      if (!mounted) return;
      setState(() => _versions = versions);
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
            // 平板：限宽水平居中（与任务详情/列表页同口径）
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
            child: OrbitPageHeader(title: '更新日志'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_failed) {
      return ListView(
        padding: _listPadding,
        children: const [
          SizedBox(
            height: 240,
            child: EmptyState(
              icon: OrbitIcons.fileText,
              message: '更新日志加载失败，请重启应用后重试。',
            ),
          ),
        ],
      );
    }
    final versions = _versions;
    if (versions == null) {
      return const _ChangelogSkeleton();
    }
    if (versions.isEmpty) {
      return ListView(
        padding: _listPadding,
        children: const [
          SizedBox(
            height: 240,
            child: EmptyState(icon: OrbitIcons.fileText, message: '暂无更新日志'),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: _listPadding,
      itemCount: versions.length,
      itemBuilder: (context, index) {
        final version = versions[index];
        return _VersionTile(
          version: version,
          edge: OrbitCardEdge.of(index, versions.length),
          onTap: () => context.push('/about/changelog/${version.version}'),
        );
      },
    );
  }
}

/// 加载骨架（2026-11-08 抽出）：整屏单路呼吸 ticker，共享同相位
///（口径同任务列表 `_TaskListSkeleton`）
class _ChangelogSkeleton extends StatefulWidget {
  const _ChangelogSkeleton();

  @override
  State<_ChangelogSkeleton> createState() => _ChangelogSkeletonState();
}

class _ChangelogSkeletonState extends State<_ChangelogSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AppMotion.skeletonPulse,
  )..repeat(reverse: true);

  late final Animation<double> _pulse = Tween<double>(begin: 0.45, end: 1.0)
      .animate(CurvedAnimation(parent: _ctrl, curve: AppMotion.breathe));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top:
            MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space16,
        left: AppDimens.space12,
        right: AppDimens.space12,
      ),
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(height: AppDimens.space12),
          OrbitSkeleton.block(height: 64, borderRadius: 12, pulse: _pulse),
        ],
      ],
    );
  }
}

/// 版本行（待办列表同款：卡片分段 + 标题/摘要左列 + 日期右列）
class _VersionTile extends StatelessWidget {
  const _VersionTile({
    required this.version,
    required this.edge,
    required this.onTap,
  });

  final ChangelogVersionInfo version;
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
          // 单行行也有完整热区高度（卡片里行高不随摘要有无跳动）
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
                      'v${version.version}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: colors.titleText,
                      ),
                    ),
                    if (version.summary.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        version.summary,
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
                    version.date,
                    style: TextStyle(
                      fontSize: 12,
                      color: OrbitAccents.themeAccent,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${version.changes.length} 项更新',
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
