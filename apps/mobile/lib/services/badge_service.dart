import 'package:flutter_app_badger/flutter_app_badger.dart';

/// B6 Android 图标角标服务（注入式：测试/换实现无痛）。
///
/// 厂商 ROM 兼容由 ShortcutBadger 内部处理，各家支持度不一——
/// 角标属锦上添花，**任何异常全吞绝不炸主流程**。
/// flutter_app_badger 已标 discontinued（2022 年后停更），
/// 注入口留好了换实现的后路（自写 MethodChannel + ShortcutBadger）。
class BadgeService {
  BadgeService({Future<void> Function(int count)? setBadge})
      : _setBadge = setBadge ?? _pluginSetBadge;

  final Future<void> Function(int count) _setBadge;

  /// 默认实现：插件通道（count<=0 走 removeBadge 显式清零）
  static Future<void> _pluginSetBadge(int count) async {
    if (count <= 0) {
      await FlutterAppBadger.removeBadge();
      return;
    }
    await FlutterAppBadger.updateBadgeCount(count);
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
