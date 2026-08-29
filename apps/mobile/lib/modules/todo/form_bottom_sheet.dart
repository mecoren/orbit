import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/api/orbit_bridge.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/wait_date_picker.dart';
import '../../shared/widgets/wait_toast.dart';
// as rep：规避 Flutter widgets 自带 RepeatMode 类名冲突
import 'logic/repeat_logic.dart' as rep;
import 'logic/task_logic.dart'
    show
        dateToMidnightMs,
        formatDateTime,
        formatYmd,
        priorityColorHex,
        priorityLabel;
import 'providers/todo_providers.dart';

/// 截止日期选择器（表单抽屉"自定义"与详情页截止日期行共用）
///
/// 已切换为 wait-home 移植的 WaitDatePicker 底部面板（月历 + 年月/年视图），
/// 函数签名保持不变，detail_screen 等调用方自动跟随。
Future<DateTime?> showTodoDatePicker(
  BuildContext context, {
  DateTime? initialDate,
}) {
  return WaitDatePicker.pick(
    context,
    initialDate: initialDate,
    accent: OrbitAccents.todoAccent,
  );
}

/// 新建/编辑待办底部抽屉（docs/05 §4.4 简化版，移动端任务书口径）
///
/// 字段顺序：标题* → 描述 → 项目下拉 → 优先级六档横排色点 → 截止日期
/// （今天/明天/下周/自定义）。保存调 create/update 后 invalidate 相关 provider。
///
/// 用法：`await showTodoFormSheet(context, editingTaskId: id, defaultProjectId: pid);`
Future<void> showTodoFormSheet(
  BuildContext context, {
  int? editingTaskId,
  int? defaultProjectId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _TodoFormSheet(
      editingTaskId: editingTaskId,
      defaultProjectId: defaultProjectId,
    ),
  );
}

/// 提醒同步（桌面端 task-form-sheet 同语义）：
/// - 清空（remindAt=null）→ 删旧提醒；
/// - 变更 → 删旧建新；
/// - 未动（同值）→ 跳过。
/// 新建场景 existing 传 null：有值即建立。
Future<void> syncTaskReminder(
  OrbitBridge bridge,
  int taskId,
  int? remindAt,
  TodoReminder? existing,
) async {
  if (remindAt == null) {
    if (existing != null) await bridge.todoReminderDelete(existing.id);
    return;
  }
  if (existing != null && existing.remindAt == remindAt) return;
  if (existing != null) await bridge.todoReminderDelete(existing.id);
  await bridge.todoReminderCreate(
    TodoReminderCreateInput(taskId: taskId, remindAt: remindAt),
  );
}

class _TodoFormSheet extends ConsumerStatefulWidget {
  const _TodoFormSheet({this.editingTaskId, this.defaultProjectId});

  /// 有值 = 编辑态（异步预填 todoTaskGet）
  final int? editingTaskId;

  /// 新建态默认归属项目（子列表项目入口携入）
  final int? defaultProjectId;

  @override
  ConsumerState<_TodoFormSheet> createState() => _TodoFormSheetState();
}

