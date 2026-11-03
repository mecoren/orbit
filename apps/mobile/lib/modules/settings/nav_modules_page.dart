/// 功能模块配置页（底部导航可配置；「更多」面板「编辑」入口，对齐竞品）
///
/// **顶部底栏预览 + 两段列表**：预览底栏落位（启用序前
/// [NavModulesState.bottomTabLimit] 个模块 + 固定「更多」位，只读，启停/
/// 重排实时跟随——编辑操作页顶部预览同口径）；已启用（红圈减号 = 停用）/
/// 未启用（绿圈加号 = 启用）段内右端拖拽手柄重排。规则见 [NavModulesState]：
/// 底栏 = 启用序前 [NavModulesState.bottomTabLimit] 个模块 + 固定「更多」
/// 动作位，其余启用模块收进「更多」面板；最后一个启用模块不可停用
/// （减号置灰）。配置即写即落盘（[navModulesProvider]），底栏/面板实时跟随重建。
///
/// 交互与编辑操作页（[QuickActionsPage]）同套语言：
/// - 行**左右滑动**在两段间移动（滑出 + 对侧淡入，预览图标同步滑到新槽位），
///   与行首圆形加/减按钮同语义（快捷路径）；滑动方向不区分左右，归属只由
///   所在卡片决定。**滑动过程中预览跟手**：`Dismissible.onUpdate` 的手势进度
///   按阈值归一后直接驱动预览图标让位/腾槽（滑出段淡出让位，滑入段幽灵图标
///   淡入占位），过阈值时一次触感确认，取消回弹则沿原路跟回；
/// - 拖动右侧手柄排序与跨段直移（抬起放大 + 轻触感反馈，与任务行同口径；
///   手指可在两张卡片之间直拖：悬停段/槽位实时映射，预览按落位结果预演，
///   跨段翻越时触感确认，松手即提交；落位行挂一次入场动画）。
/// - 槽位映射按列表高度比例折算（行内带简介、高度不一，不能沿用编辑操作页
///   的 `touchTarget` 整除口径）。
///
/// **组件承载（对照 flutter_miuix 1.3.0 逐个核过）**：卡片与预览底 =
/// `MiuixCard`（[OrbitCard] 收口，squircle + 同形描边）、行 =
/// `MiuixBasicComponent`（标题 headline1 / 简介 body2 / 最小行高 56 / 槽位间距
/// 8）、启停圆钮 = `MiuixIconButton(backgroundColor:)`（[OrbitIconButton] 收口，
/// 32 紧凑档）、行间分隔线 = `MiuixHorizontalDivider`（[OrbitDivider]）、
/// 全部文字 = `MiuixText`（随外观页字重档联动）。库内**确无等价物**的只有两处：
/// **底栏落位预览**（`MiuixNavigationBar` 是交互栏且材质要采样页面背景，配置页
/// 无可采样内容，故降级为静态示意图）与**右端拖拽手柄**（库无拖拽行组件、图标
/// 集也无 drag 字形，沿用 lucide `gripVertical` + `ReorderableDragStartListener`，
/// 尺寸/配色仍取 miuix 口径）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../shared/widgets/shadcn/orbit_card.dart';
import '../../shared/widgets/shadcn/orbit_divider.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_icon_button.dart';
import '../shell/nav_modules.dart';

/// 横滑换段的滑动阈值（与编辑操作页同值）：`Dismissible.dismissThresholds`
/// 与预览跟手位移共用这一个常量——手势进度（行位移占宽比 0…1）除以它即
/// 预览插值进度（0…1，钳制），1 = 落位后的最终布局。
const double _swipeThreshold = 0.4;

/// 行首启停圆钮边长：miuix 图标钮（`MiuixIconButton`）的紧凑档，
/// 整圆底 + 16 号加减号（库默认 40 是独立动作位，行内用 32 才不压行高）。
const double _toggleExtent = 32;

