/// 底部快速添加面板（任务列表页右下加号唤起）
///
/// 形制参考竞品移动端快速添加栏（TickTick / 微软 To-Do），但**能力面只对齐本仓
/// 已有能力**：输入框「准备做什么？」+ 已选条件 chips + 快捷操作图标行（档位由
/// [QuickActions] 配置决定）+「...」更多菜单（未启用档 + 固定「设置」入口）+ 发送。
///
/// 提交口径与桌面 `QuickAddBar` 一致：标题实时走 NLP 解析（`parseQuickInput`），
/// 提交瞬间以最新输入重算，**NLP 显式值 > 面板手动选择 > 当前快捷视图默认值**
///（#39 视图标记注入：我的一天/收藏/今日/本周；今日/本周截止时刻归一 18:00）。
/// 图片走「先建任务再挂附件」两段式（任务暂无 id 无法先传附件），附件失败不阻断
/// 任务本身——部分成功口径与表单的标签/子任务挂载一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_actions_sheet.dart';
import '../../shared/widgets/shadcn/orbit_checkbox.dart';
import '../../shared/widgets/shadcn/orbit_date_picker.dart';
import '../../shared/widgets/shadcn/orbit_sheet_scaffold.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import 'form_bottom_sheet.dart';
import 'logic/parse_quick_input.dart';
import 'logic/quick_actions.dart';
import 'logic/template_apply.dart';
import 'logic/task_logic.dart'
    show
        QuickViewKey,
        atViewDueHour,
        dateToMidnightMs,
        formatYmd,
        priorityColorHex,
        priorityLabel,
        quickViewCreateDefaults;
import 'providers/todo_providers.dart';

/// 快捷操作档 → 图标（面板工具栏与设置页预览/列表共用同一映射）
IconData quickActionIcon(QuickActionId id) => switch (id) {
      QuickActionId.due => OrbitIcons.calendar,
      QuickActionId.priority => OrbitIcons.flag,
      QuickActionId.label => OrbitIcons.tag,
      QuickActionId.project => OrbitIcons.list,
      QuickActionId.image => OrbitIcons.image,
      QuickActionId.template => OrbitIcons.template,
      QuickActionId.fullscreen => OrbitIcons.fullscreen,
    };

/// 打开快速添加面板（提交成功后自动关闭）
///
/// [defaultProjectId]/[quickView] 由入口页携入：列表页带当前项目与快捷视图，
/// 面板内新建因此与 FAB 完整表单同口径（视图标记静默附加）。
/// [initialDueDate] 预填截止（午夜毫秒，日历长按日格快捷新增用）。
///
/// **统一新建入口**：列表页 FAB/空态、侧栏 FAB（含桌面快捷方式）、日历 FAB/
/// 日格长按的新建一律走本面板；完整表单（`showTodoFormSheet`）只留给编辑态、
/// 面板内「全屏」展开与模板套用（notes/子任务字段快加面板承接不了）。
Future<void> showQuickAddSheet(
  BuildContext context, {
  int? defaultProjectId,
  QuickViewKey? quickView,
  int? initialDueDate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (_) => _QuickAddSheet(
      defaultProjectId: defaultProjectId,
      quickView: quickView,
      initialDueDate: initialDueDate,
    ),
  );
}

