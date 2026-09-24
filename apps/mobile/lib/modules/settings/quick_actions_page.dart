/// 编辑操作设置页 /settings/quick-actions
///
/// 配置任务列表页底部快速添加面板的快捷操作档位（形制参考 TickTick
/// 「设置 → 编辑操作」，截图口径 = 双卡片）：
/// - 顶部预览行**实时跟随**：档位顺序变化时图标用 `AnimatedPositioned`
///   平滑滑到新槽位，落位即所见（面板里长什么样这里就长什么样）；
/// - **两张卡片**：「编辑操作」卡 = 工具栏直显档，「更多」卡 = 收进「...」
///   菜单的档（更多段为空时整卡隐藏，不留空卡）；
/// - 行**左右滑动**在两段间移动（滑出 + 对侧淡入，预览图标同步滑到新槽位），
///   与行内圆形加/减按钮同语义（快捷路径）；滑动方向不区分左右，归属只由
///   所在卡片决定。**滑动过程中预览跟手**：`Dismissible.onUpdate` 的手势进度
///   按阈值归一后直接驱动预览图标让位/腾槽（滑出段淡出让位，滑入段幽灵图标
///   淡入占位），过阈值时一次触感确认，取消回弹则沿原路跟回；
/// - 拖动右侧手柄排序与跨段直移（抬起放大 + 轻触感反馈，与任务行同口径；
///   手指可在两张卡片之间直拖：悬停段/槽位实时映射，预览按落位结果预演，
///   跨段翻越时触感确认，松手即提交；落位行挂一次入场动画）。
///
/// 档位集合由 [QuickActionId] 封闭定义（只收录本仓真有对应能力的操作），
/// 存 [LocalPrefs] 本机偏好——不进 DB、不进同步。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../todo/logic/quick_actions.dart';
import '../todo/quick_add_sheet.dart' show quickActionIcon;

/// 预览行单个图标槽宽（图标 22 + 间距 12），供 `AnimatedPositioned` 定位
const double _previewSlot = 34;

/// 横滑换段的滑动阈值（行宽占比）：`Dismissible.dismissThresholds` 与预览
/// 跟手位移共用这一个常量——手势进度（行位移占宽比 0…1）除以它即预览插值
/// 进度（0…1，钳制），1 = 落位后的最终布局。
const double _swipeThreshold = 0.4;

/// 横滑过程中的实时快照（驱动预览图标跟手位移）。
///
/// 数据源 = `Dismissible.onUpdate`（它监听行位移控制器：手指拖动、松手回弹、
/// 惯性滑出都会持续回调，进度归零即自然复位，无需定时器收尾）。
class _SwipeLive {
  const _SwipeLive({
    required this.id,
    required this.fromEnabled,
    required this.progress,
  });

  /// 被横滑的档位
  final QuickActionId id;

  /// 它来自工具栏段（true）还是「更多」段（false）
  final bool fromEnabled;

  /// 预览插值进度 0…1（= 手势进度 ÷ [_swipeThreshold] 后钳制）
  final double progress;
}

class QuickActionsPage extends StatefulWidget {
  const QuickActionsPage({super.key});

  @override
  State<QuickActionsPage> createState() => _QuickActionsPageState();
}

class _QuickActionsPageState extends State<QuickActionsPage> {
  final _scrollController = ScrollController();

  /// 抬起中的档位（预览行对应图标着强调色 + 行文案加粗；落位即清）
  QuickActionId? _lifting;

  /// 抬起项来自工具栏段（true）还是「更多」段（false）
  bool _liftingFromEnabled = true;

  /// 抬起拖拽中的悬停槽位（[_hoverSection] 内的序号）：拖拽排序时预览按此
  /// 实时重排；落位提交/取消即清（`onReorderEnd`）。
  int? _hoverSlot;

  /// 手指当前所在的段（true = 工具栏段，false =「更多」段，null = 都不在）：
  /// 与来源段不同即跨段拖拽，落点段决定提交去向，预览实时预演落位结果。
  bool? _hoverSection;

  /// 拖拽中最后一个指针位置（落点判定用；松手瞬间即上一次 move 的位置）。
  Offset? _lastPointer;

  /// 本次拖拽落点已提交（`onReorderItem` 与 `onReorderEnd` 都会到，用它防双提交）
  bool _dropHandled = false;

  /// 拖拽开始时两段的长度快照（拖拽中提交前长度不变，槽位钳制用，避免逐帧读配置）
  (int, int)? _dragLens;

