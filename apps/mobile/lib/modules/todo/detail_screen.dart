import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../services/notification_service.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_strikethrough.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_confirm_sheet.dart';
import '../../shared/widgets/shadcn/orbit_image_thumb.dart';
import '../../shared/widgets/shadcn/orbit_info_row.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_skeleton.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart' show bottomSheetTopShape;
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'form_bottom_sheet.dart' show showTodoDatePicker, syncTaskReminder;
// as rep：规避 Flutter widgets 自带 RepeatMode 类名冲突
import 'logic/activity_format.dart';
import 'logic/markdown_lite.dart';
import 'logic/repeat_logic.dart' as rep;
import 'repeat_edit_sheet.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';
import '../../core/theme/icon_map.dart';

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
      await ref.read(orbitBridgeProvider).todoTaskUpdate(id, encodePatch(patch));
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
    if (id == null || task.isDone) return _patchTask(buildDoneTogglePatch(task));
    try {
      await ref.read(orbitBridgeProvider).todoTaskComplete(id);
      if (!mounted) return;
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider(id));
    } catch (_) {
      WaitToast.destructive('完成失败');
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
                    data: (detail) => _DetailView(
                      // key 仅绑 id，不纳入 updatedAt——若含之，任何 patch 后
                      // invalidate 会导致整树按新 key 替换重建，旧 ListView
                      // 延迟卸载与新 ListView 挂载同帧共存，_scrollController
                      // 瞬时双附着触发断言。各区块外部变更同步已由
                      // didUpdateWidget / provider 回读覆盖，无需整树重置。
                      key: ValueKey('task-detail:${detail.id}'),
                      detail: detail,
                      scrollController: _scrollController,
                      onPatch: _patchTask,
                      onToggleDone: _toggleDone,
                      onRefresh: _refreshDetail,
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: detailAsync?.value?.title ?? '详情',
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
          TextButton(onPressed: () => context.pop(), child: const Text('返回')),
        ],
      ),
    );
  }
}

/// 详情初次加载骨架：标题块 + 四行信息行占位
///
/// 版式对齐 `_DetailView`（同款顶边距 + 横向 space16），加载落定即整块替换；
/// `skipLoadingOnReload` 保证重查时旧内容保留，不闪骨架。
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space12,
        left: AppDimens.space16,
        right: AppDimens.space16,
      ),
      children: const [
        OrbitSkeleton.block(height: 26, borderRadius: 13),
        SizedBox(height: AppDimens.space16),
        OrbitSkeleton.line(width: 200),
        SizedBox(height: AppDimens.space12),
        OrbitSkeleton.line(width: 160),
        SizedBox(height: AppDimens.space12),
        OrbitSkeleton.line(width: 220),
        SizedBox(height: AppDimens.space12),
        OrbitSkeleton.line(width: 140),
      ],
    );
  }
}

/// 详情主体：十区块滚动容器（区块间距 12、页面尾留白）
class _DetailView extends StatelessWidget {
  const _DetailView({
    super.key,
    required this.detail,
    required this.scrollController,
    required this.onPatch,
    required this.onToggleDone,
    required this.onRefresh,
  });

