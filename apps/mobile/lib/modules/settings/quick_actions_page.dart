/// 编辑操作设置页 /settings/quick-actions
///
/// 配置任务列表页底部快速添加面板的快捷操作档位（形制参考 TickTick
/// 「设置 → 编辑操作」）：
/// - **一张连续可拖列表**：段标题「更多」之上 = 工具栏直显档，之下 = 收进
///   「...」菜单的档。拖拽跨过「更多」标题行即换段（标题行不可拖起，但会被
///   拖拽项实时挤开——分界线随落点移动），同段内拖拽只调顺序；
/// - 行内圆形加/减按钮在两段间快速移动（与拖拽同语义的快捷路径）；
/// - 顶部预览行**实时跟随**：档位顺序变化时图标用 `AnimatedPositioned`
///   平滑滑到新槽位，落位即所见（面板里长什么样这里就长什么样）。
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

class QuickActionsPage extends StatefulWidget {
  const QuickActionsPage({super.key});

  @override
  State<QuickActionsPage> createState() => _QuickActionsPageState();
}

class _QuickActionsPageState extends State<QuickActionsPage> {
  final _scrollController = ScrollController();

  /// 抬起中的档位（预览行对应图标着强调色 + 行文案加粗；落位即清）
  QuickActionId? _lifting;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 跨段拖拽：重排 + 按「更多」标题行的新位置解析两段（纯逻辑见
  /// [reorderQuickActions]，此处只负责落库与状态复位）
  void _onReorder(int oldIndex, int newIndex) {
    final (enabled, hidden) = QuickActions.read();
    final (newEnabled, newHidden) = reorderQuickActions(
      enabled: enabled,
      hidden: hidden,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    unawaited(QuickActions.write(newEnabled, newHidden));
    setState(() => _lifting = null);
  }

  /// 单档在两段间移动（加号 = 提到工具栏尾部，减号 = 收回「更多」尾部）
  void _toggle(QuickActionId id, bool currentlyEnabled) {
    unawaited(QuickActions.setEnabled(id, !currentlyEnabled));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final (enabled, hidden) = QuickActions.read();
    final items = quickActionDragItems(enabled, hidden);
    final boundary = items.indexOf(moreHeaderSentinel);

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
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: items.length,
                  onReorderItem: _onReorder,
                  // 拾起 / 落位各一次轻触感反馈 + 抬起放大（与任务行/项目行同口径）
                  onReorderStart: (index) {
                    HapticFeedback.selectionClick();
                    final item = items[index];
                    if (item is QuickActionId) {
                      setState(() => _lifting = item);
                    }
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
                    final item = items[index];
                    if (item is! QuickActionId) {
                      return _moreHeader(colors);
                    }
                    return _actionRow(
                      colors,
                      id: item,
                      enabled: boundary < 0 || index < boundary,
                      index: index,
                    );
                  },
                ),
              ),
              const SizedBox(height: AppDimens.cardGap),
              Text(
                '拖动右侧手柄可调整顺序：越过「更多」标题即换段（标题上方显示在'
                '快速添加面板上，下方收进面板的「...」菜单）；也可用行内加减按钮'
                '在两段之间快速移动。',
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

  /// 面板形态预览（只读）：输入框占位 + 工具栏图标行 + 发送钮。
  ///
  /// 图标行用 `AnimatedPositioned` 按槽位定位——档位增减或换序时图标**平滑
  /// 滑到新槽位**（而非整行重绘），这是"上面图标跟着动"的动画来源。
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
                  child: SizedBox(
                    width: (enabled.length + 1) * _previewSlot,
                    height: AppDimens.iconSizeMd,
                    child: Stack(
                      children: [
                        for (var i = 0; i < enabled.length; i++)
                          AnimatedPositioned(
                            // key = 档位身份：换序时同一图标滑向新槽位
                            key: ValueKey(enabled[i]),
                            duration: AppMotion.normal,
                            curve: AppMotion.standard,
                            left: i * _previewSlot,
                            top: 0,
                            child: Icon(
                              quickActionIcon(enabled[i]),
                              size: AppDimens.iconSizeMd,
                              color: _lifting == enabled[i]
                                  ? OrbitAccents.themeAccent
                                  : colors.iconText,
                            ),
                          ),
                        AnimatedPositioned(
                          key: const ValueKey('preview-more'),
                          duration: AppMotion.normal,
                          curve: AppMotion.standard,
                          left: enabled.length * _previewSlot,
                          top: 0,
                          child: Icon(
                            OrbitIcons.moreVertical,
                            size: AppDimens.iconSizeMd,
                            color: colors.iconText,
                          ),
                        ),
                      ],
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

  /// 「更多」段标题行（分隔线 + 灰字标题；不可拖起，拖拽项跨过它即换段）
  Widget _moreHeader(AppColorSet colors) => Column(
        key: const ValueKey(moreHeaderSentinel),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AppDimens.space8),
            child: Divider(height: 1, color: colors.divider),
          ),
          Padding(
            padding: const EdgeInsets.only(
              top: AppDimens.space12,
              bottom: AppDimens.space4,
            ),
            child: Text(
              '更多',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.secondaryText,
              ),
            ),
          ),
        ],
      );

  Widget _actionRow(
    AppColorSet colors, {
    required QuickActionId id,
    required bool enabled,
    required int index,
  }) {
    final lifting = _lifting == id;
    return SizedBox(
      key: ValueKey(id),
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
