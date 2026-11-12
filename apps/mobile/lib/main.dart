import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:progressive_background_blur/progressive_background_blur.dart';

import 'app.dart';
import 'data/api/rust_orbit_bridge.dart';
import 'data/providers/bridge_provider.dart';
import 'services/appearance.dart';
import 'services/local_prefs.dart';
import 'shared/widgets/shadcn/orbit_select_popup.dart';

/// Orbit 移动端入口
///
/// 启动序列（对齐 React 版 App.tsx 门控）：
/// intl 日期本地化数据 → FRB 运行时初始化 → 本机偏好/强调色 → 启动门控
/// （masterAuthHas? unlock : plaintext）。
///
/// 不锁屏幕方向（#107）：平板/横屏由 `OrbitBreakpoints` 断点驱动布局。
///
/// 桥接切换：默认注入 RustOrbitBridge（真 Rust 后端）；
/// 纯 UI 开发可用 `flutter run --dart-define=ORBIT_USE_MOCK_BRIDGE=true`
/// 切回内存 Mock（MockOrbitBridge，无需 Rust 工具链/NDK）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();
  // #107：不再锁竖屏。平板/横屏由 OrbitBreakpoints 断点驱动布局
  // （840dp 起非清单页常驻侧栏、详情/子列表/抽屉限宽、月历日格封顶）；
  // 360dp 竖屏保持原版式。有意不设 landscapeLeft/Right 白名单：
  // 折叠屏/分屏的旋转语义归系统。

  // 月历（table_calendar）与 zh_CN 日期格式依赖 intl 的语言数据，
  // 必须在 runApp 前装载完成，否则首帧日历会抛 LocaleDataException。
  // en_US 一并装载：intl 的默认 locale 是 en_US，未装载时 DateFormat 默认构造会报错。
  await initializeDateFormatting('zh_CN');
  await initializeDateFormatting('en_US');

  const useMock = bool.fromEnvironment('ORBIT_USE_MOCK_BRIDGE');
  if (!useMock) {
    await initRustBridge();
  }

  // 本机 UI 偏好（隐藏已完成等视图态）：首帧前载入，失败静默走默认值
  await LocalPrefs.load();

  // 强调色（#107）：首帧前写回 OrbitAccents，避免启动瞬间闪一次默认蓝
  Appearance.restoreAccent();

  // 图片解码缓存上限（内存收口 2026-09-25）：Flutter 默认 1000 张 / 100MB，
  // 附件图多的库来回浏览会把驻留顶高；解码侧已有 cacheWidth 降采样
  // （orbit_image_thumb / detail_screen），这里再给缓存总量封顶。
  PaintingBinding.instance.imageCache
    ..maximumSize = 300
    ..maximumSizeBytes = 60 << 20;

  // 页头渐进磨砂的 shader 预编译（建议 runApp 前调用，避免首帧出现模糊时
  // 同步编译卡顿）；Skia 后端内部自动跳过。加载失败静默降级为「不模糊」，
  // 不能把资源异常抛到根 zone 拖垮启动。
  unawaited(ProgressiveBlur.precache().catchError((_) {}));

  // 单选浮层贴着触发行弹出，靠「最近一次指针按下」定位。必须在首帧前装好
  // 全局指针路由：懒安装会漏掉触发本次弹层的那次按下（首开落到屏幕底部）。
  OrbitPointerAnchor.install();

  runApp(
    ProviderScope(
      overrides: [
        if (!useMock) orbitBridgeProvider.overrideWithValue(RustOrbitBridge()),
      ],
      child: const OrbitApp(),
    ),
  );
}

/// 全局错误兜底（PRIVACY.md §三「崩溃信息仅落本地」的移动端实现点）
///
/// 此前移动端没有任何全局 handler：框架异常/未捕获异步异常只进控制台，
/// 用户侧表现为「点了没反应/突然回到桌面」，报障时拿不到任何现场。
/// 这里统一落 `{应用数据目录}/crash.log`（1MB 上限，超限重建），
/// 不上报任何远端。
void _installErrorHandlers() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _appendCrashLog('flutter', details.exceptionAsString(), details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _appendCrashLog('async', '$error', stack);
    // 已记录并展示：返回 true 避免同一个异常被再次升级上报/终止
    return true;
  };
}

void _appendCrashLog(String kind, String message, StackTrace? stack) {
  final entry =
      '=== ${DateTime.now().toIso8601String()} [$kind] ===\n$message\n${stack ?? ''}\n\n';
  debugPrint('[crash] $entry');
  // 文件写入不阻塞 UI；失败只可能发生在磁盘不可写，此时控制台仍有记录
  unawaited(() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}crash.log');
      final exists = await file.exists();
      if (exists && await file.length() > 1024 * 1024) {
        await file.writeAsString(entry, flush: true);
      } else {
        await file.writeAsString(
          entry,
          mode: FileMode.append,
          flush: true,
        );
      }
    } catch (_) {
      // 崩溃留痕本身不能再抛（否则会在错误处理里递归）
    }
  }());
}
