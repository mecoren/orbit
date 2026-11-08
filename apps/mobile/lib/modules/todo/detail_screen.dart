// 任务详情页：十区块（标题/信息/描述/子任务/标签/提醒/关联/评论/附件/历史）。
//
// 交互口径（2026-11-05 重构）：信息区九行统一 `OrbitDropdownPreference`
// 档位行——行内常显当前值、就地展开玻璃菜单、日期/重复/时长的二级面板由
// 菜单项进入；预计时长/开始日期/截止日期/重复全部可编辑，进度与完成时间
// 只读。页面内输入框（标题/子任务/评论）不再用 `onTapOutside` 当帧卸载，
// 抽屉输入统一走 `OrbitSheetScaffold` 且键盘弹起后仍可滚动到输入框。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/layout/orbit_breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../services/notification_service.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_color_swatches.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_image_thumb.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart'
    show bottomSheetMotion, bottomSheetTopShape, OrbitPanelItem;
// 页头 ⋮：OS4 玻璃形变菜单（与「今天」页头 ⋮ 同一套承载，2026-11-06）
import '../../shared/widgets/shadcn/orbit_glass_menu.dart';
import '../../shared/widgets/shadcn/orbit_glass_surface.dart'
    show OrbitGlassScope;
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart'
    show showSelectBottomSheet;
// 档位行：信息区统一「行内常显当前值 + 就地展开玻璃菜单」，与设置页同款
import '../../shared/widgets/shadcn/orbit_dropdown_preference.dart';
import '../../shared/widgets/shadcn/orbit_spinner.dart';
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_button.dart';
import '../../shared/widgets/shadcn/orbit_progress_bar.dart';
import '../../shared/widgets/shadcn/orbit_icon_button.dart';
import '../../shared/widgets/shadcn/orbit_text_field.dart';
import 'form_bottom_sheet.dart' show showTodoDatePicker, syncTaskReminder;
// as rep：规避 Flutter widgets 自带 RepeatMode 类名冲突
import 'logic/activity_format.dart';
import 'logic/markdown_lite.dart';
import 'logic/repeat_logic.dart' as rep;
import 'logic/subtask_tree.dart';
import 'repeat_edit_sheet.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

/// 提醒选择列表里「自定义时间…」项的哨兵值（与表单同口径）
const String _reminderCustomKey = 'custom';

/// 评论区列表滚动区（预览限高后区块内滑动；测试按 key 定位取高度）
const Key detailCommentsListKey = ValueKey('task-detail-comments-list');

/// 历史区块列表滚动区（预览限高 + 常显滚动条；测试按 key 定位取高度）
const Key detailHistoryListKey = ValueKey('task-detail-history-list');

/// 预计时长常用档（与任务表单 `_pickDuration` 同口径；值 = 分钟数字符串）
const List<({String value, String label})> _durationPresets = [
  (value: '15', label: '15 分钟'),
  (value: '30', label: '30 分钟'),
  (value: '45', label: '45 分钟'),
  (value: '60', label: '1 小时'),
  (value: '90', label: '1.5 小时'),
  (value: '120', label: '2 小时'),
  (value: '180', label: '3 小时'),
];

// ══ 分组版式：与设置页（settings_screen.dart 的 `_sectionCard` / `_RowDivider`
// + `MiuixSmallTitle`）同构，2026-11-06 对齐 ══
//
// 原先详情页把分组标题画在卡内（13sp 蓝色），且行间没有分隔线——与设置页
// 并排看是两套页面。统一为：卡外小标题（14sp 加粗、中性灰、28×8 内边距）
// + 零内边距 [MiuixCard] 分组卡（左右 12 外距）+ 行间左缩进分隔线。

/// 分组卡（设置页 `_sectionCard` 同款：h:12 外距 + 零内边距 MiuixCard）
Widget _groupCard(List<Widget> children) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
  child: MiuixCard(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  ),
);

/// 行间分隔线：左缩进 16 对齐行标题
///
/// 设置页用 56 是因为其行首有 24 图标位；详情页信息区的行首没有图标，
/// 缩进取行内边距本身（16）才能与标题同一条竖线。
class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(left: AppDimens.space16),
    child: MiuixHorizontalDivider(),
  );
}

/// 卡外分组标题（[MiuixSmallTitle] 同规格：subtitle 14sp 加粗 /
/// `onBackgroundVariant` / 28×8 内边距）
///
/// 左 28 = 卡片外距 12 + 行内边距 16，与卡内行标题同一条竖线；
/// [trailing] 右缘同线（右 28），[subtitle] 换 12sp 次要色跟在标题后。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.title, {this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Padding(
      // 左 28 = 卡外距 12 + 行内距 16（与卡内行标题同线）；
      // 右 16：trailing（编辑 / 添加提醒）贴齐卡片内容右缘，不跟标题同缩进——
      // 同缩进会让按钮离卡右缘留 28 + 按钮自身内边距，读起来「没靠右」
      // （2026-11-06 截图反馈）。
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space28,
        AppDimens.space8,
        AppDimens.space16,
        AppDimens.space8,
      ),
      child: Row(
        children: [
          // 标题集群整体 Expanded、内部 Flexible：trailing 恒贴右
          // （SectionCard 头行同款，避免两个 flex 子项平分剩余空间）
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: MiuixText(
                    title,
                    style: theme.textStyles.subtitle,
                    color: theme.colors.onBackgroundVariant,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: AppDimens.space8),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.ofContext(context).secondaryText,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 关联类型中文标签（只读展示；桌面 RELATION_TYPE_LABEL 同口径）。
/// `related` 是 2026-10 前移动端旧写入值的兼容别名（新写入一律 relates_to）
const Map<String, String> _relationTypeLabels = {
  'subtask': '子任务',
  'blocks': '阻塞',
  'blocked_by': '被阻塞',
  'relates_to': '关联',
  'related': '关联',
  'duplicates': '重复于',
  'duplicated_by': '重复项',
};

/// 详情全屏 /todo/:id（docs/05 §4.3 + 移动端任务书）
///
/// 数据源 todoTaskGetDetail(id) 聚合（taskDetailProvider）。
/// 十区块固定顺序：标题区 → 信息 → 描述 → 子任务 → 标签 → 提醒 → 关联 →
/// 评论 → 附件 → 历史（历史单独走 taskActivityProvider，不受详情刷新牵动）。
/// 上半区更新走 patchTask 出口（缺省键=跳过语义），下半五区增删改后统一
/// invalidate 详情与列表，禁局部合并。
class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({super.key, required this.taskId});

  /// 路由参数解析出的任务 id；非法值由路由层传 null（走失败态）
  final int? taskId;

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 更新统一出口：patch 直传，成功失效列表 + 详情
  Future<void> _patchTask(Map<String, Object?> patch) async {
    final id = widget.taskId;
    if (id == null) return;
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoTaskUpdate(id, encodePatch(patch));
      if (!mounted) return;
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider(id));
    } catch (_) {
      WaitToast.destructive('更新失败');
    }
  }

  /// 完成/取消统一入口：完成走 todoTaskComplete（Rust 单事务推进重复
  /// 任务下一实例——引擎下沉后与桌面同口径）；取消完成仍走普通 patch
  Future<void> _toggleDone(TodoTask task) async {
    final id = widget.taskId;
    if (id == null || task.isDone) {
      return _patchTask(buildDoneTogglePatch(task));
    }
    try {
      final res = await ref.read(orbitBridgeProvider).todoTaskComplete(id);
      if (!mounted) return;
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider(id));
      // 重复任务推进提示：明确告知「列表里多出来的那条」从哪来（与桌面同文案）
      final next = res.nextInstance;
      if (next != null && next.dueDate != null) {
        WaitToast.success('已完成，已生成下一期：${rep.formatCnDate(next.dueDate!)}');
      }
    } catch (_) {
      WaitToast.destructive('完成失败');
    }
  }

  /// 状态选择统一出口（对齐桌面详情状态设置器）：切到「已完成」必须走
  /// `todoTaskComplete`——普通 update 只落 status/done，重复任务不会推进
  /// 下一实例；从已完成切回未完成走普通 patch（清 done/done_at）。
  Future<void> _setStatus(TodoTaskDetail detail, String status) async {
    final id = widget.taskId;
    if (id == null) return;
    if (status == 'done' && !detail.isDone) {
      try {
        final res = await ref.read(orbitBridgeProvider).todoTaskComplete(id);
        if (!mounted) return;
        ref.invalidate(todoTasksProvider);
        ref.invalidate(taskDetailProvider(id));
        final next = res.nextInstance;
        if (next != null && next.dueDate != null) {
          WaitToast.success('已完成，已生成下一期：${rep.formatCnDate(next.dueDate!)}');
        }
      } catch (_) {
        WaitToast.destructive('更新失败');
      }
      return;
    }
    // 已完成 → 待办/进行中不能走 done 翻转补丁（它固定回落 pending）；
    // 统一落目标状态并清完成戳
    return _patchTask(buildStatusPatch(status));
  }

  // ── 页头 ⋮ 任务级动作（对齐桌面详情标题行 Sunrise/Star/Copy/Trash 四枚钮；
  //    移动端收进页头 ⋮ 玻璃形变菜单——与「今天」页头 ⋮ 同一套承载（按钮 →
  //    菜单连续形变、玻璃卡面、行与组间分隔同源），不再从底部升抽屉；四枚
  //    图标并排会把标题挤到半行，列表页视图/筛选/排序收 ⋮ 是同款既有决策）──

  /// ⋮ 菜单条目：标签回显我的一天/收藏的当前状态（点开时按当下 detail 构建）
  List<List<OrbitPanelItem>> _taskActionGroups(TodoTask task) => [
    [
      OrbitPanelItem(
        icon: OrbitIcons.sun,
        label: task.isInMyDay ? '移出我的一天' : '加入我的一天',
        color: OrbitAccents.myDayAmber,
        onTap: () => _toggleMyDay(task),
      ),
      OrbitPanelItem(
        icon: OrbitIcons.star,
        label: task.isStarred ? '取消收藏' : '收藏',
        color: OrbitAccents.starYellow,
        onTap: () => _toggleFavorite(task),
      ),
      OrbitPanelItem(
        icon: OrbitIcons.copy,
        label: '复制任务',
        onTap: () => _duplicateTask(task),
      ),
      OrbitPanelItem(
        icon: OrbitIcons.delete,
        label: '删除',
        color: OrbitAccents.overdueRed,
        onTap: () => _deleteTask(task),
      ),
    ],
  ];

  /// 我的一天：加入今天（本地零点）/ 移出（null）——与桌面 toggleMyDayValue 同口径
  Future<void> _toggleMyDay(TodoTask task) {
    final now = DateTime.now();
    final todayZero = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    return _patchTask({'my_day_date': task.isInMyDay ? null : todayZero});
  }

  Future<void> _toggleFavorite(TodoTask task) =>
      _patchTask({'is_favorite': task.isStarred ? 0 : 1});

  /// 复制任务：克隆后 toast + 原页替换为新副本详情（对齐桌面复制后选中切到副本）
  Future<void> _duplicateTask(TodoTask task) async {
    try {
      final copy = await ref
          .read(orbitBridgeProvider)
          .todoTaskDuplicate(task.id);
      if (!mounted) return;
      WaitToast.success('已复制为「${copy.title}」');
      ref.invalidate(todoTasksProvider);
      context.pushReplacement('/todo/${copy.id}');
    } catch (_) {
      if (mounted) WaitToast.destructive('复制失败');
    }
  }

  /// 删除：二次确认抽屉 + 落库后返回上一页（详情页不另挂撤销条，恢复走回收站）
  Future<void> _deleteTask(TodoTask task) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除任务',
      message: '确定要删除任务「${task.title}」吗？删除后将移入回收站，可在回收站中恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(orbitBridgeProvider).todoTaskDelete(task.id);
      if (!mounted) return;
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider(task.id));
      context.pop();
    } catch (_) {
      WaitToast.destructive('删除失败');
    }
  }

  /// 下半五区（子任务/标签/提醒/关联/评论）增删改统一失效出口
  void _refreshDetail() {
    final id = widget.taskId;
    if (id == null) return;
    ref.invalidate(taskDetailProvider(id));
    ref.invalidate(todoTasksProvider);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.taskId;
    final detailAsync = id == null ? null : ref.watch(taskDetailProvider(id));
    final detail = detailAsync?.value;
    final colors = AppColors.ofContext(context);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: detailAsync == null
                ? const _ErrorView()
                : detailAsync.when(
                    skipLoadingOnReload: true,
                    // 初次加载骨架：标题 + 信息行占位（重查有旧值时不闪，直接旧内容）
                    loading: () => const _DetailSkeleton(),
                    error: (_, _) => const _ErrorView(),
                    // #107 平板：详情限宽（760）水平居中，行宽不随屏宽无限拉伸。
                    // 用 topCenter 而非 Center：意图只是「限宽」，纵向仍贴顶
                    // （换了短内容分支也不会被垂直居中拽到屏幕中间）
                    data: (detail) => Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: OrbitBreakpoints.contentMaxWidth,
                        ),
                        // key 仅绑 id，不纳入 updatedAt——若含之，任何 patch 后
                        // invalidate 会导致整树按新 key 替换重建，旧 ListView
                        // 延迟卸载与新 ListView 挂载同帧共存，_scrollController
                        // 瞬时双附着触发断言。各区块外部变更同步已由
                        // didUpdateWidget / provider 回读覆盖，无需整树重置。
                        child: _DetailView(
                          key: ValueKey('task-detail:${detail.id}'),
                          detail: detail,
                          scrollController: _scrollController,
                          onPatch: _patchTask,
                          onToggleDone: _toggleDone,
                          onSetStatus: _setStatus,
                          onRefresh: _refreshDetail,
                        ),
                      ),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: detail?.title ?? '详情',
              // 任务级动作收进页头 ⋮ 玻璃形变菜单（对照桌面标题行四枚动作钮；
              // 标签回显我的一天/收藏的当前状态）。弹层经 OverlayPortal 挂在
              // 捕获树之外，采样器走本页 OrbitGlassPage 暴露的实例
              actions: detail == null
                  ? null
                  : [
                      OrbitGlassMenuButton(
                        groupsBuilder: () => _taskActionGroups(detail),
                        backdrop: OrbitGlassScope.maybeOf(context),
                        tooltip: '任务操作',
                        icon: Icon(
                          OrbitIcons.moreVertical,
                          size: AppDimens.iconSizeMd,
                          color: colors.titleText,
                        ),
                      ),
                    ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 失败态：记录不存在或加载失败 + 返回钮
class _ErrorView extends StatelessWidget {
  const _ErrorView();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '记录不存在或加载失败',
            style: TextStyle(fontSize: 14, color: colors.secondaryText),
          ),
          const SizedBox(height: AppDimens.space16),
          OrbitButton.text(
            onPressed: () => context.pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}

/// 详情初次加载骨架：标题块 + 四行信息行占位
///
/// 版式对齐 `_DetailView`（同款顶边距 + 卡外距 12 + 卡内 16 = 28），
/// 加载落定即整块替换；`skipLoadingOnReload` 保证重查时旧内容保留，不闪骨架。
class _DetailSkeleton extends StatefulWidget {
  const _DetailSkeleton();

  @override
  State<_DetailSkeleton> createState() => _DetailSkeletonState();
}

class _DetailSkeletonState extends State<_DetailSkeleton>
    with SingleTickerProviderStateMixin {
  /// 整屏单路呼吸（2026-11-08）：5 块逐块自建 controller 就是 5 路 ticker
  /// 同时逐帧驱动；共享一路同相位（口径同 `_TaskListSkeleton`）
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AppMotion.skeletonPulse,
  )..repeat(reverse: true);

  late final Animation<double> _pulse = Tween<double>(begin: 0.45, end: 1.0)
      .animate(CurvedAnimation(parent: _ctrl, curve: AppMotion.breathe));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top:
            MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space12,
        left: AppDimens.space28,
        right: AppDimens.space28,
      ),
      children: [
        OrbitSkeleton.block(height: 26, borderRadius: 13, pulse: _pulse),
        const SizedBox(height: AppDimens.space16),
        OrbitSkeleton.line(width: 200, pulse: _pulse),
        const SizedBox(height: AppDimens.space12),
        OrbitSkeleton.line(width: 160, pulse: _pulse),
        const SizedBox(height: AppDimens.space12),
        OrbitSkeleton.line(width: 220, pulse: _pulse),
        const SizedBox(height: AppDimens.space12),
        OrbitSkeleton.line(width: 140, pulse: _pulse),
      ],
    );
  }
}

