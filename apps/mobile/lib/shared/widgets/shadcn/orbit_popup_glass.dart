/// 锚定弹层的玻璃性能闸门（2026-11-07）
///
/// 真机反馈「弹窗菜单太卡」——今天页头标题切换、清单/详情页 ⋮、快速添加五处
/// 卡片、底栏「更多」全部同源（`MiuixGlassTransformPopup` / `MiuixGlassDropdownPopup`）。
/// 定位到两段开销，都在库内形变承载上：
///
/// 1. **每帧重算玻璃纹理**：`MiuixGlassPanel` 每次重绘都是「离屏模糊 + 两趟混色 +
///    `toImageSync`」，而纹理缓存键含面板 `origin/size`——形变期间二者逐帧变化，
///    缓存逐帧全盘失效，每帧 3 次 `toImageSync` 全量重跑（材质档此前已从库默认的
///    blur 60 收到 32，见各承载的注释；再往下收就损观感了）；
/// 2. **弹簧尾巴空转**：库内开场/退场弹簧按 `Tolerance(.0015)` 要跑到 ~690ms，
///    而卡面在 ~320ms 就已贴合目标矩形（退场那边已由
///    `orbit_menu_popup.dart` 的 `_transformExitCutoff` 截断）——多出来的
///    ~370ms 逐帧重画整张玻璃卡，真机就是这一段在掉帧。
///
/// 本件把「卡面材质」与「动画帧数」一起收口，所有锚定弹层共用：
///
/// - 形变窗口 [OrbitPopupGlass.morphWindow]（320ms）内卡面**不采样背景**：库内
///   无快照分支直接画实色圆角（[OrbitPopupGlass.fill]），不跑离屏模糊/混色/
///   `toImageSync`；描边也关掉（1px 高光在运动中不可辨，省一趟全分辨率 shader）。
///   观感上仍是同一张磨砂白卡——本仓页面以白卡为主，97% 白底与玻璃档肉眼无差；
/// - 窗口结束**同帧**做两件事：切回真玻璃（此时卡面已静止 → 纹理只准备一次、
///   之后全程命中缓存）＋ 用 `TickerMode` 冻结承载的弹簧（不再逐帧重绘）。
///   两件事必须同帧：卡面若还在动就切玻璃，切完那几十帧又开始逐帧 miss；
/// - 冻结的代价是几何停在弹簧的 ~98% 处（≤1.5%，400 高的卡差 4–6px，肉眼不可辨），
///   以及行按压高亮被一起静音（行在 `OverlayPortal` 子树里，同受 `TickerMode`）。
///   故**按下弹层任意位置即解冻**——按压高亮照常，且此时弹簧一步归位；
/// - 退场立刻解冻（不解冻回收动画不动），卡面回到实色（退场只有 320ms，见
///   `_transformExitCutoff`）；
/// - 只冻结**开场**形变。二级面板这类「弹层已开」的后续形变只解冻、不再冻结：
///   二级面板的退场（`MiuixGlassSecondaryPopup` 收回到锚行）要靠库内 ticker 才
///   移除 `OverlayPortal`，冻结会把它停在屏幕上；而它的进场量级本就小一半。
///
/// **不要**把这里换成固定 `Duration` 的 `AnimatedOpacity` 之类：冻结是「停掉库内
/// 的 ticker」，不是另造一段动画——另造一段只会在收尾处再补一次全分辨率重绘。
library;

import 'dart:async';

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerDownEvent, PointerEvent;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 弹层卡面的材质与形变期降级档（唯一口径，勿在调用点各调一套）
class OrbitPopupGlass {
  OrbitPopupGlass._();

  /// 形变窗口：之后库内弹簧只剩 1–2px 的过冲回摆
  ///
  /// 与 `orbit_menu_popup.dart` 的 `_transformExitCutoff` 同一测量口径（探针
  /// 实测卡面 320ms 已贴合目标矩形，弹簧跑到 690ms 才收尾）。
  static const morphWindow = Duration(milliseconds: 320);

  /// 卡面材质（与页头 ⋮ 菜单同档：puredThinGlass + blurRadius 32）
  ///
  /// 必须是缓存实例：`MiuixGlassMaterial` 是库内纹理缓存的 key 之一，逐帧新建
  /// 等价材质会让缓存全盘失效（值相等是性能要件，不只是礼貌）。
  static final _materialLight = MiuixGlassMaterials.puredThinGlassLight
      .copyWith(blurRadius: 32);
  static final _materialDark = MiuixGlassMaterials.puredThinGlassDark.copyWith(
    blurRadius: 32,
  );

  static MiuixGlassMaterial material(bool isDark) =>
      isDark ? _materialDark : _materialLight;

  /// 形变期卡面底色（无背景采样时的实色填充；留 3% 透明让下层透出一点）
  static const _fillLight = Color(0xF7FFFFFF);
  static const _fillDark = Color(0xF72C2C2C);

  static Color fill(bool isDark) => isDark ? _fillDark : _fillLight;

