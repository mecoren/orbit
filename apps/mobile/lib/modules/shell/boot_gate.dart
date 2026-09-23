import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/routing/router_keys.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/providers/bridge_provider.dart';
import '../../data/providers/todo_widget_provider.dart';
import '../../services/device_id.dart';
import '../../services/local_prefs.dart';
import '../../services/todo_widget_service.dart';
import '../../services/badge_service.dart';
import '../../services/notification_service.dart';
import '../../services/reminder_scheduler.dart';
import '../../services/reminder_snooze.dart';
import '../../services/share_receiver.dart';
import '../../services/sync_on_change_scheduler.dart';
import '../todo/logic/badge_count.dart';
import '../todo/providers/todo_providers.dart';
import '../auth/unlock_page.dart';
import 'db_invalidation.dart';

/// 启动门控（对齐原 React 版 App.tsx 门控序列）
///
/// - masterAuthHas == true → 展示 [UnlockPage]，解锁成功 dbInitEncrypted；
/// - 否则 → dbInitPlaintext 直入；
/// - ready 后渲染主路由内容（[BootGate.child]），并挂载桥层事件流监听：
///   dbChanges 按表精确失效（B7，未知表回退全量）；reminderDue 经
///   [NotificationService] 呈现本地通知（无权限静默降级 warning toast）。
///   注：云同步结果经 cloudSyncNow 返回值直达（ADR 0003），无 sync-finished 流。
///   bootstrap 失败回落解锁页仅针对"已设密码需解锁"场景；
///   未设密码时初始化异常也回落解锁页属历史兜底，真实错误经日志暴露。
///   ready 后挂 WidgetsBindingObserver：
///   - resumed：轮询分享接收（Android「分享到」热运行 onNewIntent 的一路）
///     + **进入应用强制同步**（先拉后推，忽略自动同步开关）
///   - paused：**退到后台尽力同步**（带超时；被系统冻结则放弃，不承诺可靠）
///
///   ready 后挂「修改后立即同步」调度器（[SyncOnChangeScheduler]）：写路径
///   db-change → 5s 防抖 → `cloudSyncPushOnly`（门控见调度器文档）。
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
  SyncOnChangeScheduler? _syncOnChange;
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
      // 回前台先补掉后台 isolate 留下的推迟暂存：它在后台隔离区写不了 DB，
      // 若用户一直不重启 App，只有这里能把推迟写回（见 _landSpooledSnoozes）
      unawaited(_landSpooledSnoozes());
      // 再补一次「孤儿闹钟落地」：切前台不一定伴随 db-change，没有这一步，
      // 后台点推迟留下的系统闹钟会在下一次重排的 cancelAll 里被清掉
      unawaited(_scheduler?.landPendingSnoozes().then((_) {}));
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

  /// 生命周期强制同步（进入 / 退出应用，对齐桌面 cloud_sync_force）
  ///
  /// 与设置页「立即同步」不同：本路径走 `cloudSyncForce`（core 侧
  /// `force_sync`：先拉后推，不检查自动同步开关 / 间隔 / 修改后立即同步）；
  /// 「进入应用」「退到后台」本身就是触发条件。未配置或未解锁时 core
  /// 直接返回错误，此处静默跳过（不打扰用户）。
  ///
  /// 超时 6 秒：移动端退到后台可能被系统冻结，超时即放弃并留痕，
  /// 绝不阻塞生命周期回调（阻塞会被系统判定应用无响应）。
  Future<void> _forceSync({required String origin}) async {
    final bridge = ref.read(orbitBridgeProvider);
    try {
      final config = await bridge.syncConfigGet();
      if (config == null) return; // 未配置云同步
      final waitMs = origin == 'exit' ? 15000 : 3000;
      final result = await bridge
          .cloudSyncForce(origin: origin, waitForIdleMs: waitMs)
          .timeout(const Duration(seconds: 6));
      // 拉取合并写入不走 db-change 事件，需在此失效业务缓存（F42 精确失效）
      invalidateAfterSyncCaches(ref, result);
    } catch (e) {
      // 静默：网络异常 / 未解锁 / 超时都不打扰用户，下次进入或手动同步会重试
      debugPrint('[BootGate] lifecycle sync($origin) skipped: $e');
    }
  }

  /// B6 角标刷新：读单份任务缓存（[todoTasksProvider]）算「今天截止或
  /// 已逾期」未完成数——此前直拉 bridge.todoTaskList 全量 IPC，与缓存
  /// 完全重复（双份万行过桥）；现只在缓存换值时计算，未就绪静默跳过
  /// （listenManual 订阅会在数据到达后补刷）。
  Future<void> _refreshBadge() async {
    try {
      final tasks = ref.read(todoTasksProvider).value;
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
    // 通知「推迟 N 分钟」action：前台把推迟写回 DB（软删旧行 + 新建新时刻行，
    // 对齐引擎 snooze 语义）——不落库则到期行被引擎清理、重排 cancelAll 又会
    // 清掉刚排的推迟闹钟 → 提醒直接消失（2026-09-20 修复）。
    // 后台 isolate 不可达（FRB 不可重入），那条路径由 ReminderScheduler 的
    // 启动补齐落地（reminder_snooze.dart 的 planSnoozeLanding）。
    NotificationService.onSnoozeAction = (taskId, fromRemindAt, nextAt) async {
      try {
        await landSnoozeInDb(
          ref.read(orbitBridgeProvider),
          taskId: taskId,
          fromRemindAt: fromRemindAt,
          nextAt: nextAt,
        );
      } catch (e) {
        debugPrint('[BootGate] notification snooze failed: $e');
      }
    };
    // 后台推迟暂存落地：App 不在前台时，通知 action 由插件在**独立后台
    // isolate** 回调（见 ADR 0002 §三）——那里无法重入 FRB、也看不到这里
    // 注入的 onSnoozeAction，推迟意图只能落在本机暂存文件。启动时 drain 并
    // 写回 DB，之后的闹钟重排（cancelAll + 按 DB 排）才会把推迟后的新时刻
    // 排上；不写回则 DB 里没有这条未来提醒，重排会把刚排的推迟闹钟清掉
    //（2026-09-20「点推迟后提醒消失」修复）。
    unawaited(_landSpooledSnoozes());
    // 后台闹钟通道：DB 未来提醒全量重排 + dbChanges 防抖跟随
    //（P2 提醒升级：后台/被杀/重启均由系统闹钟保证提醒）
    // B6：标题 join 改读单份任务缓存（此前每次重排直拉全量任务，与列表
    // 缓存完全重复）；快照为 null（缓存未就绪）时服务内回落直拉一次
    _scheduler = ReminderScheduler.attachOnce(
      ref.read(orbitBridgeProvider),
      taskSnapshot: () => ref.read(todoTasksProvider).value,
    );
    // 「修改后立即同步」（docs/10 §A-2 M6）：写路径 db-change → 5s 防抖后
    // cloudSyncPushOnly（门控：已配置 + 两个开关 + 已解锁 + 引擎空闲）。
    // 后台推送不产生进度事件，成功后只失效同步配置缓存刷新「上次同步」，
    // 标题栏同步指示不被后台推送占用（仅手动同步走本地态）
    _syncOnChange = SyncOnChangeScheduler.attachOnce(
      ref.read(orbitBridgeProvider),
      onPushed: () {
        if (mounted) ref.invalidate(syncConfigProvider);
      },
    );
    // 节假日自动更新守护（Rust 60s tick：每日固定时刻一次，
    // 错过时刻本次启动首轮即补更；首装从未成功也在此补拉）
    ref.read(orbitBridgeProvider).startHolidayScheduler();
    // 回收站 TTL 清理守护（Rust 60s tick：每日最多清一次，
    // 多日未开时本次启动首轮即补清过期间隔的过期任务）
    ref.read(orbitBridgeProvider).startTrashScheduler();
    // 自动备份守护（Rust 60s tick：按 backup_prefs 频率触发；未解锁同步
    // 密码时静默跳过只推进下次时间，不打扰用户）
    ref.read(orbitBridgeProvider).startBackupScheduler();
    // 开机清理过期通知日志：db_maintenance 内含通知历史 + 活动日志 30 天
    // TTL 修剪（core db_maintenance_api 口径），失败静默不阻断启动
    unawaited(ref.read(orbitBridgeProvider).dbMaintenance().then((_) {}).catchError((e) {
      debugPrint('[BootGate] boot maintenance skipped: $e');
    }));
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

  /// 消费后台 isolate 留下的推迟暂存（写回 DB；失败静默不阻断启动）
  Future<void> _landSpooledSnoozes() async {
    try {
      final bridge = ref.read(orbitBridgeProvider);
      for (final s in await SnoozeSpool.drain()) {
        await landSnoozeInDb(
          bridge,
          taskId: s.taskId,
          fromRemindAt: s.fromRemindAt,
          nextAt: s.nextAt,
        );
      }
    } catch (e) {
      debugPrint('[BootGate] snooze spool drain failed: $e');
    }
  }

  /// 桥层事件流监听（ready 后挂载，全生命周期持有）
  void _subscribeStreams() {
    final bridge = ref.read(orbitBridgeProvider);

    // 本地写操作 → B7 表级精确失效（db_invalidation.dart 映射；未知表
    // 回退全量），并按表转发派生刷新（dbChanges 是 FRB 单播流：全 App
    // 唯一订阅在此，二次 listen 会被 Rust 侧 FORWARDER_STARTED 闸静默
    // 丢弃——见 events.rs 注释）
    _dbChangesSub = bridge.dbChanges.listen((e) {
      if (!mounted) return;
      if (!invalidateByTable(ref, e.table)) {
        invalidateBusinessCaches(ref);
      }
      // 闹钟重排只受提醒行与任务完成态影响；其余表重排是纯重复工作量
      if (affectsReminderSchedule(e.table)) {
        _scheduler?.onDbChange();
      }
      // 小组件快照（#3）：读今日任务口径，只有任务表变化需重写
      if (affectsTaskSnapshot(e.table)) {
        _widget.refresh();
      }
      // 「修改后立即同步」（M6）：写路径落库即排一次防抖推送（表过滤与
      // 门控都在调度器内——不过滤表，引擎指纹未变会秒级跳过）
      _syncOnChange?.onDbChange();
    });

    // B6 图标角标数据口：订阅单份任务缓存，每次换值（含失效重拉完成）即
    // 重算——订阅本身让失效立即重拉并回调，不必在 dbChanges 里抢跑
    //（ref.listen 仅限 build 期——异步流程用 listenManual）
    ref.listenManual(todoTasksProvider, (_, _) => _refreshBadge());
    _refreshBadge(); // 订阅前缓存已就绪（热重入）时补一次

    // 小组件快照（#3）：ready 首刷（后续由 todo_tasks 事件驱动）
    _widget.refresh();

    // 提醒到期 → 本地通知即时呈现（无权限 / 异常时内部回落 warning toast）。
    // 僵尸清理：后台推迟未写 DB，旧行到期时由 handleReminderDue 判定为
    // 推迟产物（系统闹钟已有更晚排程）→ 删除该行，DB 与闹钟面收敛。
    // 完成实例清理（对齐桌面端 P1#10）：任务已完成则不再打扰，删除行。
    _reminderDueSub = bridge.reminderDue.listen((e) async {
      // 提醒总开关（通知历史页 LocalPrefs `reminder_enabled`，默认开）：
      // 关后到期事件仅由 Rust 写历史，不再弹窗打扰
      if (!LocalPrefs.getBool('reminder_enabled', fallback: true)) return;
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
        // 启动等待画面：白底 + 居中品牌图（与桌面端**同一枚图标**，
        // 由 scripts/generate_icons.py 产出为 assets/app_icon.png）。
        // 与原生启动屏（launch_background：白底 + 居中同图）无缝衔接。
        return const Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Image(
              image: AssetImage('assets/app_icon.png'),
              width: AppDimens.splashLogoSize,
              height: AppDimens.splashLogoSize,
            ),
          ),
        );
    }
  }
}