/// 详情主体：十区块滚动容器（区块间距 12、页面尾留白）
///
/// 水平留白由分组卡自带（卡外距 12，见 [_groupCard]），列表本身不再加
/// 水平内边距——与设置页同口径，卡外标题才能与卡内行标题同一条竖线。
class _DetailView extends StatelessWidget {
  const _DetailView({
    super.key,
    required this.detail,
    required this.scrollController,
    required this.onPatch,
    required this.onToggleDone,
    required this.onSetStatus,
    required this.onRefresh,
  });

  final TodoTaskDetail detail;
  final ScrollController scrollController;
  final Future<void> Function(Map<String, Object?> patch) onPatch;
  final Future<void> Function(TodoTask task) onToggleDone;
  final Future<void> Function(TodoTaskDetail detail, String status) onSetStatus;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.only(
        top:
            MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space12,
        bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
      ),
      children: [
        // 十区块固定顺序（docs/05 §4.3）
        _TitleSection(
          detail: detail,
          onPatch: onPatch,
          onToggleDone: onToggleDone,
        ),
        const SizedBox(height: AppDimens.space12),
        _InfoSection(
          detail: detail,
          onPatch: onPatch,
          onSetStatus: onSetStatus,
        ),
        const SizedBox(height: AppDimens.space12),
        _DescriptionSection(detail: detail, onPatch: onPatch),
        const SizedBox(height: AppDimens.space12),
        _SubtasksSection(detail: detail, onChanged: onRefresh),
        const SizedBox(height: AppDimens.space12),
        _LabelsSection(detail: detail),
        const SizedBox(height: AppDimens.space12),
        _RemindersSection(
          taskId: detail.id,
          reminders: detail.reminders,
          repeatMode: detail.repeatMode,
          repeatAfter: detail.repeatAfter,
          repeatWeekdays: detail.repeatWeekdays,
          repeatEndType: detail.repeatEndType,
          repeatEndParam: detail.repeatEndParam,
          repeatFromDone: detail.repeatFromDone,
          repeatMonthMode: detail.repeatMonthMode,
          repeatNthWeek: detail.repeatNthWeek,
          dueDate: detail.dueDate,
          startDate: detail.startDate,
          durationMinutes: detail.durationMinutes,
          onChanged: onRefresh,
        ),
        const SizedBox(height: AppDimens.space12),
        _RelationsSection(
          taskId: detail.id,
          relations: detail.relations,
          onChanged: onRefresh,
        ),
        const SizedBox(height: AppDimens.space12),
        _CommentsSection(detail: detail, onChanged: onRefresh),
        const SizedBox(height: AppDimens.space12),
        _AttachmentsSection(taskId: detail.id),
        const SizedBox(height: AppDimens.space12),
        _HistorySection(taskId: detail.id),
      ],
    );
  }
}

// ── 一、标题区 ──

class _TitleSection extends StatefulWidget {
  const _TitleSection({
    required this.detail,
    required this.onPatch,
    required this.onToggleDone,
  });

  final TodoTaskDetail detail;
  final Future<void> Function(Map<String, Object?> patch) onPatch;
  final Future<void> Function(TodoTask task) onToggleDone;

  @override
  State<_TitleSection> createState() => _TitleSectionState();
}

class _TitleSectionState extends State<_TitleSection> {
  bool _editing = false;
  late final TextEditingController _controller = TextEditingController(
    text: widget.detail.title,
  );