  /// 卡面视觉档
  ///
  /// [glass] 为 false（形变期）= 实色卡面 + 不画描边；为 true（落定后）= 真玻璃
  /// + 库内标准描边。`containerColor` 两档都给同一底色——它只在「没有采样快照」
  /// 时兜底（首帧），不给就会落到库内默认的纯白/纯炭黑。
  static MiuixGlassPopupVisuals visuals({
    required bool isDark,
    required bool glass,
  }) => MiuixGlassPopupVisuals(
    material: material(isDark),
    containerColor: fill(isDark),
    showStroke: glass,
  );
}

/// 形变弹层的玻璃 + 帧数闸门（用法见文件头）
///
/// 宿主只需把「弹层是否打开」与「每次新形变」告诉本件，卡面材质、背景采样与
/// 弹簧冻结由它统一决定：
/// ```dart
/// OrbitPopupGlassMotion(
///   open: _open,
///   builder: (context, glass) => MiuixGlassTransformPopup(
///     show: _open,
///     backdrop: glass ? widget.backdrop : null,
///     visuals: OrbitPopupGlass.visuals(isDark: isDark, glass: glass),
///     ...
///   ),
/// )
/// ```
class OrbitPopupGlassMotion extends StatefulWidget {
  const OrbitPopupGlassMotion({
    super.key,
    required this.open,
    required this.builder,
    this.motionToken,
  });

  /// 弹层是否打开
  ///
  /// true→false（收场）立即解冻并把卡面切回实色；false→true（开场）开启形变
  /// 窗口：实色卡面 → 窗口结束切玻璃并冻结弹簧。
  final bool open;

  /// 每次**弹层已开后的新形变**换一个值（二级面板堆叠展开、返回上级）
  ///
  /// 只解冻、不再冻结、也不动卡面材质（已落定的玻璃卡不闪回实色）：二级面板的
  /// 退场靠库内 ticker 才能移除 `OverlayPortal`，冻结会把它停在屏幕上。
  final Object? motionToken;

  /// 承载构建；`glass` = 卡面此刻是否可以采样背景
  final Widget Function(BuildContext context, bool glass) builder;

  @override
  State<OrbitPopupGlassMotion> createState() => _OrbitPopupGlassMotionState();
}

class _OrbitPopupGlassMotionState extends State<OrbitPopupGlassMotion> {
  /// 卡面是否已落定（可切真玻璃）
  bool _glass = false;

  /// 弹簧是否已冻结（形变窗口结束）
  bool _frozen = false;

  /// 全局指针路由是否已注册（解冻时据此决定要不要摘）
  bool _routing = false;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.open) _beginEntrance();
  }

  @override
  void didUpdateWidget(OrbitPopupGlassMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open != oldWidget.open) {
      widget.open ? _beginEntrance() : _endMotion();
      return;
    }
    if (widget.open && widget.motionToken != oldWidget.motionToken) {
      _thawForSideMotion();
    }
  }

  /// 开场：实色卡面 + 解冻，窗口到点切玻璃并冻结
  void _beginEntrance() {
    _timer?.cancel();
    _setState(glass: false, frozen: false);
    _arm();
  }

  /// 二级面板等后续形变：卡面保持玻璃（不闪回实色），只解冻放行它的动画
  void _thawForSideMotion() {
    _timer?.cancel();
    _timer = null;
    _setState(frozen: false);
  }

  /// 收场：取消计时、立即解冻（回收动画要靠库内 ticker）、卡面回实色
  void _endMotion() {
    _timer?.cancel();
    _timer = null;
    _setState(glass: false, frozen: false);
  }

  void _arm() {
    _timer = Timer(OrbitPopupGlass.morphWindow, () {
      if (!mounted) return;
      // 同帧切玻璃 + 冻结：见文件头（卡面静止后切，纹理只准备一次）
      _setState(glass: true, frozen: true);
    });
  }

  /// 写状态（`setState` 只在真的变了时才做，避免开场同帧多余重建）
  void _setState({bool? glass, bool? frozen}) {
    final nextGlass = glass ?? _glass;
    final nextFrozen = frozen ?? _frozen;
    if (nextGlass == _glass && nextFrozen == _frozen) return;
    setState(() {
      _glass = nextGlass;
      _frozen = nextFrozen;
    });
    _syncPointerRoute();
  }

  /// 冻结期间才挂全局指针路由（解冻/销毁即摘；`removeGlobalRoute` 对未注册的
  /// 路由会断言，故自己记一份注册状态）
  void _syncPointerRoute() {
    if (_frozen == _routing) return;
    _routing = _frozen;
    if (_frozen) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    } else {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    }
  }

  /// 冻结期间按下即解冻：`TickerMode` 会连行的按压弹簧一起静音，按下补回
  ///
  /// 走 `pointerRouter` 全局路由而不是 `Listener`：弹层卡面挂在 `OverlayPortal`
  /// 的 overlay 子树里，由 `_RenderTheater` 直接命中，祖先 `Listener` 收不到事件。
  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _setState(frozen: false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frozen = false;
    _syncPointerRoute();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: !_frozen,
    child: widget.builder(context, _glass),
  );
}
