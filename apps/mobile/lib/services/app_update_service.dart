import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 应用内 Android 更新：下载 APK → 调起系统安装器。
///
/// **为什么在壳层**：这一层全是平台能力——应用缓存目录落盘、Android 的
/// 「安装未知应用」权限、FileProvider content:// 与安装器 Intent。版本检查
/// 与版本比较仍在 core（`update_api` / `check_latest_release`），下载地址由
/// 清单的 `apk_url` 给出，本文件不做任何版本判断。
///
/// 口径（对齐 `docs/08` §3.5 的手动更新边界）：
/// - 只在用户确认「下载并安装」后发一次请求，不后台轮询、不静默安装；
/// - 下载写 `getTemporaryDirectory()/update/`（FileProvider 白名单只放这层），
///   每次开始前清掉旧包，避免多版本堆积；
/// - 交给系统安装器即返回，安装确认与签名校验归 Android 系统。
class AppUpdateService {
  AppUpdateService._();

  static const MethodChannel _channel = MethodChannel('orbit/update_install');

  /// APK 下载子目录（与 `res/xml/file_paths.xml` 的 `cache-path path="update/"` 对齐）
  static const String downloadDirName = 'update';

  /// Android 8.0+ 是否已允许本应用安装未知应用
  static Future<bool> canInstallPackages() async {
    final ok = await _channel.invokeMethod<bool>('canInstallPackages');
    return ok ?? false;
  }

  /// 跳转本应用的「安装未知应用」授权页（由用户手动开启）
  static Future<void> openInstallPermissionSettings() =>
      _channel.invokeMethod<void>('openInstallPermissionSettings');

  /// 把已下载的 APK 交给系统安装器；返回是否成功拉起
  static Future<bool> installApk(String filePath) async {
    final ok = await _channel.invokeMethod<bool>('installApk', {
      'filePath': filePath,
    });
    return ok ?? false;
  }

  /// 下载 APK 到应用缓存，返回落盘文件。
  ///
  /// [onProgress] 已按 ~200ms 节流（`total` 未知时为 -1）；[cancel] 可中途取消，
  /// 取消会抛 [UpdateDownloadCancelled]，调用方按「用户主动取消」静默处理。
  static Future<File> downloadApk({
    required Uri url,
    required String version,
    required UpdateDownloadCancel cancel,
    required void Function(int received, int total) onProgress,
  }) async {
    if (cancel.isCancelled) throw const UpdateDownloadCancelled();
    final cache = await getTemporaryDirectory();
    final dir = Directory(
      '${cache.path}${Platform.pathSeparator}$downloadDirName',
    );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
    final target = File(
      '${dir.path}${Platform.pathSeparator}${apkFileName(version)}',
    );
    final part = File('${target.path}.part');

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(minutes: 2);
    cancel._bind(client);

    IOSink? sink;
    var sinkClosed = false;
    try {
      if (cancel.isCancelled) throw const UpdateDownloadCancelled();
      final request = await client.getUrl(url);
      request.followRedirects = true;
      request.maxRedirects = 10;
      request.headers.set(HttpHeaders.userAgentHeader, 'orbit-android-updater');
      request.headers.set(HttpHeaders.acceptHeader, '*/*');

      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      sink = part.openWrite();

      var received = 0;
      final throttle = _ProgressThrottle();
      await for (final chunk in response) {
        if (cancel.isCancelled) throw const UpdateDownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        if (throttle.shouldReport()) onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      sinkClosed = true;
      sink = null;

      if (cancel.isCancelled) throw const UpdateDownloadCancelled();
      // 只判「少于声明长度」：透明解压时字节数可能大于 contentLength，
      // 压缩场景不应误判；截断则必然小于。
      if (total > 0 && received < total) {
        throw AppUpdateException('下载不完整（$received/$total 字节）');
      }
      if (!await _looksLikeApk(part)) {
        throw const AppUpdateException('下载内容不是有效 APK');
      }
      onProgress(received, total);
      return await part.rename(target.path);
    } catch (e) {
      // 取消时 HttpClient 被强制关闭，底层会抛 HttpException/SocketException：
      // 统一归一成「用户取消」，不让 UI 弹失败提示。
      if (cancel.isCancelled) throw const UpdateDownloadCancelled();
      rethrow;
    } finally {
      if (!sinkClosed) {
        try {
          await sink?.close();
        } catch (_) {
          /* 异常路径下的收尾失败无需上抛 */
        }
      }
      cancel._unbind();
      client.close(force: true);
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {
          /* 缓存目录清理失败不影响下一次下载（开始前会整目录重建） */
        }
      }
    }
  }

  /// APK 是 zip，开头应为 `PK\x03\x04`（防 302/HTML 错误页被当安装包）
  static Future<bool> _looksLikeApk(File file) async {
    if (!await file.exists() || await file.length() < 4) return false;
    final reader = await file.open();
    try {
      final header = await reader.read(4);
      return header.length == 4 &&
          header[0] == 0x50 &&
          header[1] == 0x4B &&
          header[2] == 0x03 &&
          header[3] == 0x04;
    } finally {
      await reader.close();
    }
  }
}

/// 下载取消令牌（用户离开进度弹层 / 点「取消下载」）
class UpdateDownloadCancel {
  bool _cancelled = false;
  HttpClient? _client;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    // 强制关闭底层连接：await-for 立即结束，不必等当前分片到齐
    _client?.close(force: true);
  }

  void _bind(HttpClient client) => _client = client;

  void _unbind() => _client = null;
}

/// 用户主动取消下载（调用方静默处理，不弹失败提示）
class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
}

/// 下载/安装前的可展示错误（HTTP 状态、不完整、非 APK）
class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下载进度节流：默认 200ms 上报一次，避免 setState 每分片触发
class _ProgressThrottle {
  final Stopwatch _watch = Stopwatch()..start();
  int _lastReportMs = -200;

  bool shouldReport() {
    final now = _watch.elapsedMilliseconds;
    if (now - _lastReportMs < 200) return false;
    _lastReportMs = now;
    return true;
  }
}

/// APK 落盘文件名（`Orbit_<ver>.apk`，与 Release 资产命名同口径）。
///
/// 版本串来自网络清单，必须净化后再拼路径：拒绝分隔符与 `..`，
/// 否则异常清单可把文件写出缓存目录。
String apkFileName(String version) {
  final safe = version
      .trim()
      .replaceFirst(RegExp(r'^[vV]'), '')
      .replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_')
      .replaceAll('..', '_');
  final normalized = safe.isEmpty ? 'unknown' : safe;
  return 'Orbit_$normalized.apk';
}

/// 字节数 → 人类可读（进度副文案；1 位小数足够，避免频繁跳字）
String formatDownloadBytes(int bytes) {
  if (bytes < 0) return '未知大小';
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