  @override
  void didUpdateWidget(covariant _TitleSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部数据刷新且非编辑态时同步标题
    if (!_editing && _controller.text != widget.detail.title) {
      _controller.text = widget.detail.title;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 进入编辑：从权威标题起稿，行内显示取消/保存两枚按钮。
  /// 旧实现把 `onTapOutside` 直接接到提交，点到键盘/页面空白处会当帧卸载
  /// 输入框，表现为「刚点进去就没了」；改由显式按钮与键盘「完成」收口。
  void _startEditing() {
    final title = widget.detail.title;
    // 光标落末尾（点标题多为续写/改结尾）；只赋 text 会得到 offset -1，
    // 由 TextField 自行归位到中间某个位置，移动端手感很怪
    _controller.value = TextEditingValue(
      text: title,
      selection: TextSelection.collapsed(offset: title.length),
    );
    setState(() => _editing = true);
  }

  void _cancel() {
    _controller.text = widget.detail.title;
    setState(() => _editing = false);
  }

  /// 保存：trim 空 / 未变化仅退出编辑态不请求（docs/05 §4.3 标题区语义）
  Future<void> _commit() async {
    setState(() => _editing = false);
    final value = _controller.text.trim();
    if (!mounted) return;
    if (value.isEmpty || value == widget.detail.title) {
      _controller.text = widget.detail.title;
      return;
    }
    await widget.onPatch({'title': value});
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final task = widget.detail;
    return _groupCard([
      Padding(
        padding: const EdgeInsets.all(AppDimens.cardPadding),
        child: Row(
        // 三者高度天然不同（28 图形 + 44 热区的复选框 / 22px 行盒标题 /
        // 18px 铅笔），start 对齐会让小图标贴顶、复选框沉底。center 才是
        // 「复选框—标题—编辑图标」共一条中线的唯一解。
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          OrbitCheckbox(
            checked: task.isDone,
            size: AppDimens.iconSizeXl,
            onToggle: () => widget.onToggleDone(task),
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: _editing
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: OrbitTextField(
                          inline: true,
                          controller: _controller,
                          autofocus: true,
                          // 单行：标题原地编辑不该换行把行高顶起来（右侧还要
                          // 让出 2 个 40px 图标钮），超长时输入框内水平滚动
                          maxLines: 1,
                          textInputAction: TextInputAction.done,
                          style: TextStyle(
                            fontSize: 22,
                            // 与展示态同字号同行高（22×1.3）：进出编辑卡片
                            // 高度不跳，视觉上只是「文字变成可输入」
                            height: 1.3,
                            color: colors.titleText,
                          ),
                          onSubmitted: (_) => _commit(),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space4),
                      OrbitIconButton(
                        compact: true,
                        tooltip: '取消编辑',
                        onPressed: _cancel,
                        icon: Icon(
                          OrbitIcons.close,
                          size: AppDimens.iconSizeSm,
                          color: colors.secondaryText,
                        ),
                      ),
                      OrbitIconButton(
                        compact: true,
                        tooltip: '保存标题',
                        onPressed: _commit,
                        icon: const Icon(
                          OrbitIcons.check,
                          size: AppDimens.iconSizeSm,
                          color: OrbitAccents.todoAccent,
                        ),
                      ),
                    ],
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _startEditing,
                    child: Row(
                      children: [
                        Expanded(
                          child: AnimatedStrikethrough(
                            text: task.title,
                            done: task.isDone,
                            thickness: 2,
                            maxLines: 2,
                            style: TextStyle(
                              fontSize: 22,
                              height: 1.3,
                              color: colors.titleText,
                            ),
                            doneColor: colors.titleText,
                          ),
                        ),
                        // 常驻编辑入口：点整行任意处都能进，不必精准点字形
                        Icon(
                          OrbitIcons.edit,
                          size: AppDimens.iconSizeSm,
                          color: colors.secondaryText.withValues(alpha: 0.6),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
        ),
      ),
    ]);
  }
}

// ── 二、基本信息 ──

class _InfoSection extends ConsumerWidget {
  const _InfoSection({
    required this.detail,
    required this.onPatch,
    required this.onSetStatus,
  });

  final TodoTaskDetail detail;
  final Future<void> Function(Map<String, Object?> patch) onPatch;
  final Future<void> Function(TodoTaskDetail detail, String status) onSetStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(todoProjectsProvider).value ?? [];

    final dueLabel =
        detail.dueDate != null ? formatDueShort(detail.dueDate!) : '无';
    final startLabel =
        detail.startDate != null ? formatDueShort(detail.startDate!) : '无';
    final durationLabel =
        formatDurationMinutes(detail.durationMinutes) ?? '无';
    final progressLabel =
        detail.percentDone > 0 ? '${detail.percentDone.round()}%' : '无';
    final doneLabel =
        detail.doneAt != null ? formatStampLabel(detail.doneAt!) : '无';
    final repeatLabel = rep.repeatLabelExt(
      detail.repeatMode,
      detail.repeatAfter,
      weekdays: detail.repeatWeekdays,
      endType: detail.repeatEndType,
      endParam: detail.repeatEndParam,
      fromDone: detail.repeatFromDone,
      monthMode: detail.repeatMonthMode,
      nthWeek: detail.repeatNthWeek,
    );

    final quickOptions = quickDateTimeOptions();
    final durationCurrent = detail.durationMinutes == null
        ? '0'
        : '${detail.durationMinutes}';
    final durationItems = <SelectItem<String>>[
      // 自定义分钟数也必须命中 items，否则行内当前值与弹层对勾双双落空
      if (durationCurrent != '0' &&
          !_durationPresets.any((p) => p.value == durationCurrent))
        SelectItem(value: durationCurrent, label: durationLabel),
      for (final p in _durationPresets)
        SelectItem(value: p.value, label: p.label),
      const SelectItem(value: 'custom', label: '自定义分钟数…'),
      const SelectItem(value: '0', label: '不设置'),
    ];

    // 九行同款：左标题 + 右当前值 + 上下双箭头，点行就地展开玻璃菜单。
    // 只读两行用 disabled 档位行承载（当前值常显、箭头转弱、不可展开）。
    final rows = <Widget>[
          OrbitDropdownPreference<int>(
            title: '优先级',
            items: [
              for (var i = 0; i <= 5; i++)
                SelectItem(
                  value: i,
                  label: priorityLabel(i),
                  colorDot: hexToColor(priorityColorHex(i)),
                ),
            ],
            current: detail.priority,
            onSelect: (v) => onPatch({'priority': v}),
          ),
          OrbitDropdownPreference<String>(
            title: '状态',
            items: [
              for (final s in const [
                ('pending', '待办', '#6B7280'),
                ('doing', '进行中', '#3B82F6'),
                ('done', '已完成', '#22C55E'),
              ])
                SelectItem(
                  value: s.$1,
                  label: s.$2,
                  colorDot: hexToColor(s.$3),
                ),
            ],
            current: detail.status,
            // done 走完成引擎（重复任务推进下一实例），其余走普通 patch
            onSelect: (v) => onSetStatus(detail, v),
          ),
          OrbitDropdownPreference<String>(
            title: '项目',
            items: [
              const SelectItem<String>(value: '', label: '未分组'),
              for (final p in projects)
                SelectItem(
                  value: '${p.id}',
                  label: p.title,
                  colorDot: hexToColor(
                    p.hexColor,
                    fallback: OrbitAccents.todoAccent,
                  ),
                ),
            ],
            current: detail.projectId == null ? '' : '${detail.projectId}',
            onSelect: (v) =>
                onPatch({'project_id': v.isEmpty ? null : int.parse(v)}),
          ),
          OrbitDropdownPreference<String>(
            title: '截止日期',
            // 自定义入口紧跟当前值排在第二位：菜单在页面下半部会向上翻转
            // 并限高，靠后的条目容易被裁到可滚区外（用户要点两次才够得着）
            items: [
              SelectItem(value: 'keep', label: dueLabel, hint: '当前'),
              const SelectItem(
                value: 'custom',
                label: '选择日期和时间',
                icon: OrbitIcons.calendarDays,
              ),
              for (final o in quickOptions)
                SelectItem(
                  value: o.key,
                  label: o.label,
                  hint: o.hint,
                  icon: dueQuickIcon(o.key),
                ),
              if (detail.dueDate != null)
                const SelectItem(
                  value: 'clear',
                  label: '清除日期',
                  icon: OrbitIcons.close,
                ),
            ],
            current: 'keep',
            onSelect: (v) => _applyDueChoice(context, v, quickOptions),
          ),
          OrbitDropdownPreference<String>(
            title: '开始日期',
            items: [
              SelectItem(value: 'keep', label: startLabel, hint: '当前'),
              const SelectItem(
                value: 'pick',
                label: '选择日期…',
                icon: OrbitIcons.calendarDays,
              ),
              if (detail.startDate != null)
                const SelectItem(
                  value: 'clear',
                  label: '清除日期',
                  icon: OrbitIcons.close,
                ),
            ],
            current: 'keep',
            onSelect: (v) => _applyStartChoice(context, v),
          ),
          OrbitDropdownPreference<String>(
            title: '预计时长',
            items: durationItems,
            current: durationCurrent,
            onSelect: (v) => _applyDurationChoice(context, v),
          ),
          OrbitDropdownPreference<String>(
            title: '进度',
            summary: '由子任务完成度自动计算',
            items: [SelectItem(value: 'readonly', label: progressLabel)],
            current: 'readonly',
            onSelect: (_) {},
            enabled: false,
          ),
          OrbitDropdownPreference<String>(
            title: '完成时间',
            items: [SelectItem(value: 'readonly', label: doneLabel)],
            current: 'readonly',
            onSelect: (_) {},
            enabled: false,
          ),
          OrbitDropdownPreference<String>(
            title: '重复',
            items: [
              SelectItem(value: 'keep', label: repeatLabel, hint: '当前'),
              for (final p in rep.repeatPresets)
                SelectItem(value: '${p.mode}:${p.after}', label: p.label),
              const SelectItem(value: 'custom', label: '自定义规则…'),
            ],
            current: 'keep',
            onSelect: (v) => _applyRepeatChoice(context, v),
          ),
    ];

    // 与设置页同款：卡外分组标题 + 行间分隔线（行自带 16 水平内边距，
    // 按压灰底横贯整卡）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GroupTitle('信息'),
        _groupCard([
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const _GroupDivider(),
            rows[i],
          ],
        ]),
      ],
    );
  }

  /// 截止日期档：快捷档为绝对时刻直接落库；自定义含时刻，选中原样回填
  /// ——不再归一化零点，避免把「明天 09:00」编辑成当天零点
  Future<void> _applyDueChoice(
    BuildContext context,
    String choice,
    List<({String key, String label, String hint, int ms})> options,
  ) async {
    if (choice == 'keep') return;
    if (choice == 'clear') return onPatch(const {'due_date': null});
    if (choice != 'custom') {
      final option = options.firstWhere((o) => o.key == choice);
      return onPatch({'due_date': option.ms});
    }
    final picked = await OrbitDatePicker.pick(
      context,
      initialDate: detail.dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(detail.dueDate!)
          : null,
      showTime: true,
    );
    if (picked == null || !context.mounted) return;
    await onPatch({'due_date': picked.millisecondsSinceEpoch});
  }

  /// 开始日期档：与任务表单同一日期选择器，落本地零点；清除走三态 null
  Future<void> _applyStartChoice(BuildContext context, String choice) async {
    if (choice == 'clear') return onPatch(const {'start_date': null});
    if (choice != 'pick') return;
    final picked = await showTodoDatePicker(
      context,
      initialDate: detail.startDate != null
          ? DateTime.fromMillisecondsSinceEpoch(detail.startDate!)
          : null,
    );
    if (picked == null || !context.mounted) return;
    await onPatch({'start_date': dateToMidnightMs(picked)});
  }

  /// 预计时长档：常用档直接落库，自定义进数字输入抽屉，不设置清 null
  Future<void> _applyDurationChoice(BuildContext context, String choice) async {
    if (choice == 'custom') return _pickCustomDuration(context);
    if (choice == '0') return onPatch(const {'duration_minutes': null});
    final minutes = int.tryParse(choice);
    if (minutes == null || minutes <= 0) return;
    await onPatch({'duration_minutes': minutes});
  }

  /// 自定义时长输入（1–10080 分钟；与任务表单同字段、同校验口径）
  Future<void> _pickCustomDuration(BuildContext context) async {
    final controller = TextEditingController(
      text: detail.durationMinutes?.toString() ?? '',
    );
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (sheetCtx) => OrbitSheetScaffold(
        title: '自定义时长',
        contentPadding: const EdgeInsets.fromLTRB(
          AppDimens.space16,
          0,
          AppDimens.space16,
          AppDimens.space16,
        ),
        content: OrbitTextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          label: '分钟数（1–10080）',
        ),
        actions: OrbitSheetActions(
          cancelLabel: '取消',
          onCancel: () => Navigator.pop(sheetCtx),
          confirmLabel: '确定',
          onConfirm: () => Navigator.pop(sheetCtx, true),
        ),
      ),
    );
    final minutes = int.tryParse(controller.text.trim());
    controller.dispose();
    if (confirmed != true) return;
    if (minutes == null || minutes <= 0 || minutes > 10080) {
      WaitToast.destructive('请输入 1–10080 之间的分钟数');
      return;
    }
    await onPatch({'duration_minutes': minutes});
  }

  /// 重复预设：整组 patch 清零扩展字段，避免从「每周二三四五六」切档后
  /// 残留 weekdays/endType 等脏值（与重复编辑抽屉的预设语义一致）
  Future<void> _applyRepeatPreset(int mode, int after) => onPatch({
        'repeat_mode': mode,
        'repeat_after': after,
        'repeat_weekdays': 0,
        'repeat_end_type': 0,
        'repeat_end_param': 0,
        'repeat_from_done': 0,
        'repeat_month_mode': rep.RepeatMonthMode.day,
        'repeat_nth_week': 0,
      });

  Future<void> _applyRepeatChoice(BuildContext context, String choice) async {
    if (choice == 'keep') return;
    if (choice == 'custom') return _editRepeat(context);
    final parts = choice.split(':');
    if (parts.length != 2) return;
    final mode = int.tryParse(parts[0]);
    final after = int.tryParse(parts[1]);
    if (mode == null || after == null) return;
    await _applyRepeatPreset(mode, after);
  }

  /// 重复行点击 → 共享重复编辑抽屉（预设点选即存即关；自定义面板「确定」
  /// 一次提交整组规则，与桌面端详情 RepeatEditor 同口径整组 patch）
  Future<void> _editRepeat(BuildContext context) async {
    final value = await showRepeatEditSheet(
      context,
      mode: detail.repeatMode,
      after: detail.repeatAfter,
      weekdays: detail.repeatWeekdays,
      endType: detail.repeatEndType,
      endParam: detail.repeatEndParam,
      fromDone: detail.repeatFromDone == 1,
      dueMs: detail.dueDate,
      monthMode: detail.repeatMonthMode,
      nthWeek: detail.repeatNthWeek,
    );
    if (value == null) return;
    await onPatch({
      'repeat_mode': value.mode,
      'repeat_after': value.after,
      'repeat_weekdays': value.weekdays,
      'repeat_end_type': value.endType,
      'repeat_end_param': value.endParam,
      'repeat_from_done': value.fromDone ? 1 : 0,
      // #72 月高级语义随整组 patch 落库（其余档位抽屉侧已清零）
      'repeat_month_mode': value.monthMode,
      'repeat_nth_week': value.nthWeek,
    });
  }
}

