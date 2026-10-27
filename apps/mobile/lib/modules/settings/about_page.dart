import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../core/theme/icon_map.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'update_check.dart';

/// 关于页 /about（设置页关于卡入口）
///
/// 三分区：品牌 + 版本（package_info_plus 真实构建版本，不硬编码）+
/// 更新日志（与 CHANGELOG.md / changelog.ts 同源要点）+
/// 开源许可（showLicensePage 系统许可页）。
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  String _version = '…';

  /// 纯版本号（不带 build 号），用于与发布清单比较
  String _currentVersion = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((info) {
          if (!mounted) return;
          setState(() {
            _version = '${info.version}+${info.buildNumber}';
            _currentVersion = info.version;
          });
        })
        .catchError((_) {});
  }

  /// 检查更新（#107）：只在点击时请求一次；有新版本给「打开发布页」，
  /// 失败同样给发布页兜底——不做静默轮询、不下载安装包。
  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await ref.read(orbitBridgeProvider).checkLatestRelease();
      if (!mounted) return;
      if (isNewerVersion(info.version, _currentVersion)) {
        final notes = info.notes?.trim() ?? '';
        final ok = await showConfirmBottomSheet(
          context,
          title: '发现新版本 ${info.version}',
          message: [
            if (info.pubDate != null && info.pubDate!.isNotEmpty)
              '发布于 ${info.pubDate}',
            notes.isNotEmpty ? notes : '前往发布页查看更新说明与下载。',
          ].join('\n\n'),
          confirmLabel: '打开发布页',
        );
        if (ok == true && mounted) {
          await launchUrl(
            Uri.parse(info.downloadUrl),
            mode: LaunchMode.externalApplication,
          );
        }
      } else {
        WaitToast.info('已是最新版本（$_currentVersion）');
      }
    } catch (_) {
      if (!mounted) return;
      final ok = await showConfirmBottomSheet(
        context,
        title: '检查更新失败',
        message: '网络不可用或发布清单暂不可达，可前往发布页手动查看最新版本。',
        confirmLabel: '打开发布页',
      );
      if (ok == true && mounted) {
        await launchUrl(
          Uri.parse('https://github.com/mecoren/orbit/releases/latest'),
          mode: LaunchMode.externalApplication,
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 最近版本要点（与仓库 CHANGELOG.md 同源；发版时同步更新，
  /// 不写「Unreleased」——关于页是用户可见的已发布说明）
  static const _changelog = <Map<String, String>>[
    {
      'version': '0.6.0（2026-10-26）',
      'summary':
          '平板/横屏适配、强调色自定义、存储清理（未使用附件/过期回收站）、'
          '检查更新、保存筛选器编辑与窗口化下推',
    },
    {
      'version': '0.1.0（2026-09-19）',
      'summary':
          '首个版本：本地优先 + 端到端加密的跨平台待办——双端全功能、云同步/备份、附件、统计与 ICS/CSV 数据出口一次到位',
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
                top:
                    MediaQuery.of(context).padding.top +
                    OrbitPageHeader.rowHeight +
                    AppDimens.space16,
                left: AppDimens.pageInline,
                right: AppDimens.pageInline,
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
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
                    const SizedBox(height: AppDimens.space4),
                    TextButton.icon(
                      onPressed: _checking ? null : _checkUpdate,
                      icon: _checking
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(OrbitIcons.refresh, size: 16),
                      label: Text(_checking ? '检查中…' : '检查更新'),
                    ),
                  ],
                ),
                const SizedBox(height: AppDimens.space16),
                SectionCard(
                  title: '更新日志',
                  child: Column(
                    children: [
                      for (var i = 0; i < _changelog.length; i++) ...[
                        if (i > 0) const SizedBox(height: AppDimens.space8),
                        OrbitCard(
                          fillColor: colors.surfaceSecondary,
                          padding: const EdgeInsets.all(AppDimens.space12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                        color: OrbitAccents.themeAccent.withValues(alpha: 0.9),
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
            child: OrbitPageHeader(title: '关于'),
          ),
        ],
      ),
    );
  }
}
