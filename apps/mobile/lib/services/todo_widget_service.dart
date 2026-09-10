import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../data/api/orbit_bridge.dart';

/// Android 桌面小组件服务（#3 存在感链条）
///
/// 数据流（与原生 TodoWidgetProvider 键契约一一）：
/// - **快照写入**：[refresh] 拉桥 widgetTodoQuery（今日截止或逾期前 N 条）
///   → home_widget 数据面 `widget.items.N.id/title/priority/done` +
///   `widget.header.count` → updateWidget 触发 RemoteViews 重渲染。
///   刷新时机 = BootGate ready + dbChanges（与 B6 角标同款双口）+ 勾选落库后。
/// - **勾选落库**：原生经 TodoWidgetHost MethodChannel("orbit/widget") 转发
///   （引擎存活直发、被杀积压冲刷）→ [attach] 监听 → 桥 widgetTodoToggle
///   落库（完成复用 complete 全语义）→ dbChanges 事件自然触发快照重写。
/// - **行点击打开 app**：widgetClicked 流 + initiallyLaunchedFromHomeWidget
///   冷启动两路（目前仅回待办页；任务详情路由后续按 uri 派发）。
///
/// 平台边界：Android 专用（iOS 无 widget 形态）；非 Android 平台所有
/// 调用静默降级不炸（插件 platform channel 缺失时 catch 全吞）。
class TodoWidgetService {
  TodoWidgetService({required this.bridge, HomeWidgetApi? api})
      : _api = api ?? HomeWidgetApi();

  final OrbitBridge bridge;
  final HomeWidgetApi _api;

  /// 小组件列表行数（与布局 2×2~4×3 容量匹配；与 core WIDGET_MAX_ITEMS 上限对齐）
  static const itemCount = 7;

  bool _attached = false;
  StreamSubscription<Uri?>? _clickSub;

  /// MethodChannel：原生 TodoWidgetHost 勾选转发（与 Kotlin 端常量一致）
  static const _channel = MethodChannel('orbit/widget');

  /// 挂载（BootGate ready 时一次）：勾选通道监听 + widget 点击流路由。
  /// 幂等：重复 attach 不重复监听。
  void attach({
    void Function(int taskId)? onOpenTask,
  }) {
    if (_attached) return;
    _attached = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'widgetToggle') {
        final taskId = (call.arguments['taskId'] as num?)?.toInt();
        final done = (call.arguments['done'] as num?)?.toInt();
        if (taskId == null || done == null) return;
        try {
          await bridge.widgetTodoToggle(taskId, done);
          // 落库即刷快照（dbChanges 也会到，双保险：被杀恢复场景事件流
          // 消费者未挂载时这里兜底）
          await refresh();
        } catch (e) {
          debugPrint('[TodoWidgetService] toggle failed: $e');
        }
      }
    });

    _clickSub = _api.widgetClicked.listen((uri) {
      // uri 形如 orbitWidget://open?taskId=3；详情路由后续迭代按参数派发
      final taskId = int.tryParse(
          uri?.queryParameters['taskId'] ?? uri?.fragment ?? '');
      if (taskId != null) onOpenTask?.call(taskId);
    });
  }

  /// 卸载（BootGate dispose）
  Future<void> detach() async {
    _attached = false;
    await _clickSub?.cancel();
    _clickSub = null;
    _channel.setMethodCallHandler(null);
  }

  /// 拉快照写入数据面并刷新 widget（今日口径前 N 条）
  ///
  /// 全异常吞（widget 是可选存在感，不炸主流程）；非 Android 平台
  /// updateWidget 抛 MissingPluginException 一并吞。
  Future<void> refresh() async {
    try {
      final items = await bridge.widgetTodoQuery(itemCount);
      for (var i = 0; i < itemCount; i++) {
        final item = i < items.length ? items[i] : null;
        await _api.saveData('widget.items.$i.id', item?.id);
        await _api.saveData('widget.items.$i.title', item?.title);
        await _api.saveData('widget.items.$i.priority', item?.priority);
        await _api.saveData('widget.items.$i.done', item?.done);
      }
      await _api.saveData('widget.header.count', items.length);
      await _api.updateWidget(androidName: 'TodoWidgetProvider');
    } catch (e) {
      debugPrint('[TodoWidgetService] refresh failed: $e');
    }
  }

  /// 冷启动补路：从 widget 拉起时取启动 uri（taskId 路由用）
  Future<int?> initiallyLaunchedTaskId() async {
    try {
      final uri = await _api.initiallyLaunched();
      if (uri == null) return null;
      return int.tryParse(uri.queryParameters['taskId'] ?? '');
    } catch (_) {
      return null;
    }
  }

  /// 请求系统添加磁贴（API 33+；低版本原生静默）
  Future<void> requestPinTile() async {
    try {
      await _channel.invokeMethod<void>('requestPinTile');
    } catch (_) {
      /* 原生端反射 API 不可用（低版本/ROM 差异）：静默 */
    }
  }
}

/// home_widget 薄包装（测试注入假实现；生产直连插件）
class HomeWidgetApi {
  Future<void> saveData(String key, Object? value) =>
      HomeWidget.saveWidgetData(key, value);

  Future<void> updateWidget({String? androidName}) =>
      HomeWidget.updateWidget(androidName: androidName);

  Stream<Uri?> get widgetClicked => HomeWidget.widgetClicked;

  Future<Uri?> initiallyLaunched() => HomeWidget.initiallyLaunchedFromHomeWidget();
}