// ── 三、描述 ──

class _DescriptionSection extends StatefulWidget {
  const _DescriptionSection({required this.detail, required this.onPatch});

  final TodoTaskDetail detail;
  final Future<void> Function(Map<String, Object?> patch) onPatch;

  @override
  State<_DescriptionSection> createState() => _DescriptionSectionState();
}

class _DescriptionSectionState extends State<_DescriptionSection> {
  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final description = widget.detail.description;
    // 展示态走 Markdown 渲染（与桌面详情抽屉同源口径：标题/粗体/斜体/
    // 行内代码/链接/列表；编辑入口 = 右上按钮 + 整块空态热区）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupTitle(
          '描述',
          trailing: OrbitButton.text(
            onPressed: () => _openEditor(context),
            child: const Text('编辑'),
          ),
        ),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              AppDimens.space16,
            ),
            child: description != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: buildMarkdownWidgets(
                description,
                bodyColor: colors.bodyText,
                accentColor: OrbitAccents.themeAccent,
              ),
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openEditor(context),
              child: SizedBox(
                height: AppDimens.touchTarget,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '暂无描述，点击添加',
                    style: TextStyle(
                      fontSize: 15,
                      color: colors.secondaryText.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ],
    );
  }

  /// 描述编辑走浮起圆角卡片抽屉（70% 高上限），保存/取消显式收口。
  /// `onApply` 返回 Future：保存必须等落库完成再关闭，避免「点了没存上」。
  void _openEditor(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (_) => _DescriptionEditSheet(
        initial: widget.detail.description ?? '',
        onApply: (text) =>
            widget.onPatch({'description': text.isEmpty ? null : text}),
      ),
    );
  }
}

/// 描述编辑抽屉：有界多行输入（6–12 行，70% 屏高上限）+ 保存/取消
class _DescriptionEditSheet extends StatefulWidget {
  const _DescriptionEditSheet({required this.initial, required this.onApply});

  final String initial;
  final Future<void> Function(String text) onApply;

  @override
  State<_DescriptionEditSheet> createState() => _DescriptionEditSheetState();
}

class _DescriptionEditSheetState extends State<_DescriptionEditSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final text = _controller.text.trim();
    final navigator = Navigator.of(context);
    if (text == widget.initial.trim()) {
      navigator.pop();
      return;
    }
    setState(() => _saving = true);
    await widget.onApply(text);
    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 行数必须有界：`maxLines: null` 在骨架的 Flexible 内拿不到确定高度，
    // 输入框会被压扁/溢出，表现为「打不了字」。与任务表单描述字段同口径。
    return OrbitSheetScaffold(
      title: '编辑描述',
      maxHeightFactor: 0.7,
      contentScrollable: false,
      contentPadding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        0,
        AppDimens.space16,
        AppDimens.space16,
      ),
      content: OrbitTextField(
        controller: _controller,
        minLines: 6,
        maxLines: 12,
        maxLength: 5000,
        autofocus: true,
        textInputAction: TextInputAction.newline,
        hintText: '请输入描述',
        style: TextStyle(fontSize: 15, color: colors.bodyText),
      ),
      actions: OrbitSheetActions(
        cancelLabel: '取消',
        onCancel: _saving ? null : () => Navigator.of(context).pop(),
        confirmLabel: '保存',
        onConfirm: _saving ? null : _save,
        confirmChild: _saving
            ? const OrbitSpinner(size: AppDimens.iconSizeSm)
            : null,
      ),
    );
  }
}

// ── 四、子任务 ──

class _SubtasksSection extends ConsumerStatefulWidget {
  const _SubtasksSection({required this.detail, required this.onChanged});

  final TodoTaskDetail detail;
  final VoidCallback onChanged;

  @override
  ConsumerState<_SubtasksSection> createState() => _SubtasksSectionState();
}

class _SubtasksSectionState extends ConsumerState<_SubtasksSection> {
  bool _adding = false;

  /// M10：行内「加子级」——非 null 时为所挂父行的 uuid（顶层添加走 _adding）
  String? _addingUnderUuid;
  final _draftController = TextEditingController();
  final _draftFocus = FocusNode();
  final _draftFieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 键盘弹出后把行内输入框滚进可视区：整页 ListView 不会自动跟随焦点，
    // 底部「添加子任务」输入框此前常被键盘盖住，表现为「点不到/打不了字」
    _draftFocus.addListener(_scrollDraftIntoView);
  }

  void _scrollDraftIntoView() {
    if (!_draftFocus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = _draftFieldKey.currentContext;
      if (fieldContext == null || !fieldContext.mounted) return;
      Scrollable.ensureVisible(
        fieldContext,
        duration: Duration.zero,
        alignment: 0.4,
      );
    });
  }

  /// 两个入口互斥且共用一份草稿：旧实现两个状态可同时挂载两个 autofocus
  /// 输入框争焦点、互相覆盖草稿，导致「输入了却提交了别的框」。
  void _startAdding(String? parentUuid) {
    _draftController.clear();
    setState(() {
      _adding = parentUuid == null;
      _addingUnderUuid = parentUuid;
    });
  }

  void _cancelAdding() {
    _draftController.clear();
    _draftFocus.unfocus();
    setState(() {
      _adding = false;
      _addingUnderUuid = null;
    });
  }

  @override
  void dispose() {
    _draftFocus.removeListener(_scrollDraftIntoView);
    _draftFocus.dispose();
    _draftController.dispose();
    super.dispose();
  }

  /// 变更统一出口：落库 → onChanged 失效
  Future<void> _mutate(
    Future<void> Function() action, {
    String failMessage = '操作失败',
  }) async {
    try {
      await action();
      widget.onChanged();
    } catch (_) {
      WaitToast.destructive(failMessage);
    }
  }

  Future<void> _submitDraft() async {
    final title = _draftController.text.trim();
    if (title.isEmpty) return;
    _draftController.clear();
    _draftFocus.unfocus();
    final parentUuid = _addingUnderUuid;
    setState(() {
      _adding = false;
      _addingUnderUuid = null;
    });
    await _mutate(
      () => ref
          .read(orbitBridgeProvider)
          .todoSubtaskCreate(
            TodoSubtaskCreateInput(
              taskId: widget.detail.id,
              title: title,
              parentUuid: parentUuid,
            ),
          ),
    );
  }

  /// 删除确认（对齐评论删除惯例：软删无恢复入口，防误触。
  /// M10：带子孙时文案说明整棵子树一并删除）
  Future<void> _confirmDelete(TodoSubtask subtask, int childCount) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除子任务',
      message: childCount > 0
          ? '确定要删除「${subtask.title}」吗？其下 $childCount 个子任务将一并删除。'
          : '确定要删除「${subtask.title}」吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _mutate(
      () => ref.read(orbitBridgeProvider).todoSubtaskDelete(subtask.id),
    );
  }

  /// M10：提到顶层（嵌套行的降级出口，误嵌套不必删了重建）
  Future<void> _liftToTop(TodoSubtask subtask) async {
    await _mutate(
      () => ref
          .read(orbitBridgeProvider)
          .todoSubtaskUpdate(subtask.id, '{"parent_uuid":null}'),
      failMessage: '操作失败',
    );
    WaitToast.success('已提到顶层');
  }

  /// 子任务转独立任务（承接父任务 project/priority/due 上下文；
  /// MS To Do Steps→Task 同款语义。M10：子孙整棵随迁到新任务）
  Future<void> _promote(TodoSubtask subtask) async {
    try {
      await ref.read(orbitBridgeProvider).todoSubtaskPromote(subtask.id);
      widget.onChanged();
      WaitToast.success('已转为独立任务');
    } catch (_) {
      WaitToast.destructive('转换失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final subtasks = widget.detail.subtasks;
    final doneCount = subtasks.where((s) => s.isDone).length;

    // M10：parent_uuid 树 → DFS 渲染序列（容错口径与桌面 subtask-tree.ts、
    // project_tree.dart 同源；写侧合法性由 Rust validate_subtask_parent 拦）
    final nodes = flattenSubtaskTree(buildSubtaskTree(subtasks), (_) => false);
    final childCountByUuid = <String, int>{};
    for (final s in subtasks) {
      final p = normalizeParentUuid(s.parentUuid);
      if (p != null) childCountByUuid[p] = (childCountByUuid[p] ?? 0) + 1;
    }

    final progress = subtasks.isEmpty ? 0.0 : doneCount / subtasks.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupTitle('子任务', subtitle: '$doneCount/${subtasks.length}'),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space8,
              AppDimens.space16,
              AppDimens.space16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
          if (subtasks.isNotEmpty) ...[
            OrbitProgressBar(
              value: progress,
              color: OrbitAccents.todoAccent,
              trackColor: OrbitAccents.todoAccent.withValues(alpha: 0.15),
            ),
            const SizedBox(height: AppDimens.space8),
          ],
          for (final node in nodes)
            Padding(
              // M10：depth 缩进体现层级（16px/层，与侧栏项目树同刻度）
              padding: EdgeInsets.only(
                left: node.depth * 16,
                top: 2,
                bottom: 2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // 22px 圆 checkbox（check 14，docs/05 §四）
                      OrbitCheckbox(
                        checked: node.subtask.isDone,
                        size: AppDimens.subtaskCheckboxSize,
                        onToggle: () => _mutate(
                          () => ref
                              .read(orbitBridgeProvider)
                              .todoSubtaskToggleDone(
                                node.subtask.id,
                                !node.subtask.isDone,
                              ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      Expanded(
                        child: AnimatedStrikethrough(
                          text: node.subtask.title,
                          done: node.subtask.isDone,
                          style: TextStyle(
                            fontSize: 15,
                            color: colors.bodyText,
                          ),
                          doneColor: colors.secondaryText.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                      // M10：行内「加子级」——在当前行下建嵌套子任务
                      OrbitIconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '添加子级',
                        icon: Icon(
                          OrbitIcons.add,
                          size: AppDimens.iconSizeSm,
                          color: colors.secondaryText,
                        ),
                        onPressed: () => _startAdding(
                          _addingUnderUuid == node.subtask.uuid
                              ? null
                              : node.subtask.uuid,
                        ),
                      ),
                      // M10：提到顶层（仅嵌套行出现）
                      if (node.depth > 0)
                        OrbitIconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '提到顶层',
                          icon: Icon(
                            OrbitIcons.indentDecrease,
                            size: AppDimens.iconSizeSm,
                            color: colors.secondaryText,
                          ),
                          onPressed: () => _liftToTop(node.subtask),
                        ),
                      // 转独立任务（承接父任务上下文；对齐桌面行尾入口）
                      OrbitIconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '转为独立任务',
                        icon: Icon(
                          OrbitIcons.openExternal,
                          size: AppDimens.iconSizeSm,
                          color: colors.secondaryText,
                        ),
                        onPressed: () => _promote(node.subtask),
                      ),
                      // close 删除（确认弹窗防误触，对齐桌面/评论删除惯例）
                      OrbitIconButton(
                        tooltip: '删除子任务',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          OrbitIcons.close,
                          size: AppDimens.iconSizeSm,
                          color: colors.secondaryText,
                        ),
                        onPressed: () => _confirmDelete(
                          node.subtask,
                          childCountByUuid[node.subtask.uuid] ?? 0,
                        ),
                      ),
                    ],
                  ),
                  // M10：行内加子级输入框（缩进对齐子级层）
                  if (_addingUnderUuid == node.subtask.uuid)
                    Padding(
                      padding: const EdgeInsets.only(top: AppDimens.space4),
                      child: _draftInput(colors),
                    ),
                ],
              ),
            ),
          _adding
              ? _draftInput(colors)
              : OrbitButton.icon(
                  variant: OrbitButtonVariant.text,
                  onPressed: () => _startAdding(null),
                  icon: const Icon(
                    OrbitIcons.add,
                    size: AppDimens.iconSizeSm + 2,
                  ),
                  label: const Text('添加子任务'),
                ),
              ],
            ),
          ),
        ]),
      ],
    );
  }

  /// 行内草稿输入（两个入口互斥，共用同一焦点节点与 GlobalKey）。
  /// 显式取消钮 + 键盘「完成」双收口，不再依赖点击外部隐式提交。
  Widget _draftInput(AppColorSet colors) => Row(
        children: [
          Expanded(
            child: OrbitTextField(
              key: _draftFieldKey,
              inline: true,
              controller: _draftController,
              focusNode: _draftFocus,
              autofocus: true,
              textInputAction: TextInputAction.done,
              hintText: '子任务标题',
              style: TextStyle(fontSize: 15, color: colors.bodyText),
              insideMargin: const EdgeInsets.symmetric(
                vertical: AppDimens.space8,
              ),
              onSubmitted: (_) => _submitDraft(),
            ),
          ),
          OrbitIconButton(
            compact: true,
            tooltip: '取消添加',
            icon: Icon(
              OrbitIcons.close,
              size: AppDimens.iconSizeSm,
              color: colors.secondaryText,
            ),
            onPressed: _cancelAdding,
          ),
          OrbitIconButton(
            compact: true,
            tooltip: '确定',
            icon: const Icon(
              OrbitIcons.check,
              size: AppDimens.iconSizeMd,
              color: OrbitAccents.todoAccent,
            ),
            onPressed: _submitDraft,
          ),
        ],
      );
}

