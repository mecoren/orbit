import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

/// 侧滑手势的方向锁（2026-11-06）
///
/// **痛点**：任务列表上下滚动时手指常带几像素横向抖动，而 Flutter 手势
/// 竞技场里**内层**的横向识别器（`flutter_slidable`）会先于外层 `ListView`
/// 的纵向识别器达到 `kTouchSlop` 并夺权——表现为「明明想上下滚，却把
/// 某一行滑出了删除 / 完成面板」。`Slidable` 自身没有方向判定（只看主轴位移
/// 是否超过 slop），故在它外侧挂一层 [Listener] 旁听指针（[Listener] 不进
/// 竞技场，不影响点击、长按与滚动）：
///
/// - 首个几像素内判定手势主轴，**纵向占优即把 [builder] 的 `swipeEnabled`
///   置 false**：`Slidable` 的横向识别器当场退出竞技场，本次手势完整交还
///   外层滚动；
/// - 横向占优则本次手势内不再干预（侧滑保持原有手感）；
/// - **打断必回弹**：一旦横向识别器已经跟手（`SlidableController.ratio`
///   非零），摘掉手势后不会再有 `onDragEnd` 来定夺开合，行会**停在半开**——
///   这是真机反馈「快速斜滑卡一截」（2026-11-06）的根因。故判定纵向时同步
///   [SlidableController.close]，把已带出的位移平滑收回，绝不停在中间；
/// - 手指抬起 / 取消后复位，下一次触摸重新判定。
class OrbitSwipeGuard extends StatefulWidget {
  const OrbitSwipeGuard({
    super.key,
    required this.builder,
    this.lockSlop = _defaultLockSlop,
    this.axisBias = _defaultAxisBias,
  });

  /// 构造受保护内容；`swipeEnabled=false` 时应关掉对应手势开关
  /// （`Slidable(enabled: swipeEnabled)`），并把 [controller] 交给同一个
  /// `Slidable`（`Slidable(controller: controller)`，用于回弹兜底）。
  final Widget Function(
    BuildContext context,
    bool swipeEnabled,
    SlidableController controller,
  )
  builder;

  /// 判定主轴所需的最小位移（逻辑像素）
  final double lockSlop;

  /// 主轴需比副轴明显的倍数；`>1` 即纵向优先，避免 45° 斜拖在两轴间摇摆
  final double axisBias;

  /// 6px：手指慢速拖动（60Hz 约 2~4px/帧）也能在横向 slop 之前判出方向
  static const double _defaultLockSlop = 6;

  /// 1.2：斜向歧义区（接近 45°）判为纵向——上下滚动是高频操作，侧滑是
  /// 明确的横向意图，优先保护前者
  static const double _defaultAxisBias = 1.2;

  @override
  State<OrbitSwipeGuard> createState() => _OrbitSwipeGuardState();
}

class _OrbitSwipeGuardState extends State<OrbitSwipeGuard>
    with SingleTickerProviderStateMixin {
  /// 与 `Slidable` 共享同一个 controller：打断时才能把半开姿态收回去
  late final SlidableController _slidable = SlidableController(this);

  Offset _origin = Offset.zero;

  /// 只跟第一根手指；多指（缩放 / 双指长按）不参与判定
  int? _pointer;

  /// 本次手势方向已判定，后续 move 不再改变结论
  bool _decided = false;

  /// 本次手势判定为纵向：禁用侧滑
  bool _blocked = false;

  @override
  void dispose() {
    _slidable.dispose();
    super.dispose();
  }

  void _handleDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _origin = event.position;
    _decided = false;
    // up/cancel 已复位，这里兜底（例如指针在系统层面被回收）
    if (_blocked) setState(() => _blocked = false);
  }

  void _handleMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _decided) return;
    final delta = event.position - _origin;
    final dx = delta.dx.abs();
    final dy = delta.dy.abs();

    if (dy >= widget.lockSlop && dy > dx * widget.axisBias) {
      _decided = true;
      if (_blocked) return;
      setState(() => _blocked = true);
      // 横向识别器可能已经跟手：摘掉后不会再有 onDragEnd，必须自己收回，
      // 否则 ratio 会停在半开（「卡一截」）
      if (_slidable.ratio != 0) unawaited(_slidable.close());
    } else if (dx >= widget.lockSlop && dx > dy * widget.axisBias) {
      // 横向手势：放行本行侧滑，本次手势内不再干预
      _decided = true;
    }
  }

  void _handleUp(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _decided = false;
    if (_blocked) setState(() => _blocked = false);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handleDown,
      onPointerMove: _handleMove,
      onPointerUp: _handleUp,
      onPointerCancel: _handleUp,
      child: widget.builder(context, !_blocked, _slidable),
    );
  }
}
