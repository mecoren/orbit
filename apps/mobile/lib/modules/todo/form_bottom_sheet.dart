import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';
import '../../data/providers/bridge_provider.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/wait_toast.dart';
import 'logic/task_logic.dart' show formatYmd, priorityColorHex, priorityLabel;
import 'providers/todo_providers.dart';

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
  final _formKey = GlobalKey<FormState>();

  int? _projectId;
  int _priority = 0;
  int? _dueDate;
  bool _saving = false;
  bool _loaded = false;
  String? _loadError;

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
    super.dispose();
  }

  /// 编辑态异步预填
  Future<void> _loadEditing(int taskId) async {
    try {
      final task = await ref.read(orbitBridgeProvider).todoTaskGet(taskId);
      if (!mounted) return;
      setState(() {
        _titleController.text = task.title;
        _descriptionController.text = task.description ?? '';
        _projectId = task.projectId;
        _priority = task.priority;
        _dueDate = task.dueDate;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = '记录不存在或加载失败');
    }
  }

  // ── 保存链：校验标题非空 → create/update → invalidate + 关闭 ──

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    try {
      final bridge = ref.read(orbitBridgeProvider);
      if (widget.editingTaskId == null) {
        await bridge.todoTaskCreate(TodoTaskCreateInput(
          title: title,
          description: description.isEmpty ? null : description,
          projectId: _projectId,
          priority: _priority,
          dueDate: _dueDate,
        ));
      } else {
        await bridge.todoTaskUpdate(
          widget.editingTaskId!,
          encodePatch({
            'title': title,
            'description': description.isEmpty ? null : description,
            'project_id': _projectId,
            'priority': _priority,
            'due_date': _dueDate,
          }),
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

  // ── 截止日期快捷项（本地时区自然日零点）──

  int _midnightOf(int offsetDays) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + offsetDays)
        .millisecondsSinceEpoch;
  }

  Future<void> _pickCustomDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(_dueDate!)
          : DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(
        () => _dueDate = DateTime(picked.year, picked.month, picked.day)
            .millisecondsSinceEpoch,
      );
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
                                    child: Row(
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
                                        Flexible(
                                          child: Text(
                                            project.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
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
                            // 5. 截止日期（今天/明天/下周/自定义 + 清除）
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '截止日期',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.secondaryText,
                                ),
                              ),
                            ),
                            const SizedBox(height: AppDimens.space8),
                            Wrap(
                              spacing: AppDimens.space8,
                              runSpacing: AppDimens.space8,
                              children: [
                                for (final (label, days) in const [
                                  ('今天', 0),
                                  ('明天', 1),
                                  ('下周', 7),
                                ])
                                  ActionChip(
                                    label: Text(label),
                                    side: BorderSide(
                                      color:
                                          colors.divider.withValues(alpha: 0.3),
                                    ),
                                    onPressed: () => setState(
                                        () => _dueDate = _midnightOf(days)),
                                  ),
                                ActionChip(
                                  label: const Text('自定义'),
                                  side: BorderSide(
                                    color: colors.divider.withValues(alpha: 0.3),
                                  ),
                                  onPressed: _pickCustomDate,
                                ),
                                if (_dueDate != null)
                                  ActionChip(
                                    label: Text(formatYmd(_dueDate!)),
                                    avatar: Icon(
                                      Icons.close_rounded,
                                      size: AppDimens.iconSizeSm,
                                      color: colors.secondaryText,
                                    ),
                                    side: BorderSide(
                                      color:
                                          colors.divider.withValues(alpha: 0.3),
                                    ),
                                    onPressed: () =>
                                        setState(() => _dueDate = null),
                                  ),
                              ],
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