// ── 五、标签（chip 展示 + "编辑"多选弹层，Phase 7）──

class _LabelsSection extends StatelessWidget {
  const _LabelsSection({required this.detail});

  final TodoTaskDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupTitle(
          '标签',
          trailing: OrbitButton.text(
            onPressed: () => _openEditor(context),
            child: const Text('编辑'),
          ),
        ),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              AppDimens.space16,
            ),
            child: Wrap(
        spacing: AppDimens.space8,
        runSpacing: AppDimens.space8,
        children: [
          // 色点+标签名（与列表优先级圆点/桌面 LabelChips 同形制：点=颜色信号）
          for (final label in detail.labels)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space8 + 2,
                vertical: AppDimens.space4,
              ),
              decoration: BoxDecoration(
                borderRadius: AppShapes.small,
                border: Border.all(color: colors.divider),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: AppDimens.colorDotSize - 2,
                    height: AppDimens.colorDotSize - 2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hexToColor(label.hexColor),
                    ),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  Text(
                    label.title,
                    style: TextStyle(fontSize: 13, color: colors.bodyText),
                  ),
                ],
              ),
            ),
          if (detail.labels.isEmpty)
            Text(
              '暂无标签',
              style: TextStyle(
                fontSize: 13,
                color: colors.secondaryText.withValues(alpha: 0.5),
              ),
            ),
            ],
            ),
          ),
        ]),
      ],
    );
  }

  void _openEditor(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (_) => _LabelEditSheet(taskId: detail.id),
    );
  }
}

/// 标签编辑弹层（Phase 7）：现有标签多选勾选态（勾选变化即建/删关联）+
/// 底部"新建标签"行（标题 + 固定 10 色板选色）。勾选态直接从详情 provider
/// 派生（写后 invalidate 即回读权威态），本地不复制状态避免漂移。
class _LabelEditSheet extends ConsumerStatefulWidget {
  const _LabelEditSheet({required this.taskId});

  final int taskId;

  @override
  ConsumerState<_LabelEditSheet> createState() => _LabelEditSheetState();
}

class _LabelEditSheetState extends ConsumerState<_LabelEditSheet> {
  final _titleController = TextEditingController();

  /// 新建标签选色（默认第 4 色 #3B82F6，对齐桌面 LabelManager）
  String _newColorHex = labelPaletteHexes[3];

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  /// 勾选/取消一个标签：经 diffLabelSelection 计算关联增删后逐条落库，
  /// 完成统一 invalidate 详情（列表 chip 与勾选态一并刷新）。
  Future<void> _toggleLabel(TodoLabel label) async {
    final detail = ref.read(taskDetailProvider(widget.taskId)).value;
    if (detail == null) return;
    final taskLabelIdByLabelId = {
      for (final l in detail.labels) l.id: l.taskLabelId,
    };
    final before = taskLabelIdByLabelId.keys.toSet();
    final after = before.contains(label.id)
        ? ({...before}..remove(label.id))
        : ({...before, label.id});
    final diff = diffLabelSelection(
      before: before,
      after: after,
      taskLabelIdByLabelId: taskLabelIdByLabelId,
    );
    try {
      final bridge = ref.read(orbitBridgeProvider);
      for (final labelId in diff.attachLabelIds) {
        await bridge.todoTaskLabelCreate(
          TodoTaskLabelCreateInput(taskId: widget.taskId, labelId: labelId),
        );
      }
      for (final taskLabelId in diff.detachTaskLabelIds) {
        await bridge.todoTaskLabelDelete(taskLabelId);
      }
      ref.invalidate(taskDetailProvider(widget.taskId));
    } catch (_) {
      WaitToast.destructive('操作失败');
    }
  }

