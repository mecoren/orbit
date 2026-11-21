import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../core/theme/icon_map.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../services/app_update_service.dart';
import '../../shared/widgets/shadcn/orbit_arrow_tile.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_settings_group.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_button.dart';
import 'update_check.dart';
import 'update_download_sheet.dart';

/// 关于页 /about（设置页关于卡入口）
///
/// 三分区：品牌 + 版本（package_info_plus 真实构建版本，不硬编码）+
/// 更新日志（只留一行入口，点进 /about/changelog 看版本列表、再点看明细；
/// 数据源在 orbit-core，与桌面同一份）+
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

  /// 检查更新（#107）：只在点击时请求一次；Android 有新版本时走应用内
  /// 下载 APK + 系统安装器，其余平台仍打开发布页——不做静默轮询、不静默安装。
  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await ref.read(orbitBridgeProvider).checkLatestRelease();
      if (!mounted) return;
      if (isNewerVersion(info.version, _currentVersion)) {
        final notes = info.notes?.trim() ?? '';
        final canInstallInApp = Platform.isAndroid && info.apkUrl.isNotEmpty;
        final ok = await showConfirmBottomSheet(
          context,
          title: '发现新版本 ${info.version}',
          message: [
            if (info.pubDate != null && info.pubDate!.isNotEmpty)
              '发布于 ${info.pubDate}',
            notes.isNotEmpty ? notes : '前往发布页查看更新说明与下载。',
            if (canInstallInApp) '确认后在本应用内下载 APK 并调起系统安装器。',
          ].join('\n\n'),
          confirmLabel: canInstallInApp ? '下载并安装' : '打开发布页',
        );
        if (ok == true && mounted) {
          if (canInstallInApp) {
            await _downloadAndInstall(info);
          } else {
            await launchUrl(
              Uri.parse(info.downloadUrl),
              mode: LaunchMode.externalApplication,
            );
          }
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

  /// Android 应用内更新：权限闸门 → 下载进度弹层 → 系统安装器。
  ///
  /// 安装确认由系统接管（Android 不允许静默安装）；任何一步失败都把发布页
  /// 作为兜底出口，保持与桌面端 `update-fallback` 同一诚实口径。
  Future<void> _downloadAndInstall(UpdateInfo info) async {
    void fallback() {
      WaitToast.global(
        '更新未能完成',
        variant: WaitToastVariant.warning,
        description: '可前往发布页手动下载安装包。',
        actionLabel: '发布页',
        onAction: () => launchUrl(
          Uri.parse(info.downloadUrl),
          mode: LaunchMode.externalApplication,
        ),
      );
    }

    try {
      final granted = await AppUpdateService.canInstallPackages();
      if (!mounted) return;
      if (!granted) {
        final go = await showConfirmBottomSheet(
          context,
          title: '需要安装权限',
          message:
              '系统尚未允许「循迹」安装应用。请在设置中开启「安装未知应用」，'
              '回到本页重新检查更新即可继续。',
          confirmLabel: '去设置',
        );
        if (go == true && mounted) {
          await AppUpdateService.openInstallPermissionSettings();
        }
        return;
      }

      final path = await showApkDownloadSheet(
        context,
        version: info.version,
        url: Uri.parse(info.apkUrl),
      );
      if (path == null || !mounted) return;

      final install = await showConfirmBottomSheet(
        context,
        title: '下载完成',
        message:
            '${info.version} 安装包已就绪。安装过程由系统接管，'
            '本应用可能被系统关闭，数据不受影响。',
        confirmLabel: '立即安装',
      );
      if (install != true || !mounted) return;

      final started = await AppUpdateService.installApk(path);
      if (!started && mounted) fallback();
    } catch (_) {
      if (mounted) fallback();
    }
  }

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
                // 卡片自带 h:12 外距（OrbitSettingsGroup），列表不加水平边距
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                Column(
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
                    OrbitButton.icon(
                      variant: OrbitButtonVariant.text,
                      onPressed: _checking ? null : _checkUpdate,
                      icon: _checking
                          ? const OrbitSpinner(size: 14)
                          : const Icon(OrbitIcons.refresh, size: 16),
                      label: Text(_checking ? '检查中…' : '检查更新'),
                    ),
                  ],
                ),
                const SizedBox(height: AppDimens.space16),
                OrbitSettingsGroup(
                  title: '更新日志',
                  // 行自带 16 水平内边距：按压灰底要横贯整卡（设置页档位行同
                  // 口径）。内容行贴底，卡片圆角统一裁切。
                  padding: EdgeInsets.zero,
                  child: OrbitArrowTile(
                    title: '查看历史版本',
                    onClick: () => context.push('/about/changelog'),
                  ),
                ),
                const SizedBox(height: AppDimens.cardGap),
                OrbitSettingsGroup(
                  title: '开源组件',
                  padding: EdgeInsets.zero,
                  child: OrbitArrowTile(
                    title: '查看开源组件',
                    onClick: () => context.push('/about/oss-components'),
                  ),
                ),
                const SizedBox(height: AppDimens.cardGap),
                OrbitSettingsGroup(
                  title: '开源许可',
                  padding: EdgeInsets.zero,
                  child: OrbitArrowTile(
                    title: '查看开源许可',
                    onClick: () => context.push('/about/licenses'),
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
