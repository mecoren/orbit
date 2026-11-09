import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../shared/widgets/shadcn/orbit_empty_state.dart';
import '../../shared/widgets/shadcn/orbit_group_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import 'license_registry.dart';

/// 开源许可全文页 /about/licenses/detail?name=…
///
/// 包名走查询参数（第三方包名可能含斜杠等字符），详情自己回查
/// `LicenseRegistry` 以支持直接打开；段落按系统许可页口径缩进/居中。
class LicenseDetailPage extends StatefulWidget {
  const LicenseDetailPage({super.key, required this.name, this.licenseStream});

  final String name;

  /// 可选许可流（测试注入）；缺省读系统 [LicenseRegistry.licenses]
  final Stream<LicenseEntry>? licenseStream;

  @override
  State<LicenseDetailPage> createState() => _LicenseDetailPageState();
}

class _LicenseDetailPageState extends State<LicenseDetailPage> {
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

  LicensePackage? _find() {
    for (final package in _packages ?? const <LicensePackage>[]) {
      if (package.name == widget.name) return package;
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
            child: OrbitPageHeader(title: '许可详情'),
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
              message: '许可记录加载失败，请稍后重试。',
              actionLabel: '重试',
              onAction: _load,
            ),
          ),
        ],
      );
    }
    if (_packages == null) {
      return ListView(
        padding: _listPadding,
        children: const [
          OrbitSkeleton.block(height: 96),
          SizedBox(height: AppDimens.space12),
          OrbitSkeleton.block(height: 200),
        ],
      );
    }
    final package = _find();
    if (package == null) {
      return ListView(
        padding: _listPadding,
        children: const [
          SizedBox(
            height: 240,
            child: EmptyState(
              icon: OrbitIcons.fileText,
              message: '许可记录不存在或加载失败',
            ),
          ),
        ],
      );
    }
    return _buildDetail(package);
  }

  Widget _buildDetail(LicensePackage package) {
    final colors = AppColors.ofContext(context);
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
                    package.name,
                    style: TextStyle(
                      fontSize: 22,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                      color: colors.titleText,
                    ),
                  ),
                  const SizedBox(height: AppDimens.space4),
                  Text(
                    '${package.licenseCount} 项许可',
                    style: TextStyle(fontSize: 13, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
          ],
        ),
        for (var i = 0; i < package.entries.length; i++) ...[
          const SizedBox(height: AppDimens.space12),
          MiuixSmallTitle(package.entries.length > 1 ? '许可 ${i + 1}' : '许可全文'),
          OrbitGroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.space16,
                  AppDimens.space12,
                  AppDimens.space16,
                  AppDimens.space16,
                ),
                child: _LicenseBody(entry: package.entries[i]),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _LicenseBody extends StatelessWidget {
  const _LicenseBody({required this.entry});

  final LicenseEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final paragraphs = entry.paragraphs.toList();
    if (paragraphs.isEmpty) {
      return Text(
        '该许可未提供正文。',
        style: TextStyle(fontSize: 13, color: colors.secondaryText),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: AppDimens.space8),
          _paragraph(paragraphs[i], colors),
        ],
      ],
    );
  }

  Widget _paragraph(LicenseParagraph paragraph, AppColorSet colors) {
    final text = paragraph.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    final centered = isCenteredLicenseParagraph(paragraph);
    final style = TextStyle(
      fontSize: 13,
      height: 1.6,
      color: centered ? colors.secondaryText : colors.bodyText,
    );
    final content = centered
        ? Text(text, textAlign: TextAlign.center, style: style)
        : SelectableText(text, style: style);

    return Padding(
      padding: EdgeInsets.only(left: licenseParagraphIndent(paragraph)),
      child: content,
    );
  }
}
