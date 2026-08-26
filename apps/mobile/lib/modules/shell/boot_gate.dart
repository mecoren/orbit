import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/orbit_accents.dart';
import '../../data/providers/bridge_provider.dart';
import '../../services/notification_service.dart';
import '../todo/providers/todo_providers.dart';
import '../auth/unlock_page.dart';

/// 启动门控（对齐原 React 版 App.tsx 门控序列）
///
/// - masterAuthHas == true → 展示 [UnlockPage]，解锁成功 dbInitEncrypted；
/// - 否则 → dbInitPlaintext 直入；
/// - ready 后渲染主路由内容（[BootGate.child]），并挂载桥层事件流监听：
///   dbChanges 全量失效业务缓存；reminderDue 经 [NotificationService]
///   呈现本地通知（无权限静默降级 warning toast）。
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
  StreamSubscription<dynamic>? _syncFinishedSub;
  StreamSubscription<dynamic>? _reminderDueSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _dbChangesSub?.cancel();
    _syncFinishedSub?.cancel();
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
    } catch (_) {
      // 初始化失败：回退解锁态让用户重试（明文库场景下重试即重跑流程）
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
    _subscribeStreams();
    if (mounted) setState(() => _phase = _BootPhase.ready);
  }

  /// 桥层事件流监听（ready 后挂载，全生命周期持有）
  void _subscribeStreams() {
    final bridge = ref.read(orbitBridgeProvider);

    // 本地写操作 → 全量失效业务缓存（列表/详情/配置）
    _dbChangesSub = bridge.dbChanges.listen((_) {
      if (!mounted) return;
      invalidateBusinessCaches(ref);
    });

    // 云同步完成 → pulled_modules > 0 才失效（纯推送无需刷新本地缓存）
    _syncFinishedSub = bridge.syncFinished.listen((e) {
      if (!mounted || e.pulledModules <= 0) return;
      invalidateBusinessCaches(ref);
    });

    // 提醒到期 → 本地通知即时呈现（无权限 / 异常时内部回落 warning toast）
    _reminderDueSub = bridge.reminderDue.listen(
      (e) => NotificationService.instance.handleReminderDue(e),
    );
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