  /// 新建标签：todoLabelCreate 后 invalidate 标签列表供即时勾选
  Future<void> _createLabel() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoLabelCreate(
            TodoLabelCreateInput(title: title, hexColor: _newColorHex),
          );
      _titleController.clear();
      if (!mounted) return;
      setState(() => _newColorHex = labelPaletteHexes[3]);
      ref.invalidate(todoLabelsProvider);
    } catch (_) {
      WaitToast.destructive('创建失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final labels = ref.watch(todoLabelsProvider).value ?? const <TodoLabel>[];
    final attachedIds =
        ref
            .watch(taskDetailProvider(widget.taskId))
            .value
            ?.labels
            .map((l) => l.id)
            .toSet() ??
        <int>{};

    // 新建标签输入与色板放进**可滚内容区**：键盘弹出时输入框不会被固定尾栏
    // 挤出可视区（旧实现把整段表单塞进 actions，抽屉收缩后几乎点不到）。
    // 尾栏只留「完成」，形状/间距仍由共享骨架统一。
    return OrbitSheetScaffold(
      title: '编辑标签',
      maxHeightFactor: 0.7,
      contentPadding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        0,
        AppDimens.space16,
        AppDimens.space16,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (labels.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppDimens.space16),
              child: Text(
                '暂无可选标签',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.secondaryText.withValues(alpha: 0.5),
                ),
              ),
            )
          else
            for (final label in labels)
              InkWell(
                onTap: () => _toggleLabel(label),
                child: SizedBox(
                  height: AppDimens.touchTarget,
                  child: Row(
                    children: [
                      const SizedBox(width: AppDimens.space16),
                      OrbitCheckbox(
                        checked: attachedIds.contains(label.id),
                        size: AppDimens.iconSizeMd + 2,
                        onToggle: () => _toggleLabel(label),
                      ),
                      const SizedBox(width: AppDimens.space12),
                      Container(
                        width: AppDimens.colorDotSize,
                        height: AppDimens.colorDotSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hexToColor(label.hexColor),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      Expanded(
                        child: Text(
                          label.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: colors.bodyText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: AppDimens.space12),
          Text(
            '新建标签',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.secondaryText,
            ),
          ),
          const SizedBox(height: AppDimens.space12),
          Row(
            children: [
              Expanded(
                child: OrbitTextField(
                  inline: true,
                  controller: _titleController,
                  maxLength: 50,
                  textInputAction: TextInputAction.done,
                  hintText: '新建标签',
                  style: TextStyle(fontSize: 15, color: colors.bodyText),
                  insideMargin: const EdgeInsets.symmetric(
                    vertical: AppDimens.space8,
                  ),
                  onSubmitted: (_) => _createLabel(),
                ),
              ),
              OrbitIconButton(
                tooltip: '新建标签',
                icon: Icon(
                  OrbitIcons.add,
                  size: AppDimens.iconSizeLg,
                  color: OrbitAccents.todoAccent,
                ),
                onPressed: _createLabel,
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space12),
          OrbitColorSwatches(
            hexes: labelPaletteHexes,
            selectedHex: _newColorHex,
            onSelected: (hex) => setState(() => _newColorHex = hex),
          ),
        ],
      ),
      actions: OrbitSheetActions(
        confirmLabel: '完成',
        onConfirm: () => Navigator.of(context).pop(),
      ),
    );
  }
}

// ── 六、提醒（可增改删；编辑=删旧建新，桌面 task-detail-drawer 同语义）──

class _RemindersSection extends ConsumerWidget {
  const _RemindersSection({
    required this.taskId,
    required this.reminders,
    required this.repeatMode,
    required this.repeatAfter,
    required this.repeatWeekdays,
    required this.repeatEndType,
    required this.repeatEndParam,
    required this.repeatFromDone,
    required this.repeatMonthMode,
    required this.repeatNthWeek,
    required this.dueDate,
    required this.startDate,
    required this.durationMinutes,
    required this.onChanged,
  });

  final int taskId;
  final List<TodoReminder> reminders;

  /// 任务重复规则（>0 时提醒行显示规则徽标，对齐桌面；#34 扩展字段完整显示）
  final int repeatMode;
  final int repeatAfter;
  final int repeatWeekdays;
  final int repeatEndType;
  final int repeatEndParam;
  final int repeatFromDone;
  final int repeatMonthMode;
  final int repeatNthWeek;

  /// 提醒相对档的锚定上下文（截止/开始/时长；见 [reminderPresets]）——
  /// 与表单 `_pickReminder` 同口径，相对档是输入便捷层，产物仍是绝对时刻
  final int? dueDate;
  final int? startDate;
  final int? durationMinutes;

  final VoidCallback onChanged;

  /// 提醒时间选择：先给相对档快捷（见 [reminderPresets]，含「结束时」/
  /// 「截止当天 9:00」/「截止前 N 分钟」），末项进日期+时分单面板；
  /// 与表单 `_pickReminder` 同口径（对齐桌面详情抽屉 DateTimePicker 的相对档）
  Future<void> _pickReminder(
    BuildContext context, {
    required int initialMs,
    required Future<void> Function(int ms) onPicked,
  }) async {
    await showSelectBottomSheet<String>(
      context,
      title: '提醒时间',
      items: [
        for (final p in reminderPresets(
          dueDate: dueDate,
          startDate: startDate,
          durationMinutes: durationMinutes,
        ))
          SelectItem<String>(value: '${p.ms}', label: p.label),
        const SelectItem<String>(value: _reminderCustomKey, label: '自定义时间…'),
      ],
      onSelect: (v) async {
        if (v == _reminderCustomKey) {
          final picked = await OrbitDatePicker.pick(
            context,
            initialDate: DateTime.fromMillisecondsSinceEpoch(initialMs),
            showTime: true,
            accent: OrbitAccents.todoAccent,
          );
          if (picked == null || !context.mounted) return;
          await onPicked(picked.millisecondsSinceEpoch);
        } else {
          await onPicked(int.parse(v));
        }
      },
    );
  }

  /// 变更统一出口：落库 → onChanged 失效详情与列表
  Future<void> _mutate(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      onChanged();
    } catch (_) {
      WaitToast.destructive('操作失败');
    }
  }

  /// 添加提醒：相对档快捷 + 自定义；自定义初值一小时后
  Future<void> _add(BuildContext context, WidgetRef ref) async {
    await _pickReminder(
      context,
      initialMs: DateTime.now().millisecondsSinceEpoch + 3600000,
      onPicked: (ms) => _mutate(context, ref, () async {
        final bridge = ref.read(orbitBridgeProvider);
        await bridge.todoReminderCreate(
          TodoReminderCreateInput(taskId: taskId, remindAt: ms),
        );
      }),
    );
  }

  /// 编辑提醒：同入口换初值，变更走删旧建新（复用表单 syncTaskReminder）
  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    TodoReminder reminder,
  ) async {
    await _pickReminder(
      context,
      initialMs: reminder.remindAt,
      onPicked: (ms) => _mutate(context, ref, () async {
        final bridge = ref.read(orbitBridgeProvider);
        await syncTaskReminder(
          bridge,
          taskId,
          ms,
          reminder,
          isConstant: reminder.isConstant,
        );
      }),
    );
  }

  /// 翻转持续提醒标记（G2）：时刻不变，仅标记变更——删旧建新（对齐桌面
  /// 详情抽屉的「持续」徽标；todo_reminders 无 update 路径）
  Future<void> _toggleConstant(
    BuildContext context,
    WidgetRef ref,
    TodoReminder reminder,
  ) async {
    await _mutate(context, ref, () async {
      final bridge = ref.read(orbitBridgeProvider);
      await bridge.todoReminderDelete(reminder.id);
      await bridge.todoReminderCreate(
        TodoReminderCreateInput(
          taskId: taskId,
          remindAt: reminder.remindAt,
          isConstant: reminder.constant ? 0 : 1,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.ofContext(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupTitle(
          '提醒',
          trailing: OrbitButton.text(
            onPressed: () => _add(context, ref),
            child: const Text('添加提醒'),
          ),
        ),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space8,
              AppDimens.space16,
              AppDimens.space12,
            ),
            child: reminders.isEmpty
          ? Text(
              '暂无提醒',
              style: TextStyle(
                fontSize: 13,
                color: colors.secondaryText.withValues(alpha: 0.5),
              ),
            )
          : Column(
              children: [
                for (final reminder in reminders)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppDimens.space4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          OrbitIcons.notification,
                          size: AppDimens.iconSizeSm + 2,
                          color: colors.secondaryText,
                        ),
                        const SizedBox(width: AppDimens.space8),
                        // 点值文本进入编辑（同桌面行点按语义）
                        Expanded(
                          child: InkWell(
                            onTap: () => _edit(context, ref, reminder),
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    formatStampLabel(reminder.remindAt),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: colors.bodyText,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: AppDimens.space8),
                                Text(
                                  relativeFromNow(reminder.remindAt),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.secondaryText,
                                  ),
                                ),
                                // 持续提醒徽标：恒显可点（激活警告色、未激活弱化灰）——
                                // 桌面把开关放在提醒编辑面板，移动端无独立编辑面板，
                                // 行内 chip 是等价能力的触控形态（能力等价、形态差异）
                                const SizedBox(width: AppDimens.space8),
                                Tooltip(
                                  message: reminder.constant
                                      ? '关闭持续提醒（未完成则每 5 分钟再提醒）'
                                      : '开启持续提醒（未完成则每 5 分钟再提醒）',
                                  child: InkWell(
                                    borderRadius: AppShapes.full,
                                    onTap: () =>
                                        _toggleConstant(context, ref, reminder),
                                    child: SizedBox(
                                      height: AppDimens.touchTarget,
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: AppDimens.space8,
                                            vertical: AppDimens.space4,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius: AppShapes.full,
                                            color: reminder.constant
                                                ? colors.warning.withValues(
                                                    alpha: 0.15,
                                                  )
                                                : colors.surfaceSecondary,
                                          ),
                                          child: Text(
                                            '持续',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: reminder.constant
                                                  ? colors.warning
                                                  : colors.secondaryText,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (repeatMode > 0) ...[
                                  const SizedBox(width: AppDimens.space8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppDimens.space4 + 2,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: AppShapes.full,
                                      color: OrbitAccents.todoAccent.withValues(
                                        alpha: 0.1,
                                      ),
                                    ),
                                    child: Text(
                                      rep.repeatLabelExt(
                                        repeatMode,
                                        repeatAfter,
                                        weekdays: repeatWeekdays,
                                        endType: repeatEndType,
                                        endParam: repeatEndParam,
                                        fromDone: repeatFromDone,
                                        monthMode: repeatMonthMode,
                                        nthWeek: repeatNthWeek,
                                      ),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: OrbitAccents.todoAccent,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        // 删除（二次确认抽屉，对齐桌面提醒行 ConfirmPopover；
                        // 确认文案点名时刻并说明后果，措辞与桌面一致）
                        OrbitIconButton(
                          tooltip: '删除提醒',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            OrbitIcons.close,
                            size: AppDimens.iconSizeSm,
                            color: colors.secondaryText,
                          ),
                          onPressed: () async {
                            final confirmed = await showConfirmBottomSheet(
                              context,
                              title: '删除提醒',
                              message:
                                  '确定要删除 ${formatStampLabel(reminder.remindAt)}'
                                  ' 的提醒吗？删除后该时间不再通知。',
                              confirmLabel: '删除',
                              destructive: true,
                            );
                            if (!confirmed || !context.mounted) return;
                            await _mutate(context, ref, () async {
                              await ref
                                  .read(orbitBridgeProvider)
                                  .todoReminderDelete(reminder.id);
                              // 同步撤掉该任务的系统闹钟：残留闹钟与「后台推迟
                              // 产物」在系统侧无法区分，不取消会在下次重排的孤儿
                              // 补齐里被误判而把刚删的提醒建回来
                              await NotificationService.instance.cancelAlarmFor(
                                reminder.taskId,
                              );
                            });
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ],
    );
  }
}

// ── 七、关联任务（搜索增删 + 只读胶囊；空态保留添加入口）──

class _RelationsSection extends ConsumerStatefulWidget {
  const _RelationsSection({
    required this.taskId,
    required this.relations,
    required this.onChanged,
  });

  final int taskId;
  final List<TodoTaskRelation> relations;
  final VoidCallback onChanged;

  @override
  ConsumerState<_RelationsSection> createState() => _RelationsSectionState();
}

class _RelationsSectionState extends ConsumerState<_RelationsSection> {
  /// 对方任务快照（other_task_id → 任务；null = 查无此任务，维持 #id 回退）。
  /// 关联行不带标题（桌面同坑，逐行 todoTaskGet 单查），按 id 缓存；
  /// 关联变化时只补查缺的行，失败不弹错——标题是增强信息
  final Map<int, TodoTask?> _peers = {};
  final Set<int> _loadingPeers = {};

  @override
  void initState() {
    super.initState();
    _ensurePeers();
  }

  @override
  void didUpdateWidget(covariant _RelationsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensurePeers();
  }

  void _ensurePeers() {
    for (final r in widget.relations) {
      final id = r.otherTaskId;
      if (_peers.containsKey(id) || _loadingPeers.contains(id)) continue;
      _loadingPeers.add(id);
      final future = ref.read(orbitBridgeProvider).todoTaskGet(id);
      future.then(
        (t) {
          if (!mounted) return;
          setState(() {
            _peers[id] = t;
            _loadingPeers.remove(id);
          });
        },
        onError: (_) {
          if (!mounted) return;
          setState(() {
            _peers[id] = null;
            _loadingPeers.remove(id);
          });
        },
      );
    }
  }

  String _peerLabel(TodoTaskRelation relation) {
    final peer = _peers[relation.otherTaskId];
    if (peer == null) return '任务 #${relation.otherTaskId}';
    return peer.isDone ? '${peer.title}（已完成）' : peer.title;
  }

  /// 解除关联：先确认（文案点名对方标题，桌面同口径——双方都会解除）
  Future<void> _remove(TodoTaskRelation relation) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除关联',
      message: '确定要移除与「${_peerLabel(relation)}」的关联吗？双方都会解除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(orbitBridgeProvider).todoTaskRelationDelete(relation.id);
      widget.onChanged();
      if (mounted) WaitToast.success('已解除关联');
    } catch (e) {
      if (mounted) WaitToast.destructive('解除关联失败');
    }
  }

  /// 关联任务搜索增删：关键词走全局搜索，点选一行即建关联；
  /// 候选排除自身与已关联（桌面同口径）。抽屉走共享骨架 + 独立 StatefulWidget，
  /// 控制器/焦点有明确生命周期，键盘避让与滚动由 OrbitSheetScaffold 统一。
  Future<void> _pickAndAdd() async {
    final linkedIds = {for (final r in widget.relations) r.otherTaskId};
    final targetId = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: bottomSheetTopShape,
      sheetAnimationStyle: bottomSheetMotion,
      builder: (_) => _RelationSearchSheet(
        taskId: widget.taskId,
        linkedIds: linkedIds,
      ),
    );
    if (targetId == null) return;
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoTaskRelationCreate(
            TodoTaskRelationCreateInput(
              taskId: widget.taskId,
              otherTaskId: targetId,
              relationType: 'relates_to',
            ),
          );
      widget.onChanged();
      if (mounted) WaitToast.success('已添加关联');
    } catch (e) {
      if (mounted) WaitToast.destructive('添加关联失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupTitle(
          '关联',
          trailing: OrbitIconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '添加关联',
            icon: const Icon(
              OrbitIcons.add,
              size: AppDimens.iconSizeSm,
              color: OrbitAccents.todoAccent,
            ),
            onPressed: _pickAndAdd,
          ),
        ),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              AppDimens.space16,
            ),
            child: widget.relations.isEmpty
          ? Text(
              '暂无关联任务，可点右上 + 搜索添加',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.ofContext(context).secondaryText,
              ),
            )
          : Wrap(
              spacing: AppDimens.space4,
              runSpacing: AppDimens.space4,
              children: [
                for (final relation in widget.relations)
                  InkWell(
                    onTap: () => context.push('/todo/${relation.otherTaskId}'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppDimens.space8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: AppShapes.small,
                        color: OrbitAccents.todoAccent.withValues(alpha: 0.1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              _peerLabel(relation),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: OrbitAccents.todoAccent,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _relationTypeLabels[relation.relationType] ??
                                relation.relationType,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.ofContext(context).secondaryText,
                            ),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () => _remove(relation),
                            child: const Icon(
                              OrbitIcons.close,
                              size: 14,
                              color: OrbitAccents.todoAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ],
    );
  }
}

/// 关联任务搜索抽屉：输入 → 搜索 → 点行返回对方任务 id。
///
/// 旧实现用 StatefulBuilder 手搓 SafeArea + 手写 viewInsets，控制器从不
/// dispose，且结果塞进 Flexible(ListView) 与键盘避让叠加后输入框常被挤出
/// 可视区。改由共享 [OrbitSheetScaffold] 承载，滚动/避让/形状统一。
class _RelationSearchSheet extends ConsumerStatefulWidget {
  const _RelationSearchSheet({
    required this.taskId,
    required this.linkedIds,
  });

  final int taskId;
  final Set<int> linkedIds;

  @override
  ConsumerState<_RelationSearchSheet> createState() =>
      _RelationSearchSheetState();
}

class _RelationSearchSheetState extends ConsumerState<_RelationSearchSheet> {
  final _queryController = TextEditingController();
  final _queryFocus = FocusNode();
  List<TodoTask> _hits = [];
  bool _searching = false;

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _queryController.text.trim();
    if (keyword.isEmpty || _searching) return;
    setState(() => _searching = true);
    try {
      final result = await ref
          .read(orbitBridgeProvider)
          .globalSearch(keyword, limit: 20);
      if (!mounted) return;
      setState(() {
        _hits = result.tasks
            .where(
              (t) =>
                  t.id != widget.taskId && !widget.linkedIds.contains(t.id),
            )
            .toList();
        _searching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return OrbitSheetScaffold(
      title: '关联任务',
      maxHeightFactor: 0.7,
      contentPadding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        0,
        AppDimens.space16,
        AppDimens.space16,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OrbitTextField(
                  controller: _queryController,
                  focusNode: _queryFocus,
                  autofocus: true,
                  label: '搜索任务标题',
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: AppDimens.space8),
              OrbitIconButton(
                tooltip: '搜索任务',
                onPressed: _search,
                icon: const Icon(
                  OrbitIcons.search,
                  size: AppDimens.iconSizeMd,
                  color: OrbitAccents.todoAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.space12),
          if (_searching)
            const Center(child: OrbitSpinner(size: AppDimens.iconSizeLg))
          else if (_hits.isEmpty)
            Text(
              '输入关键词后点搜索（排除本任务与已关联）',
              style: TextStyle(fontSize: 13, color: colors.secondaryText),
            )
          else
            for (final t in _hits.take(20))
              InkWell(
                onTap: () => Navigator.of(context).pop(t.id),
                child: SizedBox(
                  height: AppDimens.touchTarget,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: colors.bodyText,
                          ),
                        ),
                      ),
                      Text(
                        '#${t.id}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
      actions: OrbitSheetActions(
        cancelLabel: '取消',
        onCancel: () => Navigator.of(context).pop(),
        confirmLabel: '搜索',
        onConfirm: _search,
      ),
    );
  }
}

// ── 八、评论（输入框 + 列表 + 删除确认）──

class _CommentsSection extends ConsumerStatefulWidget {
  const _CommentsSection({required this.detail, required this.onChanged});

  final TodoTaskDetail detail;
  final VoidCallback onChanged;

  @override
  ConsumerState<_CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends ConsumerState<_CommentsSection> {
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  final _inputFieldKey = GlobalKey();

  /// 评论列表预览上限：区块内最多露出 3 条的篇幅，超出在区块内滑动查看
  ///
  /// 单条约 84dp（正文 15sp 单行 + 4 + 时间/删除行 + 上下各 10 + 条间距 8）。
  /// 正文可能多行，故这是「篇幅」而非精确条数：内容不足 3 条高度时列表
  /// 自然收缩，超出才出现内层滚动，并在列表上方常驻一条条数提示。
  static const int _previewCount = 3;
  static const double _previewHeight = _previewCount * 84.0;

  @override
  void initState() {
    super.initState();
    // 评论框在页面很下方：键盘弹起后整页 ListView 不会自动滚到焦点控件，
    // 显式 ensureVisible 才能避免输入框被键盘盖住。
    _inputFocus.addListener(_scrollInputIntoView);
  }

  void _scrollInputIntoView() {
    if (!_inputFocus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = _inputFieldKey.currentContext;
      if (fieldContext == null || !fieldContext.mounted) return;
      Scrollable.ensureVisible(
        fieldContext,
        duration: Duration.zero,
        alignment: 0.4,
      );
    });
  }

  @override
  void dispose() {
    _inputFocus.removeListener(_scrollInputIntoView);
    _inputFocus.dispose();
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _inputController.text.trim();
    if (content.isEmpty) return;
    _inputController.clear();
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoCommentCreate(
            TodoCommentCreateInput(taskId: widget.detail.id, content: content),
          );
      widget.onChanged();
    } catch (_) {
      WaitToast.destructive('操作失败');
    }
  }

  Future<void> _delete(TodoComment comment) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除评论',
      message: '确定要删除这条评论吗？此操作无法撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(orbitBridgeProvider).todoCommentDelete(comment.id);
      widget.onChanged();
    } catch (_) {
      WaitToast.destructive('操作失败');
    }
  }

  /// 单条评论（灰底圆角块：正文 + 相对时间 + 删除）
  Widget _commentTile(AppColorSet colors, TodoComment comment) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: AppDimens.space8),
    padding: const EdgeInsets.all(AppDimens.space8 + 2),
    decoration: BoxDecoration(
      color: colors.surfaceSecondary,
      borderRadius: AppShapes.small,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          comment.content,
          style: TextStyle(fontSize: 15, color: colors.bodyText),
        ),
        const SizedBox(height: AppDimens.space4),
        Row(
          children: [
            Text(
              formatRelativeTime(comment.createdAt),
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
            const Spacer(),
            OrbitIconButton(
              compact: true,
              tooltip: '删除评论',
              onPressed: () => _delete(comment),
              icon: Icon(
                OrbitIcons.delete,
                size: AppDimens.iconSizeSm,
                color: colors.secondaryText,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final comments = widget.detail.comments;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GroupTitle('评论'),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              AppDimens.space16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (comments.isEmpty)
                  Text(
                    '暂无评论',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.secondaryText.withValues(alpha: 0.5),
                    ),
                  )
                else ...[
                  // 超出 3 条篇幅才给提示：条数常驻在列表上方，滚动时也看得见
                  if (comments.length > _previewCount)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppDimens.space8),
                      child: Text(
                        '共 ${comments.length} 条评论 · 上下滑动查看',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: _previewHeight),
                    child: SingleChildScrollView(
                      key: detailCommentsListKey,
                      // 详情页本身是 ListView：内层滚动必须显式 primary=false，
                      // 否则两层都认 PrimaryScrollController
                      primary: false,
                      physics: const ClampingScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final comment in comments)
                            _commentTile(colors, comment),
                        ],
                      ),
                    ),
                  ),
                ],
                // 底部输入区：分隔线 + 灰底圆角输入条 + 发送钮
                //
                // 内联档的 OrbitTextField 是透明底（标签降级为占位符），直接
                // 贴在分隔线下会读成「一行灰字」——占位与上方空态文案同色同
                // 字号，看不出这是输入框（2026-11-06 反馈「输入文字看不清」）。
                // 补一层 surfaceSecondary 圆角底 + 水平 12 内边距 + 44 最小
                // 行高后，输入区有明确边界，占位也不再贴着分隔线。
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.only(top: AppDimens.space12),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: colors.divider)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(
                            minHeight: AppDimens.touchTarget,
                          ),
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppDimens.space12,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surfaceSecondary,
                            borderRadius: AppShapes.small,
                          ),
                          child: OrbitTextField(
                            key: _inputFieldKey,
                            inline: true,
                            controller: _inputController,
                            focusNode: _inputFocus,
                            textInputAction: TextInputAction.send,
                            hintText: '输入评论...',
                            style: TextStyle(
                              fontSize: 15,
                              color: colors.bodyText,
                            ),
                            insideMargin: const EdgeInsets.symmetric(
                              vertical: AppDimens.space8,
                            ),
                            onSubmitted: (_) => _submit(),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      OrbitIconButton(
                        tooltip: '发送',
                        icon: const Icon(
                          OrbitIcons.send,
                          size: AppDimens.iconSizeMd,
                          color: OrbitAccents.todoAccent,
                        ),
                        onPressed: _submit,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ]),
      ],
    );
  }
}

