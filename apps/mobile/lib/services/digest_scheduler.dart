import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api/orbit_bridge.dart';
import 'notification_service.dart';

/// 每日摘要排程协调器（G3，对标 TickTick Daily Reminder）
///
/// 职责：让「cfg_kv 里的摘要偏好」与「系统闹钟里的每日重复通知」保持收敛：
/// - **启动**：BootGate ready 后 [attachOnce] 首排（读偏好 + 取一次文案）；
/// - **设置变更**：设置页保存后调 [refresh] 立即重排（用户改完就想生效）；
/// - **文案跟随**：dbChanges（BootGate 唯一订阅转发，任务表过滤）→ 防抖 2s
///   重排，让通知正文跟上最新计数。
///
/// 为什么正文要重排：系统闹钟由原生 Receiver 直接展示，**不执行 Dart**，
/// 正文只能取「排程那一刻」的快照。因此这里不追求实时（实时也做不到），
/// 只保证「打开过应用之后」文案是最新的——这与 Android 系统对重复通知的
/// 能力边界一致，不值得为它引入后台 isolate。
///
/// 生命周期与 [ReminderScheduler] 同款：进程级单例；[shutdown] 仅测试用
/// （widget 测试的 fake_async 要求退出时无 pending Timer）。
class DigestScheduler {
  DigestScheduler._(this._bridge);

  final OrbitBridge _bridge;

  Timer? _debounce;
  bool _syncing = false;
  bool _attached = false;
  bool _shutdown = false;

  static DigestScheduler? _instance;

  /// 单例工厂（bridge 注入一次；幂等）
  static DigestScheduler attachOnce(OrbitBridge bridge) {
    _instance ??= DigestScheduler._(bridge);
    final s = _instance!;
    if (!s._attached && !s._shutdown) {
      s._attached = true;
      unawaited(s._apply());
    }
    return s;
  }

  /// dbChanges 转发口（由 BootGate 的唯一 dbChanges 订阅转发——
  /// FRB subscribe_db_changes 是 Rust 侧单播闸设计，调度器不得自行订阅流）
  void onDbChange() {
    if (_shutdown) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      unawaited(_apply());
    });
  }

  /// 立即重排（设置页保存后调用；防抖定时器一并取消）
  Future<void> refresh() async {
    _debounce?.cancel();
    await _apply();
  }

  /// 测试清理口：取消防抖定时器（fake_async 断言无 pending Timer）。
  /// 生产进程不调用——单例与进程同生命周期。
  static void shutdown() {
    _instance?._shutdown = true;
    _instance?._debounce?.cancel();
    _instance = null;
  }

  /// 读偏好 + 取文案 + 落到系统闹钟（幂等：内部先 cancel 再 schedule）
  Future<void> _apply() async {
    if (_syncing || _shutdown) return;
    _syncing = true;
    try {
      final prefs = await _bridge.digestPrefs();
      // 关闭时不取文案（省一次查询）
      final body = prefs.enabled ? await _bridge.digestBody() : null;
      await NotificationService.instance.syncDailyDigest(
        enabled: prefs.enabled,
        hour: prefs.hour,
        minute: prefs.minute,
        body: body,
      );
      debugPrint(
        '[DigestScheduler] 摘要排程 ${prefs.enabled ? prefs.label : "关闭"}',
      );
    } catch (e, st) {
      debugPrint('[DigestScheduler] 排程失败: $e\n$st');
    } finally {
      _syncing = false;
    }
  }
}
