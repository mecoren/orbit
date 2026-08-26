import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/circle_checkbox.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/select_bottom_sheet.dart';
import '../../shared/widgets/wait_toast.dart';
import 'logic/task_logic.dart';
import 'providers/todo_providers.dart';

/// 详情全屏 /todo/:id（docs/05 §4.3 + 移动端任务书）
///
/// 数据源 todoTaskGetDetail(id) 聚合（taskDetailProvider）。
/// 八区块固定顺序：标题区 → 信息 → 描述 → 子任务 → 标签 → 提醒 → 关联 → 评论。
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
                    loading: () => const Center(
                      child: CircularProgressIndicator(
                        color: OrbitAccents.themeAccent,
                      ),
                    ),
                    error: (_, _) => const _ErrorView(),
                    data: (detail) => _DetailView(
                      key: ValueKey('${detail.id}:${detail.updatedAt}'),
                      detail: detail,
                      scrollController: _scrollController,
                      onPatch: _patchTask,
                      onRefresh: _refreshDetail,
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: detailAsync?.value?.title ?? '详情',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
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

/// 详情主体：八区块滚动容器（区块间距 12、页面尾留白）
class _DetailView extends StatelessWidget {
  const _DetailView({
    super.key,
    required this.detail,
    required this.scrollController,
    required this.onPatch,
    required this.onRefresh,
  });

  final TodoTaskDetail detail;
  final ScrollController scrollController;
  final Future<void> Function(Map<String, Object?> patch) onPatch;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top +
            LiquidGlassTitleBar.rowHeight +
            AppDimens.space12,
        left: AppDimens.space16,
        right: AppDimens.space16,
        bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
      ),
      children: [
        // 八区块固定顺序（docs/05 §4.3）
        _TitleSection(detail: detail, onPatch: onPatch),
        const SizedBox(height: AppDimens.space12),
        _InfoSection(detail: detail, onPatch: onPatch),
        const SizedBox(height: AppDimens.space12),
        _DescriptionSection(detail: detail, onPatch: onPatch),
        const SizedBox(height: AppDimens.space12),
        _SubtasksSection(detail: detail, onChanged: onRefresh),
        const SizedBox(height: AppDimens.space12),
        _LabelsSection(labels: detail.labels),
        const SizedBox(height: AppDimens.space12),
        _RemindersSection(reminders: detail.reminders),
        if (detail.relations.isNotEmpty) ...[
          const SizedBox(height: AppDimens.space12),
          _RelationsSection(relations: detail.relations),
        ],
        const SizedBox(height: AppDimens.space12),
        _CommentsSection(detail: detail, onChanged: onRefresh),
      ],
    );
  }
}

// ── 一、标题区 ──

class _TitleSection extends StatefulWidget {
  const _TitleSection({required this.detail, required this.onPatch});

  final TodoTaskDetail detail;
  final Future<void> Function(Map<String, Object?> patch) onPatch;

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
            checkSize: 18,
            onToggle: () => widget.onPatch(buildDoneTogglePatch(task)),
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
                    child: Text(
                      task.title,
                      style: TextStyle(
                        fontSize: 24,
                        height: 1.2,
                        color: colors.titleText,
                        decoration:
                            task.isDone ? TextDecoration.lineThrough : null,
                        decorationThickness: 2,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── 二、基本信息 ──

/// 信息行（docs/05 §4.3 _InfoTile）：label 固定列宽 80 → 色点 + 值 → 尾箭头
class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.label,
    required this.value,
    this.dotColorHex,
    this.onClick,
  });

  final String label;
  final String value;

  /// 值前 10×10 色点 hex（空串不渲染）
  final String? dotColorHex;
  final VoidCallback? onClick;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final row = Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              if (dotColorHex != null && dotColorHex!.isNotEmpty) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hexToColor(dotColorHex!),
                  ),
                ),
                const SizedBox(width: AppDimens.space8),
              ],
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: colors.bodyText),
                ),
              ),
            ],
          ),
        ),
        if (onClick != null)
          Icon(
            Icons.keyboard_arrow_right_rounded,
            size: AppDimens.iconSizeSm + 2,
            color: colors.secondaryText,
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
      child: onClick == null
          ? row
          : InkWell(borderRadius: AppShapes.small, onTap: onClick, child: row),
    );
  }
}

class _InfoSection extends ConsumerWidget {
  const _InfoSection({required this.detail, required this.onPatch});

  final TodoTaskDetail detail;
  final Future<void> Function(Map<String, Object?> patch) onPatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(todoProjectsProvider).value ?? [];
    final projectTitle = detail.projectId == null
        ? '未分组'
        : (projects.where((p) => p.id == detail.projectId).firstOrNull?.title ??
            '未分组');

