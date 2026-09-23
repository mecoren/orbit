import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api/orbit_bridge.dart';

/// 「修改后立即同步」写路径调度器（docs/10 §A-2 M6）
///
/// 桌面参照实现：`apps/desktop/src-tauri/src/commands/sync_scheduler.rs` 的
/// on-change watcher（`sync_on_change_watcher_start` / `run_on_change_sync`）。
///
/// 职责链：业务写路径落库（Rust 仓储层 emit EVENT_BUS）→ FRB dbChanges 流
/// （BootGate 唯一订阅转发）→ **防抖 5s 合并连续编辑** → 门控通过后
/// `cloudSyncPushOnly(origin: 'background')` 仅推送本地变更到云端。
///
/// 与桌面逐条对齐的口径：
/// - 防抖 5s **滑动窗口**（桌面 `ON_CHANGE_DEBOUNCE_SECS = 5`），窗口内新事件
///   重置计时，连续编辑只推一次；
/// - 四道门控：已配置云同步 && `sync_on_change` && `is_auto_sync` && 有同步
///   密码且已解锁，再叠加「引擎不忙」（`cloudSyncIsRunning`，core 侧 try_lock
///   探测）——与桌面 `run_on_change_sync` 判定顺序一致；
/// - **不做表过滤**（含 pull 合并产生的 db-change 也会触发）：引擎 push 走增量
///   指纹比对，无变更时秒级跳过，无放大效应；
/// - 配置每轮现读（不缓存），设置页改动下一轮即生效。
///
/// 与桌面的两处有意差异（移动端无后台调度器所致）：
/// 1. 桌面有 60s tick 兜底，移动端没有——故推送进行中若又收到新事件，本轮
///    结束后**补排一轮**防抖，避免漏推只能等下一次编辑或切前台；
/// 2. 移动端无 sync-progress 事件流（FRB 只转发 db-change / reminder-due），
///    后台推送不驱动标题栏「同步中」指示，仅在成功后经 [attachOnce] 的
///    `onPushed` 回调刷新同步配置缓存（「上次同步」时间）。
///
/// 耗电/流量（docs/10 §A-2 权衡落点）：触发只来自用户真实编辑，每窗口至多
/// 一次 push，引擎忙 / 指纹未变时零上传；不做后台轮询——进入 / 退出前台另有
/// `cloudSyncForce` 必同步兜底（见 BootGate 生命周期钩子）。
///
/// 生命周期：进程级单例（BootGate ready 后常驻）；[shutdown] 仅测试用
/// （widget 测试的 fake_async 环境要求退出时无 pending Timer）。
class SyncOnChangeScheduler {
  SyncOnChangeScheduler._(this._bridge);

  final OrbitBridge _bridge;

  /// 防抖窗口：对齐桌面 `ON_CHANGE_DEBOUNCE_SECS = 5`
  static const Duration debounceWindow = Duration(seconds: 5);

  /// 推送来源标识：对齐桌面 `SyncOrigin::Background`（serde lowercase）
  static const String pushOrigin = 'background';

  Timer? _debounce;
  bool _pushing = false;
  bool _dirtyDuringPush = false;
  bool _shutdown = false;
  void Function()? _onPushed;

  static SyncOnChangeScheduler? _instance;

  /// 单例工厂（bridge 注入一次）；[onPushed] 为推送成功回调，每次挂载可覆盖
  /// （BootGate 用于失效 [syncConfigProvider] 刷新「上次同步」）
  static SyncOnChangeScheduler attachOnce(
    OrbitBridge bridge, {
    void Function()? onPushed,
  }) {
    _instance ??= SyncOnChangeScheduler._(bridge);
    final s = _instance!;
    if (onPushed != null) s._onPushed = onPushed;
    return s;
  }

  /// dbChanges 转发口（由 BootGate 的唯一 dbChanges 订阅转发——
  /// FRB subscribe_db_changes 是 Rust 侧单播闸设计，第二次 listen 静默
  /// 收不到事件，本调度器不得自行订阅流）
  void onDbChange() {
    if (_shutdown) return;
    _debounce?.cancel();
    if (_pushing) {
      // 推送进行中的新写入：标记脏，本轮结束后补一轮（移动端无 tick 兜底）
      _dirtyDuringPush = true;
      return;
    }
    _debounce = Timer(debounceWindow, () => unawaited(pushNow()));
  }

  /// 到点推送一次；门控不通过则静默返回（不打扰用户，不算失败）
  Future<void> pushNow() async {
    if (_pushing || _shutdown) return;
    _pushing = true;
    _debounce?.cancel();
    var pushed = false;
    try {
      final config = await _bridge.syncConfigGet();
      if (config == null) return; // 未配置云同步
      if (!config.syncOnChange || !config.autoSyncEnabled) return; // 开关未开
      final crypto = await _bridge.syncCryptoStatus();
      if (!crypto.hasPassword || !crypto.isUnlocked) return; // 未解锁
      if (await _bridge.cloudSyncIsRunning()) return; // 引擎忙：本轮让位
      final result = await _bridge.cloudSyncPushOnly(origin: pushOrigin);
      pushed = true;
      debugPrint('[SyncOnChange] push_only 推送 ${result.pushedModules} 模块 / '
          '上传 ${result.uploadedAttachments} 附件 / ${result.durationMs}ms'
          '${result.skipped ? '（引擎忙跳过）' : ''}');
    } catch (e, st) {
      // 失败静默不打扰：core 已按 sync_type=push_only 写同步历史（设置页
      // 「同步历史」可见），与桌面 log::warn! 口径一致（不弹窗、不打断编辑）
      debugPrint('[SyncOnChange] push_only 失败: $e\n$st');
    } finally {
      _pushing = false;
      if (pushed) _onPushed?.call();
      if (_dirtyDuringPush) {
        _dirtyDuringPush = false;
        onDbChange();
      }
    }
  }

  /// 测试清理口：取消防抖定时器并重置单例。生产进程不调用——单例与进程同
  /// 生命周期（与 ReminderScheduler.shutdown 同款口径）。
  static void shutdown() {
    _instance?._shutdown = true;
    _instance?._debounce?.cancel();
    _instance = null;
  }
}