  final TodoTaskDetail detail;
  final ScrollController scrollController;
  final Future<void> Function(Map<String, Object?> patch) onPatch;
  final Future<void> Function(TodoTask task) onToggleDone;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top +
            OrbitPageHeader.rowHeight +
            AppDimens.space12,
        left: AppDimens.space16,
        right: AppDimens.space16,
        bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
      ),
      children: [
        // 十区块固定顺序（docs/05 §4.3）
        _TitleSection(detail: detail, onPatch: onPatch, onToggleDone: onToggleDone),
        const SizedBox(height: AppDimens.space12),
        _InfoSection(detail: detail, onPatch: onPatch),
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.detail.title);

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

  /// 保存：trim 空 / 未变化仅退出编辑态不请求（docs/05 §4.3 标题区语义）
  Future<void> _commit() async {
    setState(() => _editing = false);
    final value = _controller.text.trim();
    if (!mounted) return;
    if (value.isEmpty || value == widget.detail.title) return;
    await widget.onPatch({'title': value});
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final task = widget.detail;
    return SectionCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 28px 圆 checkbox（check 18，docs/05 §七）
          CircleCheckbox(
            checked: task.isDone,
            size: 28,
            onToggle: () => widget.onToggleDone(task),
          ),
          const SizedBox(width: AppDimens.space12),
          Expanded(
            child: _editing
                ? TextField(
                    controller: _controller,
                    autofocus: true,
                    style: TextStyle(fontSize: 24, color: colors.titleText),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      filled: false,
                    ),
                    onSubmitted: (_) => _commit(),
                    onTapOutside: (_) => _commit(),
                  )
                : GestureDetector(
                    onTap: () => setState(() => _editing = true),
                    child: AnimatedStrikethrough(
                      text: task.title,
                      done: task.isDone,
                      thickness: 2,
                      style: TextStyle(
                        fontSize: 24,
                        height: 1.2,
                        color: colors.titleText,
                      ),
                      doneColor: colors.titleText,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── 二、基本信息 ──

class _InfoSection extends ConsumerWidget {
  const _InfoSection({required this.detail, required this.onPatch});

  final TodoTaskDetail detail;
  final Future<void> Function(Map<String, Object?> patch) onPatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(todoProjectsProvider).value ?? [];
    final colors = AppColors.ofContext(context);
    final project = detail.projectId == null
        ? null
        : projects.where((p) => p.id == detail.projectId).firstOrNull;
    final projectTitle = project?.title ?? '未分组';

    return SectionCard(
      title: '信息',
      child: Column(
        children: [
          InfoTile(
            label: '优先级',
            value: priorityLabel(detail.priority),
            dotColorHex: priorityColorHex(detail.priority),
            onClick: () => showSelectBottomSheet<int>(
              context,
              title: '优先级',
              // 六档 P0–P5 全带色点（P0「无」浅灰 #D1D5DB，与列表/日历同源）
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
          ),
          InfoTile(
            label: '状态',
            value: statusLabel(detail.status),
            dotColorHex: statusColorHex(detail.status),
            onClick: () => showSelectBottomSheet<String>(
              context,
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
              // 选 done 自动补 done_at，切走清空（buildStatusPatch 同源语义）
              onSelect: (v) => onPatch(buildStatusPatch(v)),
            ),
          ),
          InfoTile(
            label: '项目',
            value: projectTitle,
            // #36：项目名按项目色着字（侧边栏圆点口径外的展示位）
            valueColor: project != null
                ? hexToColor(project.hexColor, fallback: colors.bodyText)
                : null,
            onClick: () => showSelectBottomSheet<String>(
              context,
              title: '项目',
              items: [
                const SelectItem<String>(value: '', label: '未分组'),
                for (final p in projects)
                  SelectItem(
                    value: '${p.id}',
                    label: p.title,
                    colorDot: hexToColor(p.hexColor,
                        fallback: OrbitAccents.todoAccent),
                  ),
              ],
              current: detail.projectId == null ? '' : '${detail.projectId}',
              onSelect: (v) =>
                  onPatch({'project_id': v.isEmpty ? null : int.parse(v)}),
            ),
          ),
          InfoTile(
            label: '截止日期',
            value: detail.dueDate != null ? formatYmd(detail.dueDate!) : '无',
            onClick: () => _pickDueDate(context),
            // 有值才可清除；patch {"due_date": null} 走三态清空语义
            onClear: detail.dueDate == null
                ? null
                : () => onPatch(const {'due_date': null}),
          ),
          InfoTile(
            label: '开始日期',
            value: detail.startDate != null ? formatYmd(detail.startDate!) : '无',
            onClick: () => _pickDateField(context,
                current: detail.startDate, key: 'start_date'),
            onClear: detail.startDate == null
                ? null
                : () => onPatch(const {'start_date': null}),
          ),
          InfoTile(
            label: '重复',
            value: rep.repeatLabelExt(
              detail.repeatMode,
              detail.repeatAfter,
              weekdays: detail.repeatWeekdays,
              endType: detail.repeatEndType,
              endParam: detail.repeatEndParam,
              fromDone: detail.repeatFromDone,
            ),
            onClick: () => _editRepeat(context),
          ),
        ],
      ),
    );
  }

  /// 截止日期行点击 → 与表单抽屉同一选择器，选中归一化本地零点回填
  Future<void> _pickDueDate(BuildContext context) async {
    final picked = await showTodoDatePicker(
      context,
      initialDate: detail.dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(detail.dueDate!)
          : null,
    );
    if (picked == null || !context.mounted) return;
    await onPatch({'due_date': dateToMidnightMs(picked)});
  }

  /// 开始日期行点击：与截止日期同一选择器，按 patch key 落库
  Future<void> _pickDateField(
    BuildContext context, {
    required int? current,
    required String key,
  }) async {
    final picked = await showTodoDatePicker(
      context,
      initialDate: current != null
          ? DateTime.fromMillisecondsSinceEpoch(current)
          : null,
    );
    if (picked == null || !context.mounted) return;
    await onPatch({key: dateToMidnightMs(picked)});
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
    );
    if (value == null) return;
    await onPatch({
      'repeat_mode': value.mode,
      'repeat_after': value.after,
      'repeat_weekdays': value.weekdays,
      'repeat_end_type': value.endType,
      'repeat_end_param': value.endParam,
      'repeat_from_done': value.fromDone ? 1 : 0,
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
    // 行内代码/链接/列表；原文编辑入口在「编辑」按钮的底部抽屉，不受影响）
    return SectionCard(
      title: '描述',
      trailing: TextButton(
        onPressed: () => _openEditor(context),
        child: const Text('编辑'),
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
          : Text(
              '暂无描述',
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                color: colors.secondaryText.withValues(alpha: 0.5),
              ),
            ),
    );
  }

  /// 编辑弹层改底部抽屉（原 AlertDialog maxLines:5 固定 5 行，长描述
  /// 看不全且点遮罩即关丢草稿；抽屉 70% 高 + 误触 barrier 不关闭）
  void _openEditor(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.ofContext(context).popup,
      shape: bottomSheetTopShape,
      builder: (_) => _DescriptionEditSheet(
        initial: widget.detail.description ?? '',
        onApply: (text) => widget.onPatch(
          {'description': text.isEmpty ? null : text},
        ),
      ),
    );
  }
}

/// 描述编辑抽屉：多行输入自适应高度（70% 屏高上限）+ 保存/取消
class _DescriptionEditSheet extends StatefulWidget {
  const _DescriptionEditSheet({
    required this.initial,
    required this.onApply,
  });

  final String initial;
  final void Function(String text) onApply;

  @override
  State<_DescriptionEditSheet> createState() => _DescriptionEditSheetState();
}

class _DescriptionEditSheetState extends State<_DescriptionEditSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text == (widget.initial.trim())) {
      Navigator.of(context).pop();
      return;
    }
    widget.onApply(text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 输入区自管高度（maxLines: null 撑到高度上限后内部滚动），
    // 取消·保存固定在骨架尾栏（口径见 orbit_sheet_scaffold.dart）
    return OrbitSheetScaffold(
      title: '编辑描述',
      maxHeightFactor: 0.7,
      contentScrollable: false,
      content: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.space16,
          0,
          AppDimens.space16,
          AppDimens.space16,
        ),
        child: TextField(
          controller: _controller,
          maxLines: null,
          minLines: 6,
          maxLength: 5000,
          autofocus: true,
          style: TextStyle(fontSize: 15, color: colors.bodyText),
          decoration: const InputDecoration(
            hintText: '请输入描述',
            counterText: '',
          ),
        ),
      ),
      actions: OrbitSheetActions(
        cancelLabel: '取消',
        onCancel: () => Navigator.of(context).pop(),
        confirmLabel: '保存',
        onConfirm: _save,
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
  final _draftController = TextEditingController();

  @override
  void dispose() {
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
    setState(() => _adding = false);
    await _mutate(() => ref
        .read(orbitBridgeProvider)
        .todoSubtaskCreate(TodoSubtaskCreateInput(
          taskId: widget.detail.id,
          title: title,
        )));
  }

  /// 删除确认（对齐评论删除惯例：软删无恢复入口，防误触）
  Future<void> _confirmDelete(TodoSubtask subtask) async {
    final confirmed = await showConfirmBottomSheet(
      context,
      title: '删除子任务',
      message: '确定要删除「${subtask.title}」吗？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _mutate(
        () => ref.read(orbitBridgeProvider).todoSubtaskDelete(subtask.id));
  }

  /// 子任务转独立任务（承接父任务 project/priority/due 上下文；
  /// MS To Do Steps→Task 同款语义）
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

    final progress = subtasks.isEmpty ? 0.0 : doneCount / subtasks.length;
    return SectionCard(
      title: '子任务',
      subtitle: '$doneCount/${subtasks.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtasks.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor:
                    OrbitAccents.todoAccent.withValues(alpha: 0.15),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  OrbitAccents.todoAccent,
                ),
              ),
            ),
            const SizedBox(height: AppDimens.space8),
          ],
          for (final subtask in subtasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  // 22px 圆 checkbox（check 14，docs/05 §四）
                  CircleCheckbox(
                    checked: subtask.isDone,
                    size: AppDimens.subtaskCheckboxSize,
                    onToggle: () => _mutate(() => ref
                        .read(orbitBridgeProvider)
                        .todoSubtaskToggleDone(subtask.id, !subtask.isDone)),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  Expanded(
                    child: AnimatedStrikethrough(
                      text: subtask.title,
                      done: subtask.isDone,
                      style: TextStyle(
                        fontSize: 15,
                        color: colors.bodyText,
                      ),
                      doneColor: colors.secondaryText.withValues(alpha: 0.5),
                    ),
                  ),
                  // 转独立任务（承接父任务上下文；对齐桌面行尾入口）
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '转为独立任务',
                    icon: Icon(OrbitIcons.openExternal,
                        size: AppDimens.iconSizeSm,
                        color: colors.secondaryText),
                    onPressed: () => _promote(subtask),
                  ),
                  // close 删除（确认弹窗防误触，对齐桌面/评论删除惯例）
                  IconButton(
                    tooltip: '删除子任务',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(OrbitIcons.close,
                        size: AppDimens.iconSizeSm,
                        color: colors.secondaryText),
                    onPressed: () => _confirmDelete(subtask),
                  ),
                ],
              ),
            ),
          _adding
              ? Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _draftController,
                        autofocus: true,
                        style:
                            TextStyle(fontSize: 15, color: colors.bodyText),
                        decoration: const InputDecoration(
                          hintText: '子任务标题',
                          isDense: true,
                          filled: false,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: AppDimens.space8),
                        ),
                        onSubmitted: (_) => _submitDraft(),
                      ),
                    ),
                    IconButton(
                      tooltip: '确定',
                      icon: const Icon(OrbitIcons.check,
                          size: AppDimens.iconSizeMd,
                          color: OrbitAccents.todoAccent),
                      onPressed: _submitDraft,
                    ),
                  ],
                )
              : TextButton.icon(
                  onPressed: () => setState(() => _adding = true),
                  icon: const Icon(OrbitIcons.add,
                      size: AppDimens.iconSizeSm + 2),
                  label: const Text('添加子任务'),
                ),
        ],
      ),
    );
  }
}

