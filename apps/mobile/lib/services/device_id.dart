import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// 设备 ID 持久化（对齐桌面 ensureDeviceId：DB 初始化后必须调用
/// dbSetDeviceId 写入 Rust OnceCell，generic_repo 的 device_id 自动填充
/// 与同步引擎 validate_config(device_id 非空) 均依赖此值——移动端此前
/// 缺失该接线，云同步在移动端必然报「device_id 不能为空」失败）。
///
/// 持久化载体：应用支持目录下 device_id.txt（进程外文件，清库不清除）。
class DeviceIdStore {
  static const _fileName = 'device_id.txt';

  /// 读取或首次生成设备 ID（UUID v4）。
  /// 无 path_provider handler 的环境（纯 Dart 单测）抛 MissingPluginException
  /// ——向上传播由调用方兜底（BootGate 静默不阻断启动）。
  static Future<String> ensure() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
    try {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    } catch (_) {
      /* 文件不存在：首次生成 */
    }
    final id = _uuidV4();
    await file.writeAsString(id, flush: true);
    return id;
  }

  /// 最小 UUID v4 生成（无 uuid 依赖；随机量来自 Random.secure）
  static String _uuidV4() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