/// 列表行之间的分隔线左缩进：对齐行标题文字起点。
///
/// 圆钮 32 + 圆钮与图标间隙 8 + 模块图标 22 + miuix 槽位间隙 8
/// （`MiuixBasicComponent` 的 `startAction` → 中心内容固定 8 间距）；行自身
/// 不吃水平内边距（见 [_moduleRow]），故分隔线容器与行的左基准同一条。
const double _dividerIndent = _toggleExtent +
    AppDimens.space8 +
    AppDimens.iconSizeMd +
    8;

/// 横滑过程中的实时快照（驱动预览图标跟手位移）。
///
/// 数据源 = `Dismissible.onUpdate`（它监听行位移控制器：手指拖动、松手回弹、
/// 惯性滑出都会持续回调，进度归零即自然复位，无需定时器收尾）。
class _SwipeLive {
  const _SwipeLive({
    required this.module,
    required this.fromEnabled,
    required this.progress,
  });

  /// 被横滑的模块
  final OrbitNavModule module;

  /// 它来自已启用段（true）还是未启用段（false）
  final bool fromEnabled;

  /// 预览插值进度 0…1（= 手势进度 ÷ [_swipeThreshold] 后钳制）
  final double progress;
}

class NavModulesPage extends ConsumerStatefulWidget {
  const NavModulesPage({super.key});

  @override
  ConsumerState<NavModulesPage> createState() => _NavModulesPageState();
}

class _NavModulesPageState extends ConsumerState<NavModulesPage> {
  /// 抬起中的模块（预览行对应图标着强调色 + 行文案加粗；落位即清）
  OrbitNavModule? _lifting;

  /// 抬起项来自已启用段（true）还是未启用段（false）
  bool _liftingFromEnabled = true;

  /// 拖拽中手指当前所在的段（true = 已启用段，false = 未启用段，
  /// null = 都不在）：与来源段不同即跨段拖拽，落点段决定提交去向，
  /// 预览实时预演落位结果。
  bool? _hoverSection;

  /// 拖拽中悬停段内的槽位序号：拖拽排序时预览按此实时重排；
  /// 落位提交/取消即清（`onReorderEnd`）。
  int? _hoverSlot;

  /// 拖拽中最后一个指针位置（落点判定用；松手瞬间即上一次 move 的位置）。
  Offset? _lastPointer;

  /// 本次拖拽落点已提交（`onReorderItem` 与 `onReorderEnd` 都会到，用它防双提交）
  bool _dropHandled = false;

  /// 拖拽开始时两段的长度快照（拖拽中提交前长度不变，槽位钳制用，避免逐帧读配置）
  (int, int)? _dragLens;

  /// 段列表容器 key（悬停槽位定位用：手指全局坐标 → 列表局部 Y → 槽位）
  final _enabledListKey = GlobalKey();
  final _hiddenListKey = GlobalKey();

  /// 横滑跟手快照（只重建预览行，不碰列表；落位提交/回弹归零时清）
  final ValueNotifier<_SwipeLive?> _swipeLive = ValueNotifier(null);

  /// 刚换段落位的模块：落位行播一次入场动画（淡入 + 滑入），播完即清——
  /// 页面初建、滚动重建都不播（滚动必然发生在后续帧，清掉后重建不再重播）。
  final Set<OrbitNavModule> _arrived = {};

  @override
  void dispose() {
    _swipeLive.dispose();
    super.dispose();
  }

