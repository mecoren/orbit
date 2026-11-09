import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';

/// 任务勾选框（设计系统 v3 原语层：方角形态，与桌面端同源）
///
/// **2026-11-09 对齐桌面端**：上一版用 flutter_miuix `MiuixCheckbox`
/// （HyperOS 圆形），与桌面 `task-list-view` / 详情抽屉的方角勾选框不一致；
/// 现自绘 **4px 圆角方框 + 2px 描边 + 白勾**（桌面 `h-5 w-5 rounded-[4px]
/// border-2` 同款）。列表 / 看板 / 矩阵 / 表格 / 日历 / 详情标题与子任务共用
/// 本原语，改一处双端同形。
///
/// 语义不变：
/// - 未勾选 = 空心方框，描边色由 [borderColor] 承载优先级（P0「无」回落中性灰）；
/// - 勾选 = 弱化灰实底（[AppColorSet.deactivatedText]）+ 白勾，已完成行整行
///   置灰（docs/05 §4.5，不保留待办蓝——`done_gray_test` 锁定）。
///
/// **热区**：勾选是高频精确点击，22–28px 图形在密集列表里误触率高；布局盒取
/// `max(size, 44)`、图形居中，可点面积扩到触控标准档而视觉边长不变。
class OrbitCheckbox extends StatelessWidget {
  const OrbitCheckbox({
    super.key,
    required this.checked,
    required this.onToggle,
    this.size = AppDimens.taskCheckboxSize,
    this.borderColor,
  });

  /// 方框圆角：与桌面 `rounded-[4px]` 同值
  static const double cornerRadius = 4;

  /// 描边宽度：与桌面 `border-2` 同档
  static const double strokeWidth = 2;

  /// 完成态白勾（测试 / 无障碍定位用）
  static const Key checkKey = ValueKey('orbit-checkbox-check');

  /// 热区外扩下限 44
  static const double minHitExtent = 44;

  final bool checked;
  final VoidCallback onToggle;

  /// 未勾选态描边色；null = 组件默认中性灰。
  ///
  /// 任务列表用它承载优先级语义（高/紧急/立即以橙红方框表达，P0「无」
  /// 回落默认灰）——同一信息不再于副标题重复一枚色点（docs/05 §4.5）。
  final Color? borderColor;

  /// 视觉边长（列表行 20 / 详情标题 28 / 子任务 22；可点热区不小于 44）
  final double size;

  void _handleChanged() {
    // 触感只给「勾选确认」（未选→已选）；点回来取消完成不震（docs/05 §9.1）
    if (!checked) HapticFeedback.selectionClick();
    onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final ringColor =
        borderColor ?? colors.secondaryText.withValues(alpha: 0.4);
    final doneColor = colors.deactivatedText;

    return Semantics(
      button: true,
      checked: checked,
      label: checked ? '标记未完成' : '标记完成',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleChanged,
        child: SizedBox.square(
          dimension: size < minHitExtent ? minHitExtent : size,
          child: Center(
            child: AnimatedContainer(
              width: size,
              height: size,
              alignment: Alignment.center,
              duration: AppMotion.fast,
              curve: AppMotion.standard,
              decoration: BoxDecoration(
                // 勾选前透明（露出页面/行底色），勾选后弱化灰实底
                color: checked ? doneColor : Colors.transparent,
                borderRadius: BorderRadius.circular(cornerRadius),
                border: Border.all(
                  color: checked ? doneColor : ringColor,
                  width: strokeWidth,
                ),
              ),
              child: AnimatedSwitcher(
                duration: AppMotion.fast,
                switchInCurve: AppMotion.bounce,
                switchOutCurve: AppMotion.standard,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: checked
                    ? _CheckMark(
                        key: checkKey,
                        size: size * 0.6,
                        color: Colors.white,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 完成态白勾：与桌面 `CheckSvg` 同形（viewBox 24、path `M20 6 L9 17 l-5-5`、
/// stroke 3、圆头线帽与转角），按方框边长等比缩放。
class _CheckMark extends StatelessWidget {
  const _CheckMark({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _CheckMarkPainter(color: color)),
      );
}

class _CheckMarkPainter extends CustomPainter {
  const _CheckMarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 20 / 24, h * 6 / 24)
      ..lineTo(w * 9 / 24, h * 17 / 24)
      ..lineTo(w * 5 / 24, h * 12 / 24);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 3 / 24
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckMarkPainter old) => old.color != color;
}
