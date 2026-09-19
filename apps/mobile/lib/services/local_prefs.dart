import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 本机 UI 偏好存储（移动端对应物 = 桌面 localStorage）
///
/// 只承载视图态类本机偏好（隐藏已完成、排序档等会话态），**不进 DB、不进同步**
/// ——与桌面 localStorage 键全集同口径（如 `todo_hide_done`），键名直接复用。
///
/// 落盘载体：应用支持目录 `prefs.json`（与 `device_id.txt` 同目录先例，
/// 清库不清偏好）。读写失败一律静默降级：偏好不是业务数据——读不到按各自
/// 默认值走、写不进不阻断 UI（纯 Dart 单测无 path_provider handler 时同样安全）。
class LocalPrefs {
  LocalPrefs._();

  static const _fileName = 'prefs.json';

  /// 已载入键值；[load] 之前为空表（读取走各自 fallback）
  static Map<String, String> _values = {};

  /// 启动序列调用一次（main 中 runApp 前）；重复调用按重载处理
  static Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      _values = {
        for (final e in raw.entries) '${e.key}': '${e.value}',
      };
    } catch (_) {
      /* 文件缺失/损坏/无插件环境：保持空表走默认值 */
    }
  }

  /// 布尔偏好：未存过按 [fallback]（桌面口径：隐藏已完成默认开）
  static bool getBool(String key, {required bool fallback}) {
    final value = _values[key];
    return value == null ? fallback : value == '1';
  }

  /// 写布尔偏好："1"/"0"（与桌面 localStorage 同编码）；内存态即时生效，
  /// 落盘失败静默（下次启动回退默认值）
  static Future<void> setBool(String key, bool value) async {
    _values[key] = value ? '1' : '0';
    await _flush();
  }

  /// 字符串偏好：未存过返回 null（调用方自行回落默认档）。
  /// 用于承载枚举档位（视图模式、外观字号/字重等），值域由调用方校验——
  /// 落盘格式与桌面 localStorage 一致（纯字符串）。
  static String? getString(String key) => _values[key];

  /// 写字符串偏好（空串视为未设置，直接删除键）
  static Future<void> setString(String key, String value) async {
    if (value.isEmpty) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    await _flush();
  }

  /// 读枚举档位：值不在 [allowed] 内（脏数据/跨版本改名）回落 [fallback]
  static T getEnum<T extends Enum>(
    String key,
    List<T> allowed, {
    required T fallback,
  }) {
    final raw = _values[key];
    if (raw == null) return fallback;
    for (final v in allowed) {
      if (v.name == raw) return v;
    }
    return fallback;
  }

  static Future<void> _flush() async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(_values), flush: true);
    } catch (_) {
      /* 落盘失败不阻断 UI */
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }
}
