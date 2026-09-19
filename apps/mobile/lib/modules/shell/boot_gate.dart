import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/routing/router_keys.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/providers/bridge_provider.dart';
import '../../data/providers/todo_widget_provider.dart';
import '../../services/device_id.dart';
import '../../services/todo_widget_service.dart';
import '../../services/badge_service.dart';
import '../../services/notification_service.dart';
import '../../services/reminder_scheduler.dart';
import '../../services/share_receiver.dart';
import '../todo/logic/badge_count.dart';
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
///   ready 后挂 WidgetsBindingObserver：
///   - resumed：轮询分享接收（Android「分享到」热运行 onNewIntent 的一路）
///     + **进入应用强制同步**（先拉后推，忽略自动同步开关）
///   - paused：**退到后台尽力同步**（带超时；被系统冻结则放弃，不承诺可靠）
class BootGate extends ConsumerStatefulWidget {
  const BootGate({super.key, required this.child});

  /// ready 后渲染的主路由内容（MaterialApp.router 的 child）
  final Widget child;

  @override
  ConsumerState<BootGate> createState() => _BootGateState();
}

enum _BootPhase { booting, unlock, ready }

class _BootGateState extends ConsumerState<BootGate>
    with WidgetsBindingObserver {
  _BootPhase _phase = _BootPhase.booting;

  StreamSubscription<dynamic>? _dbChangesSub;
  StreamSubscription<dynamic>? _reminderDueSub;
  ReminderScheduler? _scheduler;
  // B6 图标角标：注入式服务（ROM 异常全吞）；listen/resumed 双口刷新
  final BadgeService _badge = BadgeService();
  // 小组件快照（#3）：与角标同款双口刷新（ready + dbChanges）；
  // 平台插件异常在服务内全吞
  late final TodoWidgetService _widget = ref.read(todoWidgetServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dbChangesSub?.cancel();
    _reminderDueSub?.cancel();
    _widget.detach();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_phase != _BootPhase.ready) return;
    if (state == AppLifecycleState.resumed) {
      // 热运行分享：Android onNewIntent 已把文本存原生侧待取，
      // 回到前台轮询取走（冷启动一路在 _goReady 首查）
      ShareReceiver.consume(ref);
      // B6 角标重算：隔夜挂后台后「今天」口径漂移，resumed 即刷新
      _refreshBadge();
      // 小组件快照同口径重算（隔夜口径漂移；#3）
      _widget.refresh();
      // 进入应用强制同步（先拉后推；未配置/未解锁静默跳过）
      unawaited(_forceSync(origin: 'background'));
    } else if (state == AppLifecycleState.paused) {
      // 退到后台：尽力同步一次（移动端无真正退出钩子，系统可能冻结进程，
      // 超时即放弃，不阻塞生命周期回调）
      unawaited(_forceSync(origin: 'exit'));
    }
  }

  /// 生命周期强制同步（进入 / 退出应用）
  ///
  /// 与设置页「立即同步」共用同一桥方法（core 侧 `pull_then_push`：先拉后推）；
  /// 差别只在**触发时机由生命周期决定**——不读取自动同步开关 / 间隔 /
  /// 修改后立即同步等设置，「进入应用」「退到后台」本身就是触发条件。
  /// 未配置或未解锁时 core 直接返回错误，此处静默跳过（不打扰用户）。
  ///
  /// 超时 6 秒：移动端退到后台可能被系统冻结，超时即放弃并留痕，
  /// 绝不阻塞生命周期回调（阻塞会被系统判定应用无响应）。
  Future<void> _forceSync({required String origin}) async {
    final bridge = ref.read(orbitBridgeProvider);
    try {
      final config = await bridge.syncConfigGet();
      if (config == null) return; // 未配置云同步
      final result = await bridge
          .cloudSyncNow(origin: origin)
          .timeout(const Duration(seconds: 6));
      // 拉取合并写入不走 db-change 事件，需在此失效业务缓存（口径同设置页）
      if (result.pulledModules > 0) invalidateBusinessCaches(ref);
    } catch (e) {
      // 静默：网络异常 / 未解锁 / 超时都不打扰用户，下次进入或手动同步会重试
      debugPrint('[BootGate] lifecycle sync($origin) skipped: $e');
    }
  }

  /// B6 角标刷新：读 todoTasksProvider 缓存值算「今天截止或已逾期」
  /// 未完成数。此前直拉 bridge.todoTaskList 全量 IPC——与 provider 缓存
  /// 完全重复（一次 db-change = provider 重拉一遍 + 角标直拉一遍 = 双份
  /// 万行过桥）；改读缓存未就绪时静默跳过，_subscribeStreams 的 listen
  /// 会在数据到达后补刷。
  Future<void> _refreshBadge() async {
    try {
      final tasks =
          ref.read(todoTasksProvider(const TaskListQuery())).value;
      if (!mounted || tasks == null) return;
      await _badge.update(dueTodayOrOverdueCount(tasks));
    } catch (e) {
      debugPrint('[BootGate] badge refresh failed: $e');
    }
  }

  Future<void> _bootstrap() async {
    final bridge = ref.read(orbitBridgeProvider);
    try {
      if (await bridge.masterAuthHas()) {
        if (mounted) setState(() => _phase = _BootPhase.unlock);
        return;
      }
      await bridge.dbInitPlaintext();
      _ensureDeviceId(bridge);
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
    _ensureDeviceId(bridge);
    _goReady();
  }

  /// 设备 ID 接线（对齐桌面 ensureDeviceId）：DB 初始化后必须
  /// dbSetDeviceId 写入 Rust OnceCell——generic_repo 的 device_id
  /// 自动填充与同步引擎 validate_config 均依赖此值，缺失则云同步在
  /// 移动端必然报「device_id 不能为空」。持久化在应用支持目录
  /// device_id.txt（清库不清除）；失败静默不阻断启动（桌面同口径）。
  ///
  /// 不 await：path_provider 的 platform channel 在 fake_async 测试
  /// zone 里永不 resolve（探针实证）——await 会把 bootstrap 挂死，
  /// pumpAndSettle 超时。真机毫秒级 IO，启动后用户进入云同步设置前
  /// 必然完成，无实用竞态。
  void _ensureDeviceId(dynamic bridge) {
    DeviceIdStore.ensure().then((id) async {
      try {
        await bridge.dbSetDeviceId(id);
      } catch (e) {
        debugPrint('[BootGate] dbSetDeviceId failed: $e');
      }
    }).catchError((e) {
      debugPrint('[BootGate] device id setup failed: $e');
    });
  }

  void _goReady() {
    // 本地通知插件初始化 + 权限请求（幂等；拒绝则事件回落 toast，静默降级）
    NotificationService.instance.ensureInitialized();
    // 通知正文点击 → 跳任务详情（服务层经此回调拿到路由，不持有 context）。
    // rootRouter 由 rootNavigatorKey 装配后可用；MaterialApp.router 尚未
    // build 时为 null——冷启动拉起已由下方 consumeLaunchNotification 补位。
    NotificationService.onNotificationTap = (taskId) async {
      final router = rootRouter;
      if (router == null) return;
      await router.push('/todo/$taskId');
    };
    // B5 通知「完成」action：前台直调桥完成任务（dbChanges 事件自然
    // 失效业务缓存 + 调度器重排闹钟——完成实例提醒行由引擎软删）。
    NotificationService.onCompleteAction = (taskId) async {
      try {
        await ref.read(orbitBridgeProvider).todoTaskComplete(taskId);
      } catch (e) {
        debugPrint('[BootGate] notification complete failed: $e');
      }
    };
    // 后台闹钟通道：DB 未来提醒全量重排 + dbChanges 防抖跟随
    //（P2 提醒升级：后台/被杀/重启均由系统闹钟保证提醒）
    _scheduler = ReminderScheduler.attachOnce(ref.read(orbitBridgeProvider));
    // 节假日自动更新守护（Rust 60s tick：每日固定时刻一次，
    // 错过时刻本次启动首轮即补更；首装从未成功也在此补拉）
    ref.read(orbitBridgeProvider).startHolidayScheduler();
    // 回收站 TTL 清理守护（Rust 60s tick：每日最多清一次，
    // 多日未开时本次启动首轮即补清过期间隔的过期任务）
    ref.read(orbitBridgeProvider).startTrashScheduler();
    // 小组件勾选通道挂载 + 首刷快照（#3：通知完成回调同款位置——ready 后
    // 引擎稳定，原生积压队列可冲刷）
    _widget.attach(onOpenTask: (taskId) async {
      final router = rootRouter;
      if (router == null) return;
      await router.push('/todo/$taskId');
    });
    _widget.refresh();
    _subscribeStreams();
    if (mounted) setState(() => _phase = _BootPhase.ready);
    // 冷启动拉起消费：应用被杀期间点通知 → 等首帧路由装配完成再跳详情
    //（push 早于 MaterialApp.router build 会丢；微任务兜一拍即可）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.consumeLaunchNotification();
      // 分享冷启动一路：onCreate intent 携带 EXTRA_TEXT 已存原生侧，
      // 路由就绪后取走建任务（toast 需 Overlay，早于此无渲染面）
      ShareReceiver.consume(ref);
    });
  }

  /// 桥层事件流监听（ready 后挂载，全生命周期持有）
  void _subscribeStreams() {
    final bridge = ref.read(orbitBridgeProvider);

    // 本地写操作 → 全量失效业务缓存（列表/详情/配置）+ 转发调度器重排
    // 闹钟（dbChanges 是 FRB 单播流：全 App 唯一订阅在此，二次 listen
    // 会被 Rust 侧 FORWARDER_STARTED 闸静默丢弃——见 events.rs 注释）
    // todo_activity_log 轨迹行只喂详情页「历史」区块：单独失效
    // taskActivityProvider 即返回，跳过全量链以免每次写都多跑万行级重拉
    //（不能并进 invalidateBusinessCaches——业务 todo_tasks 事件先于轨迹
    // INSERT 到达，历史靠那条链刷新会读到旧行）
    _dbChangesSub = bridge.dbChanges.listen((e) {
      if (!mounted) return;
      if (e.table == 'todo_activity_log') {
        ref.invalidate(taskActivityProvider);
        return;
      }
      invalidateBusinessCaches(ref);
      _scheduler?.onDbChange();
    });

    // B6 图标角标数据口：dbChanges 失效后经 provider 重拉新值刷角标
    //（ref.listen 仅限 build 期——异步流程用 manualRead 模式）。
    _refreshBadge();

    // 小组件快照（#3）：与角标同一失效链——dbChanges 后重拉今日口径
    _widget.refresh();

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
