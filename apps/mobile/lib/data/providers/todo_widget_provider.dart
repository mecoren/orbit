import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/todo_widget_service.dart';
import 'bridge_provider.dart';

/// TodoWidgetService 注入点（orbitBridgeProvider 同款模式）
///
/// 服务持有 home_widget 平台插件与 MethodChannel，进程内单例即可
///（快照数据实时从桥拉，无缓存态需要失效）。
final todoWidgetServiceProvider = Provider<TodoWidgetService>((ref) {
  return TodoWidgetService(bridge: ref.watch(orbitBridgeProvider));
});