  /// 段内重排落点（`onReorderItem`）：落点段决定提交去向——
  /// 落回本段即段内重排，落在另一段即跨段搬移（拖拽中手指可跨过卡片边界）。
  void _onReorderEnabled(int oldIndex, int newIndex) {
    _commitDrop(
      sourceEnabled: true,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
  }

  /// 段内重排落点（未启用段；去向判定同上）
  void _onReorderDisabled(int oldIndex, int newIndex) {
    _commitDrop(
      sourceEnabled: false,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
  }

  /// 拖拽落点统一提交：按松手位置所在段路由（跨段即搬移，同段即重排）。
  void _commitDrop({
    required bool sourceEnabled,
    required int oldIndex,
    required int newIndex,
  }) {
    if (_dropHandled) return;
    _dropHandled = true;
    final nav = ref.read(navModulesProvider);
    final dropSection = _locate(
          _lastPointer,
          enabledLen: nav.enabled.length,
          disabledLen: nav.disabled.length,
        )?.$1 ??
        sourceEnabled;
    if (dropSection == sourceEnabled) {
      unawaited(ref.read(navModulesProvider.notifier).reorder(
            enabledSection: sourceEnabled,
            oldIndex: oldIndex,
            newIndex: newIndex,
          ));
    } else {
      final id = _lifting;
      if (id != null) {
        // 跨段搬移：落到悬停槽位（无悬停记录时追加尾部）
        final lens = _dragLens;
        var slot = dropSection ? (lens?.$1 ?? 0) : (lens?.$2 ?? 0);
        if (_hoverSection == dropSection && _hoverSlot != null) {
          slot = _hoverSlot!;
        }
        _commitCrossMove(id, sourceEnabled, slot);
      }
    }
    setState(() {
      _lifting = null;
      _hoverSlot = null;
      _hoverSection = null;
    });
  }

  /// 跨段搬移提交（拖拽落到另一段 / 滑动换段的落位都走这里，按槽位插入，
  /// 不是追加尾部；落位行挂一次入场动画）。
  void _commitCrossMove(
      OrbitNavModule module, bool fromEnabled, int destSlot) {
    unawaited(ref.read(navModulesProvider.notifier).move(
          module: module,
          toEnabled: !fromEnabled,
          destSlot: destSlot,
        ));
    _arrived.add(module);
    WidgetsBinding.instance.addPostFrameCallback((_) => _arrived.remove(module));
  }

  /// 行在两段间移动（滑动换段与加/减按钮的统一出口）：
  /// 停用 → 追加到未启用尾部，反之追加到已启用尾部（各自相对顺序不乱）。
  /// 落位行挂一次入场动画（本帧 build 即起播，播完后清标记，滚动重建不重播）。
  void _moveAcross(OrbitNavModule module, bool toEnabled) {
    HapticFeedback.selectionClick();
    unawaited(
        ref.read(navModulesProvider.notifier).toggle(module));
    _arrived.add(module);
    WidgetsBinding.instance.addPostFrameCallback((_) => _arrived.remove(module));
    setState(() {});
  }

  /// 单模块在两段间移动（减号 = 停用收进未启用尾部，加号 = 启用提到已启用尾部）
  void _toggle(OrbitNavModule module, bool currentlyEnabled) {
    _moveAcross(module, !currentlyEnabled);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final nav = ref.watch(navModulesProvider);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              // 拖拽中页面被自动滚动时内容在手指下移动，按最后指针位置重定位
              onNotification: (n) {
                if (_lifting != null && n is ScrollUpdateNotification) {
                  _refreshHover();
                }
                return false;
              },
              child: ListView(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top +
                      OrbitPageHeader.rowHeight +
                      AppDimens.space16,
                  left: AppDimens.pageInline,
                  right: AppDimens.pageInline,
                  bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
                ),
                children: [
                  _preview(context, colors, _liveOrder(nav.enabled)),
                  const SizedBox(height: AppDimens.cardGap),
                  _section(
                    context,
                    label: '已启用',
                    modules: nav.enabled,
                    enabledSection: true,
                  ),
                  const SizedBox(height: AppDimens.cardGap),
                  _section(
                    context,
                    label: '未启用',
                    modules: nav.disabled,
                    enabledSection: false,
                  ),
                  const SizedBox(height: AppDimens.space12),
                  MiuixText(
                    '上方为底栏预览（与真实底栏同形同序）；底栏显示已启用列表的前 '
                    '${NavModulesState.bottomTabLimit} 个模块，'
                    '其余入口收在「更多」面板里。左右滑动行可在「已启用」与'
                    '「未启用」之间移动，也可用行首加减按钮；按住右侧手柄可'
                    '直接拖到另一段（含跨卡片），上方预览实时跟随。',
                    style: MiuixTheme.of(context).textStyles.footnote1,
                    height: 1.5,
                    color: colors.secondaryText,
                  ),
                ],
              ),
            ),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(title: '功能模块'),
          ),
        ],
      ),
    );
  }

  /// 拖拽排序中的实时顺序（仅已启用段驱动预览；未启用段拖拽不影响底栏）。
  ///
  /// - 本段内：抬起项按悬停槽位重排；
  /// - 悬停在另一段：已启用段预演落位结果（拖走即闭合缺口，拖入即按槽位插入）；
  /// - 手指在两段之外：保持原序（视同取消预演）。
  List<OrbitNavModule> _liveOrder(List<OrbitNavModule> enabled) {
    final id = _lifting;
    if (id == null) return enabled;
    final hover = _hoverSection;
    final slot = _hoverSlot ?? 0;
    if (_liftingFromEnabled) {
      if (hover == null) return enabled;
      final order = List<OrbitNavModule>.of(enabled)..remove(id);
      if (hover) order.insert(slot.clamp(0, order.length), id);
      return order;
    }
    if (hover == true) {
      final order = List<OrbitNavModule>.of(enabled);
      order.insert(slot.clamp(0, order.length), id);
      return order;
    }
    return enabled;
  }

  /// 拖拽中指针定位：返回手指所在的段与槽位。
  ///
  /// 行内带简介、高度不一（与编辑操作页的等高行不同），槽位按列表高度
  /// 比例折算；上下各放宽半行，落点判定不苛刻。未启用段为空时整卡只有
  /// 一句占位提示（无列表 key）：落在已启用列表下方即视为未启用段首位——
  /// 空段也能被拖拽直建（与编辑操作页空段回退同口径）。
  (bool, int)? _locate(
    Offset? global, {
    required int enabledLen,
    required int disabledLen,
  }) {
    if (global == null) return null;
    const tolerance = AppDimens.touchTarget / 2;
    final hBox =
        _hiddenListKey.currentContext?.findRenderObject() as RenderBox?;
    if (hBox != null && hBox.hasSize) {
      final rect = hBox.localToGlobal(Offset.zero) & hBox.size;
      if (_expanded(rect, tolerance).contains(global)) {
        return (false, _slotIn(rect, global, disabledLen));
      }
    }
    final eBox =
        _enabledListKey.currentContext?.findRenderObject() as RenderBox?;
    if (eBox != null && eBox.hasSize) {
      final rect = eBox.localToGlobal(Offset.zero) & eBox.size;
      if (_expanded(rect, tolerance).contains(global)) {
        return (true, _slotIn(rect, global, enabledLen));
      }
      if (disabledLen == 0 && global.dy > rect.bottom + tolerance) {
        return (false, 0);
      }
    }
    return null;
  }

  /// 列表局部 Y → 槽位（按高度比例折算，允许等于长度，即尾后追加位）
  int _slotIn(Rect rect, Offset global, int length) {
    if (length <= 0 || rect.height <= 0) return 0;
    return ((global.dy - rect.top) / rect.height * length)
        .floor()
        .clamp(0, length);
  }

  Rect _expanded(Rect rect, double tolerance) => Rect.fromLTRB(
        rect.left - tolerance,
        rect.top - tolerance,
        rect.right + tolerance,
        rect.bottom + tolerance,
      );

  void _onDragMove(Offset global) {
    if (_lifting == null) return;
    _lastPointer = global;
    _refreshHover();
  }

  /// 按最后指针位置刷新悬停段/槽位（手指移动与拖拽中页面滚动共用；
  /// 跨段翻越时给一次触感确认）。
  void _refreshHover() {
    if (_lifting == null) return;
    final nav = ref.read(navModulesProvider);
    final located = _locate(
      _lastPointer,
      enabledLen: nav.enabled.length,
      disabledLen: nav.disabled.length,
    );
    final section = located?.$1;
    final slot = located?.$2;
    if (section != _hoverSection || slot != _hoverSlot) {
      if (section != null && section != _hoverSection) {
        HapticFeedback.selectionClick();
      }
      setState(() {
        _hoverSection = section;
        _hoverSlot = slot;
      });
    }
  }

  /// 一个配置段（段卡 + 段内拖拽重排 + 横滑换段）。
  ///
  /// 未启用段为空时只挂一句占位提示（整卡保留：既让「未启用」标题常年可见，
  /// 段位不漂移；空段拖拽直建走 [_locate] 的「已启用列表下方回退”，不挂 key——
  /// 同一个 GlobalKey 在空占位与列表两种类型间切换会撞复用判定）。
  Widget _section(
    BuildContext context, {
    required String label,
    required List<OrbitNavModule> modules,
    required bool enabledSection,
  }) {
    final colors = AppColors.ofContext(context);
    return SectionCard(
      title: label,
      child: modules.isEmpty
          ? _emptyHint(context, colors, '全部模块已启用，左滑行或点减号可停用。')
          : _sectionList(
              colors,
              listKey:
                  enabledSection ? _enabledListKey : _hiddenListKey,
              items: modules,
              enabledSection: enabledSection,
            ),
    );
  }

  /// 空段占位（未启用被搬空时；与编辑操作页工具栏搬空提示同口径）
  ///
  /// 文字走 `MiuixText` + `body2`：跟随 miuix 字阶与字重档（外观页调字重时
  /// 同步变化），不再裸 `Text`。
  Widget _emptyHint(BuildContext context, AppColorSet colors, String text) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
        child: MiuixText(
          text,
          style: MiuixTheme.of(context).textStyles.body2,
          color: colors.secondaryText,
        ),
      );

  /// 单段可拖列表：行体横滑换段（`Dismissible`），手柄纵拖排序
  ///（`buildDefaultDragHandles: false`，手势互不抢占）。
  ///纵拖拾起后手指 Y 实时映射悬停槽位，顶部预览按此重排（落位即所见）。
  Widget _sectionList(
    AppColorSet colors, {
    required GlobalKey listKey,
    required List<OrbitNavModule> items,
    required bool enabledSection,
  }) {
    final onReorder = enabledSection ? _onReorderEnabled : _onReorderDisabled;
    return Listener(
      // 裸指针事件（竞技场之前）：重排拖拽中也照常收到，不干扰手势归属；
      // 两段共用同一定位，手指跨过卡片边界即跨段预演
      onPointerMove: (e) => _onDragMove(e.position),
      child: ReorderableListView.builder(
        // 段列表容器 key（悬停槽位定位用；只挂列表本体一种类型，
        // 空段占位不挂 key，见 [_section]）
        key: listKey,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: items.length,
        onReorderItem: onReorder,
        // 拖拽起止触感 + 抬起放大（与侧栏项目/任务列表 manual 档同口径）
        onReorderStart: (index) {
          HapticFeedback.selectionClick();
          final nav = ref.read(navModulesProvider);
          setState(() {
            _lifting = items[index];
            _liftingFromEnabled = enabledSection;
            _hoverSection = enabledSection;
            _hoverSlot = index;
            _lastPointer = null;
            _dropHandled = false;
            _dragLens = (nav.enabled.length, nav.disabled.length);
          });
        },
        onReorderEnd: (_) {
          HapticFeedback.selectionClick();
          // 兜底：落点回调未覆盖（如拖拽被取消）时按最后指针位置再路由一次
          if (!_dropHandled) {
            final nav = ref.read(navModulesProvider);
            final dropSection = _locate(
                  _lastPointer,
                  enabledLen: nav.enabled.length,
                  disabledLen: nav.disabled.length,
                )?.$1 ??
                _liftingFromEnabled;
            final id = _lifting;
            if (id != null && dropSection != _liftingFromEnabled) {
              var slot = dropSection
                  ? (_dragLens?.$1 ?? 0)
                  : (_dragLens?.$2 ?? 0);
              if (_hoverSection == dropSection && _hoverSlot != null) {
                slot = _hoverSlot!;
              }
              _commitCrossMove(id, _liftingFromEnabled, slot);
            }
          }
          if (_lifting != null ||
              _hoverSlot != null ||
              _hoverSection != null) {
            setState(() {
              _lifting = null;
              _hoverSlot = null;
              _hoverSection = null;
            });
          }
        },
        proxyDecorator: (child, index, animation) => AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final elevated = AppMotion.standard.transform(
              Tween<double>(begin: 0, end: 1).evaluate(animation),
            );
            return Transform.scale(
              scale: 1 + (AppMotion.dragLiftScale - 1) * elevated,
              child: Material(
                elevation: 6 * elevated,
                borderRadius: AppShapes.medium,
                clipBehavior: Clip.antiAlias,
                color: Color.lerp(
                  Colors.transparent,
                  colors.surface,
                  elevated,
                ),
                child: child,
              ),
            );
          },
          child: child,
        ),
        itemBuilder: (context, index) {
          final module = items[index];
          return Dismissible(
            key: ValueKey(module),
            direction: DismissDirection.horizontal,
            movementDuration: AppMotion.normal,
            resizeDuration: AppMotion.normal,
            dismissThresholds: const {
              DismissDirection.startToEnd: _swipeThreshold,
              DismissDirection.endToStart: _swipeThreshold,
            },
            background: _swipeBackground(
              context,
              colors,
              toEnabled: !enabledSection,
            ),
            secondaryBackground: _swipeBackground(
              context,
              colors,
              toEnabled: !enabledSection,
            ),
            // 最后一个已启用模块不可停用：横滑直接拒收，不播出场
            confirmDismiss: (_) async {
              if (enabledSection &&
                  ref.read(navModulesProvider).enabled.length <= 1) {
                return false;
              }
              return true;
            },
            // 跟手驱动预览：手势进度 ÷ 阈值 = 预览插值进度。回弹/落位动画的每帧
            // 都会回调（行位移控制器的 listener），进度归零即复位，无需收尾。
            onUpdate: (details) {
              if (details.reached && !details.previousReached) {
                HapticFeedback.selectionClick();
              }
              final p =
                  (details.progress / _swipeThreshold).clamp(0.0, 1.0);
              final cur = _swipeLive.value;
              if (p < 0.02) {
                if (cur != null) _swipeLive.value = null;
                return;
              }
              if (cur == null ||
                  cur.module != module ||
                  cur.fromEnabled != enabledSection ||
                  (cur.progress - p).abs() > 0.005) {
                _swipeLive.value = _SwipeLive(
                  module: module,
                  fromEnabled: enabledSection,
                  progress: p,
                );
              }
            },
            onDismissed: (_) {
              _swipeLive.value = null;
              _moveAcross(module, !enabledSection);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 行分隔线落在首行之外（miuix 分组卡惯例：项之间用
                // `MiuixHorizontalDivider`，见库内 preferences demo 的
                // `IndentDivider`），随行一起横滑离场
                if (index > 0)
                  OrbitDivider(
                    indent: _dividerIndent,
                    endIndent: AppDimens.space16,
                  ),
                _EnterTransition(
                  animate: _arrived.contains(module),
                  child: _moduleRow(
                    context,
                    colors,
                    module: module,
                    enabled: enabledSection,
                    index: index,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 横滑底衬：去向已启用 = 绿色系加号，去向未启用 = 红色系减号
  /// （与编辑操作页同色系：加回用绿、收走用红）。
  Widget _swipeBackground(
    BuildContext context,
    AppColorSet colors, {
    required bool toEnabled,
  }) {
    final tone = toEnabled ? colors.success : colors.destructive;
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: AppShapes.medium,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(
            toEnabled ? OrbitIcons.add : OrbitIcons.remove,
            size: AppDimens.iconSizeMd,
            color: tone,
          ),
          MiuixText(
            toEnabled ? '加到启用' : '收进停用',
            style: MiuixTheme.of(context).textStyles.body2,
            fontWeight: FontWeight.w600,
            color: tone,
          ),
          Icon(
            toEnabled ? OrbitIcons.add : OrbitIcons.remove,
            size: AppDimens.iconSizeMd,
            color: tone,
          ),
        ],
      ),
    );
  }

  /// 底栏落位预览（只读）：启用序前 [NavModulesState.bottomTabLimit] 个模块 +
  /// 固定「更多」位。此处是**实色卡片示意图**（56 高 + 表面 + 描边 + 页签均分
  /// + 22 图标、图标独立无文字），不复刻真实底栏的悬浮胶囊与玻璃材质——玻璃靠
  /// 宿主 `MiuixLayerBackdrop` 采样页面内容，配置页里没有可采样的背景。
  /// 页签排布口径仍与 [OrbitBottomNav] 同源（图标等分、无文字）。
  ///
  /// 落位即所见：调用方传拖拽实时顺序（[_liveOrder]），横滑/拖拽经
  /// [_swipeLive] 逐帧给出插值进度——滑出项淡出、后项实时让位；滑入项以
  /// 幽灵图标在槽位淡入占位（落位即扶正，无跳变）。跟手追踪中零延迟直跟
  /// （与行 1:1），手指离开后切回常规时长收尾（与编辑操作页同机制）。
  Widget _preview(BuildContext context, AppColorSet colors,
      List<OrbitNavModule> enabled) {
    // 卡面走原生语（[OrbitCard] = `MiuixCard` squircle + 同形描边），高度固定
    // 56、无内边距：槽位宽度全部留给图标等分，与真实底栏页签密度同档
    return OrbitCard(
      key: const ValueKey('nav-preview'),
      padding: EdgeInsets.zero,
      borderRadius: AppShapes.medium,
      child: SizedBox(
        height: 56,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 槽位固定五档（4 个页签位 + 固定「更多」位）：图标只在槽内平移，
            // 宽度恒定不伸缩，落位提交与进度 1.0 时完全一致，无跳变
            final slotW = constraints.maxWidth /
                (NavModulesState.bottomTabLimit + 1);
            return ValueListenableBuilder<_SwipeLive?>(
              valueListenable: _swipeLive,
              builder: (context, live, _) {
                final bottom = enabled
                    .take(NavModulesState.bottomTabLimit)
                    .toList(growable: false);
                // 落位即所见：调用方传当前落位，横滑/拖拽经 provider 重建即跟随
                var outIndex = -1;
                var swipeIn = false;
                if (live != null) {
                  if (live.fromEnabled) {
                    outIndex = bottom.indexOf(live.module);
                  } else {
                    // 滑入项落在底栏（追加位仍在前 4 槽内）才进预览；
                    // 追加到面板区的换段不影响底栏落位
                    swipeIn = !enabled.contains(live.module) &&
                        enabled.length < NavModulesState.bottomTabLimit;
                  }
                }
                final p = live?.progress ?? 0;
                // 跟手追踪中零延迟直跟（与行 1:1），手指离开后切回常规时长收尾——
                // 同一套隐式动画，只换时长，故收尾从当前显示位置平滑起播，无跳变。
                final tracking = outIndex >= 0 || swipeIn;
                final posDuration =
                    tracking ? AppMotion.instant : AppMotion.normal;
                final fadeDuration =
                    tracking ? AppMotion.instant : AppMotion.fast;
                final icons = <Widget>[
                  for (var i = 0; i < bottom.length; i++)
                    AnimatedPositioned(
                      // key = 模块身份：换序/换段时同一图标滑向新槽位
                      key: ValueKey(bottom[i]),
                      duration: posDuration,
                      curve: AppMotion.standard,
                      left: i * slotW -
                          (outIndex >= 0 && i > outIndex ? p * slotW : 0),
                      top: 0,
                      bottom: 0,
                      width: slotW,
                      child: AnimatedOpacity(
                        duration: fadeDuration,
                        curve: AppMotion.standard,
                        opacity: outIndex == i ? 1 - p : 1,
                        child: Center(
                          child: Icon(
                            bottom[i].icon,
                            size: AppDimens.iconSizeLg,
                            color: _lifting == bottom[i]
                                ? OrbitAccents.themeAccent
                                : colors.iconText,
                          ),
                        ),
                      ),
                    ),
                  if (swipeIn)
                    AnimatedPositioned(
                      key: const ValueKey('preview-ghost'),
                      duration: posDuration,
                      curve: AppMotion.standard,
                      left: bottom.length * slotW,
                      top: 0,
                      bottom: 0,
                      width: slotW,
                      child: AnimatedOpacity(
                        duration: fadeDuration,
                        curve: AppMotion.standard,
                        opacity: p,
                        child: Center(
                          child: Icon(
                            live!.module.icon,
                            size: AppDimens.iconSizeLg,
                            color: colors.iconText,
                          ),
                        ),
                      ),
                    ),
                  AnimatedPositioned(
                    key: const ValueKey('preview-more'),
                    duration: posDuration,
                    curve: AppMotion.standard,
                    left: NavModulesState.bottomTabLimit * slotW,
                    top: 0,
                    bottom: 0,
                    width: slotW,
                    child: Center(
                      child: Icon(OrbitIcons.more,
                          size: AppDimens.iconSizeLg,
                          color: colors.iconText),
                    ),
                  ),
                ];
                return Stack(children: icons);
              },
            );
          },
        ),
      ),
    );
  }

  /// 模块行（`MiuixBasicComponent` 承载）：行首启停圆钮 + 模块图标 → 名称/简介
  /// → 右端拖拽手柄。圆钮底色/图标随归属渐变（换段时不是硬切）。
  ///
  /// 全部尺寸/字阶走 miuix 口径，不再手搓 `Row`：
  /// - 行内边距 16×10、最小行高 56（`MiuixBasicComponent` 内置 `minHeight`）；
  /// - 标题 `headline1`（17）、简介 `body2`（14），`startAction`→中心内容
  ///   固定 8 间距（[_dividerIndent] 即按这套几何算出来的）；
  /// - 启停钮是 `MiuixIconButton`（经 [OrbitIconButton] 收口）的 32 紧凑档，
  ///   色圈由 `backgroundColor` 承载（原手搓 `Container(circle)` 已退场）。
  Widget _moduleRow(
    BuildContext context,
    AppColorSet colors, {
    required OrbitNavModule module,
    required bool enabled,
    required int index,
  }) {
    final lifting = _lifting == module;
    // 最后一个已启用模块不可停用（减号置灰，与控制器守卫同口径）
    final canToggle = enabled
        ? ref.read(navModulesProvider).enabled.length > 1
        : true;
    final textStyles = MiuixTheme.of(context).textStyles;
    return MiuixBasicComponent(
      // 水平内边距交给外层卡片（[SectionCard] → `OrbitCard` 的 16）：miuix 的
      // 「卡内 16 + 行内 16」在本页会叠成 32，360dp 窄屏下简介被挤成两行；
      // 垂直 8 + 库内 `minHeight` 56 保持 miuix 行高口径
      insideMargin: const EdgeInsets.symmetric(
        vertical: AppDimens.space8,
      ),
      startAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            // 圆钮底色/图标随归属渐变（换段时不是硬切）
            tween: Tween(begin: 0, end: enabled ? 1 : 0),
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            builder: (context, t, _) {
              final tone =
                  Color.lerp(colors.success, colors.destructive, t)!;
              return OrbitIconButton(
                tooltip: enabled ? '停用' : '启用',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: _toggleExtent,
                  height: _toggleExtent,
                ),
                backgroundColor: tone.withValues(alpha: 0.12),
                onPressed: canToggle ? () => _toggle(module, enabled) : null,
                icon: Icon(
                  enabled ? OrbitIcons.remove : OrbitIcons.add,
                  size: 16,
                  color: tone,
                ),
              );
            },
          ),
          const SizedBox(width: AppDimens.space8),
          Icon(
            module.icon,
            size: AppDimens.iconSizeMd,
            color: enabled ? colors.iconText : colors.deactivatedText,
          ),
        ],
      ),
      endActions: [
        ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.all(AppDimens.space8),
            child: Icon(
              OrbitIcons.drag,
              size: AppDimens.iconSizeMd,
              color: enabled
                  ? colors.secondaryText
                  : colors.deactivatedText,
            ),
          ),
        ),
      ],
      content: [
        MiuixText(
          module.label,
          style: textStyles.headline1,
          fontWeight: lifting ? FontWeight.w600 : FontWeight.w500,
          color: enabled ? colors.bodyText : colors.secondaryText,
        ),
        MiuixText(
          module.description,
          style: textStyles.body2,
          color: colors.secondaryText,
        ),
      ],
    );
  }
}

/// 换段落位行的入场过渡（淡入 + 轻微滑入；调用方用落位标记控制只播一次，
/// 滚动重建不播；与编辑操作页同机制）。
class _EnterTransition extends StatelessWidget {
  const _EnterTransition({required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset((1 - t) * AppDimens.space16, 0),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

