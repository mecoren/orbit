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
/// - 拖动右侧手柄在**段内**调整顺序（抬起放大 + 轻触感反馈，与任务行同口径）。
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

  /// 横滑跟手快照（只重建预览行，不碰列表；落位提交/回弹归零时清）
  final ValueNotifier<_SwipeLive?> _swipeLive = ValueNotifier(null);

  /// 各档位的初始归属（打开页面时快照）：入场动画只播给**换段落位**的行——
  /// 页面初建、滚动重建都不播（否则滑出缓存区再回来会重播淡入）。
  /// 每次换段提交后同步更新，故二次换段仍能播。
  late Set<QuickActionId> _initiallyEnabled;

  @override
  void initState() {
    super.initState();
    _initiallyEnabled = Set.of(QuickActions.read().$1);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _swipeLive.dispose();
    super.dispose();
  }

  /// 段内重排（新顺序直接落库；预览行图标滑到新槽位）
  void _onReorderEnabled(int oldIndex, int newIndex) {
    final (enabled, hidden) = QuickActions.read();
    final reordered = reorderWithinSection(enabled, oldIndex, newIndex);
    unawaited(QuickActions.write(reordered, hidden));
    setState(() => _lifting = null);
  }

  /// 段内重排（「更多」段；工具栏预览不受影响）
  void _onReorderHidden(int oldIndex, int newIndex) {
    final (enabled, hidden) = QuickActions.read();
    final reordered = reorderWithinSection(hidden, oldIndex, newIndex);
    unawaited(QuickActions.write(enabled, reordered));
    setState(() => _lifting = null);
  }

  /// 行在两段间移动（滑动换段与加/减按钮的统一出口）：
  /// 启用 → 追加到「更多」尾部，反之追加到工具栏尾部（各自相对顺序不乱）。
  void _moveAcross(QuickActionId id, bool toEnabled) {
    HapticFeedback.selectionClick();
    unawaited(QuickActions.setEnabled(id, toEnabled));
    // 同步归属快照：落位行播入场动画，其余行不受影响
    toEnabled ? _initiallyEnabled.add(id) : _initiallyEnabled.remove(id);
    setState(() {});
  }

  /// 该行是否刚换段落位（相对打开页面时的归属）：是才播入场动画。
  bool _isNewlyPlaced(QuickActionId id, bool inEnabledSection) =>
      _initiallyEnabled.contains(id) != inEnabledSection;

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
          ListView(
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
              _preview(colors, enabled),
              const SizedBox(height: AppDimens.cardGap),
              SectionCard(
                title: '编辑操作',
                child: enabled.isEmpty
                    ? _emptyHint(colors, '全部收进了「更多」，工具栏只剩「...」入口。')
                    : _sectionList(
                        colors,
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
                    items: hidden,
                    enabledSection: false,
                    onReorder: _onReorderHidden,
                  ),
                ),
              ],
              const SizedBox(height: AppDimens.cardGap),
              Text(
                '左右滑动行可在「编辑操作」与「更多」之间移动，也可用行内加减按钮；'
                '拖动右侧手柄调整段内顺序，上方预览实时跟随。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: colors.secondaryText,
                ),
              ),
            ],
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

  /// 单段可拖列表：行体横滑换段（`Dismissible`），手柄纵拖排序
  ///（`buildDefaultDragHandles: false`，手势互不抢占）。
  Widget _sectionList(
    AppColorSet colors, {
    required List<QuickActionId> items,
    required bool enabledSection,
    required void Function(int oldIndex, int newIndex) onReorder,
  }) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorderItem: onReorder,
      // 拾起 / 落位各一次轻触感反馈 + 抬起放大（与任务行/项目行同口径）
      onReorderStart: (index) {
        HapticFeedback.selectionClick();
        setState(() => _lifting = items[index]);
      },
      onReorderEnd: (_) {
        HapticFeedback.selectionClick();
        if (_lifting != null) setState(() => _lifting = null);
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
            animate: _isNewlyPlaced(id, enabledSection),
            child: _actionRow(
              colors,
              id: id,
              enabled: enabledSection,
              index: index,
            ),
          ),
        );
      },
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

/// 换段落位行的入场过渡（淡入 + 轻微滑入；只在跨段移动时挂载，滚动重建不播）。
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
