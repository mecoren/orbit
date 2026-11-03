import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/orbit_accents.dart';

/// 下拉刷新（原语层：自绘手势状态机 + 「弧 → 拉长圆 → 收圆转点」指示器）
///
/// **指示器口径（2026-11-03 改自绘）**：
/// 1. 下拉未达阈值：按进度扫开一段细弧（弧闭合即到达可释放阈值）；
/// 2. 越过阈值（`reached`）：保持 miuix 同口径的「拉长圆」——上圆 + 下圆 + 两段
///    竖线，长度 = 越过触发阈值后的下拉量，越拉越长，文案「释放刷新」；
/// 3. 松手（`refreshing`）：弹簧把下拉量吸附回阈值，拉长圆**收缩成正常圆**，
///    环内一枚实心点开始匀速绕行；刷新成功后环上浮淡出。
///
/// 几何与 `OrbitSpinner` 同源（描边 = 边长 8%、点半径 = 边长 10%、轨道内缩
/// 2 倍点半径），所以「收圆 + 点转」与全局加载指示器是同一语言。
///
/// **为什么不再直用 `MiuixPullToRefresh`**：库内 painter 只在 refreshing 状态
/// 画绕行点，阈值态画拉伸胶囊但**松手后直接跳成整圆 + 点**，且绘制与布局全部
/// 锁死，无法控制收圆过渡。本组件保留它的手势与弹簧口径（阻尼多项式、临界阻尼
/// 弹簧、0.25 触发比例、下拉带整体下移避让），绘制换成本文件口径。
///
/// **调用口径不变**：`onRefresh` 返回 Future，期间指示器自持绕行；调用点只需
/// 传 `child`（含纵向可滚动组件）。`color` 为 null 时取 [OrbitAccents.themeAccent]。
///
/// **指示器避让玻璃页头**：`edgeOffset + displacement` 仍只作为下拉带的绘制
/// 下移量（`Transform.translate`，不占布局），与 miuix 版视觉落点一致，
/// 不会被 `OrbitPageHeader` 盖住。
///
/// **短内容提示**：列表内容不满一屏时，滚动组件需 `AlwaysScrollableScrollPhysics`
/// 才能产生 overscroll 触发刷新。
class OrbitPullToRefresh extends StatefulWidget {
  const OrbitPullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.color,
    this.edgeOffset = 0,
    this.displacement = 0,
  });

  /// 刷新回调（返回 Future；期间指示器保持绕行）
  final Future<void> Function() onRefresh;

  /// 被包滚动视图
  final Widget child;

  /// 指示圈颜色（null = 全局主题强调色）
  final Color? color;

  /// 指示条避让量（原 `RefreshIndicator.edgeOffset`：状态栏 + 页头高）
  final double edgeOffset;

  /// 指示条相对避让位的下移量（原 `RefreshIndicator.displacement`）
  final double displacement;

  @override
  State<OrbitPullToRefresh> createState() => _OrbitPullToRefreshState();
}

/// 刷新指示器的五个视觉阶段（与手势状态一一对应）
enum _PullPhase { idle, pulling, reached, refreshing, complete }

