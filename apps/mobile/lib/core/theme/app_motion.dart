import 'package:flutter/material.dart';

/// 应用动效 Token（时长 / 曲线 / 缩放档）—— 设计系统 v2
///
/// 动效参数的**单一来源**：所有动画时长与缓动一律取此处常量，
/// 视图内禁止出现裸 `Duration(milliseconds: …)` 与裸 `Curves.*`。
///
/// v2 变化：旧版一律 `Curves.easeOut`，起势平缓、收尾拖沓，观感"生硬"。
/// v2 引入阶梯化缓动：
/// - [standard]   通用（easeOutQuint 类，收尾干脆利落）
/// - [emphasized] 大位移转场（M3 emphasized，起势果断 + 收尾沉稳）
/// - [decelerate] 元素入场（快速起步）
/// - [accelerate] 元素退场（加速离场）
class AppMotion {
  AppMotion._();

  // ── 时长（duration）──

  /// 快速动画（按压反馈、状态切换、即时确认感）
  static const Duration fast = Duration(milliseconds: 150);

  /// 中速动画（图标切换、淡入淡出、勾选填充、列表行入场）
  static const Duration normal = Duration(milliseconds: 220);

  /// 慢速动画（容器形变、展开收起、同步对勾回弹）
  static const Duration slow = Duration(milliseconds: 300);

  /// 视图切换（日期选择器日/年月/年三态切换）
  static const Duration viewSwitch = Duration(milliseconds: 200);

  /// 完成态删除线绘制
  static const Duration strikethrough = Duration(milliseconds: 260);

  /// 页面入栈转场（自右滑入）
  static const Duration pageEnter = Duration(milliseconds: 280);

  /// 页面出栈转场（反向播放，略快于入栈）
  static const Duration pageExit = Duration(milliseconds: 220);

  /// 骨架呼吸周期（首屏加载占位专用；往返一次的时长）
  static const Duration skeletonPulse = Duration(milliseconds: 1100);

  // ── 曲线（curve）──

  /// 通用收尾曲线：起势快、收尾干净（easeOutQuint 近似）
  ///
  /// 旧版 `Curves.easeOut` 在长距离位移上末尾明显拖尾，是"生硬/廉价"的
  /// 主要来源之一；本曲线在中后段迅速收敛。
  static const Curve standard = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 强调转场曲线（M3 emphasized：起势果断、中途缓、收尾沉稳）
  ///
  /// 用于页面转场、底部抽屉入场等大位移场景。
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// 元素入场（快速起步，适合淡入/缩放出现）
  static const Curve decelerate = Cubic(0.05, 0.7, 0.1, 1.0);

  /// 元素退场（缓缓起步、加速离场）
  static const Curve accelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  /// 页面入栈曲线
  static const Curve pageIn = emphasized;

  /// 底部抽屉入场曲线（**不用过冲曲线**——全高抽屉过冲会在上移后露出屏幕
  /// 底部空白，观感是错位而非弹跳）
  static const Curve sheetEnter = emphasized;

  /// 页面出栈曲线
  static const Curve pageOut = accelerate;

  /// 弹跳收尾曲线（星标弹跳、同步对勾回弹等小尺寸元素；
  /// 大尺寸容器不适用——过冲会产生可见错位）
  static const Curve bounce = Curves.easeOutBack;

  /// 呼吸曲线（骨架明暗往返：对称过渡，来回观感一致；
  /// 不用 standard——easeOut 系单程收尾快，往返播放会"一头沉"）
  static const Curve breathe = Curves.easeInOut;

  // ── 缩放档（scale）──

  /// 星标切换弹跳峰值
  static const double starBounceScale = 1.3;

  /// 拖拽抬起缩放（任务行 / 项目行拖动中）
  static const double dragLiftScale = 1.02;

  /// 按压缩放（可点击卡片/按钮的按下反馈）
  static const double pressScale = 0.97;
}
