import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 全局 Navigator key（app_router 装配 + WaitToast 浮层挂载点）
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 便捷跳转（供无 context 场景备用；常规导航直接用 context.push）
GoRouter? get rootRouter => rootNavigatorKey.currentState?.context != null
    ? GoRouter.of(rootNavigatorKey.currentState!.context)
    : null;