/// 待挂载图片（任务创建成功后才上传，故暂存字节）
class _PendingImage {
  const _PendingImage({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;

  /// 附件 mime 按扩展名推断（图片场景只覆盖常见格式，其余回落 jpeg）
  String get mime {
    switch (name.split('.').last.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
  }
}

class _QuickAddSheet extends ConsumerStatefulWidget {
  const _QuickAddSheet({this.defaultProjectId, this.quickView, this.initialDueDate});

  /// 新建任务默认归属项目（null = 未分组）
  final int? defaultProjectId;

  /// 当前快捷视图（视图内新建自动带本视图标记）
  final QuickViewKey? quickView;

  /// 预填截止（午夜毫秒；日历长按日格快捷新增用）
  final int? initialDueDate;

  @override
  ConsumerState<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends ConsumerState<_QuickAddSheet> {
  final _titleController = TextEditingController();

  int _priority = 0;
  int? _dueDate;
  int? _projectId;
  List<TodoLabel> _labels = [];
  final List<_PendingImage> _images = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _projectId = widget.defaultProjectId;
    _dueDate = widget.initialDueDate;
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  // ── 提交（NLP 优先于手动选择，手动选择优先于视图默认）──

  Future<void> _submit() async {
    if (_saving) return;
    final raw = _titleController.text.trim();
    if (raw.isEmpty) return;
    setState(() => _saving = true);
    try {
      final bridge = ref.read(orbitBridgeProvider);
      final projects = ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
      final labels = ref.read(todoLabelsProvider).value ?? const <TodoLabel>[];
      final parsed = parseQuickInput(
        raw,
        QuickInputContext(
          projects: [
            for (final p in projects) QuickInputRef(id: p.id, title: p.title),
          ],
          labels: [
            for (final l in labels) QuickInputRef(id: l.id, title: l.title),
          ],
          now: DateTime.now(),
        ),
      );
      final title = parsed.title.trim();
      if (title.isEmpty) {
        WaitToast.destructive('请输入任务标题');
        return;
      }
      final viewDefaults = quickViewCreateDefaults(widget.quickView);
      final inDueView = widget.quickView == QuickViewKey.today ||
          widget.quickView == QuickViewKey.week;
      final due = parsed.dueDate != null
          ? dateToMidnightMs(parsed.dueDate!)
          : (_dueDate ?? viewDefaults.dueMs);
      final created = await bridge.todoTaskCreate(TodoTaskCreateInput(
        title: title,
        projectId: parsed.projectId ?? _projectId,
        priority: parsed.priority > 0 ? parsed.priority : _priority,
        status: 'pending',
        dueDate: inDueView && due != null ? atViewDueHour(due) : due,
        // 开始日期默认今天（与移动端表单同口径：新建任务恒有开始日期）
        startDate: dateToMidnightMs(DateTime.now()),
        myDayDate: viewDefaults.myDayMs,
        isFavorite: viewDefaults.favorite,
      ));
      // 标签：NLP 命中 ∪ 手动选择（去重；单条失败不阻断任务本身）
      final labelIds = <int>{...parsed.labelIds, ..._labels.map((l) => l.id)};
      for (final labelId in labelIds) {
        try {
          await bridge.todoTaskLabelCreate(
            TodoTaskLabelCreateInput(taskId: created.id, labelId: labelId),
          );
        } catch (_) {
          /* 忽略单个标签失败 */
        }
      }
      // 图片：任务落库后逐张挂附件（失败不阻断任务本身）
      for (final image in _images) {
        try {
          await bridge.taskAttachmentAdd(
            created.id,
            image.name,
            image.mime,
            image.bytes,
          );
        } catch (_) {
          /* 忽略单张图片失败 */
        }
      }
      ref.invalidate(todoTasksProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      WaitToast.destructive('创建失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── 档位动作 ──

  Future<void> _onAction(QuickActionId id) async {
    switch (id) {
      case QuickActionId.due:
        await _pickDue();
      case QuickActionId.priority:
        await _pickPriority();
      case QuickActionId.label:
        await _pickLabels();
      case QuickActionId.project:
        await _pickProject();
      case QuickActionId.image:
        await _pickImage();
      case QuickActionId.template:
        await _openTemplate();
      case QuickActionId.fullscreen:
        await _openFullForm();
    }
  }

  Future<void> _pickDue() async {
    final picked = await OrbitDatePicker.pick(
      context,
      initialDate: _dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(_dueDate!)
          : null,
      accent: OrbitAccents.todoAccent,
    );
    if (picked == null || !mounted) return;
    setState(() => _dueDate = dateToMidnightMs(picked));
  }

  Future<void> _pickPriority() async {
    await showSelectBottomSheet<int>(
      context,
      title: '优先级',
      items: [
        for (var i = 0; i <= 5; i++)
          SelectItem(
            value: i,
            label: priorityLabel(i),
            colorDot: hexToColor(priorityColorHex(i)),
          ),
      ],
      current: _priority,
      onSelect: (v) {
        if (mounted) setState(() => _priority = v);
      },
    );
  }

  Future<void> _pickLabels() async {
    final all = ref.read(todoLabelsProvider).value ?? const <TodoLabel>[];
    if (all.isEmpty) {
      WaitToast.destructive('还没有标签，可在设置 → 标签管理中新建');
      return;
    }
    final picked = await _pickLabelsSheet(
      context,
      all,
      _labels.map((l) => l.id).toSet(),
    );
    if (picked == null || !mounted) return;
    setState(() => _labels = picked);
  }

  Future<void> _pickProject() async {
    final projects = ref.read(todoProjectsProvider).value ?? const <TodoProject>[];
    await showSelectBottomSheet<String>(
      context,
      title: '清单',
      items: [
        const SelectItem<String>(value: '', label: '未分组'),
        for (final project in projects)
          SelectItem(
            value: '${project.id}',
            label: project.title,
            colorDot:
                hexToColor(project.hexColor, fallback: OrbitAccents.todoAccent),
          ),
      ],
      current: _projectId == null ? '' : '$_projectId',
      onSelect: (v) {
        if (mounted) setState(() => _projectId = v.isEmpty ? null : int.parse(v));
      },
    );
  }

  /// 相册选图：只暂存字节，提交时随任务一并挂载（可多张累积）
  Future<void> _pickImage() async {
    try {
      final shot = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
      );
      if (shot == null) return;
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      setState(() => _images.add(_PendingImage(name: shot.name, bytes: bytes)));
    } catch (_) {
      if (mounted) WaitToast.destructive('选择图片失败');
    }
  }

  /// 模板档：面板让位给既有「模板选择 → 表单预填」链（与列表页长按加号同源）
  Future<void> _openTemplate() async {
    final projectId = _projectId;
    final quickView = widget.quickView;
    final bridge = ref.read(orbitBridgeProvider);
    Navigator.of(context).pop();
    await showTemplateCreateFlow(
      context,
      bridge,
      defaultProjectId: projectId,
      quickView: quickView,
    );
  }

  /// 全屏档：把当前草稿（标题/优先级/截止）带进完整新建表单做详细编辑
  Future<void> _openFullForm() async {
    final projectId = _projectId;
    final quickView = widget.quickView;
    final title = _titleController.text.trim();
    final priority = _priority;
    final dueOffsetDays = _dueOffsetDays(_dueDate);
    Navigator.of(context).pop();
    await showTodoFormSheet(
      context,
      defaultProjectId: projectId,
      quickView: quickView,
      presetTemplate: TemplatePayload(
        title: title.isEmpty ? null : title,
        priority: priority > 0 ? priority : null,
        dueOffsetDays: dueOffsetDays,
      ),
    );
  }

  /// 已选截止 → 距今天零点的天数（表单模板 payload 只认相对偏移；过去日期不回传）
  int? _dueOffsetDays(int? ms) {
    if (ms == null) return null;
    final days =
        ((ms - dateToMidnightMs(DateTime.now())) / Duration.millisecondsPerDay)
            .round();
    return days >= 0 ? days : null;
  }

  void _openSettings() {
    Navigator.of(context).pop();
    context.push('/settings/quick-actions');
  }

  /// 「更多」菜单：未启用档 + 固定「设置」入口（点选后菜单自关，回调内再处理面板）
  Future<void> _openMoreMenu(List<QuickActionId> hidden) async {
    await showMoreActionsSheet(
      context,
      title: '更多',
      actions: [
        for (final id in hidden)
          MoreActionItem(
            icon: quickActionIcon(id),
            label: id.label,
            onTap: () => _onAction(id),
          ),
        MoreActionItem(
          icon: OrbitIcons.settings,
          label: '设置',
          onTap: _openSettings,
        ),
      ],
    );
  }

  // ── 视图 ──

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final (enabled, hidden) = QuickActions.read();
    final projects = ref.watch(todoProjectsProvider).value ?? const <TodoProject>[];
    final project =
        _projectId == null ? null : projects.where((p) => p.id == _projectId).firstOrNull;
    final chips = _buildChips(colors, project);

    return OrbitSheetScaffold(
      showHandle: true,
      contentScrollable: false,
      maxHeightFactor: 0.7,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chips.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                AppDimens.space16,
                AppDimens.space4,
                AppDimens.space16,
                0,
              ),
              child: Row(children: chips),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              AppDimens.space12,
              AppDimens.space16,
              0,
            ),
            child: TextField(
              controller: _titleController,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              maxLength: 200,
              style: TextStyle(fontSize: 15, color: colors.bodyText),
              decoration: InputDecoration(
                hintText: '准备做什么？',
                counterText: '',
                border: InputBorder.none,
                isDense: true,
                hintStyle: TextStyle(fontSize: 15, color: colors.deactivatedText),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space8,
              AppDimens.space4,
              AppDimens.space12,
              AppDimens.space8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final id in enabled) _toolbarButton(id),
                        _moreButton(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppDimens.space8),
                _sendButton(colors),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 工具档按钮：已选中（有值）时着待办强调色，与列表勾选/图表同色系
  Widget _toolbarButton(QuickActionId id) {
    final colors = AppColors.ofContext(context);
    final active = _isActive(id);
    return IconButton(
      tooltip: id.label,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 42, height: 42),
      onPressed: () => _onAction(id),
      icon: Icon(
        quickActionIcon(id),
        size: AppDimens.iconSizeMd,
        color: active ? OrbitAccents.todoAccent : colors.iconText,
      ),
    );
  }

  Widget _moreButton() {
    final colors = AppColors.ofContext(context);
    return IconButton(
      tooltip: '更多',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 42, height: 42),
      onPressed: () {
        final (_, hidden) = QuickActions.read();
        _openMoreMenu(hidden);
      },
      icon: Icon(
        OrbitIcons.moreVertical,
        size: AppDimens.iconSizeMd,
        color: colors.iconText,
      ),
    );
  }

  Widget _sendButton(AppColorSet colors) {
    final canSend = _titleController.text.trim().isNotEmpty && !_saving;
    return SizedBox.square(
      dimension: 40,
      child: Material(
        color: canSend ? OrbitAccents.themeAccent : colors.surfaceSecondary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: canSend ? _submit : null,
          child: Center(
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    OrbitIcons.send,
                    size: AppDimens.iconSizeSm,
                    color: canSend ? Colors.white : colors.deactivatedText,
                  ),
          ),
        ),
      ),
    );
  }

  /// 档位是否「已选值」（仅影响着色，不影响可用性）
  bool _isActive(QuickActionId id) => switch (id) {
        QuickActionId.due => _dueDate != null,
        QuickActionId.priority => _priority > 0,
        QuickActionId.label => _labels.isNotEmpty,
        QuickActionId.project => _projectId != null,
        QuickActionId.image => _images.isNotEmpty,
        QuickActionId.template || QuickActionId.fullscreen => false,
      };

  /// 已选条件 chips（日期/优先级/清单/标签/图片数；点 x 逐项清除或清空）
  List<Widget> _buildChips(AppColorSet colors, TodoProject? project) {
    final chips = <Widget>[];
    if (_dueDate != null) {
      chips.add(_chip(
        colors,
        icon: OrbitIcons.calendar,
        label: formatYmd(_dueDate!),
        onClear: () => setState(() => _dueDate = null),
      ));
    }
    if (_priority > 0) {
      chips.add(_chip(
        colors,
        icon: OrbitIcons.flag,
        label: 'P$_priority ${priorityLabel(_priority)}',
        color: hexToColor(priorityColorHex(_priority)),
        onClear: () => setState(() => _priority = 0),
      ));
    }
    if (project != null) {
      chips.add(_chip(
        colors,
        icon: OrbitIcons.list,
        label: project.title,
        color: hexToColor(project.hexColor, fallback: colors.bodyText),
        onClear: () => setState(() => _projectId = null),
      ));
    }
    for (final label in _labels) {
      chips.add(_chip(
        colors,
        icon: OrbitIcons.tag,
        label: label.title,
        color: hexToColor(label.hexColor, fallback: colors.bodyText),
        onClear: () => setState(
            () => _labels = _labels.where((l) => l.id != label.id).toList()),
      ));
    }
    if (_images.isNotEmpty) {
      chips.add(_chip(
        colors,
        icon: OrbitIcons.image,
        label: '图片 ×${_images.length}',
        onClear: () => setState(() => _images.clear()),
      ));
    }
    return chips;
  }

  Widget _chip(
    AppColorSet colors, {
    required IconData icon,
    required String label,
    required VoidCallback onClear,
    Color? color,
  }) {
    final tone = color ?? colors.secondaryText;
    return Container(
      margin: const EdgeInsets.only(right: AppDimens.space6),
      padding: const EdgeInsets.only(left: AppDimens.space8, right: 2),
      decoration: BoxDecoration(
        borderRadius: AppShapes.full,
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: tone),
          const SizedBox(width: AppDimens.space4),
          Text(label, style: TextStyle(fontSize: 12, color: tone)),
          IconButton(
            tooltip: '清除',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            onPressed: onClear,
            icon: Icon(
              OrbitIcons.close,
              size: 12,
              color: colors.secondaryText,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标签多选抽屉：**本地勾选态**（任务尚未创建，不能像详情页那样勾选即落库），
/// 底部「确定」回填整份选中列表；取消返回 null（不动面板现有选择）。
Future<List<TodoLabel>?> _pickLabelsSheet(
  BuildContext context,
  List<TodoLabel> all,
  Set<int> selected,
) {
  final picked = Set<int>.of(selected);
  return showModalBottomSheet<List<TodoLabel>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.ofContext(context).popup,
    shape: bottomSheetTopShape,
    sheetAnimationStyle: bottomSheetMotion,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => OrbitSheetScaffold(
        title: '标签',
        contentScrollable: false,
        maxHeightFactor: 0.6,
        content: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: AppDimens.space8),
          itemCount: all.length,
          itemBuilder: (context, index) {
            final colors = AppColors.ofContext(context);
            final label = all[index];
            final checked = picked.contains(label.id);
            void toggle() => setSheetState(() {
                  checked ? picked.remove(label.id) : picked.add(label.id);
                });
            return InkWell(
              onTap: toggle,
              child: SizedBox(
                height: AppDimens.touchTarget,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.space16,
                  ),
                  child: Row(
                    children: [
                      CircleCheckbox(
                        checked: checked,
                        onToggle: toggle,
                        size: AppDimens.subtaskCheckboxSize,
                      ),
                      const SizedBox(width: AppDimens.space12),
                      Container(
                        width: AppDimens.colorDotSize,
                        height: AppDimens.colorDotSize,
                        decoration: BoxDecoration(
                          color: hexToColor(
                            label.hexColor,
                            fallback: OrbitAccents.todoAccent,
                          ),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: AppDimens.space8),
                      Expanded(
                        child: Text(
                          label.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, color: colors.bodyText),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        actions: OrbitSheetActions(
          confirmLabel: '确定',
          onConfirm: () => Navigator.of(sheetContext).pop(
            [for (final l in all) if (picked.contains(l.id)) l],
          ),
        ),
      ),
    ),
  );
}