  /// 段列表容器 key（悬停槽位定位用：手指全局坐标 → 列表局部 Y → 槽位；
  /// 行高等 `touchTarget`，直接整除）。
  final _enabledListKey = GlobalKey();
  final _hiddenListKey = GlobalKey();

  /// 横滑跟手快照（只重建预览行，不碰列表；落位提交/回弹归零时清）
  final ValueNotifier<_SwipeLive?> _swipeLive = ValueNotifier(null);

  /// 刚换段落位的档位：落位行播一次入场动画（淡入 + 滑入），播完即清——
  /// 页面初建、滚动重建都不播（滚动必然发生在后续帧，清掉后重建不再重播）。
  final Set<QuickActionId> _arrived = {};

  @override
  void dispose() {
    _scrollController.dispose();
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

  /// 段内重排落点（「更多」段；去向判定同上）
  void _onReorderHidden(int oldIndex, int newIndex) {
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
    final dropSection = _locate(_lastPointer)?.$1 ?? sourceEnabled;
    if (dropSection == sourceEnabled) {
      final (enabled, hidden) = QuickActions.read();
      if (sourceEnabled) {
        final reordered = reorderWithinSection(enabled, oldIndex, newIndex);
        unawaited(QuickActions.write(reordered, hidden));
      } else {
        final reordered = reorderWithinSection(hidden, oldIndex, newIndex);
        unawaited(QuickActions.write(enabled, reordered));
      }
    } else {
      final id = _lifting;
      if (id != null) {
        // 跨段搬移：落到悬停槽位（无悬停记录时追加尾部）
        final lens = _dragLens;
        var slot = dropSection
            ? (lens?.$1 ?? 0)
            : (lens?.$2 ?? 0);
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
  void _commitCrossMove(QuickActionId id, bool fromEnabled, int destSlot) {
    final (enabled, hidden) = QuickActions.read();
    final src = fromEnabled ? enabled : hidden;
    final dst = fromEnabled ? hidden : enabled;
    src.remove(id);
    dst.insert(destSlot.clamp(0, dst.length), id);
    unawaited(QuickActions.write(
      fromEnabled ? src : dst,
      fromEnabled ? dst : src,
    ));
    _arrived.add(id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _arrived.remove(id));
  }

  /// 行在两段间移动（滑动换段与加/减按钮的统一出口）：
  /// 启用 → 追加到「更多」尾部，反之追加到工具栏尾部（各自相对顺序不乱）。
  /// 落位行挂一次入场动画（本帧 build 即起播，播完后清标记，滚动重建不重播）。
  void _moveAcross(QuickActionId id, bool toEnabled) {
    HapticFeedback.selectionClick();
    unawaited(QuickActions.setEnabled(id, toEnabled));
    _arrived.add(id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _arrived.remove(id));
    setState(() {});
  }

  /// 单档在两段间移动（加号 = 提到工具栏尾部，减号 = 收回「更多」尾部）
  void _toggle(QuickActionId id, bool currentlyEnabled) {
    _moveAcross(id, !currentlyEnabled);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final (enabled, hidden) = QuickActions.read();

    return Scaffold(
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            // 拖拽中页面被自动滚动时内容在手指下移动，按最后指针位置重定位
            onNotification: (n) {
              if (_lifting != null && n is ScrollUpdateNotification) {
                _refreshHover();
              }
              return false;
            },
            child: ListView(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  OrbitPageHeader.rowHeight +
                  AppDimens.space16,
              left: AppDimens.pageInline,
              right: AppDimens.pageInline,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
            ),
            children: [
              _preview(colors, _liveOrder(enabled)),
              const SizedBox(height: AppDimens.cardGap),
              SectionCard(
                title: '编辑操作',
                child: enabled.isEmpty
                    // 空段也挂定位 key：更多段的行可直接拖进来建首位
                    ? SizedBox(
                        key: _enabledListKey,
                        child: _emptyHint(colors,
                            '全部收进了「更多」，工具栏只剩「...」入口。'),
                      )
                    : _sectionList(
                        colors,
                        listKey: _enabledListKey,
                        items: enabled,
                        enabledSection: true,
                        onReorder: _onReorderEnabled,
                      ),
              ),
              if (hidden.isNotEmpty) ...[
                const SizedBox(height: AppDimens.cardGap),
                SectionCard(
                  title: '更多',
                  child: _sectionList(
                    colors,
                    listKey: _hiddenListKey,
                    items: hidden,
                    enabledSection: false,
                    onReorder: _onReorderHidden,
                  ),
                ),
              ],
              const SizedBox(height: AppDimens.cardGap),
              Text(
                '左右滑动行可在「编辑操作」与「更多」之间移动，也可用行内加减按钮；'
                '按住右侧手柄可直接拖到另一段（含跨卡片），上方预览实时跟随。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: colors.secondaryText,
                ),
              ),
            ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(title: '编辑操作'),
          ),
        ],
      ),
    );
  }

  /// 拖拽中指针定位：返回手指所在的段与槽位（行高等 `touchTarget` 整除；
  /// 上下各放宽半行，落点判定不苛刻）。
  ///
  /// 「更多」段为空（无卡）且指针在工具栏段下方时，视为更多段首位——
  /// 空段也能被拖拽直建。
  (bool, int)? _locate(Offset? global) {
    if (global == null) return null;
    final lens = _dragLens;
    const tolerance = AppDimens.touchTarget / 2;
    final hBox =
        _hiddenListKey.currentContext?.findRenderObject() as RenderBox?;
    if (hBox != null && hBox.hasSize) {
      final rect = hBox.localToGlobal(Offset.zero) & hBox.size;
      if (_expanded(rect, tolerance).contains(global)) {
        return (false, _slotIn(rect, global, lens?.$2 ?? 0));
      }
    }
    final eBox =
        _enabledListKey.currentContext?.findRenderObject() as RenderBox?;
    if (eBox != null && eBox.hasSize) {
      final rect = eBox.localToGlobal(Offset.zero) & eBox.size;
      if (_expanded(rect, tolerance).contains(global)) {
        return (true, _slotIn(rect, global, lens?.$1 ?? 0));
      }
      if ((lens?.$2 ?? 1) == 0 && global.dy > rect.bottom + tolerance) {
        return (false, 0);
      }
    }
    return null;
  }

  /// 列表局部 Y → 槽位（允许等于长度，即尾后追加位）
  int _slotIn(Rect rect, Offset global, int length) {
    if (length <= 0) return 0;
    return ((global.dy - rect.top) / AppDimens.touchTarget)
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
    final located = _locate(_lastPointer);
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

  /// 拖拽排序中的实时顺序（仅工具栏段驱动预览；「更多」段拖拽不影响工具栏）。
  ///
  /// - 本段内：抬起项按悬停槽位重排；
  /// - 悬停在另一段：工具栏段预演落位结果（拖走即闭合缺口，拖入即按槽位插入）；
  /// - 手指在两段之外：保持原序（视同取消预演）。
  List<QuickActionId> _liveOrder(List<QuickActionId> enabled) {
    final id = _lifting;
    if (id == null) return enabled;
    final hover = _hoverSection;
    final slot = _hoverSlot ?? 0;
    if (_liftingFromEnabled) {
      if (hover == null) return enabled;
      final order = List<QuickActionId>.of(enabled)..remove(id);
      if (hover) order.insert(slot.clamp(0, order.length), id);
      return order;
    }
    if (hover == true) {
      final order = List<QuickActionId>.of(enabled);
      order.insert(slot.clamp(0, order.length), id);
      return order;
    }
    return enabled;
  }

  /// 单段可拖列表：行体横滑换段（`Dismissible`），手柄纵拖排序
  ///（`buildDefaultDragHandles: false`，手势互不抢占）。
  ///纵拖拾起后手指 Y 实时映射悬停槽位，顶部预览按此重排（落位即所见）。
  Widget _sectionList(
    AppColorSet colors, {
    required GlobalKey listKey,
    required List<QuickActionId> items,
    required bool enabledSection,
    required void Function(int oldIndex, int newIndex) onReorder,
  }) {
    return Listener(
      key: listKey,
      // 裸指针事件（竞技场之前）：重排拖拽中也照常收到，不干扰手势归属；
      // 两段共用同一定位，手指跨过卡片边界即跨段预演
      onPointerMove: (e) => _onDragMove(e.position),
      child: ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorderItem: onReorder,
      // 拾起 / 落位各一次轻触感反馈 + 抬起放大（与任务行/项目行同口径）
      onReorderStart: (index) {
        HapticFeedback.selectionClick();
        final (enabled, hidden) = QuickActions.read();
        setState(() {
          _lifting = items[index];
          _liftingFromEnabled = enabledSection;
          _hoverSection = enabledSection;
          _hoverSlot = index;
          _lastPointer = null;
          _dropHandled = false;
          _dragLens = (enabled.length, hidden.length);
        });
      },
      onReorderEnd: (_) {
        HapticFeedback.selectionClick();
        // 兜底：落点回调未覆盖（如拖拽被取消）时按最后指针位置再路由一次
        if (!_dropHandled) {
          final dropSection = _locate(_lastPointer)?.$1 ?? _liftingFromEnabled;
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
        final id = items[index];
        return Dismissible(
          key: ValueKey(id),
          direction: DismissDirection.horizontal,
          movementDuration: AppMotion.normal,
          resizeDuration: AppMotion.normal,
          dismissThresholds: const {
            DismissDirection.startToEnd: _swipeThreshold,
            DismissDirection.endToStart: _swipeThreshold,
          },
          background: _swipeBackground(colors, toEnabled: !enabledSection),
          secondaryBackground:
              _swipeBackground(colors, toEnabled: !enabledSection),
          confirmDismiss: (_) async => true,
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
                cur.id != id ||
                cur.fromEnabled != enabledSection ||
                (cur.progress - p).abs() > 0.005) {
              _swipeLive.value = _SwipeLive(
                id: id,
                fromEnabled: enabledSection,
                progress: p,
              );
            }
          },
          onDismissed: (_) {
            _swipeLive.value = null;
            _moveAcross(id, !enabledSection);
          },
          child: _EnterTransition(
            animate: _arrived.contains(id),
            child: _actionRow(
              colors,
              id: id,
              enabled: enabledSection,
              index: index,
            ),
          ),
        );
      },
      ),
    );
  }