// ── 五、标签（chip 展示 + "编辑"多选弹层，Phase 7）──

class _LabelsSection extends StatelessWidget {
  const _LabelsSection({required this.detail});

  final TodoTaskDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return SectionCard(
      title: '标签',
      trailing: TextButton(
        onPressed: () => _openEditor(context),
        child: const Text('编辑'),
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
                border: Border.all(
                  color: colors.divider,
                ),
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
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.bodyText,
                    ),
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
    );
  }

  void _openEditor(BuildContext context) {
    final colors = AppColors.ofContext(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.popup,
      shape: bottomSheetTopShape,
      builder: (_) => _LabelEditSheet(taskId: detail.id),
    );
  }
}

/// 标签编辑弹层（Phase 7）：现有标签多选勾选态（勾选变化即建/删关联）+
/// 底部"新建标签"行（标题 + 固定 8 色板选色）。勾选态直接从详情 provider
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
        await bridge.todoTaskLabelCreate(TodoTaskLabelCreateInput(
          taskId: widget.taskId,
          labelId: labelId,
        ));
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
      await ref.read(orbitBridgeProvider).todoLabelCreate(
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
        ref.watch(taskDetailProvider(widget.taskId)).value?.labels
                .map((l) => l.id)
                .toSet() ??
            <int>{};

    // 键盘避让：底部 padding 跟随 viewInsets
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppDimens.space16),
                child: Text(
                  '编辑标签',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.titleText,
                  ),
                ),
              ),
              Flexible(
                child: labels.isEmpty
                    ? Padding(
                        padding:
                            const EdgeInsets.all(AppDimens.space16),
                        child: Text(
                          '暂无可选标签',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.secondaryText.withValues(alpha: 0.5),
                          ),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final label in labels)
                            InkWell(
                              onTap: () => _toggleLabel(label),
                              child: SizedBox(
                                height: AppDimens.touchTarget,
                                child: Row(
                                  children: [
                                    const SizedBox(width: AppDimens.space16),
                                    CircleCheckbox(
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
                        ],
                      ),
              ),
              // 新建标签行：输入标题 + 固定 8 色板选色 → todoLabelCreate
              Container(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.space16,
                  AppDimens.space8,
                  AppDimens.space16,
                  0,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: colors.divider,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _titleController,
                            maxLength: 50,
                            style: TextStyle(
                                fontSize: 15, color: colors.bodyText),
                            decoration: const InputDecoration(
                              hintText: '新建标签',
                              counterText: '',
                              isDense: true,
                            ),
                            onSubmitted: (_) => _createLabel(),
                          ),
                        ),
                        IconButton(
                          tooltip: '新建标签',
                          icon: Icon(OrbitIcons.add,
                              size: AppDimens.iconSizeLg,
                              color: OrbitAccents.todoAccent),
                          onPressed: _createLabel,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppDimens.space8),
                    Wrap(
                      spacing: AppDimens.space12,
                      runSpacing: AppDimens.space8,
                      children: [
                        for (final hex in labelPaletteHexes)
                          GestureDetector(
                            onTap: () => setState(() => _newColorHex = hex),
                            // 26 色点视觉不变，热区补到 48（touchTarget）
                            child: Padding(
                              padding: const EdgeInsets.all(11),
                              child: Container(
                                width: 26,
                                height: 26,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: hexToColor(hex),
                                border: Border.all(
                                  width: _newColorHex == hex ? 3 : 1,
                                  color: _newColorHex == hex
                                      ? OrbitAccents.themeAccent
                                      : colors.outline,
                                ),
                              ),
                            ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: AppDimens.gestureInsetFallback / 2),
                  ],
                ),
              ),
            ],
          ),
        ),
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

  final VoidCallback onChanged;

  /// 底部弹 wait 面板选日期+时间，确认返回毫秒；取消/清除返回 null
  Future<DateTime?> _pick(BuildContext context, int? currentMs) {
    return OrbitDatePicker.pick(
      context,
      initialDate: currentMs != null
          ? DateTime.fromMillisecondsSinceEpoch(currentMs)
          : null,
      showTime: true,
      accent: OrbitAccents.todoAccent,
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

  /// 添加提醒：默认初值一小时后
  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final picked = await _pick(
        context, DateTime.now().millisecondsSinceEpoch + 3600000);
    if (picked == null || !context.mounted) return;
    await _mutate(context, ref, () async {
      final bridge = ref.read(orbitBridgeProvider);
      await bridge.todoReminderCreate(
        TodoReminderCreateInput(
            taskId: taskId, remindAt: picked.millisecondsSinceEpoch),
      );
    });
  }

  /// 编辑提醒：点行唤起面板，变更走删旧建新（复用表单 syncTaskReminder）
  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    TodoReminder reminder,
  ) async {
    final picked = await _pick(context, reminder.remindAt);
    if (picked == null || !context.mounted) return;
    await _mutate(context, ref, () async {
      final bridge = ref.read(orbitBridgeProvider);
      await syncTaskReminder(
        bridge,
        taskId,
        picked.millisecondsSinceEpoch,
        reminder,
      );
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.ofContext(context);
    return SectionCard(
      title: '提醒',
      trailing: TextButton(
        onPressed: () => _add(context, ref),
        child: const Text('添加提醒'),
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
                    padding:
                        const EdgeInsets.symmetric(vertical: AppDimens.space4),
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
                                    formatDateTime(reminder.remindAt),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 15,
                                        color: colors.bodyText),
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
                                if (repeatMode > 0) ...[
                                  const SizedBox(width: AppDimens.space8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppDimens.space4 + 2,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: AppShapes.full,
                                      color: OrbitAccents.todoAccent
                                          .withValues(alpha: 0.1),
                                    ),
                                    child: Text(
                                      rep.repeatLabelExt(
                                        repeatMode,
                                        repeatAfter,
                                        weekdays: repeatWeekdays,
                                        endType: repeatEndType,
                                        endParam: repeatEndParam,
                                        fromDone: repeatFromDone,
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
                        // 删除（无确认直删，对齐桌面行为）
                        IconButton(
                          tooltip: '删除提醒',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(OrbitIcons.close,
                              size: AppDimens.iconSizeSm,
                              color: colors.secondaryText),
                          onPressed: () => _mutate(context, ref, () async {
                            await ref
                                .read(orbitBridgeProvider)
                                .todoReminderDelete(reminder.id);
                            // 同步撤掉该任务的系统闹钟：残留闹钟与「后台推迟
                            // 产物」在系统侧无法区分，不取消会在下次重排的孤儿
                            // 补齐里被误判而把刚删的提醒建回来
                            await NotificationService.instance
                                .cancelAlarmFor(reminder.taskId);
                          }),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
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
  Future<void> _remove(TodoTaskRelation relation) async {
    try {
      await ref
          .read(orbitBridgeProvider)
          .todoTaskRelationDelete(relation.id);
      widget.onChanged();
      if (mounted) WaitToast.success('已解除关联');
    } catch (e) {
      if (mounted) WaitToast.destructive('解除关联失败');
    }
  }

  /// 关联任务搜索增删：关键词走全局搜索，多选一即建关联
  Future<void> _pickAndAdd() async {
    final queryCtl = TextEditingController();
    List<TodoTask> hits = [];
    bool searching = false;
    final targetId = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.ofContext(context).popup,
      shape: bottomSheetTopShape,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              left: AppDimens.space16,
              right: AppDimens.space16,
              top: AppDimens.space16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + AppDimens.space16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '关联任务',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: AppDimens.space8),
                TextField(
                  controller: queryCtl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '搜索任务标题',
                    hintText: '输入关键词后点搜索',
                  ),
                  onSubmitted: (_) async {
                    setSheet(() => searching = true);
                    try {
                      final r = await ref
                          .read(orbitBridgeProvider)
                          .globalSearch(queryCtl.text.trim(), limit: 20);
                      setSheet(() {
                        hits = r.tasks
                            .where((t) => t.id != widget.taskId)
                            .toList();
                        searching = false;
                      });
                    } catch (_) {
                      setSheet(() => searching = false);
                    }
                  },
                ),
                const SizedBox(height: AppDimens.space8),
                if (searching)
                  const Center(child: CircularProgressIndicator())
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in hits.take(20))
                          SizedBox(
                            height: AppDimens.touchTarget,
                            child: InkWell(
                              onTap: () => Navigator.pop(sheetCtx, t.id),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      t.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 15),
                                    ),
                                  ),
                                  Text(
                                    '#${t.id}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.ofContext(
                                        context,
                                      ).secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (hits.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '输入关键词后回车搜索（排除本任务）',
                              style: TextStyle(fontSize: 13),
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
    );
    if (targetId == null) return;
    try {
      await ref.read(orbitBridgeProvider).todoTaskRelationCreate(
            TodoTaskRelationCreateInput(
              taskId: widget.taskId,
              otherTaskId: targetId,
              relationType: 'related',
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
    return SectionCard(
      title: '关联',
      trailing: IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: '添加关联',
        icon: const Icon(
          OrbitIcons.add,
          size: AppDimens.iconSizeSm,
          color: OrbitAccents.todoAccent,
        ),
        onPressed: _pickAndAdd,
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
                          Text(
                            '任务 #${relation.otherTaskId}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: OrbitAccents.todoAccent,
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

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _inputController.text.trim();
    if (content.isEmpty) return;
    _inputController.clear();
    try {
      await ref.read(orbitBridgeProvider).todoCommentCreate(
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

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final comments = widget.detail.comments;

    return SectionCard(
      title: '评论',
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
            ),
          for (final comment in comments)
            Container(
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
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.secondaryText,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _delete(comment),
                        child: Icon(
                          OrbitIcons.delete,
                          size: AppDimens.iconSizeSm,
                          color: colors.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          // 底部输入框 + 发送钮
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: AppDimens.space8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: colors.divider),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    style: TextStyle(fontSize: 15, color: colors.bodyText),
                    decoration: const InputDecoration(
                      hintText: '输入评论...',
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                IconButton(
                  tooltip: '发送',
                  icon: const Icon(OrbitIcons.send,
                      size: AppDimens.iconSizeMd,
                      color: OrbitAccents.todoAccent),
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ],
      ),
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
      final list =
          await ref.read(orbitBridgeProvider).taskAttachmentsList(widget.taskId);
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
      await ref.read(orbitBridgeProvider).taskAttachmentAdd(
            widget.taskId,
            name,
            _mimeFromName(name),
            bytes,
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
    final path = result?.files.single.path;
    if (path == null) return;
    final name = result!.files.single.name;
    final bytes = await File(path).readAsBytes();
    await _uploadBytes(name, bytes, '文件');
  }

  /// 拍照添加附件（相机直拍；取消静默返回，无权限时提示）
  Future<void> _addCamera() async {
    if (_busy) return;
    try {
      final shot = await ImagePicker().pickImage(source: ImageSource.camera);
      if (shot == null) return;
      final bytes = await shot.readAsBytes();
      final name =
          'photo-${DateTime.now().millisecondsSinceEpoch}.jpg';
      await _uploadBytes(name, bytes, '拍照');
    } catch (_) {
      if (mounted) WaitToast.destructive('相机不可用');
    }
  }



  String _mimeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    const map = {
      'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
      'gif': 'image/gif', 'webp': 'image/webp', 'pdf': 'application/pdf',
      'txt': 'text/plain', 'md': 'text/markdown', 'csv': 'text/csv',
      'json': 'application/json', 'zip': 'application/zip',
      'mp3': 'audio/mpeg', 'mp4': 'video/mp4',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  Future<void> _open(TaskAttachmentView att) async {
    if (att.isLocalCached == 0) {
      WaitToast.info('附件尚未从云端同步到本机，稍后自动拉取');
      return;
    }
    try {
      final bytes =
          await ref.read(orbitBridgeProvider).taskAttachmentRead(att.hash);
      final dir = await getTemporaryDirectory();
      final target = File(
          '${dir.path}/orbit-att-${att.hash}${_extOf(att.originalName)}');
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

    return SectionCard(
      title: '附件',
      trailing: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
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
                onSelect: (v) =>
                    v == 'camera' ? _addCamera() : _addFile(),
              ),
            ),
      child: list == null
          ? const SizedBox(height: 16)
          : list.isEmpty
              ? Text(
                  '点 + 添加附件：文件 / 拍照（单任务 20 个，单文件 50MB）\n系统分享的文本会自动建任务（分享导入）',
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
                            GestureDetector(
                              onTap: () => _open(att),
                              child: const Icon(
                                OrbitIcons.openExternal,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: AppDimens.space8),
                            GestureDetector(
                              onTap: () => _remove(att),
                              child: Icon(
                                OrbitIcons.delete,
                                size: 18,
                                color: colors.secondaryText,
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

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 事件行文案由写入端 detail 快照驱动，格式化镜像桌面 activity-format.ts
    final asyncRows = ref.watch(
      taskActivityProvider((taskId: widget.taskId, limit: _limit)),
    );

    return SectionCard(
      title: '历史',
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
                  for (final r in rows)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: AppDimens.space8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            formatDateTime(r.createdAt),
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
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
                  if (rows.length >= _limit)
                    Row(
                      children: [
                        Text(
                          '仅显示最近 $_limit 条操作',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.secondaryText,
                          ),
                        ),
                        if (_limit < _maxLimit)
                          TextButton(
                            onPressed: () => setState(() => _limit = _maxLimit),
                            style: TextButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('显示更多',
                                style: TextStyle(fontSize: 12)),
                          ),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}
