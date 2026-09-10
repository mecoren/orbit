import 'package:flutter/services.dart';

/// B6 Android 图标角标服务（注入式：测试/换实现无痛）。
///
/// 厂商 ROM 兼容由 ShortcutBadger 内部处理，各家支持度不一——
/// 角标属锦上添花，**任何异常全吞绝不炸主流程**。
/// flutter_app_badger 已标 discontinued（2022 年后停更），
/// 注入口留好了换实现的后路（自写 MethodChannel + ShortcutBadger）。
class BadgeService {
  BadgeService({Future<void> Function(int count)? setBadge})
      : _setBadge = setBadge ?? _channelSetBadge;

  final Future<void> Function(int count) _setBadge;

  /// 原生通道（BadgeChannel：厂商 ROM 广播；替代 discontinued 插件
  /// ——其 compileSdk 29 与 AGP 9 硬不兼容，且注入口设计本就为此）
  static const _channel = MethodChannel('orbit/badge');

  static Future<void> _channelSetBadge(int count) async {
    if (count <= 0) {
      await _channel.invokeMethod<void>('removeBadge');
      return;
    }
    await _channel.invokeMethod<void>('updateBadge', count);
  }

  /// 更新角标；ROM 不支持等异常静默吞掉
  Future<void> update(int count) async {
    try {
      await _setBadge(count);
    } catch (_) {
      /* 厂商 ROM 不支持：角标可选，不炸主流程 */
    }
  }
}
