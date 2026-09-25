import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../shell/nav_modules.dart';

/// 功能模块配置页（底部导航可配置；「更多」面板「编辑」入口，对齐竞品）
///
/// **两段列表**：已启用（红圈减号 = 停用）/ 未启用（绿圈加号 = 启用），段内
/// 右端拖拽手柄重排。规则见 [NavModulesState]：底栏 = 启用序前
/// [NavModulesState.bottomTabLimit] 个模块 + 固定「更多」动作位，其余启用
/// 模块收进「更多」面板；最后一个启用模块不可停用（减号置灰）。
/// 配置即写即落盘（[navModulesProvider]），底栏/面板实时跟随重建。
class NavModulesPage extends ConsumerWidget {
  const NavModulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.ofContext(context);
    final nav = ref.watch(navModulesProvider);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
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
                _section(
                  context,
                  ref,
                  label: '已启用',
                  modules: nav.enabled,
                  enabledSection: true,
                ),
                const SizedBox(height: AppDimens.sectionGap),
                _section(
                  context,
                  ref,
                  label: '未启用',
                  modules: nav.disabled,
                  enabledSection: false,
                ),
                const SizedBox(height: AppDimens.space12),
                Text(
                  '底栏显示启用列表的前 ${NavModulesState.bottomTabLimit} 个模块，'
                  '其余入口收在「更多」面板里。',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.secondaryText,
                  ),
                ),
              ],
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

  /// 一个配置段（段卡 + 段内拖拽重排）
  Widget _section(
    BuildContext context,
    WidgetRef ref, {
    required String label,
    required List<OrbitNavModule> modules,
    required bool enabledSection,
  }) {
    return SectionCard(
      title: label,
      child: ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        padding: EdgeInsets.zero,
        onReorderItem: (oldIndex, newIndex) => ref
            .read(navModulesProvider.notifier)
            .reorder(
              enabledSection: enabledSection,
              oldIndex: oldIndex,
              newIndex: newIndex,
            ),
        // 拖拽起止触感 + 抬起放大（与侧栏项目/任务列表 manual 档同口径）
        onReorderStart: (_) => HapticFeedback.selectionClick(),
        onReorderEnd: (_) => HapticFeedback.selectionClick(),
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
                color: Colors.transparent,
                child: child,
              ),
            );
          },
          child: child,
        ),
        children: [
          for (var i = 0; i < modules.length; i++)
            _ModuleRow(
              key: ValueKey(modules[i]),
              module: modules[i],
              index: i,
              enabledSection: enabledSection,
              canToggle: enabledSection ? modules.length > 1 : true,
            ),
        ],
      ),
    );
  }
}

/// 模块行：图标块 + 名称/简介 + 启停钮 + 拖拽手柄（竞品同款版式）
class _ModuleRow extends ConsumerWidget {
  const _ModuleRow({
    super.key,
    required this.module,
    required this.index,
    required this.enabledSection,
    required this.canToggle,
  });

  final OrbitNavModule module;

  /// ReorderableListView 内的行序（拖拽手柄绑定用）
  final int index;

  /// 所在段（true = 已启用：显示减号；false = 未启用：显示加号）
  final bool enabledSection;

  /// 启停钮是否可用（最后一个启用模块的减号置灰）
  final bool canToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.ofContext(context);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colors.surfaceSecondary,
            borderRadius: AppShapes.small,
          ),
          alignment: Alignment.center,
          child: Icon(module.icon, size: 20, color: colors.iconText),
        ),
        const SizedBox(width: AppDimens.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                module.label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.titleText,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                module.description,
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
            ],
          ),
        ),
        // 启停钮：红圈减号 / 绿圈加号（竞品同款）；外扩触控区到 44
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canToggle
              ? () => ref.read(navModulesProvider.notifier).toggle(module)
              : null,
          child: Padding(
            // 外扩到 48 触控高（勾选框热区口径 ≥44；刻度无 10 取 12）
            padding: const EdgeInsets.all(AppDimens.space12),
            child: Opacity(
              opacity: canToggle ? 1 : 0.35,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: enabledSection
                      ? OrbitAccents.overdueRed
                      : colors.success,
                ),
                alignment: Alignment.center,
                child: Icon(
                  enabledSection ? OrbitIcons.remove : OrbitIcons.add,
                  size: 14,
                  color: const Color(0xFFFFFFFF),
                ),
              ),
            ),
          ),
        ),
        // 拖拽手柄：仅手柄可拖（行内容保持可读可点）
        ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimens.space8,
              vertical: AppDimens.rowVertical,
            ),
            child: Icon(
              OrbitIcons.drag,
              size: AppDimens.iconSizeMd,
              color: colors.deactivatedText,
            ),
          ),
        ),
      ],
    );
  }
}
