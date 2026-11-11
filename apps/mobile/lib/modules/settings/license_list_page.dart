import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_group_card.dart';
import '../../shared/widgets/shadcn/orbit_list_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import 'license_registry.dart';

/// 开源许可列表页 /about/licenses
///
/// 数据来自 Flutter 的 `LicenseRegistry`（构建期打进的第三方许可），按包名
/// 聚合后以与「开源组件」页同款的分段卡片展示；点包名进入许可全文。
class LicenseListPage extends StatefulWidget {
  const LicenseListPage({super.key, this.licenseStream});

  /// 可选许可流（测试注入）；缺省读系统 [LicenseRegistry.licenses]
  final Stream<LicenseEntry>? licenseStream;

  @override
  State<LicenseListPage> createState() => _LicenseListPageState();
}

class _LicenseListPageState extends State<LicenseListPage> {
  /// null = 加载中
  List<LicensePackage>? _packages;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await (widget.licenseStream ?? LicenseRegistry.licenses)
          .toList();
      if (!mounted) return;
      setState(() {
        _packages = groupLicenses(entries);
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
            child: OrbitPageHeader(title: '开源许可'),
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
              icon: OrbitIcons.fileText,
              message: '开源许可加载失败，请稍后重试。',
              actionLabel: '重试',
              onAction: _load,
            ),
          ),
        ],
      );
    }
    final packages = _packages;
    if (packages == null) {
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
    if (packages.isEmpty) {
      return ListView(
        padding: _listPadding,
        children: const [
          SizedBox(
            height: 240,
            child: EmptyState(icon: OrbitIcons.fileText, message: '未找到开源许可记录'),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: _listPadding,
      itemCount: packages.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppDimens.space12),
            child: _BrandCard(packageCount: packages.length),
          );
        }
        final package = packages[index - 1];
        return _LicenseTile(
          package: package,
          edge: OrbitCardEdge.of(index - 1, packages.length),
          onTap: () => context.push(
            '/about/licenses/detail?name=${Uri.encodeQueryComponent(package.name)}',
          ),
        );
      },
    );
  }
}

/// 顶部品牌卡（对应系统许可页的「循迹 / Powered by Flutter」）
class _BrandCard extends StatelessWidget {
  const _BrandCard({required this.packageCount});

  final int packageCount;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return OrbitGroupCard(
      // 列表页自身已按 12 留边：卡片外边距归零，避免叠成 24 比列表窄一圈
      outerPadding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppDimens.cardPadding),
          child: Column(
            children: [
              Image.asset(
                'assets/app_icon.png',
                width: AppDimens.splashLogoSize,
                height: AppDimens.splashLogoSize,
              ),
              const SizedBox(height: AppDimens.space8),
              Text(
                '循迹',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  color: colors.titleText,
                ),
              ),
              const SizedBox(height: AppDimens.space4),
              Text(
                'Powered by Flutter',
                style: TextStyle(fontSize: 13, color: colors.secondaryText),
              ),
              const SizedBox(height: AppDimens.space8),
              Text(
                '共 $packageCount 个开源包',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LicenseTile extends StatelessWidget {
  const _LicenseTile({
    required this.package,
    required this.edge,
    required this.onTap,
  });

  final LicensePackage package;
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
            children: [
              Expanded(
                child: Text(
                  package.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: colors.titleText,
                  ),
                ),
              ),
              const SizedBox(width: AppDimens.space12),
              Text(
                '${package.licenseCount} 项许可',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
              const SizedBox(width: AppDimens.space8),
              Icon(OrbitIcons.chevronRight, size: 16, color: colors.iconText),
            ],
          ),
        ),
      ),
    );
  }
}
