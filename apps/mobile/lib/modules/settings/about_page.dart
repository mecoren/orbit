import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../core/theme/icon_map.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';

/// 关于页 /about（设置页关于卡入口）
///
/// 三分区：品牌 + 版本（package_info_plus 真实构建版本，不硬编码）+
/// 更新日志（与 CHANGELOG.md / changelog.ts 同源要点）+
/// 开源许可（showLicensePage 系统许可页）。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '…';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _version = '${info.version}+${info.buildNumber}');
      }
    }).catchError((_) {});
  }

  static const _changelog = <Map<String, String>>[
    {
      'version': 'Unreleased',
      'summary': '移动端补齐：FRB 桥 10 函数缺口、筛选器七键抽屉、详情关联搜索、附件拍照、外观三态、通知历史、关于页真实版本',
    },
    {
      'version': '0.1.0（2026-09-19）',
      'summary': '首个版本：本地优先 + 端到端加密的跨平台待办——双端全功能、云同步/备份、附件、统计与 ICS/CSV 数据出口一次到位',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top +
                    OrbitPageHeader.rowHeight +
                    AppDimens.space16,
                left: AppDimens.pageInline,
                right: AppDimens.pageInline,
                bottom:
                    AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                Column(
                  children: [
                    Text(
                      '循迹',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: colors.titleText,
                      ),
                    ),
                    const SizedBox(height: AppDimens.space8),
                    Text(
                      'Orbit · 本地优先的待办与知识库',
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.secondaryText,
                      ),
                    ),
                    const SizedBox(height: AppDimens.space4),
                    Text(
                      '版本 $_version',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.secondaryText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppDimens.space16),
                SectionCard(
                  title: '更新日志',
                  child: Column(
                    children: [
                      for (var i = 0; i < _changelog.length; i++) ...[
                        if (i > 0)
                          const SizedBox(height: AppDimens.space8),
                        OrbitCard(
                          fillColor: colors.surfaceSecondary,
                          padding:
                              const EdgeInsets.all(AppDimens.space12),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                _changelog[i]['version']!,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _changelog[i]['summary']!,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.bodyText,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.cardGap),
                SectionCard(
                  title: '开源许可',
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => showLicensePage(context: context),
                      icon: const Icon(OrbitIcons.fileText, size: 18),
                      label: const Text('查看开源许可'),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: AppDimens.space16),
                  child: Center(
                    child: Text(
                      '数据经端到端同步加密，仅你持有密钥。',
                      style: TextStyle(
                        fontSize: 12,
                        color: OrbitAccents.themeAccent
                            .withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '关于',
            ),
          ),
        ],
      ),
    );
  }
}