class _TodoFormSheetState extends ConsumerState<_TodoFormSheet> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _colorController = TextEditingController();
  final _intervalController = TextEditingController(text: '1');
  final _formKey = GlobalKey<FormState>();

  int? _projectId;
  int _priority = 0;
  int? _dueDate;
  String _status = 'pending';
  int? _startDate;
  int? _endDate;
  int? _remindAt;
  TodoReminder? _existingReminder;
  int _repeatMode = rep.RepeatMode.none;
  int _repeatAfter = 1;
  bool _customRepeat = false;
  rep.RepeatUnit _customUnit = rep.RepeatUnit.day;
  bool _saving = false;
  bool _loaded = false;
  String? _loadError;

  /// 自定义档位派生 mode：单位 → repeat_mode
  int get _effectiveRepeatMode =>
      _customRepeat ? rep.modeForUnit(_customUnit) : _repeatMode;

  /// 自定义档位派生 after：间隔输入（解析失败按 1 兜底）
  int get _effectiveRepeatAfter => _customRepeat
      ? (int.tryParse(_intervalController.text.trim()) ?? 1)
      : _repeatAfter;

  @override
  void initState() {
    super.initState();
    _projectId = widget.defaultProjectId;
    if (widget.editingTaskId != null) {
      _loadEditing(widget.editingTaskId!);
    } else {
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _colorController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  /// 编辑态异步预填（含提醒：取该任务第一条未删除提醒）
  Future<void> _loadEditing(int taskId) async {
    try {
      final bridge = ref.read(orbitBridgeProvider);
      final task = await bridge.todoTaskGet(taskId);
      // 提醒为独立实体，列表拉取后按 task_id 过滤（与桌面端一致）
      final reminders = await bridge.todoReminderList(const ListFilter());
      final firstReminder = reminders
          .where((r) => r.taskId == taskId && r.isDeleted == 0)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _titleController.text = task.title;
        _descriptionController.text = task.description ?? '';
        _projectId = task.projectId;
        _priority = task.priority;
        _dueDate = task.dueDate;
        _status = task.status;
        _startDate = task.startDate;
        _endDate = task.endDate;
        _colorController.text = task.hexColor;
        _repeatMode = task.repeatMode;
        _repeatAfter = task.repeatAfter;
        _existingReminder = firstReminder;
        _remindAt = firstReminder?.remindAt;
        // 非预设组合（如"每 3 天"）→ 进自定义态并回填间隔/单位
        final isPreset = rep.repeatPresets.any((p) =>
            p.mode == task.repeatMode &&
            (p.mode == rep.RepeatMode.none || task.repeatAfter == p.after));
        _customRepeat =
            task.repeatMode != rep.RepeatMode.none && !isPreset;
        _customUnit = _unitForMode(task.repeatMode);
        _intervalController.text = '${task.repeatAfter <= 0 ? 1 : task.repeatAfter}';
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = '记录不存在或加载失败');
    }
  }

  /// repeat_mode → 自定义单位（编辑回填用；不重复归到"天"占位）
  rep.RepeatUnit _unitForMode(int mode) => switch (mode) {
        rep.RepeatMode.weekly => rep.RepeatUnit.week,
        rep.RepeatMode.monthly => rep.RepeatUnit.month,
        rep.RepeatMode.yearly => rep.RepeatUnit.year,
        _ => rep.RepeatUnit.day,
      };

  // ── 保存链：校验标题非空 → create/update → invalidate + 关闭 ──

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    // 颜色：空=不设置；正则已在 TextFormField validator 拦截非法值
    final hexColor = _colorController.text.trim();
    final repeatMode = _effectiveRepeatMode;
    final repeatAfter = _effectiveRepeatAfter;
    try {
      final bridge = ref.read(orbitBridgeProvider);
      if (widget.editingTaskId == null) {
        final created = await bridge.todoTaskCreate(TodoTaskCreateInput(
          title: title,
          description: description.isEmpty ? null : description,
          projectId: _projectId,
          priority: _priority,
          status: _status,
          dueDate: _dueDate,
          startDate: _startDate,
          endDate: _endDate,
          repeatMode: repeatMode,
          repeatAfter: repeatAfter,
          hexColor: hexColor.isEmpty ? null : hexColor,
        ));
        // 新建：设置提醒 → 建立提醒实体
        if (_remindAt != null) {
          await syncTaskReminder(bridge, created.id, _remindAt, null);
        }
      } else {
        await bridge.todoTaskUpdate(
          widget.editingTaskId!,
          encodePatch({
            'title': title,
            'description': description.isEmpty ? null : description,
            'project_id': _projectId,
            'priority': _priority,
            'status': _status,
            'due_date': _dueDate,
            'start_date': _startDate,
            'end_date': _endDate,
            'repeat_mode': repeatMode,
            'repeat_after': repeatAfter,
            'hex_color': hexColor.isEmpty ? null : hexColor,
          }),
        );
        // 编辑：提醒按"清空删/变更删旧建新/未动跳过"同步
        await syncTaskReminder(
          bridge,
          widget.editingTaskId!,
          _remindAt,
          _existingReminder,
        );
      }
      ref.invalidate(todoTasksProvider);
      ref.invalidate(taskDetailProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      WaitToast.destructive('保存失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── 新字段选择器 ──

  /// 日期字段选择（开始/结束日期共用：取自然日零点毫秒）
  Future<void> _pickDateField({
    required int? current,
    required ValueChanged<int> onPicked,
  }) async {
    final picked = await showTodoDatePicker(
      context,
      initialDate: current != null
          ? DateTime.fromMillisecondsSinceEpoch(current)
          : null,
    );
    if (picked != null && mounted) onPicked(dateToMidnightMs(picked));
  }

  /// 提醒时间选择：wait 面板 showTime 模式，日期+时分单面板一次选完
  Future<void> _pickReminder() async {
    final picked = await WaitDatePicker.pick(
      context,
      initialDate: _remindAt != null
          ? DateTime.fromMillisecondsSinceEpoch(_remindAt!)
          : null,
      showTime: true,
      accent: OrbitAccents.todoAccent,
    );
    // null = 取消或面板内清除；取消不动值，清空走字段行叉号（语义与桌面一致）
    if (picked == null || !mounted) return;
    setState(() => _remindAt = picked.millisecondsSinceEpoch);
  }

  /// 字段小节标题（与优先级/截止日期小节同规格：12px secondary）
  Widget _sectionLabel(String text) {
    final colors = AppColors.ofContext(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: colors.secondaryText),
      ),
    );
  }

  /// 行间分隔线（日期与提醒卡片内）
  Widget _tileDivider(AppColorSet colors) => Container(
        height: 0.5,
        color: colors.divider.withValues(alpha: 0.3),
      );

  // ── 截止日期快捷项（本地时区自然日零点）──

  int _midnightOf(int offsetDays) {
    final now = DateTime.now();
    return dateToMidnightMs(DateTime(now.year, now.month, now.day + offsetDays));
  }

  Future<void> _pickCustomDate() async {
    final picked = await showTodoDatePicker(
      context,
      initialDate: _dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(_dueDate!)
          : null,
    );
    if (picked != null && mounted) {
      setState(() => _dueDate = dateToMidnightMs(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final projects = ref.watch(todoProjectsProvider).value ?? [];
    final isEdit = widget.editingTaskId != null;

    // 键盘避让：底部 padding 跟随 viewInsets
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        decoration: BoxDecoration(
          color: colors.popup,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: !_loaded
              ? (_loadError != null ? _errorView(colors) : _loadingView())
              : Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 标题行：添加待办/编辑待办 + 保存钮
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppDimens.space16,
                          AppDimens.space12,
                          AppDimens.space8,
                          0,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isEdit ? '编辑待办' : '添加待办',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: colors.titleText,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: _saving
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: OrbitAccents.themeAccent,
                                      ),
                                    )
                                  : Icon(
                                      Icons.check_rounded,
                                      size: AppDimens.iconSizeLg,
                                      color: OrbitAccents.todoAccent,
                                    ),
                              onPressed: _saving ? null : _save,
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(
                            AppDimens.space16,
                            AppDimens.space8,
                            AppDimens.space16,
                            AppDimens.gestureInsetFallback / 2,
                          ),
                          children: [
                            // 1. 标题*
                            TextFormField(
                              controller: _titleController,
                              maxLength: 200,
                              style: TextStyle(
                                  fontSize: 15, color: colors.bodyText),
                              decoration: const InputDecoration(
                                labelText: '标题 *',
                                hintText: '请输入标题',
                                counterText: '',
                              ),
                              validator: (v) =>
                                  v == null || v.trim().isEmpty ? '请输入标题' : null,
                            ),
                            const SizedBox(height: AppDimens.space12),
                            // 2. 描述
                            TextFormField(
                              controller: _descriptionController,
                              maxLines: 3,
                              maxLength: 2000,
                              style: TextStyle(
                                  fontSize: 15, color: colors.bodyText),
                              decoration: const InputDecoration(
                                labelText: '描述',
                                hintText: '请输入描述',
                                alignLabelWithHint: true,
                                counterText: '',
                              ),
                            ),
                            const SizedBox(height: AppDimens.space12),
                            // 3. 项目下拉（ListFilter 拉取数据生成选项）
                            DropdownButtonFormField<String>(
                              initialValue: _projectId == null ? '' : '$_projectId',
                              style: TextStyle(
                                  fontSize: 15, color: colors.bodyText),
                              dropdownColor: colors.popup,
                              decoration: const InputDecoration(labelText: '项目'),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('无项目'),
                                ),
                                for (final project in projects)
                                  DropdownMenuItem(
                                    value: '${project.id}',
                                    // 注意：菜单项 child 禁用 Flexible/Expanded——
                                    // DropdownButtonFormField 构建时会以无界宽度
                                    // 预量每个菜单项（弹层定宽），flex 子件遇无界
                                    // 宽度约束会抛断言导致抽屉布局崩溃。
                                    // mainAxisSize.min + 普通文本在无界下取固有
                                    // 宽度、有界下仍可 ellipsis，两端皆安全。
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: AppDimens.colorDotSize,
                                          height: AppDimens.colorDotSize,
                                          decoration: BoxDecoration(
                                            color: hexToColor(project.hexColor,
                                                fallback:
                                                    OrbitAccents.todoAccent),
                                            borderRadius: AppShapes.of(4),
                                          ),
                                        ),
                                        const SizedBox(width: AppDimens.space8),
                                        Text(
                                          project.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                              onChanged: (v) => setState(() => _projectId =
                                  v == null || v.isEmpty ? null : int.parse(v)),
                            ),
                            const SizedBox(height: AppDimens.space16),
                            // 4. 优先级六档横排色点
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '优先级',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.secondaryText,
                                ),
                              ),
                            ),
                            const SizedBox(height: AppDimens.space8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                for (var i = 0; i <= 5; i++)
                                  _PriorityDot(
                                    index: i,
                                    selected: _priority == i,
                                    onTap: () => setState(() => _priority = i),
                                  ),
                              ],
                            ),
                            const SizedBox(height: AppDimens.space16),
                            // 5. 状态（三档单选，默认待办）
                            _sectionLabel('状态'),
                            const SizedBox(height: AppDimens.space8),
                            Wrap(
                              spacing: AppDimens.space8,
                              runSpacing: AppDimens.space8,
                              children: [
                                for (final (label, value) in const [
                                  ('待办', 'pending'),
                                  ('进行中', 'doing'),
                                  ('已完成', 'done'),
                                ])
                                  ChoiceChip(
                                    label: Text(label),
                                    selected: _status == value,
                                    onSelected: (_) =>
                                        setState(() => _status = value),
                                  ),
                              ],
                            ),
                            const SizedBox(height: AppDimens.space16),
                            // 6-9. 日期与提醒（卡片信息行：与详情页 _InfoTile 同设计语言）
                            SectionCard(
                              title: '日期与提醒',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // 截止日期：未设 → 行内快捷胶囊；已设 → 值 + 清除
                                  _FormDateTile(
                                    icon: Icons.flag_outlined,
                                    label: '截止日期',
                                    value: _dueDate != null
                                        ? formatYmd(_dueDate!)
                                        : null,
                                    onTap: _pickCustomDate,
                                    onClear: _dueDate == null
                                        ? null
                                        : () =>
                                            setState(() => _dueDate = null),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _QuickCapsule(
                                            label: '今天',
                                            onTap: () => setState(
                                                () => _dueDate = _midnightOf(0))),
                                        const SizedBox(width: 6),
                                        _QuickCapsule(
                                            label: '明天',
                                            onTap: () => setState(
                                                () => _dueDate = _midnightOf(1))),
                                        const SizedBox(width: 6),
                                        _QuickCapsule(
                                            label: '下周',
                                            onTap: () => setState(
                                                () => _dueDate = _midnightOf(7))),
                                      ],
                                    ),
                                  ),
                                  _tileDivider(colors),
                                  _FormDateTile(
                                    icon: Icons.play_circle_outline_rounded,
                                    label: '开始日期',
                                    value: _startDate != null
                                        ? formatYmd(_startDate!)
                                        : null,
                                    onTap: () => _pickDateField(
                                      current: _startDate,
                                      onPicked: (ms) =>
                                          setState(() => _startDate = ms),
                                    ),
                                    onClear: _startDate == null
                                        ? null
                                        : () =>
                                            setState(() => _startDate = null),
                                  ),
                                  _tileDivider(colors),
                                  _FormDateTile(
                                    icon: Icons.stop_circle_outlined,
                                    label: '结束日期',
                                    value: _endDate != null
                                        ? formatYmd(_endDate!)
                                        : null,
                                    onTap: () => _pickDateField(
                                      current: _endDate,
                                      onPicked: (ms) =>
                                          setState(() => _endDate = ms),
                                    ),
                                    onClear: _endDate == null
                                        ? null
                                        : () =>
                                            setState(() => _endDate = null),
                                  ),
                                  _tileDivider(colors),
                                  // 提醒时间（虚拟字段：提交时同步 todo_reminders）
                                  _FormDateTile(
                                    icon: Icons.notifications_outlined,
                                    label: '提醒时间',
                                    value: _remindAt != null
                                        ? formatDateTime(_remindAt!)
                                        : null,
                                    onTap: _pickReminder,
                                    onClear: _remindAt == null
                                        ? null
                                        : () =>
                                            setState(() => _remindAt = null),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppDimens.space16),
                            // 10. 重复规则（预设 + 自定义 N×单位）
                            _sectionLabel('重复'),
                            const SizedBox(height: AppDimens.space8),
                            Wrap(
                              spacing: AppDimens.space8,
                              runSpacing: AppDimens.space8,
                              children: [
                                for (final preset in rep.repeatPresets)
                                  ChoiceChip(
                                    label: Text(preset.label),
                                    // 预设选中态：非自定义且 mode/after 与预设一致
                                    selected: !_customRepeat &&
                                        preset.mode == _repeatMode &&
                                        (preset.mode ==
                                                rep.RepeatMode.none ||
                                            _repeatAfter == preset.after),
                                    onSelected: (_) => setState(() {
                                      _customRepeat = false;
                                      _repeatMode = preset.mode;
                                      _repeatAfter = preset.after;
                                    }),
                                  ),
                                ChoiceChip(
                                  label: const Text('自定义'),
                                  selected: _customRepeat,
                                  onSelected: (_) =>
                                      setState(() => _customRepeat = true),
                                ),
                              ],
                            ),
                            if (_customRepeat) ...[
                              const SizedBox(height: AppDimens.space8),
                              Wrap(
                                spacing: AppDimens.space8,
                                runSpacing: AppDimens.space8,
                                children: [
                                  SizedBox(
                                    width: 88,
                                    child: TextFormField(
                                      controller: _intervalController,
                                      keyboardType: TextInputType.number,
                                      style: TextStyle(
                                          fontSize: 15,
                                          color: colors.bodyText),
                                      decoration: const InputDecoration(
                                        labelText: '间隔',
                                        counterText: '',
                                      ),
                                    ),
                                  ),
                                  for (final unit in rep.RepeatUnit.values)
                                    ChoiceChip(
                                      label: Text(unit.label),
                                      selected: _customUnit == unit,
                                      onSelected: (_) =>
                                          setState(() => _customUnit = unit),
                                    ),
                                ],
                              ),
                            ],
                            const SizedBox(height: AppDimens.space16),
                            // 11. 颜色（#RRGGBB 文本 + 正则校验，桌面 MVP 同口径）
                            TextFormField(
                              controller: _colorController,
                              maxLength: 7,
                              style: TextStyle(
                                  fontSize: 15, color: colors.bodyText),
                              decoration: const InputDecoration(
                                labelText: '颜色',
                                hintText: '#3B82F6',
                                counterText: '',
                              ),
                              validator: (v) {
                                final t = v?.trim() ?? '';
                                if (t.isEmpty) return null;
                                return RegExp(r'^#[0-9a-fA-F]{6}$')
                                        .hasMatch(t)
                                    ? null
                                    : '格式应为 #RRGGBB';
                              },
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
  }

  Widget _loadingView() => const Padding(
        padding: EdgeInsets.all(AppDimens.space32),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child:
                CircularProgressIndicator(color: OrbitAccents.themeAccent),
          ),
        ),
      );

  Widget _errorView(AppColorSet colors) => Padding(
        padding: const EdgeInsets.all(AppDimens.space32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              style: TextStyle(fontSize: 14, color: colors.secondaryText),
            ),
            const SizedBox(height: AppDimens.space16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回'),
            ),
          ],
        ),
      );
}