  /// 横滑底衬：去向「更多」= 红色系减号，去向工具栏 = 绿色系加号。
  Widget _swipeBackground(AppColorSet colors, {required bool toEnabled}) {
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
          Text(
            toEnabled ? '加到工具栏' : '收进更多',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
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

  /// 空段占位（工具栏被搬空时；「更多」段为空时整卡隐藏，不走这里）
  Widget _emptyHint(AppColorSet colors, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
        child: Text(
          text,
          style: TextStyle(fontSize: 13, color: colors.deactivatedText),
        ),
      );

  /// 面板形态预览（只读）：输入框占位 + 工具栏图标行 + 发送钮。
  ///
  /// 图标行用 `AnimatedPositioned` 按槽位定位——档位增减、换序、横滑换段时
  /// 图标**平滑滑到新槽位**（而非整行重绘），这是"上面图标跟着动"的动画来源。
  /// 横滑过程中 [_swipeLive] 逐帧给出插值进度：滑出段的图标淡出、后项实时
  /// 让位；滑入段在尾部用幽灵图标淡入占位。跟手期间时长切零延迟直跟（与行
  /// 1:1 无拖尾），手指离开后切回常规时长收尾。落位提交的布局与进度 1.0 时
  /// 完全一致，故提交瞬间无跳变；取消回弹则沿同一插值原路跟回。
  Widget _preview(AppColorSet colors, List<QuickActionId> enabled) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.cardPadding,
        AppDimens.space12,
        AppDimens.space12,
        AppDimens.space8,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.medium,
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '准备做什么？',
            style: TextStyle(fontSize: 15, color: colors.deactivatedText),
          ),
          const SizedBox(height: AppDimens.space12),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ValueListenableBuilder<_SwipeLive?>(
                    valueListenable: _swipeLive,
                    builder: (context, live, _) => SizedBox(
                      width: _previewWidth(enabled, live),
                      height: AppDimens.iconSizeMd,
                      child:
                          Stack(children: _previewIcons(colors, enabled, live)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: OrbitAccents.themeAccent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  OrbitIcons.send,
                  size: AppDimens.iconSizeSm,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 预览行宽：跟手过程中按插值进度实时伸缩，与落位后的真实宽度在两端对齐。
  double _previewWidth(List<QuickActionId> enabled, _SwipeLive? live) {
    var slots = (enabled.length + 1).toDouble();
    if (live != null) {
      if (live.fromEnabled && enabled.contains(live.id)) {
        slots -= live.progress;
      } else if (!live.fromEnabled && !enabled.contains(live.id)) {
        slots += live.progress;
      }
    }
    return slots * _previewSlot;
  }

  /// 预览图标（含「...」)：常态按槽位排布；跟手过程中滑出项淡出、后项让位，
  /// 滑入项以幽灵图标在尾部淡入占位（落位即扶正，无跳变）。
  List<Widget> _previewIcons(
    AppColorSet colors,
    List<QuickActionId> enabled,
    _SwipeLive? live,
  ) {
    // 落位提交后 id 已换段：防御性忽略过期快照（按常态排布）
    var outIndex = -1;
    var swipeIn = false;
    if (live != null) {
      if (live.fromEnabled) {
        outIndex = enabled.indexOf(live.id);
      } else {
        swipeIn = !enabled.contains(live.id);
      }
    }
    final p = live?.progress ?? 0;
    // 跟手追踪中零延迟直跟（与行 1:1），手指离开后切回常规时长收尾——
    // 同一套隐式动画，只换时长，故收尾从当前显示位置平滑起播，无跳变。
    final tracking = outIndex >= 0 || swipeIn;
    final posDuration = tracking ? AppMotion.instant : AppMotion.normal;
    final fadeDuration = tracking ? AppMotion.instant : AppMotion.fast;
    final icons = <Widget>[
      for (var i = 0; i < enabled.length; i++)
        AnimatedPositioned(
          // key = 档位身份：换序/换段时同一图标滑向新槽位
          key: ValueKey(enabled[i]),
          duration: posDuration,
          curve: AppMotion.standard,
          left: i * _previewSlot -
              (outIndex >= 0 && i > outIndex ? p * _previewSlot : 0),
          top: 0,
          child: AnimatedOpacity(
            duration: fadeDuration,
            curve: AppMotion.standard,
            opacity: outIndex == i ? 1 - p : 1,
            child: Icon(
              quickActionIcon(enabled[i]),
              size: AppDimens.iconSizeMd,
              color: _lifting == enabled[i]
                  ? OrbitAccents.themeAccent
                  : colors.iconText,
            ),
          ),
        ),
      if (swipeIn)
        AnimatedPositioned(
          key: const ValueKey('preview-ghost'),
          duration: posDuration,
          curve: AppMotion.standard,
          left: enabled.length * _previewSlot,
          top: 0,
          child: AnimatedOpacity(
            duration: fadeDuration,
            curve: AppMotion.standard,
            opacity: p,
            child: Icon(
              quickActionIcon(live!.id),
              size: AppDimens.iconSizeMd,
              color: colors.iconText,
            ),
          ),
        ),
      AnimatedPositioned(
        key: const ValueKey('preview-more'),
        duration: posDuration,
        curve: AppMotion.standard,
        left: (enabled.length + (swipeIn ? p : 0) - (outIndex >= 0 ? p : 0)) *
            _previewSlot,
        top: 0,
        child: Icon(
          OrbitIcons.moreVertical,
          size: AppDimens.iconSizeMd,
          color: colors.iconText,
        ),
      ),
    ];
    return icons;
  }

  Widget _actionRow(
    AppColorSet colors, {
    required QuickActionId id,
    required bool enabled,
    required int index,
  }) {
    final lifting = _lifting == id;
    return SizedBox(
      height: AppDimens.touchTarget,
      child: Row(
        children: [
          IconButton(
            tooltip: enabled ? '收到「更多」' : '加到工具栏',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            onPressed: () => _toggle(id, enabled),
            icon: TweenAnimationBuilder<double>(
              // 圆钮底色/图标随归属渐变（换段时不是硬切）
              tween: Tween(begin: 0, end: enabled ? 1 : 0),
              duration: AppMotion.fast,
              curve: AppMotion.standard,
              builder: (context, t, _) => Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Color.lerp(colors.success, colors.destructive, t)!
                      .withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Transform.scale(
                  // 图标随归属翻转尺度（减号 ⇄ 加号切换时的轻微回弹）
                  scale: 1 - 0.15 * (1 - (t * 2 - 1).abs()),
                  child: Icon(
                    enabled ? OrbitIcons.remove : OrbitIcons.add,
                    size: 14,
                    color: Color.lerp(colors.success, colors.destructive, t),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppDimens.space12),
          Icon(
            quickActionIcon(id),
            size: AppDimens.iconSizeMd,
            color: enabled ? colors.iconText : colors.deactivatedText,
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: Text(
              id.label,
              style: TextStyle(
                fontSize: 15,
                color: enabled ? colors.bodyText : colors.secondaryText,
                fontWeight: lifting ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(AppDimens.space8),
              child: Icon(
                OrbitIcons.drag,
                size: AppDimens.iconSizeMd,
                color: enabled ? colors.secondaryText : colors.deactivatedText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 换段落位行的入场过渡（淡入 + 轻微滑入；调用方用落位标记控制只播一次，
/// 滚动重建不播）。
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
