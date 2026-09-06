import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/orbit_accents.dart';
import '../../data/providers/bridge_provider.dart';
import '../../services/notification_service.dart';
import '../../services/reminder_scheduler.dart';
import '../todo/providers/todo_providers.dart';
import '../auth/unlock_page.dart';

/// 启动门控（对齐原 React 版 App.tsx 门控序列）
///
/// - masterAuthHas == true → 展示 [UnlockPage]，解锁成功 dbInitEncrypted；
/// - 否则 → dbInitPlaintext 直入；
/// - ready 后渲染主路由内容（[BootGate.child]），并挂载桥层事件流监听：
///   dbChanges 全量失效业务缓存；reminderDue 经 [NotificationService]
///   呈现本地通知（无权限静默降级 warning toast）。
///   注：云同步结果经 cloudSyncNow 返回值直达（ADR 0003），无 sync-finished 流。
///   bootstrap 失败回落解锁页仅针对"已设密码需解锁"场景；
///   未设密码时初始化异常也回落解锁页属历史兜底，真实错误经日志暴露。
class BootGate extends ConsumerStatefulWidget {
  const BootGate({super.key, required this.child});

  /// ready 后渲染的主路由内容（MaterialApp.router 的 child）
  final Widget child;

  @override
  ConsumerState<BootGate> createState() => _BootGateState();
}

enum _BootPhase { booting, unlock, ready }

class _BootGateState extends ConsumerState<BootGate> {
  _BootPhase _phase = _BootPhase.booting;

  StreamSubscription<dynamic>? _dbChangesSub;
  StreamSubscription<dynamic>? _reminderDueSub;
  ReminderScheduler? _scheduler;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _dbChangesSub?.cancel();
    _reminderDueSub?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final bridge = ref.read(orbitBridgeProvider);
    try {
      if (await bridge.masterAuthHas()) {
        if (mounted) setState(() => _phase = _BootPhase.unlock);
        return;
      }
      await bridge.dbInitPlaintext();
      _goReady();
    } catch (e, st) {
      // 初始化失败：回退解锁态让用户重试（明文库场景下重试即重跑流程）。
      // 必须留痕：此 catch 曾静默吞掉订阅异常导致未设密码也误入解锁页。
      debugPrint('[BootGate] bootstrap failed: $e\n$st');
      if (mounted) setState(() => _phase = _BootPhase.unlock);
    }
  }

  Future<void> _onUnlocked(String dbKeyHex) async {
    final bridge = ref.read(orbitBridgeProvider);
    await bridge.dbInitEncrypted(dbKeyHex);
    _goReady();
  }

  void _goReady() {
    // 本地通知插件初始化 + 权限请求（幂等；拒绝则事件回落 toast，静默降级）
    NotificationService.instance.ensureInitialized();
    // 后台闹钟通道：DB 未来提醒全量重排 + dbChanges 防抖跟随
    //（P2 提醒升级：后台/被杀/重启均由系统闹钟保证提醒）
    _scheduler = ReminderScheduler.attachOnce(ref.read(orbitBridgeProvider));
    // 节假日自动更新守护（Rust 60s tick：每日固定时刻一次，
    // 错过时刻本次启动首轮即补更；首装从未成功也在此补拉）
    ref.read(orbitBridgeProvider).startHolidayScheduler();
    // 回收站 TTL 清理守护（Rust 60s tick：每日最多清一次，
    // 多日未开时本次启动首轮即补清过期间隔的过期任务）
    ref.read(orbitBridgeProvider).startTrashScheduler();
    _subscribeStreams();
    if (mounted) setState(() => _phase = _BootPhase.ready);
  }

  /// 桥层事件流监听（ready 后挂载，全生命周期持有）
  void _subscribeStreams() {
    final bridge = ref.read(orbitBridgeProvider);

    // 本地写操作 → 全量失效业务缓存（列表/详情/配置）+ 转发调度器重排
    // 闹钟（dbChanges 是 FRB 单播流：全 App 唯一订阅在此，二次 listen
    // 会被 Rust 侧 FORWARDER_STARTED 闸静默丢弃——见 events.rs 注释）
    _dbChangesSub = bridge.dbChanges.listen((_) {
      if (!mounted) return;
      invalidateBusinessCaches(ref);
      _scheduler?.onDbChange();
    });

    // 提醒到期 → 本地通知即时呈现（无权限 / 异常时内部回落 warning toast）。
    // 僵尸清理：后台推迟未写 DB，旧行到期时由 handleReminderDue 判定为
    // 推迟产物（系统闹钟已有更晚排程）→ 删除该行，DB 与闹钟面收敛。
    // 完成实例清理（对齐桌面端 P1#10）：任务已完成则不再打扰，删除行。
    _reminderDueSub = bridge.reminderDue.listen((e) async {
      try {
        final task = await bridge.todoTaskGet(e.taskId);
        if (task.done == 1 || task.isDeleted == 1) {
          try {
            await bridge.todoReminderDelete(e.id);
          } catch (_) {}
          return;
        }
      } catch (_) {
        /* 任务查询失败：照常提醒（提醒本就带任务标题） */
      }
      await NotificationService.instance.handleReminderDue(
        e,
        onZombieCleanup: (reminderId) => bridge.todoReminderDelete(reminderId),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _BootPhase.ready:
        return widget.child;
      case _BootPhase.unlock:
        return UnlockPage(onUnlocked: _onUnlocked);
      case _BootPhase.booting:
        return const Scaffold(
          body: Center(
            child: CircularProgressIndicator(color: OrbitAccents.themeAccent),
          ),
        );
    }
  }
}