// ── 九、附件（文件/拍照双来源 + 内容寻址列表 + 删除确认）──
// 来源口径：文件（file_picker）/ 拍照（image_picker 相机）/ 分享导入
// （系统分享文本经 ShareReceiver 建任务，BootGate 冷热双路消费）

class _AttachmentsSection extends ConsumerStatefulWidget {
  const _AttachmentsSection({required this.taskId});

  final int taskId;

  @override
  ConsumerState<_AttachmentsSection> createState() =>
      _AttachmentsSectionState();
}

class _AttachmentsSectionState extends ConsumerState<_AttachmentsSection> {
  List<TaskAttachmentView>? _attachments;
  bool _busy = false;

  /// 行内缩略图字节缓存（hash → 压缩字节）
  // bounded: 条数 ≤ [_thumbMaxEntries] 且总量 ≤ [_thumbBudgetBytes]，超出按插入序 FIFO 淘汰
  final Map<String, Uint8List> _thumbs = {};
  int _thumbBytes = 0;

  /// 单图源字节上限：超过则不做缩略图（读一次的成本高于收益，行内回落图片图标）
  static const _thumbSourceLimitBytes = 2 * 1024 * 1024;
  static const _thumbBudgetBytes = 16 * 1024 * 1024;
  static const _thumbMaxEntries = 12;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // 缩略图字节随区块卸载整体释放（bounded-by-lifecycle：与详情页同生命周期）
    _thumbs.clear();
    _thumbBytes = 0;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await ref
          .read(orbitBridgeProvider)
          .taskAttachmentsList(widget.taskId);
      if (mounted) setState(() => _attachments = list);
      unawaited(_loadThumbs(list));
    } catch (_) {
      if (mounted) setState(() => _attachments = []);
    }
  }

  /// 只对「本机已落地的小体积图片」做行内缩略图
  bool _thumbnailable(TaskAttachmentView att) =>
      att.mimeType.startsWith('image/') &&
      att.isLocalCached == 1 &&
      att.sizeBytes > 0 &&
      att.sizeBytes <= _thumbSourceLimitBytes;

  /// 串行读取缩略图字节（一次 `_load` 最多 20 条；并发读会把 20 份字节同时压进堆）
  ///
  /// 单条失败（未落地 / 读取异常）静默跳过——行内回落文件图标，不影响其余行。
  Future<void> _loadThumbs(List<TaskAttachmentView> list) async {
    final bridge = ref.read(orbitBridgeProvider);
    var changed = false;
    for (final att in list) {
      if (_thumbs.containsKey(att.hash) || !_thumbnailable(att)) continue;
      try {
        final bytes = await bridge.taskAttachmentRead(att.hash);
        if (!mounted) return;
        if (bytes.isEmpty) continue; // 空字节流不渲染（mock / 占位）
        _thumbs[att.hash] = Uint8List.fromList(bytes);
        _thumbBytes += bytes.length;
        _evictThumbs();
        changed = true;
      } catch (_) {
        /* 单条失败不影响其余 */
      }
    }
    if (changed && mounted) setState(() {});
  }

  /// 缓存淘汰：条数与总字节双上限，任一超出即从最旧（插入序）开始丢
  void _evictThumbs() {
    while (_thumbs.length > _thumbMaxEntries ||
        (_thumbBytes > _thumbBudgetBytes && _thumbs.length > 1)) {
      final oldest = _thumbs.keys.first;
      _thumbBytes -= _thumbs.remove(oldest)!.length;
    }
  }

  Future<void> _uploadBytes(String name, List<int> bytes, String source) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(orbitBridgeProvider)
          .taskAttachmentAdd(widget.taskId, name, _mimeFromName(name), bytes);
      await _load();
      if (mounted) WaitToast.success('已添加附件（$source）');
    } catch (e) {
      if (mounted) WaitToast.destructive('附件上传失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 文件来源走路径入参：core 流式读盘，不把整份字节读进 Dart 堆
  Future<void> _uploadPath(String name, String path, String source) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(orbitBridgeProvider)
          .taskAttachmentAddPath(
            widget.taskId,
            name,
            _mimeFromName(name),
            path,
          );
      await _load();
      if (mounted) WaitToast.success('已添加附件（$source）');
    } catch (e) {
      if (mounted) WaitToast.destructive('附件上传失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFile() async {
    if (_busy) return;
    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    final file = result?.files.single;
    final path = file?.path;
    if (path == null) return;
    await _uploadPath(file!.name, path, '文件');
  }

  /// 拍照添加附件（相机直拍；取消静默返回，无权限时提示）
  Future<void> _addCamera() async {
    if (_busy) return;
    try {
      final shot = await ImagePicker().pickImage(source: ImageSource.camera);
      if (shot == null) return;
      final bytes = await shot.readAsBytes();
      final name = 'photo-${DateTime.now().millisecondsSinceEpoch}.jpg';
      await _uploadBytes(name, bytes, '拍照');
    } catch (_) {
      if (mounted) WaitToast.destructive('相机不可用');
    }
  }

  String _mimeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    const map = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'pdf': 'application/pdf',
      'txt': 'text/plain',
      'md': 'text/markdown',
      'csv': 'text/csv',
      'json': 'application/json',
      'zip': 'application/zip',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  Future<void> _open(TaskAttachmentView att) async {
    if (att.isLocalCached == 0) {
      WaitToast.info('附件尚未从云端同步到本机，稍后自动拉取');
      return;
    }
    try {
      final bytes = await ref
          .read(orbitBridgeProvider)
          .taskAttachmentRead(att.hash);
      final dir = await getTemporaryDirectory();
      final target = File(
        '${dir.path}/orbit-att-${att.hash}${_extOf(att.originalName)}',
      );
      await target.writeAsBytes(bytes);
      if (!mounted) return;
      if (att.mimeType.startsWith('image/')) {
        // 图片：应用内全屏预览（无第三方打开器依赖；双指缩放走内置
        // InteractiveViewer，不引第三方查看器）。点按任意处关闭。
        // cacheWidth 降采样解码（F4 内存优化）：4K 照片按屏宽 3x 像素解码，
        // 不再原图全尺寸进纹理——单图 ~4000x3000 解码内存从 ~45MB 降到 ~8MB
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final screenWidth = MediaQuery.sizeOf(context).width;
        final cacheWidth = (screenWidth * dpr).round();
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(16),
            child: GestureDetector(
              onTap: () => Navigator.of(dialogContext).pop(),
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Image.file(
                  target,
                  fit: BoxFit.contain,
                  cacheWidth: cacheWidth,
                ),
              ),
            ),
          ),
        );
      } else {
        // 非图片类型：写入临时目录后引导（Android 用户可经文件管理器取用；
        // 引入系统打开器属新依赖，本批不扩）
        WaitToast.info('已保存到缓存目录：${target.path}');
      }
    } catch (_) {
      if (mounted) WaitToast.destructive('打开附件失败');
    }
  }

  String _extOf(String name) {
    final parts = name.split('.');
    return parts.length > 1 ? '.${parts.last}' : '';
  }

  /// 另存到用户选择的目录（#107）：流式导出，不把整份字节读进 Dart 堆。
  /// Android 走系统目录选择器；iOS 无目录选择（返回 null）→ 静默返回，
  /// 仍可用行首「打开」走系统分享/预览。
  Future<void> _saveAs(TaskAttachmentView att) async {
    if (att.isLocalCached == 0) {
      WaitToast.info('附件尚未从云端同步到本机');
      return;
    }
    try {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择保存位置',
      );
      if (dir == null) return;
      final target = '$dir${Platform.pathSeparator}${att.originalName}';
      final written = await ref
          .read(orbitBridgeProvider)
          .exportTaskAttachment(att.hash, target);
      if (mounted) {
        WaitToast.success(
          '已保存「${att.originalName}」（${humanFileSize(written)}）',
        );
      }
    } catch (_) {
      if (mounted) WaitToast.destructive('保存失败');
    }
  }

  Future<void> _remove(TaskAttachmentView att) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '移除附件',
      message: '确定要移除「${att.originalName}」吗？仅解除与任务的关联。',
      confirmLabel: '移除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await ref.read(orbitBridgeProvider).taskAttachmentRemove(att.linkId);
      await _load();
    } catch (_) {
      if (mounted) WaitToast.destructive('操作失败');
    }
  }

  /// 行首视觉：图片附件走 32 缩略图（字节缺失回落图片图标），其余走文件类型图标
  ///
  /// 未同步到本机（isLocalCached == 0）一律云下载图标——缩略图只可能来自本地字节。
  Widget _leading(AppColorSet colors, TaskAttachmentView att) {
    final cached = att.isLocalCached != 0;
    final isImage = att.mimeType.startsWith('image/');
    final icon = Icon(
      !cached
          ? OrbitIcons.cloudDownload
          : isImage
          ? OrbitIcons.image
          : OrbitIcons.fileText,
      size: AppDimens.iconSizeSm,
      color: colors.secondaryText,
    );
    if (!isImage) return icon;
    return OrbitImageThumb(
      size: AppDimens.space32,
      bytes: _thumbs[att.hash],
      fallback: icon,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final list = _attachments;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupTitle(
          '附件',
          trailing: _busy
              ? const OrbitSpinner(size: 16)
              : OrbitIconButton(
                  tooltip: '添加附件',
                  icon: const Icon(OrbitIcons.add),
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => showSelectBottomSheet<String>(
                    context,
                    title: '添加附件',
                    current: null,
                    items: const [
                      SelectItem(value: 'file', label: '选择文件'),
                      SelectItem(value: 'camera', label: '拍照'),
                    ],
                    onSelect: (v) => v == 'camera' ? _addCamera() : _addFile(),
                  ),
                ),
        ),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              AppDimens.space16,
            ),
            child: list == null
          ? const SizedBox(height: AppDimens.space16)
          : list.isEmpty
          ? Text(
              '点 + 添加文件或拍照（单任务 20 个，单文件 50MB）',
              style: TextStyle(
                fontSize: 13,
                color: colors.secondaryText.withValues(alpha: 0.5),
              ),
            )
          : Column(
              children: [
                for (final att in list)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: AppDimens.space8),
                    padding: const EdgeInsets.all(AppDimens.space8 + 2),
                    decoration: BoxDecoration(
                      color: colors.surfaceSecondary,
                      borderRadius: AppShapes.small,
                    ),
                    child: Row(
                      children: [
                        _leading(colors, att),
                        const SizedBox(width: AppDimens.space8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                att.originalName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.bodyText,
                                ),
                              ),
                              Text(
                                att.isLocalCached == 0
                                    ? '待同步'
                                    : humanFileSize(att.sizeBytes),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.secondaryText,
                                ),
                              ),
                            ],
                          ),
                        ),
                        OrbitIconButton(
                          compact: true,
                          tooltip: '打开附件',
                          onPressed: () => _open(att),
                          icon: Icon(
                            OrbitIcons.openExternal,
                            size: AppDimens.iconSizeSm,
                            color: colors.secondaryText,
                          ),
                        ),
                        OrbitIconButton(
                          compact: true,
                          tooltip: '另存附件',
                          onPressed: att.isLocalCached == 0
                              ? null
                              : () => _saveAs(att),
                          icon: Icon(
                            OrbitIcons.download,
                            size: AppDimens.iconSizeSm,
                            color: att.isLocalCached == 0
                                ? colors.secondaryText.withValues(alpha: 0.4)
                                : colors.secondaryText,
                          ),
                        ),
                        OrbitIconButton(
                          compact: true,
                          tooltip: '移除附件',
                          onPressed: () => _remove(att),
                          icon: Icon(
                            OrbitIcons.delete,
                            size: AppDimens.iconSizeSm,
                            color: colors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ],
    );
  }
}