    return SectionCard(
      title: '信息',
      child: Column(
        children: [
          _InfoTile(
            label: '优先级',
            value: priorityLabel(detail.priority),
            dotColorHex: priorityColorHex(detail.priority),
            onClick: () => showSelectBottomSheet<int>(
              context,
              title: '优先级',
              // 六档 P0–P5；P0「无」用灰点（桌面同款）
              items: [
                for (var i = 0; i <= 5; i++)
                  SelectItem(
                    value: i,
                    label: priorityLabel(i),
                    colorDot: hexToColor(priorityColorHex(i).isEmpty
                        ? '#D1D5DB'
                        : priorityColorHex(i)),
                  ),
              ],
              current: detail.priority,
              onSelect: (v) => onPatch({'priority': v}),
            ),
          ),
          _InfoTile(
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
          _InfoTile(
            label: '项目',
            value: projectTitle,
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
          _InfoTile(
            label: '截止日期',
            value: detail.dueDate != null ? formatYmd(detail.dueDate!) : '无',
          ),
        ],
      ),
    );
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
    return SectionCard(
      title: '描述',
      trailing: TextButton(
        onPressed: () => _editDescription(context),
        child: const Text('编辑'),
      ),
      child: Text(
        description ?? '暂无描述',
        style: TextStyle(
          fontSize: 15,
          height: 1.5,
          color: description == null
              ? colors.secondaryText.withValues(alpha: 0.5)
              : colors.bodyText,
        ),
      ),
    );
  }

  /// 编辑对话框 textarea → patch（trim 空写 null 清空语义）
  Future<void> _editDescription(BuildContext context) async {
    final controller =
        TextEditingController(text: widget.detail.description ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑描述'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入描述'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (ok != true || !context.mounted) return;
    if (text == (widget.detail.description?.trim() ?? '')) return;
    await widget.onPatch({'description': text.isEmpty ? null : text});
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

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final subtasks = widget.detail.subtasks;
    final doneCount = subtasks.where((s) => s.isDone).length;

    return SectionCard(
      title: '子任务',
      subtitle: '$doneCount/${subtasks.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final subtask in subtasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  // 22px 圆 checkbox（check 14，docs/05 §四）
                  CircleCheckbox(
                    checked: subtask.isDone,
                    size: AppDimens.subtaskCheckboxSize,
                    checkSize:
                        AppDimens.subtaskCheckboxSize - AppDimens.space8,
                    onToggle: () => _mutate(() => ref
                        .read(orbitBridgeProvider)
                        .todoSubtaskToggleDone(subtask.id, !subtask.isDone)),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  Expanded(
                    child: Text(
                      subtask.title,
                      style: TextStyle(
                        fontSize: 15,
                        color: subtask.isDone
                            ? colors.secondaryText.withValues(alpha: 0.5)
                            : colors.bodyText,
                        decoration: subtask.isDone
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                  // close 删除（无确认直删，对齐桌面行为）
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded,
                        size: AppDimens.iconSizeSm,
                        color: colors.secondaryText),
                    onPressed: () => _mutate(() => ref
                        .read(orbitBridgeProvider)
                        .todoSubtaskDelete(subtask.id)),
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
                      icon: const Icon(Icons.check_rounded,
                          size: AppDimens.iconSizeMd,
                          color: OrbitAccents.todoAccent),
                      onPressed: _submitDraft,
                    ),
                  ],
                )
              : TextButton.icon(
                  onPressed: () => setState(() => _adding = true),
                  icon: const Icon(Icons.add_rounded,
                      size: AppDimens.iconSizeSm + 2),
                  label: const Text('添加子任务'),
                ),
        ],
      ),
    );
  }
}

// ── 五、标签（chip 只读展示）──

class _LabelsSection extends StatelessWidget {
  const _LabelsSection({required this.labels});

  final List<TaskLabelWithId> labels;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return SectionCard(
      title: '标签',
      child: Wrap(
        spacing: AppDimens.space8,
        runSpacing: AppDimens.space8,
        children: [
          for (final label in labels)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space8 + 2,
                vertical: AppDimens.space4,
              ),
              decoration: BoxDecoration(
                borderRadius: AppShapes.small,
                border: Border.all(
                  color: hexToColor(label.hexColor).withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                label.title,
                style: TextStyle(
                  fontSize: 13,
                  color: hexToColor(label.hexColor),
                ),
              ),
            ),
          if (labels.isEmpty)
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
}

// ── 六、提醒（列表 + 相对时间）──

class _RemindersSection extends StatelessWidget {
  const _RemindersSection({required this.reminders});

  final List<TodoReminder> reminders;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return SectionCard(
      title: '提醒',
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
                          Icons.notifications_outlined,
                          size: AppDimens.iconSizeSm + 2,
                          color: colors.secondaryText,
                        ),
                        const SizedBox(width: AppDimens.space8),
                        Text(
                          formatDateTime(reminder.remindAt),
                          style: TextStyle(
                              fontSize: 15, color: colors.bodyText),
                        ),
                        const SizedBox(width: AppDimens.space8),
                        Text(
                          relativeFromNow(reminder.remindAt),
                          style: TextStyle(
                            fontSize: 12,
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

// ── 七、关联任务（只读胶囊，空则不渲染区块——由父级判断）──

class _RelationsSection extends StatelessWidget {
  const _RelationsSection({required this.relations});

  final List<TodoTaskRelation> relations;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '关联',
      child: Wrap(
        spacing: AppDimens.space4,
        runSpacing: AppDimens.space4,
        children: [
          for (final relation in relations)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.space8,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                borderRadius: AppShapes.small,
                color: OrbitAccents.todoAccent.withValues(alpha: 0.1),
              ),
              child: Text(
                '任务 #${relation.otherTaskId}',
                style: const TextStyle(
                  fontSize: 12,
                  color: OrbitAccents.todoAccent,
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
    final destructive = AppColors.ofContext(context).destructive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除评论'),
        content: const Text('确定要删除这条评论吗？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: destructive),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
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
                          Icons.delete_outline_rounded,
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
                top: BorderSide(color: colors.divider.withValues(alpha: 0.3)),
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
                  icon: const Icon(Icons.send_rounded,
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
