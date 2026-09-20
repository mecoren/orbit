import 'package:flutter/material.dart';

/// 应用动效 Token（时长 / 曲线 / 缩放档）
///
/// 动效参数的**单一来源**：所有动画时长与缓动一律取此处常量，
/// 视图内禁止出现裸 `Duration(milliseconds: …)` 与裸 `Curves.*`
/// （与 [AppDimens] 尺寸口径同规矩，docs/05 §七 常量速查卡）。
///
/// 命名沿用 docs/05 §七 的 fast/normal/slow 三档，其余按键位语义命名。
class AppMotion {
  AppMotion._();

  // ── 时长（duration）──

  /// 快速动画（按压反馈、状态切换、即时确认感）
  static const Duration fast = Duration(milliseconds: 150);

  /// 常规动画（图标切换、淡入淡出、勾选填充、星标弹跳、抽屉入场）
  static const Duration normal = Duration(milliseconds: 250);

  /// 慢速动画（容器形变、展开收起、同步对勾回弹、行入场）
  static const Duration slow = Duration(milliseconds: 300);

  /// 视图切换（日期选择器日/年月/年三态切换）
  static const Duration viewSwitch = Duration(milliseconds: 200);

  /// 完成态删除线绘制
  static const Duration strikethrough = Duration(milliseconds: 260);

  /// 页面入栈转场（docs/05 §一：入栈自右滑入）
  static const Duration pageEnter = Duration(milliseconds: 280);

  /// 页面出栈转场（反向播放，略快于入栈）
  static const Duration pageExit = Duration(milliseconds: 220);

  // ── 曲线（curve）──

  /// 默认收尾曲线（淡入淡出、图标切换、删除线绘制）
  static const Curve standard = Curves.easeOut;

  /// 页面入栈曲线
  static const Curve pageIn = Curves.easeOutCubic;

  /// 底部抽屉入场曲线（轻快滑入收尾；**不用过冲曲线**——全高抽屉过冲会
  /// 在上移后露出屏幕底部空白，观感是错位而非弹跳）
  static const Curve sheetEnter = Curves.easeOutCubic;

  /// 页面出栈曲线
  static const Curve pageOut = Curves.easeInCubic;

  /// 弹跳收尾曲线（星标弹跳、同步对勾回弹等小尺寸元素；
  /// 大尺寸容器不适用——过冲会产生可见错位）
  static const Curve bounce = Curves.easeOutBack;

  // ── 缩放档（scale）──

  /// 星标切换弹跳峰值
  static const double starBounceScale = 1.3;

  /// 拖拽抬起缩放（任务行 / 项目行拖动中）
  static const double dragLiftScale = 1.02;
}