// ── 十、历史（只读轨迹：taskActivityProvider 时间倒序；档位口径同桌面）──

class _HistorySection extends ConsumerStatefulWidget {
  const _HistorySection({required this.taskId});

  final int taskId;

  @override
  ConsumerState<_HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends ConsumerState<_HistorySection> {
  /// 取数档位：默认 30 条，满档提示「仅显示最近 N 条」并可展到
  /// core clamp 上限 100（双端同口径，桌面见 ActivitySection）
  static const _baseLimit = 30;
  static const _maxLimit = 100;
  int _limit = _baseLimit;

  /// 历史列表预览上限：区块内最多露出约 9 条篇幅，超出在区块内滑动查看
  ///
  /// 单条约 28dp（11sp 时间与 13sp 正文取高 18 + 条间距 8；正文换行更高），
  /// 故按篇幅而非精确条数限高。9 条最小篇幅已超限高——条数多于
  /// [_previewRows] 时必然可滚，滑块才转常显。
  static const int _previewRows = 9;
  static const double _previewHeight = _previewRows * 28.0;

  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 事件行文案由写入端 detail 快照驱动，格式化镜像桌面 activity-format.ts
    final asyncRows = ref.watch(
      taskActivityProvider((taskId: widget.taskId, limit: _limit)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _GroupTitle('历史'),
        _groupCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              AppDimens.space16,
            ),
            child: asyncRows.when(
        loading: () => const SizedBox(height: 16),
        error: (_, _) => Text(
          '历史加载失败',
          style: TextStyle(fontSize: 13, color: colors.secondaryText),
        ),
        data: (rows) => rows.isEmpty
            ? Text(
                '暂无操作记录',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.secondaryText.withValues(alpha: 0.5),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 超出预览篇幅才给提示：条数与「可滑动」常驻在列表上方，
                  // 滚动时也看得见（口径同评论区「共 N 条评论 · 上下滑动查看」）
                  if (rows.length > _previewRows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppDimens.space8),
                      child: Text(
                        '共 ${rows.length} 条操作 · 上下滑动查看',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: _previewHeight),
                    child: Scrollbar(
                      controller: _scrollController,
                      // 触屏没有 hover 态：可滚时滑块常显，否则「下面还有」
                      // 没有任何视觉线索（条数超限高即一定可滚）
                      thumbVisibility: rows.length > _previewRows,
                      child: SingleChildScrollView(
                        key: detailHistoryListKey,
                        // 详情页本身是 ListView：内层滚动必须显式 primary=false，
                        // 否则两层都认 PrimaryScrollController
                        primary: false,
                        controller: _scrollController,
                        physics: const ClampingScrollPhysics(),
                        // 右侧留出滑块位置，避免常显滑块压在行尾文字上
                        child: Padding(
                          padding: const EdgeInsets.only(
                            right: AppDimens.space8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final r in rows)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: AppDimens.space8,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        formatStampLabel(r.createdAt),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: colors.secondaryText,
                                        ),
                                      ),
                                      const SizedBox(width: AppDimens.space8),
                                      Expanded(
                                        child: Text(
                                          describeActivity(r.action, r.detail),
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: colors.bodyText,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 档位提示钉在滚动区外：列表内滚动时也常驻可见
                  if (rows.length >= _limit)
                    Padding(
                      padding: const EdgeInsets.only(top: AppDimens.space8),
                      child: Row(
                        children: [
                          Text(
                            '仅显示最近 $_limit 条操作',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.secondaryText,
                            ),
                          ),
                          if (_limit < _maxLimit)
                            OrbitButton.text(
                              compact: true,
                              onPressed: () =>
                                  setState(() => _limit = _maxLimit),
                              child: const Text(
                                '显示更多',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ]),
      ],
    );
  }
}
