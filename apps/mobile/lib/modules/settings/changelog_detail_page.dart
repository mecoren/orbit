import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_group_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';

/// 更新明细页 /about/changelog/:version
///
/// 版式对齐任务详情页（同构三件套：卡外 `MiuixSmallTitle` + 零内边距
/// [MiuixCard] 分组卡 + 行间左缩进分隔线）：
/// 标题区（版本号 + 发布日期）→ 信息（版本 / 发布日期 / 变更条目）→
/// 摘要 → 变更逐条（类别徽标 + 说明，类别口径与桌面更新日志同源）。
///
/// 路由只带版本号，页面自己回查 orbit-core 的静态日志（支持深链/重启恢复，
/// 不依赖上一页传对象）。
class ChangelogDetailPage extends ConsumerStatefulWidget {
  const ChangelogDetailPage({super.key, required this.version});

  /// 目标版本号（如 `0.1.0`，路由已剥掉 `v` 前缀以外的内容）
  final String version;

  @override
  ConsumerState<ChangelogDetailPage> createState() =>
      _ChangelogDetailPageState();
}

class _ChangelogDetailPageState extends ConsumerState<ChangelogDetailPage> {
  /// null = 加载中 / 未命中
  ChangelogVersionInfo? _entry;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final versions = await ref.read(orbitBridgeProvider).changelogVersions();
      ChangelogVersionInfo? entry;
      for (final v in versions) {
        if (v.version == widget.version) {
          entry = v;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _entry = entry;
        _failed = entry == null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            // 平板：详情限宽（与任务详情同口径，行宽不随屏宽无限拉伸）
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: OrbitBreakpoints.contentMaxWidth,
                ),
                child: _buildBody(entry),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: 'v${entry?.version ?? widget.version}',
            ),
          ),
        ],
      ),
    );
  }

  /// 内容区顶部让位：状态栏 + 页头 + 一档卡距
  EdgeInsets get _listPadding => EdgeInsets.only(
    top:
        MediaQuery.of(context).padding.top +
        OrbitPageHeader.rowHeight +
        AppDimens.space12,
    bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
  );

  Widget _buildBody(ChangelogVersionInfo? entry) {
    if (_loading) {
      return _ChangelogDetailSkeleton(padding: _listPadding);
    }
    if (_failed || entry == null) {
      return ListView(
        padding: _listPadding,
        children: const [
          SizedBox(
            height: 240,
            child: EmptyState(
              icon: OrbitIcons.fileText,
              message: '版本记录不存在或加载失败',
            ),
          ),
        ],
      );
    }
    return _buildDetail(entry);
  }

  Widget _buildDetail(ChangelogVersionInfo entry) {
    final colors = AppColors.ofContext(context);
    return ListView(
      padding: _listPadding,
      children: [
        // 一、标题区（无头卡：版本号 + 发布日期）
        OrbitGroupCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppDimens.cardPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'v${entry.version}',
                    style: TextStyle(
                      fontSize: 22,
                      height: 1.3,
                      color: colors.titleText,
                    ),
                  ),
                  const SizedBox(height: AppDimens.space4),
                  Text(
                    '发布于 ${entry.date}',
                    style: TextStyle(fontSize: 13, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.space12),
        // 二、信息（只读行：左标题 + 右值）
        const MiuixSmallTitle('信息'),
        OrbitGroupCard(
          children: [
            _InfoRow(label: '版本', value: 'v${entry.version}'),
            const OrbitGroupDivider(),
            _InfoRow(label: '发布日期', value: entry.date),
            const OrbitGroupDivider(),
            _InfoRow(label: '变更条目', value: '${entry.changes.length} 项'),
          ],
        ),
        const SizedBox(height: AppDimens.space12),
        // 三、摘要
        const MiuixSmallTitle('摘要'),
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
                entry.summary.isEmpty ? '本版本未提供摘要。' : entry.summary,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: entry.summary.isEmpty
                      ? colors.secondaryText
                      : colors.bodyText,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.space12),
        // 四、变更逐条（类别徽标 + 说明）
        MiuixSmallTitle('变更（${entry.changes.length} 项）'),
        OrbitGroupCard(
          children: [
            if (entry.changes.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.space16,
                  AppDimens.space12,
                  AppDimens.space16,
                  AppDimens.space16,
                ),
                child: Text(
                  '本版本未逐条记录变更。',
                  style: TextStyle(fontSize: 15, color: colors.secondaryText),
                ),
              )
            else
              for (var i = 0; i < entry.changes.length; i++) ...[
                if (i > 0) const OrbitGroupDivider(),
                _ChangeRow(change: entry.changes[i]),
              ],
          ],
        ),
      ],
    );
  }
}

/// 加载骨架（2026-11-08 抽出）：整屏单路呼吸 ticker，共享同相位
///（口径同任务列表 `_TaskListSkeleton`）
class _ChangelogDetailSkeleton extends StatefulWidget {
  const _ChangelogDetailSkeleton({required this.padding});

  final EdgeInsetsGeometry padding;

  @override
  State<_ChangelogDetailSkeleton> createState() =>
      _ChangelogDetailSkeletonState();
}

class _ChangelogDetailSkeletonState extends State<_ChangelogDetailSkeleton>
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
    Widget block(double height) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
      child: OrbitSkeleton.block(
        height: height,
        borderRadius: 14,
        pulse: _pulse,
      ),
    );
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: widget.padding,
      children: [
        block(96),
        const SizedBox(height: AppDimens.space12),
        block(144),
        const SizedBox(height: AppDimens.space12),
        block(96),
      ],
    );
  }
}

/// 只读信息行：左标题 + 右值（无箭头——这里没有可切换的档位）
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space16,
          vertical: AppDimens.space12,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: colors.bodyText),
              ),
            ),
            const SizedBox(width: AppDimens.space12),
            Text(
              value,
              style: TextStyle(fontSize: 14, color: colors.secondaryText),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条变更：类别徽标 + 说明（徽标口径对齐桌面更新日志 Badge）
class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change});

  final ChangelogEntryInfo change;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space16,
        vertical: AppDimens.space12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 徽标文字 11sp、正文 15sp：顶对齐时徽标下沉半个字高才与首行同中线
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _CategoryBadge(category: change.category),
          ),
          const SizedBox(width: AppDimens.space8),
          Expanded(
            child: Text(
              change.description,
              style: TextStyle(
                fontSize: 15,
                height: 1.45,
                color: colors.bodyText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 变更类别徽标（feature/fix/refactor/chore → 新增/修复/优化/其他）
///
/// 配色与桌面 `CHANGE_CATEGORY_STYLE` 同口径：新增蓝、修复红、优化灰、
/// 其他描边灰；未知类别原样显示串值（数据侧新增类别时不至于渲染成空白）。
class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final String label;
    final Color fg;
    final Color bg;
    final Color? border;
    switch (category) {
      case 'feature':
        label = '新增';
        fg = OrbitAccents.todoAccent;
        bg = OrbitAccents.todoAccent.withValues(alpha: 0.12);
        border = null;
      case 'fix':
        label = '修复';
        fg = colors.destructive;
        bg = colors.destructive.withValues(alpha: 0.12);
        border = null;
      case 'refactor':
        label = '优化';
        fg = colors.secondaryText;
        bg = colors.surfaceSecondary;
        border = null;
      case 'chore':
        label = '其他';
        fg = colors.secondaryText;
        bg = Colors.transparent;
        border = colors.outline;
      default:
        label = category;
        fg = colors.secondaryText;
        bg = colors.surfaceSecondary;
        border = null;
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 38),
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.space8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppShapes.xs,
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }
}
