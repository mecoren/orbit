import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/dto.dart';
import '../data/api/orbit_bridge.dart';
import '../data/providers/bridge_provider.dart';
import '../modules/todo/logic/parse_quick_input.dart';
import '../modules/todo/providers/todo_providers.dart';
import '../shared/widgets/wait_toast.dart';

/// 分享接收服务（小而美批次④：Android 分享到 Orbit 建任务）
///
/// 原生层（MainActivity）经 MethodChannel("orbit/share") 暴露
/// takeSharedText——冷启动（onCreate intent）与热运行（onNewIntent）两路
/// 都存入原生 pendingText，取走即清（幂等）。本服务在
/// AppLifecycleState.resumed（含冷启动首查，见 BootGate._goReady）时
/// 轮询取走，过 NLP 短语法解析（与快加栏同源）建任务——命中
/// 日期/优先级/项目/标签 时自动应用并从标题剥离，完成后失效业务缓存。
///
/// 非 Android 平台无该通道（MissingPluginException / PlatformException）
/// ——静默返回，平台特性不作错误处理。
class ShareReceiver {
  static const _channel = MethodChannel('orbit/share');

  /// resumed 时取一次原生侧待取文本（每次都查——冷启动与回到前台都覆盖；
  /// 原生侧取走即清，无文本时 invoke 返回 null，开销可忽略）
  static Future<void> consume(WidgetRef ref) async {
    String? text;
    try {
      text = await _channel.invokeMethod<String>('takeSharedText');
    } on PlatformException {
      return; // iOS/桌面无该通道——静默（平台特性）
    } on MissingPluginException {
      return;
    }
    if (text == null || text.trim().isEmpty) return;
    final created = await createTaskFromSharedText(
      ref.read(orbitBridgeProvider),
      text.trim(),
    );
    if (created) invalidateBusinessCaches(ref);
  }

  /// 分享文本 → NLP 解析 → 建任务（桥注入，纯函数面可测）
  ///
  /// 项目/标签 ctx 用库内既有数据（分享方 App 无 Orbit 上下文，命中不了
  /// 就留原文——与快加栏口径一致）；标签挂载失败不阻断（部分成功口径，
  /// 与表单保存一致）。返回是否建成功（供调用方决定是否失效缓存）。
  static Future<bool> createTaskFromSharedText(
      OrbitBridge bridge, String text) async {
    final projects = await bridge.todoProjectList(const ListFilter());
    final labels = await bridge.todoLabelList(const ListFilter());
    final parsed = parseQuickInput(
      text,
      QuickInputContext(
        projects: [
          for (final p in projects) QuickInputRef(id: p.id, title: p.title),
        ],
        labels: [
          for (final l in labels) QuickInputRef(id: l.id, title: l.title),
        ],
        now: DateTime.now(),
      ),
    );

    final title = parsed.title.trim().isEmpty ? text : parsed.title.trim();
    try {
      final created = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: title,
        dueDate: parsed.dueDate?.millisecondsSinceEpoch,
        priority: parsed.priority == 0 ? null : parsed.priority,
        projectId: parsed.projectId,
      ));
      // NLP 命中的标签挂载（失败不阻断——部分成功口径）
      for (final labelId in parsed.labelIds) {
        try {
          await bridge.todoTaskLabelCreate(
              TodoTaskLabelCreateInput(taskId: created.id, labelId: labelId));
        } catch (_) {}
      }
      WaitToast.success('已从分享创建任务');
      return true;
    } catch (_) {
      WaitToast.destructive('分享创建任务失败');
      return false;
    }
  }
}