class _OrbitPullToRefreshState extends State<OrbitPullToRefresh>
    with TickerProviderStateMixin {
  // ── 指示器几何（与 OrbitSpinner 同源，禁止改成裸数字）──

  /// 指示环边长（与 `OrbitSpinner` 默认值同档）
  static const double _indicatorSize = 20;

  /// 环描边宽度 / 边长
  static const double _strokeRatio = 0.08;

  /// 绕行点半径 / 边长
  static const double _dotRatio = 0.10;

  /// 圆弧起点：顶部（-90°），顺时针扫到闭合
  static const double _arcStartAngle = -math.pi / 2;

  // ── 下拉带布局 ──

  /// 指示圈与文案的间距
  static const double _textGap = AppDimens.space6;

  /// 文案区高度（含间距 + 行高余量；与 miuix 刷新头 `circleSize + 36` 同口径）
  static const double _textBlockHeight = 36;

  /// 触发刷新所需的阻尼进度比例（与 miuix 默认一致）
  static const double _refreshThresholdRatio = 0.25;

  /// 临界阻尼弹簧刚度所对应的响应周期（miuix 同值，0.4s 收敛）
  static const double _springResponseSeconds = 0.4;

  late final AnimationController _spring;
  late final AnimationController _spin;
  late final AnimationController _complete;

  double _containerHeight = 0;
  double _maxDragDistance = 0;
  double _fullDragRange = 0;

  /// 指示器完全展开所需的阻尼距离（容器高 / 24，miuix 同值）
  double _revealThreshold = 0;

  /// 触发刷新的阻尼距离
  double _triggerThreshold = 0;

  double _dragOffset = 0;
  double _currentTouch = 0;

  _PullPhase _phase = _PullPhase.idle;

  /// 刷新回调在途（同时挡住重复触发）
  bool _refreshing = false;
  bool _touching = false;
  bool _processingRelease = false;
  bool _rebounding = false;
  bool _hapticArmed = true;
  int _pointerCount = 0;
  int _springGeneration = 0;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController.unbounded(vsync: this)
      ..addListener(_driveSpring);
    // 绕行周期取全局加载动效 token；阈值态就开始转，刷新区间不重启，角度连续
    _spin = AnimationController(vsync: this, duration: AppMotion.spinnerOrbit);
    _complete = AnimationController(vsync: this, duration: AppMotion.normal)
      ..addListener(_driveComplete);
  }

  @override
  void dispose() {
    _spring.dispose();
    _spin.dispose();
    _complete.dispose();
    super.dispose();
  }

  // ── 阻尼换算（miuix / Compose 同源多项式）──

  void _configure(double height) {
    if (!height.isFinite || height <= 0) return;
    _containerHeight = height;
    _maxDragDistance = height;
    _fullDragRange = _obtainDampingDistance(1, height);
    _revealThreshold = height / 24;
    _triggerThreshold = _refreshThresholdRatio * _fullDragRange;
  }

  double get _revealProgress {
    final end = math.min(_revealThreshold, _triggerThreshold);
    if (end > 0) return (_dragOffset / end).clamp(0.0, 1.0);
    return _dragOffset > 0 ? 1.0 : 0.0;
  }

  /// 弧扫开进度：越过可释放阈值的瞬间恰好闭合成圆
  double get _arcProgress {
    if (_triggerThreshold <= 0) return 0;
    return (_dragOffset / _triggerThreshold).clamp(0.0, 1.0);
  }

  /// 拉长圆的长度：越过触发阈值后的下拉量（刚过阈值时为 0，继续下拉才拉长；
  /// 松手吸附回阈值时收缩为 0，即「变回正常圆」）
  double get _capsuleLength =>
      math.max(0.0, _dragOffset - _triggerThreshold);

  double get _stretch => math.max(0.0, _dragOffset - _revealThreshold);

  void _syncTouch() {
    _currentTouch = _obtainTouchDistance(_dragOffset, _maxDragDistance);
  }

  void _setOffset(double value) {
    if (_dragOffset == value) return;
    _dragOffset = value;
    _syncTouch();
    if (mounted) setState(() {});
  }

  void _updatePhase(_PullPhase next) {
    if (_phase == next) return;
    if (!mounted) return;
    _phase = next;
    // 阈值态仍是拉长圆（不转点），松手进入 refreshing 才收圆并启动绕行
    final spinning = next == _PullPhase.refreshing;
    if (spinning && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!spinning && _spin.isAnimating) {
      _spin.stop();
    }
  }

  void _applyDrag(double delta) {
    if (delta == 0 || _maxDragDistance <= 0) return;
    _currentTouch = (_currentTouch + delta).clamp(
      -_maxDragDistance,
      _maxDragDistance,
    );
    final normalized = math.min(_currentTouch.abs() / _maxDragDistance, 1.0);
    _dragOffset =
        _currentTouch.sign *
        _obtainDampingDistance(normalized, _maxDragDistance);
    _syncTouch();

    final next = _dragOffset > 0
        ? (_dragOffset >= _triggerThreshold
              ? _PullPhase.reached
              : _PullPhase.pulling)
        : _PullPhase.idle;
    if (next == _PullPhase.reached && _phase != _PullPhase.reached) {
      if (_hapticArmed) {
        _hapticArmed = false;
        HapticFeedback.selectionClick();
      }
    } else if (next != _PullPhase.reached) {
      _hapticArmed = true;
    }
    _updatePhase(next);
    setState(() {});
  }

  // ── 弹簧吸附 ──

  Future<bool> _animateSpringTo(double target) async {
    final generation = ++_springGeneration;
    _spring.value = _dragOffset;
    final spring = SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: math.pow(2 * math.pi / _springResponseSeconds, 2).toDouble(),
      ratio: 1,
    );
    try {
      await _spring
          .animateWith(SpringSimulation(spring, _spring.value, target, 0))
          .orCancel;
    } on TickerCanceled {
      return false;
    }
    if (!mounted || generation != _springGeneration) return false;
    _setOffset(target);
    return true;
  }

  void _driveSpring() => _setOffset(_spring.value);

  void _cancelSpring() {
    _springGeneration++;
    _spring.stop(canceled: true);
  }

  // ── 刷新流程 ──

  Future<void> _handleRelease() async {
    if (_processingRelease || _rebounding) return;
    _touching = false;
    if (_dragOffset <= 0) return;
    _processingRelease = true;
    try {
      if (_dragOffset >= _triggerThreshold) {
        await _refresh();
      } else {
        _rebounding = true;
        await _animateSpringTo(0);
        _rebounding = false;
        if (!mounted) return;
        if (!_touching && _phase != _PullPhase.refreshing) {
          _updatePhase(_PullPhase.idle);
          setState(() {});
        }
      }
    } finally {
      _rebounding = false;
      _processingRelease = false;
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    final settled = await _animateSpringTo(_revealThreshold);
    if (!mounted) return;
    if (!settled || _touching) {
      // 吸附途中被新的下拉取消（或手指重新按下）：释放内部锁，
      // 否则后续松手都会被「已在刷新」挡掉，指示器卡在展开态。
      _refreshing = false;
      return;
    }
    _updatePhase(_PullPhase.refreshing);
    setState(() {});
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) await _finishRefresh();
      _refreshing = false;
    }
  }

  Future<void> _finishRefresh() async {
    if (!mounted) return;
    _updatePhase(_PullPhase.complete);
    _complete.value = 0;
    try {
      await _complete.forward().orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted) return;
    _setOffset(0);
    _updatePhase(_PullPhase.idle);
    setState(() {});
  }

  void _driveComplete() {
    // 成功态：环上浮淡出（painter 按 completeProgress 画），下拉带同步收回
    _setOffset(_revealThreshold * (1 - _complete.value));
  }

  // ── 滚动通知（overscroll 驱动下拉）──

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_phase == _PullPhase.refreshing ||
        _phase == _PullPhase.complete ||
        // 松手吸附/刷新在途：列表自身的 overscroll 回弹也会发滚动通知，
        // 必须挡住，否则会打断弹簧吸附（下拉量停在半路、刷新不触发）
        _processingRelease ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }

    if (notification is OverscrollNotification) {
      final delta = _pullDownOverscroll(notification);
      if (delta > 0 && notification.metrics.extentBefore == 0) {
        _touching = true;
        _cancelSpring();
        _applyDrag(delta);
      }
    } else if (notification is ScrollUpdateNotification && _dragOffset > 0) {
      final delta = _upwardScrollDelta(notification);
      if (delta < 0) {
        _touching = true;
        _cancelSpring();
        _applyDrag(delta);
      }
    } else if (notification is ScrollEndNotification &&
        _pointerCount == 0 &&
        (_phase == _PullPhase.pulling || _phase == _PullPhase.reached)) {
      _handleRelease();
    }
    return false;
  }

  double _pullDownOverscroll(OverscrollNotification notification) {
    final value = notification.overscroll;
    return switch (notification.metrics.axisDirection) {
      AxisDirection.down => value < 0 ? -value : 0,
      AxisDirection.up => value > 0 ? value : 0,
      _ => 0,
    };
  }

  double _upwardScrollDelta(ScrollUpdateNotification notification) {
    final value = notification.scrollDelta ?? 0;
    return switch (notification.metrics.axisDirection) {
      AxisDirection.down => value > 0 ? -value : 0,
      AxisDirection.up => value < 0 ? value : 0,
      _ => 0,
    };
  }

  // ── 文案 ──

  String get _refreshText => switch (_phase) {
    _PullPhase.idle => '',
    _PullPhase.pulling => _revealProgress > 0.5 ? '下拉刷新' : '',
    _PullPhase.reached => '释放刷新',
    _PullPhase.refreshing => '正在刷新…',
    _PullPhase.complete => '刷新成功',
  };

  double get _refreshTextAlpha => switch (_phase) {
    _PullPhase.idle => 0,
    _PullPhase.pulling =>
      _revealProgress > 0.6 ? ((_revealProgress - 0.5) * 2).clamp(0.0, 1.0) : 0,
    _PullPhase.reached => 1,
    _PullPhase.refreshing => ((_revealProgress - 0.5) * 2).clamp(0.0, 1.0),
    _PullPhase.complete => (1 - _complete.value * 1.95).clamp(0.0, 1.0),
  };

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? OrbitAccents.themeAccent;
    final resolvedPadding = EdgeInsets.only(
      top: widget.edgeOffset + widget.displacement,
    ).resolve(Directionality.of(context));
    final text = _refreshText;
    final textAlpha = _refreshTextAlpha;

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        if ((_containerHeight - height).abs() > 0.01) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _configure(height);
            if (_phase == _PullPhase.refreshing && !_spring.isAnimating) {
              _animateSpringTo(_revealThreshold);
            }
          });
        }

        final headerHeight = _phase == _PullPhase.idle
            ? 0.0
            : (_indicatorSize + _textBlockHeight) * _revealProgress + _stretch;

        return Semantics(
          container: true,
          liveRegion:
              _phase == _PullPhase.refreshing || _phase == _PullPhase.complete,
          label: '下拉刷新',
          value: text.isEmpty ? null : text,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              _pointerCount++;
              _touching = true;
            },
            onPointerUp: (_) {
              _pointerCount = math.max(0, _pointerCount - 1);
              if (_pointerCount == 0) _handleRelease();
            },
            onPointerCancel: (_) {
              _pointerCount = math.max(0, _pointerCount - 1);
              if (_pointerCount == 0) _handleRelease();
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: _handleScrollNotification,
              child: Column(
                children: [
                  Transform.translate(
                    offset: Offset(0, resolvedPadding.top),
                    child: SizedBox(
                      width: double.infinity,
                      height: headerHeight,
                      child: ClipRect(
                        // 刷新头以动画高度展开，内容（指示圈 + 文案）按自然高度
                        // 顶部锚定，由 ClipRect 裁掉未展开部分；不加 OverflowBox
                        // 时 Column 会在受限高度里布局，下拉中段触发溢出断言。
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minHeight: 0,
                          maxHeight: double.infinity,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                // 拉长圆向下延伸，指示器区高度跟着胶囊走，
                                // 文案始终贴在胶囊底部 6px 处
                                height: _indicatorSize + _capsuleLength,
                                width: double.infinity,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: SizedBox.square(
                                    dimension: _indicatorSize,
                                    child: CustomPaint(
                                      painter: _OrbitRefreshPainter(
                                        phase: _phase,
                                        arcProgress: _arcProgress,
                                        capsuleLength: _capsuleLength,
                                        completeProgress: _complete.value,
                                        color: color,
                                        spin: _spin,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Opacity(
                                opacity: textAlpha,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: _textGap),
                                  child: Text(
                                    text,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: color,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 指示器绘制：下拉画弧、阈值态画拉长圆、松手后画「正常圆 + 绕行点」、
/// 成功态画上浮淡出的环
class _OrbitRefreshPainter extends CustomPainter {
  _OrbitRefreshPainter({
    required this.phase,
    required this.arcProgress,
    required this.capsuleLength,
    required this.completeProgress,
    required this.color,
    required this.spin,
  }) : super(repaint: spin);

  final _PullPhase phase;

  /// 弧扫开进度（0..1）；到 1 即越过可释放阈值
  final double arcProgress;

  /// 阈值态拉长圆的长度（0 = 正常圆）
  final double capsuleLength;
  final double completeProgress;
  final Color color;

  /// 绕行点相位（0..1 一圈）；pulling / complete 阶段不驱动
  final Animation<double> spin;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || phase == _PullPhase.idle) return;

    final side = size.shortestSide;
    final strokeWidth = side * _OrbitPullToRefreshState._strokeRatio;
    final radius = (side - strokeWidth) / 2;
    if (radius <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);

    switch (phase) {
      case _PullPhase.idle:
        return;
      case _PullPhase.pulling:
        // 弧随下拉进度扫开，到阈值（可释放）时恰好闭合
        final alpha = ((arcProgress - 0.2) / 0.8).clamp(0.0, 1.0);
        if (alpha <= 0 || arcProgress <= 0) return;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          _OrbitPullToRefreshState._arcStartAngle,
          2 * math.pi * arcProgress,
          false,
          Paint()
            ..color = color.withValues(alpha: alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeCap = StrokeCap.round,
        );
      case _PullPhase.reached:
        // 阈值态：miuix 同口径的「拉长圆」——上圆 + 下圆 + 左右两段竖线，
        // 长度随下拉继续增长；此阶段不画点（点留给松手后的 refreshing）
        final paint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round;
        final topY = center.dy;
        final bottomY = center.dy + capsuleLength;
        canvas.drawArc(
          Rect.fromCircle(center: Offset(center.dx, topY), radius: radius),
          math.pi,
          math.pi,
          false,
          paint,
        );
        canvas.drawArc(
          Rect.fromCircle(center: Offset(center.dx, bottomY), radius: radius),
          0,
          math.pi,
          false,
          paint,
        );
        canvas.drawLine(
          Offset(center.dx - radius, topY),
          Offset(center.dx - radius, bottomY),
          paint,
        );
        canvas.drawLine(
          Offset(center.dx + radius, topY),
          Offset(center.dx + radius, bottomY),
          paint,
        );
      case _PullPhase.refreshing:
        // 松手后：拉长圆已吸附收回成正常圆，环内实心点匀速绕行
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeCap = StrokeCap.round,
        );
        final dotRadius = side * _OrbitPullToRefreshState._dotRatio;
        final orbitRadius = radius - 2 * dotRadius;
        final angle = spin.value * 2 * math.pi;
        canvas.drawCircle(
          center +
              Offset(
                orbitRadius * math.cos(angle),
                orbitRadius * math.sin(angle),
              ),
          dotRadius,
          Paint()..color = color,
        );
      case _PullPhase.complete:
        // 成功收尾：环略微上浮并淡出（与 miuix 成功态同观感）
        final risingRadius = radius * math.max(1 - completeProgress, 0.9);
        canvas.drawCircle(
          Offset(center.dx, center.dy - radius - strokeWidth + risingRadius),
          risingRadius,
          Paint()
            ..color = color.withValues(
              alpha: (1 - completeProgress - 0.35).clamp(0.0, 1.0),
            )
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeCap = StrokeCap.round,
        );
    }
  }

  @override
  bool shouldRepaint(_OrbitRefreshPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.arcProgress != arcProgress ||
      oldDelegate.capsuleLength != capsuleLength ||
      oldDelegate.completeProgress != completeProgress ||
      oldDelegate.color != color;
}

double _obtainDampingDistance(double value, double range) {
  if (range <= 0) return 0;
  final x = value.clamp(0.0, 1.0);
  return (x - x * x + x * x * x / 3) * range;
}

double _obtainTouchDistance(double distance, double range) {
  if (range <= 0) return 0;
  final sign = distance.sign;
  final absolute = distance.abs().clamp(0.0, _obtainDampingDistance(1, range));
  final base = range - 3 * absolute;
  final cubeRoot = base == 0
      ? 0.0
      : base.sign * math.pow(base.abs(), 1 / 3).toDouble();
  return sign * (range - math.pow(range, 2 / 3) * cubeRoot);
}