/// 日期/提醒信息行（与详情页 _InfoTile 同设计语言，表单版）
///
/// 结构：图标 + 标签 → Spacer → 值区（已设：值+清除叉；未设：trailing
/// 快捷胶囊或「无」占位）→ 尾箭头。整行可点唤起选择面板。
class _FormDateTile extends StatelessWidget {
  const _FormDateTile({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.onClear,
    this.trailing,
  });

  final IconData icon;

  /// 行标签（截止日期/开始日期/结束日期/提醒时间）
  final String label;

  /// 已设值文本；null = 未设（显示 trailing 或「无」占位）
  final String? value;

  final VoidCallback? onTap;

  /// 已设值的清除回调；null 不渲染清除叉
  final VoidCallback? onClear;

  /// 未设值时的行内快捷胶囊组（仅截止日期行使用）
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final hasValue = value != null;

    final row = Row(
      children: [
        Icon(icon,
            size: AppDimens.iconSizeSm + 2, color: colors.secondaryText),
        const SizedBox(width: AppDimens.space12),
        Text(label, style: TextStyle(fontSize: 14, color: colors.bodyText)),
        const Spacer(),
        if (!hasValue && trailing != null)
          trailing!
        else if (!hasValue)
          Text(
            '无',
            style: TextStyle(
              fontSize: 14,
              color: colors.secondaryText.withValues(alpha: 0.5),
            ),
          ),
        if (hasValue) ...[
          Flexible(
            child: Text(
              value!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: colors.bodyText),
            ),
          ),
          if (onClear != null) ...[
            const SizedBox(width: AppDimens.space8),
            GestureDetector(
              onTap: onClear,
              child: Icon(
                Icons.close_rounded,
                size: AppDimens.iconSizeSm,
                color: colors.secondaryText,
              ),
            ),
          ],
        ],
        if (onTap != null) ...[
          const SizedBox(width: AppDimens.space4),
          Icon(
            Icons.keyboard_arrow_right_rounded,
            size: AppDimens.iconSizeSm + 2,
            color: colors.secondaryText,
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space12),
      child: onTap == null
          ? row
          : InkWell(
              borderRadius: AppShapes.small,
              onTap: onTap,
              child: row,
            ),
    );
  }
}

/// 行内快捷胶囊（截止日期未设时：今天/明天/下周，点选即设）
class _QuickCapsule extends StatelessWidget {
  const _QuickCapsule({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: AppShapes.full,
          border: Border.all(color: colors.divider.withValues(alpha: 0.4))),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: colors.secondaryText),
        ),
      ),
    );
  }
}

/// 优先级色点（32px 圆；P0 无色用灰描边占位，选中 3px accent 环）
class _PriorityDot extends StatelessWidget {
  const _PriorityDot({
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final hex = priorityColorHex(index);
    return Tooltip(
      message: 'P$index ${priorityLabel(index)}',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hex.isEmpty ? Colors.transparent : hexToColor(hex),
            border: Border.all(
              width: selected ? 3 : 1,
              color: selected
                  ? OrbitAccents.themeAccent
                  : hex.isEmpty
                      ? colors.divider.withValues(alpha: 0.6)
                      : Colors.transparent,
            ),
          ),
          child: hex.isEmpty
              ? Icon(Icons.block_rounded,
                  size: AppDimens.iconSizeSm, color: colors.secondaryText)
              : null,
        ),
      ),
    );
  }
}
