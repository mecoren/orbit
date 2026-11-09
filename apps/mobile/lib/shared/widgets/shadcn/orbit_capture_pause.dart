import 'package:flutter/material.dart';

/// 整页背景捕获的全局暂停计数（2026-11-09）
///
/// `OrbitScrollAwareBackdropCapture` 在渲染对象层订阅本计数：>0 时不录新
/// 快照，回到 0 时 `markNeedsPaint` 补录一次。生产者只有两类：
/// - `OrbitPopupGlassMotion`：锚定弹层形变窗（有限 690ms 窗口）；
/// - [OrbitCapturePause]：常驻/无界逐帧动画（骨架呼吸、spinner）挂载期持有。
///
/// 全局计数而非 InheritedWidget：弹层承载可能挂在根 Overlay（取不到页面树
/// 里的 scope），而同一时刻只会有一批相关动画在跑；计数变化只改渲染对象的
/// bool，不触发任何 widget 重建，可在 build 阶段安全通知。
final ValueNotifier<int> orbitCapturePauses = ValueNotifier<int>(0);

/// 挂载期冻结整页背景捕获（常驻动画专用）
///
/// 用于「没有明确动画窗口、只要组件在树上就逐帧重绘」的加载态：骨架呼吸、
/// [OrbitSpinner] 等。它们没有滚动通知、没有键盘、也没有弹层形变窗，三档
/// 冻结都拦不住，却会一直驱动捕获树每帧 `toImageSync` 整页。加载态内容本就
/// 是静态占位，冻结期间玻璃沿用最后一帧零观感损失；组件卸载即放行并补录。
///
/// [active] 为 false 时不持令牌，供调用方按状态收放（默认挂载即冻结）。
class OrbitCapturePause extends StatefulWidget {
  const OrbitCapturePause({
    super.key,
    this.active = true,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<OrbitCapturePause> createState() => _OrbitCapturePauseState();
}

class _OrbitCapturePauseState extends State<OrbitCapturePause> {
  bool _held = false;

  void _sync() {
    final want = widget.active;
    if (want == _held) return;
    _held = want;
    if (want) {
      orbitCapturePauses.value++;
    } else {
      final current = orbitCapturePauses.value;
      if (current > 0) orbitCapturePauses.value = current - 1;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(OrbitCapturePause oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    if (_held) {
      final current = orbitCapturePauses.value;
      if (current > 0) orbitCapturePauses.value = current - 1;
      _held = false;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
